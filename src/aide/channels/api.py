"""HTTP API for the iOS app. The contract is docs/API.md; keep the two in step."""

import asyncio
import hmac
import logging
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import anthropic
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from ..agent import CONVERSATION, Agent, UnknownConversation
from ..db import Database
from ..icloud import CalendarBackend, CalEvent
from ..reminders import Reminder, ReminderStore

log = logging.getLogger(__name__)

VERSION = "0.2.0"


class ChatIn(BaseModel):
    text: str
    conversation_id: str | None = None  # None: the conversation shared with Discord


class ConversationIn(BaseModel):
    conversation_id: str | None = None


class MemoryIn(BaseModel):
    text: str


class ReminderChange(BaseModel):
    id: str | None = None
    apple_id: str | None = None
    title: str
    notes: str = ""
    due_at: str | None = None
    completed: bool = False
    modified_at: str
    deleted: bool = False


class SyncIn(BaseModel):
    cursor: str | None = None
    changes: list[ReminderChange] = []


def create_app(agent: Agent, store: ReminderStore, calendar: CalendarBackend | None,
               tz: ZoneInfo, token: str) -> FastAPI:
    db: Database = agent.db
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

    @app.exception_handler(ValueError)
    async def bad_value(_: Request, exc: ValueError):
        return JSONResponse({"error": str(exc)}, status_code=400)

    def pending() -> list[dict]:
        return agent.pending_with_ids(CONVERSATION)

    def local(utc_iso: str) -> str:
        return datetime.fromisoformat(utc_iso).astimezone(tz).replace(microsecond=0).isoformat()

    def conversation_json(c: dict) -> dict:
        return {"id": c["id"], "title": c["title"], "preview": c["preview"], "updated_at": local(c["updated_at"])}

    def memory_json(m) -> dict:
        return {"id": m["id"], "text": m["text"], "created_at": local(m["created_at"])}

    def reminder_json(r: Reminder) -> dict:
        return {
            "id": r.id, "title": r.title, "notes": r.notes,
            "due_at": r.due_at.astimezone(tz).isoformat() if r.due_at else None,
            "completed": r.completed, "apple_id": r.apple_id,
            "modified_at": r.modified_at.isoformat().replace("+00:00", "Z"), "deleted": r.deleted,
        }

    def event_json(e: CalEvent) -> dict:
        def t(d):
            return d.astimezone(tz).isoformat() if isinstance(d, datetime) else d.isoformat()
        return {"id": e.uid, "title": e.title, "calendar": e.calendar, "start": t(e.start), "end": t(e.end),
                "all_day": e.all_day, "location": e.location, "recurring": e.recurring}

    @app.get("/v1/health")
    async def health():
        return {"ok": True, "version": VERSION}

    @app.post("/v1/chat", dependencies=[Depends(auth)])
    async def chat(body: ChatIn):
        text = body.text.strip()
        if not text:
            raise HTTPException(400, "text is empty")
        conversation = body.conversation_id or CONVERSATION
        reply = await agent.reply(CONVERSATION, text, conversation)
        return {"reply": reply, "pending": pending(), "conversation_id": conversation}

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
        return {"messages": agent.visible_history(CONVERSATION, max(1, min(limit, 500)), conversation_id)}

    @app.get("/v1/conversations", dependencies=[Depends(auth)])
    async def conversations():
        return {"conversations": [conversation_json(c) for c in agent.conversations(CONVERSATION)]}

    @app.post("/v1/conversations", dependencies=[Depends(auth)])
    async def new_conversation():
        return conversation_json(agent.new_conversation())

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
        return memory_json(db.add_memory(text))

    @app.delete("/v1/memory/{memory_id}", dependencies=[Depends(auth)])
    async def delete_memory(memory_id: int):
        if not db.delete_memory(memory_id):
            raise HTTPException(404, f"no memory {memory_id}")
        return {"ok": True}

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

            def key(e):
                s = e.start if isinstance(e.start, datetime) else datetime.combine(e.start, time.min, tz)
                return s.astimezone(tz)
            events = [event_json(e) for e in sorted(found, key=key)]
        return {"date": day.isoformat(), "events": events,
                "reminders": [reminder_json(r) for r in store.due_before(end)]}

    @app.post("/v1/reminders/sync", dependencies=[Depends(auth)])
    async def sync(body: SyncIn):
        try:
            cursor = int(body.cursor) if body.cursor else None
        except ValueError:
            raise HTTPException(400, "cursor must be the value returned by the last sync")
        new_cursor, changed = store.sync(cursor, [c.model_dump() for c in body.changes])
        return {"cursor": str(new_cursor), "reminders": [reminder_json(r) for r in changed]}

    return app
