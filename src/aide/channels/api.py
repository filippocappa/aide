"""HTTP API for the iOS app. The contract is docs/API.md; keep the two in step."""

import asyncio
import hmac
import json
import logging
from datetime import date, datetime, time, timedelta
from typing import Awaitable, Callable
from zoneinfo import ZoneInfo

import anthropic
import httpx
from fastapi import Body, Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field

from ..agent import CONVERSATION, Agent, Turn, UnknownConversation
from ..agents import AGENTS, check_agent, connectors, mentions
from ..db import Database
from ..digest import DigestService, check_kind
from ..food import FoodStore, totals
from ..habits import HabitStore
from ..health import HealthStore, workout_date, workout_minutes
from ..icloud import CalendarBackend
from ..photos import MAX_BYTES as MAX_PHOTO, TYPES as PHOTO_TYPES, PhotoStore
from ..push import Push
from ..reminders import ReminderStore
from ..routines import EDITABLE as ROUTINE_FIELDS, deliver
from ..shapes import event_json, event_start, reminder_json
from ..material import MAX_FILE, PdfError
from ..moodle import MoodleError, MoodleSync
from ..notebook import NotebookStore
from ..study import AUDIO_TYPES, MAX_AUDIO as MAX_LECTURE, StudyStore, StudyWorker
from ..transcribe import FORMATS as AUDIO_FORMATS, MAX_BYTES as MAX_AUDIO, Transcriber
from ..wake import WakeService

log = logging.getLogger(__name__)

VERSION = "0.2.0"


class ChatIn(BaseModel):
    text: str = ""
    conversation_id: str | None = None  # None: the first chat, "main"
    stream: bool = False  # answer as text/event-stream, with team talk as it happens
    photos: list[str] = []  # ids from POST /v1/photos


class FoodLogIn(BaseModel):
    photos: list[str] = []
    text: str = ""
    day: date | None = Field(None, alias="date")  # the day it was eaten, default today


class MealPatch(BaseModel):
    name: str | None = None
    eaten_at: datetime | None = None
    calories: float | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
    notes: str | None = None


class FoodGoals(BaseModel):
    calories: float | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None


class LectureIn(BaseModel):
    photos: list[str] = []
    files: list[str] = []  # PDFs from POST /v1/files: the lecture's slides
    text: str = ""
    course: int | None = None  # None: filed by the timetable event on at recorded_at
    title: str = ""
    recorded_at: datetime | None = None  # default now


class FilePatch(BaseModel):
    name: str | None = None
    course: int | None = None
    lecture: str | None = None  # null: course material


class MoodleConnect(BaseModel):
    url: str = Field(max_length=4000)  # the moodlemobile://token=… address the login ended on


class MoodleMatch(BaseModel):
    course: int | None  # the Aide course; null: don't sync it


class ProposalApply(BaseModel):
    items: list[int] | None = None  # numbered from 1; null: all
    note: str | None = Field(default=None, max_length=2000)


class LecturePatch(BaseModel):
    title: str | None = None
    course: int | None = None  # null: unfiled
    notes: str | None = None


class TeamIn(BaseModel):
    text: str
    stream: bool = False


class RoutineIn(BaseModel):
    agent: str
    title: str
    prompt: str
    time: str
    days: list[int] = []
    enabled: bool = True
    watch: bool = False


class RoutinePatch(BaseModel):
    title: str | None = None
    prompt: str | None = None
    time: str | None = None
    days: list[int] | None = None
    enabled: bool | None = None
    watch: bool | None = None


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
    list: str | None = None


class DeviceIn(BaseModel):
    token: str
    environment: str
    name: str = ""


class SyncIn(BaseModel):
    cursor: str | None = None
    changes: list[ReminderChange] = []
    lists: list[str] | None = None  # the phone's Apple Reminders lists, by name
    default_list: str | None = None


UNAVAILABLE = "The assistant is unavailable right now. Try again."


def sse(event: str, data: dict) -> str:
    """One server-sent event: json.dumps escapes line breaks, so data stays on one line."""
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


def create_app(agent: Agent, store: ReminderStore, calendar: CalendarBackend | None,
               tz: ZoneInfo, token: str, habits: HabitStore | None = None,
               digest: DigestService | None = None, push: Push | None = None,
               health: HealthStore | None = None, wake: WakeService | None = None,
               transcriber: Transcriber | None = None, food: FoodStore | None = None,
               study: StudyStore | None = None, worker: StudyWorker | None = None,
               vault: dict | None = None, moodle: MoodleSync | None = None,
               notebook: NotebookStore | None = None) -> FastAPI:
    db: Database = agent.db
    push = push or Push(db.conn)  # no key: devices are kept, nothing is sent
    habits = habits or HabitStore(db.conn, tz)
    health = health or HealthStore(db.conn, tz)
    digest = digest or DigestService(db.conn, agent.client, agent.model, tz, store, habits, calendar, health=health)
    wake = wake or WakeService(digest, health, tz, push=push)
    food = food or FoodStore(db.conn, tz)
    study = study or StudyStore(db, tz, calendar)
    moodle = moodle or MoodleSync(study, None, None)  # no AIDE_MOODLE_URL: enabled false
    notebook = notebook or NotebookStore(study)  # without a worker, nothing queued runs
    photos: PhotoStore | None = agent.photos
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
        return JSONResponse({"error": UNAVAILABLE}, status_code=502)

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
        course = db.conn.execute("SELECT id FROM courses WHERE chat = ?", (c["id"],)).fetchone()
        return {"id": c["id"], "agent": c["agent"], "title": c["title"], "routine": c["routine"],
                "course": course[0] if course else None, "preview": c["preview"], "updated_at": local(c["updated_at"])}

    def team_json(t: dict) -> dict:
        return {**t, "ts": local(t["ts"])}

    def chat_json(conversation: str, turn: Turn) -> dict:
        return {"reply": turn.reply, "pending": pending(), "conversation_id": conversation,
                "attachments": turn.attachments, "consulted": turn.consulted,
                "team": [team_json(t) for t in turn.team]}

    turns: set[asyncio.Task] = set()  # streamed turns, held so they finish even if the app hangs up

    def streamed(run: Callable[[Callable[[str, dict], None]], Awaitable], done: Callable[[object], str]):
        """Run a turn as server-sent events: `run(emit)` emits events as they happen, `done(result)` is the last one."""
        events: asyncio.Queue = asyncio.Queue()
        task = asyncio.create_task(run(lambda event, data: events.put_nowait(sse(event, data))))
        turns.add(task)

        def finished(t: asyncio.Task) -> None:
            turns.discard(t)
            if not t.cancelled() and t.exception():
                log.error("streamed turn failed", exc_info=t.exception())
            events.put_nowait(None)
        task.add_done_callback(finished)

        async def stream():
            while (event := await events.get()) is not None:
                yield event
            if task.cancelled() or task.exception():
                error = task.cancelled() or task.exception()
                yield sse("error", {"error": UNAVAILABLE if isinstance(error, anthropic.APIError)
                                    else "Something went wrong on the server. It's in the logs."})
            else:
                yield done(task.result())

        # No caching or proxy buffering, so each event reaches the app as it's sent.
        return StreamingResponse(stream(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    def memory_json(m) -> dict:
        return {"id": m["id"], "text": m["text"], "agent": m["agent"], "created_at": local(m["created_at"])}

    @app.get("/v1/health")
    async def alive():
        return {"ok": True, "version": VERSION}

    @app.post("/v1/chat", dependencies=[Depends(auth)])
    async def chat(body: ChatIn):
        text = body.text.strip()
        if not text and not body.photos:
            raise HTTPException(400, "text is empty")
        agent.check_photos(body.photos)  # a plain 400, before a stream starts
        conversation = body.conversation_id or CONVERSATION
        if not body.stream:
            return chat_json(conversation, await agent.respond(CONVERSATION, text, conversation, photos=body.photos))
        if conversation != CONVERSATION and db.app_conversation(conversation) is None:
            raise UnknownConversation(f"no conversation {conversation}")  # a plain 404, before the stream starts
        return streamed(
            lambda emit: agent.respond(CONVERSATION, text, conversation, lambda t: emit("team", team_json(t)),
                                       lambda delta, restart: emit("text", {"delta": delta, "restart": restart}),
                                       body.photos),
            lambda turn: sse("reply", chat_json(conversation, turn)))

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
        for m in messages:
            m["team"] = [team_json(t) for t in m["team"]]  # reminders as they are now, so a reload shows ticks made since
            for a in m["attachments"]:
                if a["type"] == "reminders":
                    a["reminders"] = [reminder_json(r, tz) if (r := store.get(old["id"])) else old
                                      for old in a["reminders"]]
        return {"messages": messages}

    @app.get("/v1/team", dependencies=[Depends(auth)])
    async def team(limit: int = 100):
        return {"messages": [team_json(t) for t in db.team_messages(max(1, min(limit, 500)))]}

    @app.post("/v1/team", dependencies=[Depends(auth)])
    async def write_in_team(body: TeamIn):
        text = body.text.strip()
        if not text:
            raise HTTPException(400, "text is empty")
        mentions(text)  # an unknown @mention is a plain 400, before anyone answers

        def team_body(new: list[dict]) -> dict:
            return {"messages": [team_json({**t, "conversation_id": None}) for t in new], "pending": pending()}

        if not body.stream:
            return team_body(await agent.team_chat(CONVERSATION, text))
        return streamed(
            lambda emit: agent.team_chat(CONVERSATION, text, lambda a: emit("working", {"agent": a}),
                                         lambda t: emit("team", team_json({**t, "conversation_id": None}))),
            lambda new: sse("done", team_body(new)))

    # -- routines ------------------------------------------------------------

    routines = agent.routines

    def routine_or_404(routine_id: int) -> dict:
        r = routines.get(routine_id)
        if r is None:
            raise HTTPException(404, f"no routine {routine_id}")
        return r

    @app.get("/v1/routines", dependencies=[Depends(auth)])
    async def list_routines(agent_id: str | None = Query(None, alias="agent")):
        return {"routines": [routines.as_json(r) for r in
                             routines.all(check_agent(agent_id) if agent_id is not None else None)]}

    @app.post("/v1/routines", dependencies=[Depends(auth)])
    async def add_routine(body: RoutineIn):
        return routines.as_json(routines.create(**body.model_dump()))

    @app.patch("/v1/routines/{routine_id}", dependencies=[Depends(auth)])
    async def edit_routine(routine_id: int, body: RoutinePatch):
        routine_or_404(routine_id)
        changes = body.model_dump(exclude_unset=True)
        return routines.as_json(routines.update(routine_id, **{k: v for k, v in changes.items()
                                                                if k in ROUTINE_FIELDS}))

    @app.delete("/v1/routines/{routine_id}", dependencies=[Depends(auth)])
    async def delete_routine(routine_id: int):
        if not routines.delete(routine_id):
            raise HTTPException(404, f"no routine {routine_id}")
        return {"ok": True}

    @app.post("/v1/routines/{routine_id}/run", dependencies=[Depends(auth)])
    async def run_routine(routine_id: int):
        r = routine_or_404(routine_id)
        reply = await deliver(agent, CONVERSATION, r, push)
        return {"routine": routines.as_json(routines.get(routine_id)), "conversation_id": r["public_id"],
                "spoke": reply is not None}

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
        out = []
        for a in AGENTS.values():
            tools = [t.name for t in agent.registries[a.id]]
            out.append({**a.as_json(), "prompt": a.prompt, "tools": tools, "connectors": connectors(tools)})
        return {"agents": out}

    @app.post("/v1/transcribe", dependencies=[Depends(auth)])
    async def transcribe(request: Request, language: str | None = Query(default=None, max_length=20)):
        if transcriber is None:
            raise HTTPException(503, "transcription needs OPENROUTER_API_KEY on the server")
        fmt = AUDIO_FORMATS.get(request.headers.get("content-type", "").split(";")[0].strip().lower())
        if fmt is None:
            raise HTTPException(415, "send the recording as audio/wav, audio/mpeg or audio/mp4")
        audio = await request.body()
        if not audio:
            raise HTTPException(400, "the recording is empty")
        if len(audio) > MAX_AUDIO:
            raise HTTPException(413, "the recording is too long")
        try:
            return {"text": await transcriber(audio, fmt, language)}
        except (httpx.HTTPError, KeyError, IndexError, ValueError) as e:
            log.error("transcription failed: %s", e)
            raise HTTPException(502, "couldn't transcribe that, try again")

    @app.post("/v1/photos", dependencies=[Depends(auth)])
    async def upload_photo(request: Request):
        if photos is None:
            raise HTTPException(503, "photos aren't set up on the server")
        kind = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if kind not in PHOTO_TYPES:
            raise HTTPException(415, f"send the photo as {', '.join(PHOTO_TYPES)}")
        data = await request.body()
        if len(data) > MAX_PHOTO:
            raise HTTPException(413, "the photo is too big; send it at most 1568 px on its longest side")
        return {"id": photos.save(data, kind)}  # empty: ValueError, a 400

    @app.get("/v1/photos/{photo_id}", dependencies=[Depends(auth)])
    async def get_photo(photo_id: str):
        if photos is None or (found := photos.load(photo_id)) is None:
            raise HTTPException(404, f"no photo {photo_id}")
        data, kind = found
        return Response(data, media_type=kind, headers={"Cache-Control": "private, max-age=31536000, immutable"})

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

    # -- food ------------------------------------------------------------------

    def meal_or_404(meal_id: int) -> dict:
        if (meal := food.get(meal_id)) is None:
            raise HTTPException(404, f"no meal {meal_id}")
        return meal

    def food_day(d: date) -> dict:
        meals = food.day(d)
        return {"date": d.isoformat(), "meals": [food.as_json(m) for m in meals], "totals": totals(meals),
                "goals": food.goals()}

    @app.get("/v1/food", dependencies=[Depends(auth)])
    async def food_today(day: date | None = Query(None, alias="date")):
        return food_day(day or food.today())

    @app.get("/v1/food/days", dependencies=[Depends(auth)])
    async def food_days(start: date | None = Query(None, alias="from"), end: date | None = Query(None, alias="to")):
        end = end or food.today()
        start = start or end - timedelta(days=6)
        if start > end or (end - start).days > 366:
            raise HTTPException(400, "from must be before to, at most a year apart")
        return {"days": food.days(start, end)}

    def food_chat() -> str:
        """Coach's "Food log" chat, made once; made again if it was deleted."""
        if (public_id := food.chat()) and db.app_conversation(public_id) is not None:
            return public_id
        row = db.new_app_conversation("coach")
        db.set_conversation_title(row["id"], "Food log")
        food.set_chat(row["public_id"])
        return row["public_id"]

    @app.post("/v1/food/log", dependencies=[Depends(auth)])
    async def log_food(body: FoodLogIn):
        text = body.text.strip()
        if not text and not body.photos:
            raise HTTPException(400, "send photos or text")
        agent.check_photos(body.photos)
        if body.day and body.day > food.today():
            raise HTTPException(400, "a meal can't be in the future")
        if body.day and body.day != food.today():
            text = "\n".join(filter(None, [text, f"(I ate this on {body.day:%A %d %B}.)"]))
        conversation = food_chat()
        turn = await agent.respond(CONVERSATION, text or "Log this.", conversation, photos=body.photos)
        meals = next((a["meals"] for a in turn.attachments if a["type"] == "meals"), [])
        return {"reply": turn.reply, "meals": meals, "conversation_id": conversation}

    @app.patch("/v1/food/meals/{meal_id}", dependencies=[Depends(auth)])
    async def edit_meal(meal_id: int, body: MealPatch):
        meal_or_404(meal_id)
        return food.as_json(food.update(meal_id, **body.model_dump(exclude_unset=True)))

    @app.delete("/v1/food/meals/{meal_id}", dependencies=[Depends(auth)])
    async def delete_meal(meal_id: int):
        if not food.delete(meal_id):
            raise HTTPException(404, f"no meal {meal_id}")
        return {"ok": True}

    @app.get("/v1/food/goals", dependencies=[Depends(auth)])
    async def food_goals():
        return food.goals()

    @app.put("/v1/food/goals", dependencies=[Depends(auth)])
    async def set_food_goals(body: FoodGoals):
        return food.set_goals(body.model_dump())

    # -- study -------------------------------------------------------------------

    def lecture_or_404(lecture_id: str) -> dict:
        if (lecture := study.get(lecture_id)) is None:
            raise HTTPException(404, f"no lecture {lecture_id}")
        return lecture

    def course_or_400(course_id: int | None) -> int | None:
        if course_id is not None and study.course(course_id) is None:
            raise HTTPException(400, f"no course {course_id}")
        return course_id

    @app.get("/v1/study", dependencies=[Depends(auth)])
    async def study_overview():
        courses = await study.courses()
        on = await study.now()
        return {"courses": [study.course_json(c) for c in courses], "unfiled": study.unfiled(),
                "now": {"course": on[0]["id"], "name": on[0]["name"], "ends": on[1].astimezone(tz).isoformat()}
                if on else None,
                "transcription": worker is not None and worker.transcribe is not None}

    @app.post("/v1/study/courses/{course_id}/chat", dependencies=[Depends(auth)])
    async def course_chat(course_id: int):
        if study.course(course_id) is None:
            raise HTTPException(404, f"no course {course_id}")
        return {"conversation_id": study.chat(course_id)}

    @app.get("/v1/lectures", dependencies=[Depends(auth)])
    async def list_lectures(course: str | None = None, limit: int = 100):
        limit = max(1, min(limit, 500))
        if course == "none":
            rows = study.lectures(unfiled=True, limit=limit)
        elif course is None:
            rows = study.lectures(limit=limit)
        elif course.isdigit():
            rows = study.lectures(int(course), limit=limit)
        else:
            raise HTTPException(400, "course must be a course id or none")
        return {"lectures": [study.as_json(lec) for lec in rows]}

    @app.post("/v1/lectures", dependencies=[Depends(auth)])
    async def add_lecture(request: Request, recorded_at: datetime | None = None, course: int | None = None,
                          title: str = Query("", max_length=100)):
        kind = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if kind == "application/json":
            body = LectureIn.model_validate(await request.json())
            for p in body.photos:
                if photos is None or not photos.exists(p):
                    raise HTTPException(400, f"no photo {p}")
            for f in body.files:
                if study.files.get(f) is None:
                    raise HTTPException(400, f"no file {f}")
            at = body.recorded_at or datetime.now(tz)
            course_id = course_or_400(body.course)
            if course_id is None and (found := await study.match(at)):
                course_id = found["id"]
            lecture = study.add(at, course_id, body.title, photos=body.photos, text=body.text, files=body.files)
        else:
            ext = AUDIO_TYPES.get(kind)
            if ext is None:
                raise HTTPException(415, f"send the recording as {', '.join(AUDIO_TYPES)}, or photos and text as JSON")
            if worker is None or worker.transcribe is None:
                raise HTTPException(503, "transcription isn't set up on the server")
            at = recorded_at or datetime.now(tz)
            if at.tzinfo is None:
                raise HTTPException(400, "recorded_at needs a UTC offset")
            course_id = course_or_400(course)
            public_id = study.new_id()
            tmp, size = worker.audio_dir / f".{public_id}.tmp", 0
            try:
                with tmp.open("wb") as f:  # streamed to disk: a lecture is tens of MB
                    async for chunk in request.stream():
                        size += len(chunk)
                        if size > MAX_LECTURE:
                            raise HTTPException(413, "the recording is too big")
                        f.write(chunk)
                if size == 0:
                    raise HTTPException(400, "the recording is empty")
                tmp.rename(worker.audio_dir / (public_id + ext))
            finally:
                tmp.unlink(missing_ok=True)
            if course_id is None and (found := await study.match(at)):
                course_id = found["id"]
            lecture = study.add(at, course_id, title, audio=public_id + ext, public_id=public_id)
        if worker is not None:
            worker.kick()
        return JSONResponse(study.as_json(lecture, full=True), status_code=202)

    @app.get("/v1/lectures/{lecture_id}", dependencies=[Depends(auth)])
    async def get_lecture(lecture_id: str, transcript: bool = False):
        return study.as_json(lecture_or_404(lecture_id), full=True, transcript=transcript)

    @app.patch("/v1/lectures/{lecture_id}", dependencies=[Depends(auth)])
    async def edit_lecture(lecture_id: str, body: LecturePatch):
        lecture_or_404(lecture_id)
        changes = body.model_dump(exclude_unset=True)
        return study.as_json(study.update(lecture_id, title=changes.get("title"),
                                          course_id=course_or_400(changes.get("course")), move="course" in changes,
                                          notes=changes.get("notes")), full=True)

    @app.delete("/v1/lectures/{lecture_id}", dependencies=[Depends(auth)])
    async def delete_lecture(lecture_id: str):
        lecture = study.delete(lecture_id)
        if lecture is None:
            raise HTTPException(404, f"no lecture {lecture_id}")
        if lecture["audio"] and worker is not None:
            (worker.audio_dir / lecture["audio"]).unlink(missing_ok=True)
        return {"ok": True}

    @app.post("/v1/lectures/{lecture_id}/retry", dependencies=[Depends(auth)])
    async def retry_lecture(lecture_id: str):
        lecture_or_404(lecture_id)
        lecture = study.retry(lecture_id)
        if worker is not None:
            worker.kick()
        return JSONResponse(study.as_json(lecture, full=True), status_code=202)

    # -- study files ---------------------------------------------------------------

    def file_or_404(file_id: str) -> dict:
        if (f := study.files.get(file_id)) is None:
            raise HTTPException(404, f"no file {file_id}")
        return f

    def file_json(f: dict) -> dict:
        lecture = study.lecture_row(f["lecture_id"]) if f["lecture_id"] else None
        return study.files.as_json(f, lecture["public_id"] if lecture else None)

    @app.post("/v1/files", dependencies=[Depends(auth)])
    async def add_file(request: Request, course: int | None = None, lecture: str | None = None,
                       name: str = Query("Untitled.pdf", max_length=300)):
        kind = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if kind != "application/pdf":
            raise HTTPException(415, "send the file as application/pdf")
        course_id = course_or_400(course)
        target = lecture_or_404(lecture) if lecture else None
        if target is not None:
            course_id = target["course_id"] if course_id is None else course_id
        public_id = study.files.new_id()
        tmp, size = study.files.folder / f".{public_id}.tmp", 0
        try:
            with tmp.open("wb") as out:
                async for chunk in request.stream():
                    size += len(chunk)
                    if size > MAX_FILE:
                        raise HTTPException(413, "the file is too big")
                    out.write(chunk)
            if size == 0:
                raise HTTPException(400, "the file is empty")
            try:
                f = await study.files.add(tmp, name, course_id, target["id"] if target else None,
                                          public_id=public_id)
            except PdfError as e:
                raise HTTPException(400, str(e))
        finally:
            tmp.unlink(missing_ok=True)
        if target is not None:
            study.rewrite(target["id"])
            if worker is not None:
                worker.kick()
        return JSONResponse(file_json(f), status_code=201)

    @app.get("/v1/files", dependencies=[Depends(auth)])
    async def list_files(course: int | None = None, lecture: str | None = None):
        target = lecture_or_404(lecture) if lecture else None
        rows = study.files.files(course, target["id"] if target else None)
        return {"files": [file_json(f) for f in rows]}

    @app.get("/v1/files/{file_id}", dependencies=[Depends(auth)])
    async def get_file(file_id: str):
        return file_json(file_or_404(file_id))

    @app.get("/v1/files/{file_id}/pdf", dependencies=[Depends(auth)])
    async def get_file_pdf(file_id: str):
        f = file_or_404(file_id)
        return FileResponse(study.files.path(f), media_type="application/pdf", filename=f["name"])

    @app.patch("/v1/files/{file_id}", dependencies=[Depends(auth)])
    async def edit_file(file_id: str, body: FilePatch):
        f = file_or_404(file_id)
        changes = body.model_dump(exclude_unset=True)
        fields: dict = {}
        if changes.get("name") is not None:
            fields["name"] = changes["name"]
        if "course" in changes:
            fields["course_id"] = course_or_400(changes["course"])
        target = None
        if "lecture" in changes:
            target = lecture_or_404(changes["lecture"]) if changes["lecture"] else None
            fields["lecture_id"] = target["id"] if target else None
            if target and "course" not in changes and target["course_id"] is not None:
                fields["course_id"] = target["course_id"]
        f = study.files.update(file_id, **fields)
        if target is not None:
            study.rewrite(target["id"])
            if worker is not None:
                worker.kick()
        return file_json(f)

    @app.delete("/v1/files/{file_id}", dependencies=[Depends(auth)])
    async def delete_file(file_id: str):
        if study.files.delete(file_id) is None:
            raise HTTPException(404, f"no file {file_id}")
        return {"ok": True}

    # -- Moodle ----------------------------------------------------------------------

    def moodle_on() -> None:
        if not moodle.site:
            raise HTTPException(503, "Moodle isn't set up on the server (AIDE_MOODLE_URL)")

    @app.get("/v1/moodle", dependencies=[Depends(auth)])
    async def moodle_status():
        return moodle.status()

    @app.post("/v1/moodle/login", dependencies=[Depends(auth)])
    async def moodle_login():
        moodle_on()
        return moodle.login()

    @app.post("/v1/moodle/connect", dependencies=[Depends(auth)])
    async def moodle_connect(body: MoodleConnect):
        moodle_on()
        try:
            return await moodle.connect(body.url)
        except ValueError as e:
            raise HTTPException(400, str(e))
        except MoodleError as e:
            raise HTTPException(502, str(e))

    @app.delete("/v1/moodle", dependencies=[Depends(auth)])
    async def moodle_logout():
        moodle.logout()
        return moodle.status()

    @app.post("/v1/moodle/sync", dependencies=[Depends(auth)])
    async def moodle_sync():
        moodle_on()
        if not moodle.token:
            raise HTTPException(409, "log in to Moodle first")
        moodle.kick()
        return JSONResponse(moodle.status(), status_code=202)

    @app.patch("/v1/moodle/courses/{moodle_id}", dependencies=[Depends(auth)])
    async def moodle_match(moodle_id: int, body: MoodleMatch):
        course_or_400(body.course)
        try:
            return moodle.course_json(moodle.match(moodle_id, body.course))
        except KeyError:
            raise HTTPException(404, f"no Moodle course {moodle_id}")

    # -- notebooks -------------------------------------------------------------------

    def course_or_404(course_id: int) -> int:
        if study.course(course_id) is None:
            raise HTTPException(404, f"no course {course_id}")
        return course_id

    def proposal_or_404(proposal_id: str) -> dict:
        if (p := notebook.proposal(proposal_id)) is None:
            raise HTTPException(404, f"no proposal {proposal_id}")
        return p

    @app.get("/v1/notebook", dependencies=[Depends(auth)])
    async def get_notebook(course: int):
        return notebook.notebook_json(course_or_404(course))

    @app.post("/v1/notebook", dependencies=[Depends(auth)])
    async def start_notebook(course: int):
        try:
            notebook.start(course_or_404(course))
        except ValueError as e:
            raise HTTPException(409, str(e))
        return JSONResponse(notebook.notebook_json(course), status_code=202)

    @app.get("/v1/topics/{topic_id}", dependencies=[Depends(auth)])
    async def get_topic(topic_id: str):
        if (t := notebook.topic(topic_id)) is None:
            raise HTTPException(404, f"no topic {topic_id}")
        return notebook.topic_json(t, full=True)

    @app.get("/v1/proposals", dependencies=[Depends(auth)])
    async def list_proposals(course: int | None = None, status: str = "pending"):
        if status not in ("pending", "all"):
            raise HTTPException(400, "status is pending or all")
        return {"proposals": [notebook.proposal_json(p) for p in
                              notebook.proposals(course, None if status == "all" else status)]}

    @app.post("/v1/proposals/{proposal_id}/apply", dependencies=[Depends(auth)])
    async def apply_proposal(proposal_id: str, body: ProposalApply | None = None):
        proposal_or_404(proposal_id)
        body = body or ProposalApply()
        try:
            p = notebook.apply(proposal_id, body.items, body.note)
        except ValueError as e:
            raise HTTPException(409 if "not waiting" in str(e) else 400, str(e))
        return JSONResponse(notebook.proposal_json(p), status_code=202)

    @app.post("/v1/proposals/{proposal_id}/decline", dependencies=[Depends(auth)])
    async def decline_proposal(proposal_id: str):
        proposal_or_404(proposal_id)
        try:
            return notebook.proposal_json(notebook.decline(proposal_id))
        except ValueError as e:
            raise HTTPException(409, str(e))

    @app.get("/v1/vault", dependencies=[Depends(auth)])
    async def vault_setup():
        """What Obsidian's Remotely Save needs to sync the vault (webdav.py), or enabled false."""
        return {"enabled": True, **vault} if vault else {"enabled": False}

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
        # exclude_unset: a change without "list" (an app from before lists) leaves the list as it is.
        new_cursor, changed = store.sync(cursor, [c.model_dump(exclude_unset=True) for c in body.changes],
                                         body.lists, body.default_list)
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
