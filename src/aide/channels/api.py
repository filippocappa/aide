"""HTTP API for the iOS app. The contract is docs/API.md; keep the two in step."""

import asyncio
import hmac
import logging
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import anthropic
from fastapi import Body, Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from ..agent import CONVERSATION, Agent, UnknownConversation
from ..agents import AGENTS, check_agent
from ..db import Database
from ..digest import DigestService, check_kind
from ..habits import HabitStore
from ..health import HealthStore, workout_date, workout_minutes
from ..icloud import CalendarBackend
from ..push import Push
from ..reminders import ReminderStore
from ..shapes import event_json, event_start, reminder_json
from ..wake import WakeService

log = logging.getLogger(__name__)

VERSION = "0.2.0"


class ChatIn(BaseModel):
    text: str
    conversation_id: str | None = None  # None: the conversation shared with Discord


class ConversationIn(BaseModel):
    conversation_id: str | None = None


class NewConversationIn(BaseModel):
    agent: str = "aide"
    digest: str | None = None  # start the chat with this digest's greeting (and make it Aide's)


class MemoryIn(BaseModel):
    text: str
    agent: str | None = None  # None: shared


class Cadence(BaseModel):
    type: str = "daily"
    per_week: int | None = None


class HabitIn(BaseModel):
    name: str
    cadence: Cadence = Cadence()
    workouts: list[str] = []


class HabitPatch(BaseModel):
    name: str | None = None
    cadence: Cadence | None = None
    workouts: list[str] | None = None


class HealthDaysIn(BaseModel):
    days: list[dict]


class WakeIn(BaseModel):
    at: datetime | None = None
    source: str = "app"
    day: dict | None = None


class CheckIn(BaseModel):
    day: date | None = Field(None, alias="date")  # a field named `date` would shadow the type
    done: bool = True


class DigestRunIn(BaseModel):
    kind: str = "daily"


class ReminderChange(BaseModel):
    id: str | None = None
    apple_id: str | None = None
    title: str
    notes: str = ""
    due_at: str | None = None
    completed: bool = False
    modified_at: str
    deleted: bool = False


class DeviceIn(BaseModel):
    token: str
    environment: str
    name: str = ""


class SyncIn(BaseModel):
    cursor: str | None = None
    changes: list[ReminderChange] = []


def create_app(agent: Agent, store: ReminderStore, calendar: CalendarBackend | None,
               tz: ZoneInfo, token: str, habits: HabitStore | None = None,
               digest: DigestService | None = None, push: Push | None = None,
               health: HealthStore | None = None, wake: WakeService | None = None) -> FastAPI:
    db: Database = agent.db
    push = push or Push(db.conn)  # no key: devices are kept, nothing is sent
    habits = habits or HabitStore(db.conn, tz)
    health = health or HealthStore(db.conn, tz)
    digest = digest or DigestService(db.conn, agent.client, agent.model, tz, store, habits, calendar, health=health)
    wake = wake or WakeService(digest, health, tz, push=push)
    app = FastAPI(title="Aide", version=VERSION, docs_url=None, redoc_url=None)

    def auth(authorization: str = Header(default="")) -> None:
        scheme, _, given = authorization.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(given.encode(), token.encode()):
            raise HTTPException(401, "missing or wrong token")

    @app.exception_handler(HTTPException)
    async def http_error(_: Request, exc: HTTPException):
        return JSONResponse({"error": exc.detail}, status_code=exc.status_code)

    @app.exception_handler(anthropic.APIError)
    async def upstream_error(_: Request, exc: anthropic.APIError):
        log.error("Claude API error: %s", exc)
        return JSONResponse({"error": "The assistant is unavailable right now. Try again."}, status_code=502)

    @app.exception_handler(UnknownConversation)
    async def unknown_conversation(_: Request, exc: UnknownConversation):
        return JSONResponse({"error": str(exc)}, status_code=404)

    @app.exception_handler(RequestValidationError)
    async def bad_body(_: Request, exc: RequestValidationError):
        first = exc.errors()[0] if exc.errors() else {}
        where = ".".join(str(p) for p in first.get("loc", ())[1:])
        return JSONResponse({"error": f"{where}: {first.get('msg', 'invalid')}" if where else "bad request body"},
                            status_code=400)

    @app.exception_handler(ValueError)
    async def bad_value(_: Request, exc: ValueError):
        return JSONResponse({"error": str(exc)}, status_code=400)

    def pending() -> list[dict]:
        return agent.pending_with_ids(CONVERSATION)

    def local(utc_iso: str) -> str:
        return datetime.fromisoformat(utc_iso).astimezone(tz).replace(microsecond=0).isoformat()

    def conversation_json(c: dict) -> dict:
        return {"id": c["id"], "agent": c["agent"], "title": c["title"], "preview": c["preview"],
                "updated_at": local(c["updated_at"])}

    def memory_json(m) -> dict:
        return {"id": m["id"], "text": m["text"], "agent": m["agent"], "created_at": local(m["created_at"])}

    @app.get("/v1/health")
    async def alive():
        return {"ok": True, "version": VERSION}

    @app.post("/v1/chat", dependencies=[Depends(auth)])
    async def chat(body: ChatIn):
        text = body.text.strip()
        if not text:
            raise HTTPException(400, "text is empty")
        conversation = body.conversation_id or CONVERSATION
        reply, attachments, consulted = await agent.respond(CONVERSATION, text, conversation)
        return {"reply": reply, "pending": pending(), "conversation_id": conversation, "attachments": attachments,
                "consulted": consulted}

    @app.post("/v1/confirm", dependencies=[Depends(auth)])
    async def confirm():
        return {"result": await agent.confirm(CONVERSATION), "pending": pending()}

    @app.post("/v1/cancel", dependencies=[Depends(auth)])
    async def cancel():
        return {"result": await agent.cancel(CONVERSATION), "pending": pending()}

    @app.post("/v1/new", dependencies=[Depends(auth)])
    async def new():
        agent.reset(CONVERSATION)
        return {"ok": True}

    @app.post("/v1/think", dependencies=[Depends(auth)])
    async def think(body: ConversationIn | None = None):
        agent.think(CONVERSATION, body.conversation_id if body else None)
        return {"ok": True}

    @app.get("/v1/history", dependencies=[Depends(auth)])
    async def history(limit: int = 50, conversation_id: str | None = None):
        messages = agent.visible_history(CONVERSATION, max(1, min(limit, 500)), conversation_id)
        for m in messages:  # reminders as they are now, so a reload shows ticks made since
            for a in m["attachments"]:
                if a["type"] == "reminders":
                    a["reminders"] = [reminder_json(r, tz) if (r := store.get(old["id"])) else old
                                      for old in a["reminders"]]
        return {"messages": messages}

    @app.get("/v1/conversations", dependencies=[Depends(auth)])
    async def conversations():
        return {"conversations": [conversation_json(c) for c in agent.conversations(CONVERSATION)]}

    @app.post("/v1/conversations", dependencies=[Depends(auth)])
    async def new_conversation(body: NewConversationIn | None = None):
        body = body or NewConversationIn()
        if body.digest:  # the chat is Aide's: agent is ignored
            return conversation_json(agent.new_conversation(await digest.opening(check_kind(body.digest))))
        return conversation_json(agent.new_conversation(agent=check_agent(body.agent)))

    @app.get("/v1/agents", dependencies=[Depends(auth)])
    async def agents():
        return {"agents": [a.as_json() for a in AGENTS.values()]}

    @app.delete("/v1/conversations/{conversation_id}", dependencies=[Depends(auth)])
    async def delete_conversation(conversation_id: str):
        agent.delete_conversation(CONVERSATION, conversation_id)
        return {"ok": True}

    @app.get("/v1/memory", dependencies=[Depends(auth)])
    async def memory():
        return {"items": [memory_json(m) for m in db.memories()]}

    @app.post("/v1/memory", dependencies=[Depends(auth)])
    async def add_memory(body: MemoryIn):
        text = " ".join(body.text.split())
        if not text:
            raise HTTPException(400, "text is empty")
        return memory_json(db.add_memory(text, check_agent(body.agent) if body.agent is not None else None))

    @app.delete("/v1/memory/{memory_id}", dependencies=[Depends(auth)])
    async def delete_memory(memory_id: int):
        if not db.delete_memory(memory_id):
            raise HTTPException(404, f"no memory {memory_id}")
        return {"ok": True}

    @app.get("/v1/habits", dependencies=[Depends(auth)])
    async def list_habits():
        return {"habits": [h.as_json() for h in habits.all()]}

    def per_week(cadence: Cadence) -> int | None:
        if cadence.type not in ("daily", "weekly"):
            raise HTTPException(400, "cadence type must be daily or weekly")
        if cadence.type == "weekly" and cadence.per_week is None:
            raise HTTPException(400, "a weekly habit needs per_week")
        return cadence.per_week if cadence.type == "weekly" else None

    @app.post("/v1/habits", dependencies=[Depends(auth)])
    async def add_habit(body: HabitIn):
        return habits.add(body.name, per_week(body.cadence), body.workouts).as_json()

    @app.patch("/v1/habits/{habit_id}", dependencies=[Depends(auth)])
    async def edit_habit(habit_id: int, body: HabitPatch):
        if habits.get(habit_id) is None:
            raise HTTPException(404, f"no habit {habit_id}")
        changes = body.model_dump(exclude_unset=True, exclude={"cadence"})
        if body.cadence is not None:
            changes["per_week"] = per_week(body.cadence)
        return habits.update(habit_id, **{k: v for k, v in changes.items() if v is not None or k == "per_week"}).as_json()

    @app.post("/v1/habits/{habit_id}/check", dependencies=[Depends(auth)])
    async def check_habit(habit_id: int, body: CheckIn | None = None):
        body = body or CheckIn()
        if habits.get(habit_id) is None:
            raise HTTPException(404, f"no habit {habit_id}")
        return habits.check(habit_id, body.day, body.done).as_json()

    @app.delete("/v1/habits/{habit_id}", dependencies=[Depends(auth)])
    async def delete_habit(habit_id: int):
        if not habits.delete(habit_id):
            raise HTTPException(404, f"no habit {habit_id}")
        return {"ok": True}

    @app.get("/v1/digest", dependencies=[Depends(auth)])
    async def latest_digest(kind: str = "daily"):
        found = await digest.view(check_kind(kind))
        if found is None:
            raise HTTPException(404, f"no {kind} digest yet")
        return found

    @app.post("/v1/digest/run", dependencies=[Depends(auth)])
    async def run_digest(body: DigestRunIn | None = None):
        return await digest.generate(check_kind((body or DigestRunIn()).kind))

    @app.get("/v1/digest/settings", dependencies=[Depends(auth)])
    async def digest_settings():
        return digest.settings()

    @app.put("/v1/digest/settings", dependencies=[Depends(auth)])
    async def save_digest_settings(body: dict = Body(...)):
        return digest.save_settings(body)

    @app.get("/v1/today", dependencies=[Depends(auth)])
    async def today(date: date | None = None):  # noqa: A002 - matches the query parameter
        day = date or datetime.now(tz).date()
        start = datetime.combine(day, time.min, tz)
        end = start + timedelta(days=1)
        events = []
        if calendar is not None:
            try:
                found = await asyncio.to_thread(calendar.events, start, end)
            except Exception:
                log.exception("calendar lookup failed")
                raise HTTPException(502, "iCloud Calendar is unavailable right now")
            events = [event_json(e, tz) for e in sorted(found, key=lambda e: event_start(e, tz))]
        return {"date": day.isoformat(), "events": events,
                "reminders": [reminder_json(r, tz) for r in store.due_before(end)]}

    @app.post("/v1/reminders/sync", dependencies=[Depends(auth)])
    async def sync(body: SyncIn):
        try:
            cursor = int(body.cursor) if body.cursor else None
        except ValueError:
            raise HTTPException(400, "cursor must be the value returned by the last sync")
        new_cursor, changed = store.sync(cursor, [c.model_dump() for c in body.changes])
        return {"cursor": str(new_cursor), "reminders": [reminder_json(r, tz) for r in changed]}

    def save_days(days: list[dict]) -> tuple[list[dict], list[dict]]:
        """Store health days and check habits from their workouts. Returns (days saved, habits checked)."""
        saved = health.save(days)
        workouts = [(w["id"], str(w.get("type", "other")), workout_minutes(w), workout_date(w, d["date"], tz))
                    for d in saved for w in d.get("workouts", [])]
        return saved, [h.as_json() for h in habits.check_workouts(workouts)]

    @app.post("/v1/health/days", dependencies=[Depends(auth)])
    async def upload_health(body: HealthDaysIn):
        saved, checked = save_days(body.days)
        wake.uploaded(saved)
        return {"ok": True, "saved": len(saved), "checked": checked}

    @app.get("/v1/health/days", dependencies=[Depends(auth)])
    async def health_days(start: date | None = Query(None, alias="from"), end: date | None = Query(None, alias="to")):
        end = end or datetime.now(tz).date()
        start = start or end - timedelta(days=29)
        return {"days": health.between(start, end)}

    @app.post("/v1/wake", dependencies=[Depends(auth)])
    async def wake_up(body: WakeIn | None = None):
        body = body or WakeIn()
        if body.at is not None and body.at.tzinfo is None:
            raise HTTPException(400, "at needs a UTC offset")
        if body.day:
            save_days([body.day])
        log.info("wake signal from %s", body.source)
        started, reason = wake.signal(body.at)
        return {"started": True} if started else {"started": False, "reason": reason}

    @app.post("/v1/devices", dependencies=[Depends(auth)])
    async def register_device(body: DeviceIn):
        push.register(body.token, body.environment, body.name.strip())
        return {"ok": True}

    @app.get("/v1/devices", dependencies=[Depends(auth)])
    async def devices():
        return {"devices": [{"token": d["token"], "environment": d["environment"], "name": d["name"],
                             "registered_at": local(d["registered_at"]),
                             "last_push_at": local(d["last_push_at"]) if d["last_push_at"] else None}
                            for d in push.devices()]}

    @app.post("/v1/devices/test", dependencies=[Depends(auth)])
    async def test_push():
        sent, failed = await push.send_test()
        return {"sent": sent, "failed": failed}

    @app.delete("/v1/devices/{token}", dependencies=[Depends(auth)])
    async def delete_device(token: str):
        push.remove(token)
        return {"ok": True}

    return app
