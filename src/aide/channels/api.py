"""HTTP API for the iOS app. The contract is docs/API.md; keep the two in step."""

import asyncio
import base64
import hmac
import json
import logging
import re
from datetime import date, datetime, time, timedelta, timezone
from typing import Awaitable, Callable, Literal
from urllib.parse import quote
from zoneinfo import ZoneInfo

import anthropic
import httpx
from fastapi import Body, Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from .. import activity, usage
from ..agent import CONVERSATION, PENDING_TTL, SCANNED, TEAM, Agent, Turn, UnknownConversation
from ..agents import AGENTS, ORCHESTRATOR, check_agent, connectors, mentions
from ..db import Database, utcnow
from ..decide import Decider
from ..feedback import FeedbackStore
from ..digest import DigestService, check_kind
from ..drafts import Drafts
from ..browser import BrowserError, check_site, full_url, site_of
from ..engine import Engine
from ..examplan import ExamPlan
from ..errands import ErrandRunner, ErrandStore
from ..pricewatch import PriceWatches
from ..releases import Releases
from ..food import MACROS, MAX_RANGE as MAX_MEAL_DAYS, FoodStore, totals
from ..foods import MAX_NAME as MAX_FOOD_NAME, FoodDB, free_notes
from ..nutrition import PROPOSE_PROMPT, PROPOSE_TOKENS, Nutrition, parse_proposal, proposal_input
from ..habits import HabitStore
from ..health import HealthStore, workout_date, workout_minutes
from ..icloud import CalendarBackend, CalEvent
from ..live import KINDS as LIVE_KINDS, LiveActivities, hooks
from ..plans import PlanStore
from ..photos import MAX_BYTES as MAX_PHOTO, TYPES as PHOTO_TYPES, PhotoStore
from ..push import Push
from ..reminders import ReminderStore
from ..reviews import ReviewStore
from ..routines import EDITABLE as ROUTINE_FIELDS, deliver
from ..shapes import event_json, event_start, reminder_json
from ..material import MAX_FILE, PdfError, page_image
from ..esse3 import Esse3Reader, SignUpFailed
from ..moodle import MoodleError, MoodleSync
from ..passwords import MAX_NAME, MAX_PASSWORD, MAX_SITES, MAX_USERNAME, Locked, PasswordError, PasswordStore, TooMany
from ..lessons import LessonStore
from ..notebook import NotebookStore
from ..objectives import ObjectivePlanner, ObjectiveStore
from ..quiz import MOST as MOST_QUESTIONS, QuizStore, mark as mark_answer, plain_math
from ..study import AUDIO_TYPES, MAX_AUDIO as MAX_LECTURE, StudyStore, StudyWorker
from ..transcribe import FORMATS as AUDIO_FORMATS, MAX_BYTES as MAX_AUDIO, Transcriber
from ..leave import LeaveWatcher
from ..livecall import LiveCall, LiveCalls, instructions as live_instructions
from ..locks import LockStore
from ..tools.nutrition import OpenFoodFacts, read_label, save_product
from ..transit import AlertStore, Boards, Location
from ..videos import VideoWorker, find_link
from ..wake import WakeService
from ..weight import WeightStore
from ..banks import Banks, BankError
from ..bedtime import Bedtime
from ..focus import PRESETS as FOCUS_PRESETS, FocusStore, FocusWatcher
from ..finance import CATEGORIES as FINANCE_CATEGORIES, NOT_SPENDING, FinanceStore, parse_amount

log = logging.getLogger(__name__)

VERSION = "0.2.0"


class ChatIn(BaseModel):
    text: str = ""
    conversation_id: str | None = None  # None: the first chat, "main"
    stream: bool = False  # answer as text/event-stream, with team talk as it happens
    photos: list[str] = []  # ids from POST /v1/photos
    files: list[str] = []  # PDFs from POST /v1/files (#78)
    voice: bool = False  # said in a voice chat: the reply is read aloud


class FoodLogIn(BaseModel):
    photos: list[str] = []
    text: str = ""
    day: date | None = Field(None, alias="date")  # the day it was eaten, default today
    barcodes: list[str] = Field([], max_length=20)  # read in the photos by the phone


class LabelIn(BaseModel):
    barcode: str
    photo: str  # id from POST /v1/photos: the nutrition facts on the packet
    name: str = ""  # what the user calls it, when the photo doesn't say


class FoodLogOne(BaseModel):
    grams: float | None = None  # None: the usual portion, else one serving
    day: date | None = Field(None, alias="date")
    conversation_id: str | None = None  # the Coach chat it was scanned in; else the Food log


class FoodItemIn(BaseModel):
    food_id: int
    grams: float | None = None  # None: the usual portion, else one serving


class FoodsLogIn(BaseModel):
    items: list[FoodItemIn] = Field(min_length=1, max_length=20)
    name: str | None = None  # None: the foods' names
    day: date | None = Field(None, alias="date")
    conversation_id: str | None = None


class MealAgainIn(BaseModel):
    day: date | None = Field(None, alias="date")
    conversation_id: str | None = None


class MealPatch(BaseModel):
    name: str | None = None
    eaten_at: datetime | None = None
    calories: float | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
    water_ml: float | None = None
    caffeine_mg: float | None = None
    notes: str | None = None


class FoodGoals(BaseModel):
    calories: float | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None


class WorkoutTargets(BaseModel):
    on: bool | None = None
    share: float | None = None
    carbs_pct: float | None = None


class FoodProfile(BaseModel):
    weight_kg: float | None = None
    height_cm: float | None = None
    age: int | None = None
    sex: str | None = None
    goal: str | None = None
    note: str | None = Field(None, max_length=500)


class FoodTargetsIn(BaseModel):
    base: FoodGoals | None = None
    workouts: WorkoutTargets | None = None
    profile: FoodProfile | None = None


class TargetsAnswer(BaseModel):
    question: str = Field(max_length=500)
    answer: str = Field(max_length=1000)


class ProposeIn(BaseModel):
    answers: list[TargetsAnswer] = Field(default=[], max_length=4)


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


class CourseDateIn(BaseModel):
    """A course date the user adds or changes; on a change, only the fields sent."""
    what: str | None = Field(default=None, max_length=200)
    kind: str | None = None  # exam, mid-term, deadline, other
    date: str | None = None  # YYYY-MM-DD
    time: str | None = None  # HH:MM, null: all day
    end: str | None = None
    room: str | None = Field(default=None, max_length=200)
    you: str | None = Field(default=None, max_length=400)
    details: str | None = Field(default=None, max_length=600)


class Exercises(BaseModel):
    topics: list[str] | None = Field(default=None, max_length=60)  # t_… ids; null: every written topic


_WIKILINK = re.compile(r"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]")


def readable(markdown: str, latex: bool = False, inline: bool = False) -> str:
    """Notes for the app (`plain=true`): maths as Unicode, [[links]] as their text. `latex`: formulas on their own
    lines stay $$…$$ LaTeX, for the app to draw; with `inline` too, the maths in sentences as \\(…\\)."""
    return plain_math(_WIKILINK.sub(lambda m: (m.group(2) or m.group(1)).strip(), markdown), blocks=latex,
                      inline=latex and inline)


class QuizStart(BaseModel):
    course: int
    count: int = Field(default=30, ge=0, le=MOST_QUESTIONS)  # multiple-choice questions
    cards: int = Field(default=0, ge=0, le=MOST_QUESTIONS)  # flashcards, answered right or wrong as the user judges
    exercises: int = Field(default=0, ge=0, le=MOST_QUESTIONS)  # the course's own exercises, open, marked after
    minutes: int | None = Field(default=None, ge=1, le=600)  # null: untimed
    topics: list[str] | None = None  # topic ids; null: all
    mock: str | None = None  # a mock exam's id (m_…): that paper, its time and scoring; count, minutes, topics unused
    kind: Literal["exam", "study"] = "exam"  # study: the Study page, untimed, each answer shown and marked as it comes
    write: int = Field(default=0, ge=0, le=MOST_QUESTIONS)  # study: flashcards answered in words, marked by the model
    due: bool = False  # study: the Due today deck (spaced repetition); count, cards, exercises, write, topics unused


class WriterIn(BaseModel):
    engine: Literal["claude", "openrouter"] | None = None  # the notes
    background: Literal["claude", "openrouter"] | None = None  # routines, watches, digests, drafts, titles


class WriterDecide(BaseModel):
    use: Literal["wait", "openrouter"]


class OpenAnswer(BaseModel):  # a mock exam's open question: typed, or photos of the work on paper, or both
    text: str = ""
    photos: list[str] = Field(default=[], max_length=10)


class LessonStart(BaseModel):
    again: bool = False  # write it again (from the notes as they are now)
    restart: bool = False  # go through it again from the start


class LessonCheck(BaseModel):
    step: int
    check: int
    answer: str  # a choice's letter, or the words


class LessonProgress(BaseModel):
    at: int  # steps done


class LessonQA(BaseModel):
    q: str
    a: str


class LessonAsk(BaseModel):
    step: int
    question: str
    history: list[LessonQA] = []  # earlier questions on this step, oldest first


class LessonFinish(BaseModel):
    explanation: str | None = None  # the topic explained back in their own words


class QuizCheck(BaseModel):
    n: int
    answer: str | OpenAnswer | None = None  # as in QuizFinish; null: blank
    seconds: float | None = None  # how long a multiple-choice answer took: right but slow is Hard for the schedule


class QuizMark(BaseModel):  # a study session's open answer: "I was right" (or not), over the model's mark
    n: int
    correct: bool


class QuizFinish(BaseModel):
    answers: dict[str, str | OpenAnswer | None] = {}  # {"1": "B", "21": {"text": …}}; left out or null: blank


class LecturePatch(BaseModel):
    title: str | None = None
    course: int | None = None  # null: unfiled
    notes: str | None = None


class TeamIn(BaseModel):
    text: str
    stream: bool = False


class DraftIn(BaseModel):
    body: str | None = None  # the reply as edited in the app; None sends it as drafted


class RoutineIn(BaseModel):
    agent: str
    title: str
    prompt: str
    time: str
    days: list[int] = []
    enabled: bool = True
    watch: bool = False
    summary: str | None = None


class RoutinePatch(BaseModel):
    title: str | None = None
    prompt: str | None = None
    time: str | None = None
    days: list[int] | None = None
    enabled: bool | None = None
    watch: bool | None = None
    summary: str | None = None


Period = Literal["day", "week", "month"]


class ObjectiveStep(BaseModel):
    text: str
    done: bool = False


class ObjectiveIn(BaseModel):
    agent: str
    period: Period
    title: str
    why: str = ""
    steps: list[str] = []
    day: date | None = Field(None, alias="date")  # a day in the period, default today


class ObjectivePatch(BaseModel):
    title: str | None = None
    done: bool | None = None
    status: Literal["active", "dropped"] | None = None
    target: int | None = None
    steps: list[ObjectiveStep] | None = None  # replaces the list


class ObjectivesPlan(BaseModel):
    period: Period
    day: date | None = Field(None, alias="date")


class ObjectivesAccept(BaseModel):
    period: Period
    day: date | None = Field(None, alias="date")
    ids: list[str] | None = None  # None: all of the period's proposals (but those in drop)
    drop: list[str] | None = None  # dropped instead


class ActionsIn(BaseModel):
    ids: list[int] | None = None  # None: every pending action
    rest: bool = False  # Confirm only: an errand's send "and the rest like it"


class ConversationIn(BaseModel):
    conversation_id: str | None = None


class ThinkIn(ConversationIn):
    on: bool = True


class FeedbackIn(ConversationIn):
    message_id: int
    rating: str | None  # up | down | None (taken back)
    note: str | None = None


class NewConversationIn(BaseModel):
    agent: str = "aide"
    digest: str | None = None  # start the chat with this digest's greeting (and make it Aide's)


class MemoryIn(BaseModel):
    text: str
    agent: str | None = None  # None: shared


class Cadence(BaseModel):
    type: str = "daily"
    per_week: int | None = None
    max: int | None = None  # a limit habit's most a day


class HabitIn(BaseModel):
    name: str
    cadence: Cadence = Cadence()
    workouts: list[str] = []
    food: str | None = None
    health: str | None = None  # a limit habit's Apple Health count: inhaler_usage
    minimum: str | None = None  # the two-minute version


class HabitPatch(BaseModel):
    name: str | None = None
    cadence: Cadence | None = None
    workouts: list[str] | None = None
    food: str | None = None
    health: str | None = None
    minimum: str | None = None


class CountIn(BaseModel):
    add: int = 1
    day: date | None = Field(None, alias="date")


class HealthDaysIn(BaseModel):
    days: list[dict]


class WeightIn(BaseModel):
    kg: float
    at: datetime | None = None  # UTC offset required; omit for now


class PaymentIn(BaseModel):
    amount: str | float  # money out, as Wallet gives it ("€4.50", "4,50 €") or a number; `income` for money in
    merchant: str = Field(min_length=1, max_length=200)
    card: str | None = Field(None, max_length=100)  # the card or pass Wallet names
    at: datetime | None = None  # UTC offset required; omit for now
    source: Literal["wallet", "manual"] = "wallet"
    income: bool = False
    category: str | None = None
    place: str | None = Field(None, max_length=200)
    lat: float | None = None
    lon: float | None = None
    note: str | None = Field(None, max_length=500)


class PaymentPatch(BaseModel):
    category: str | None = None
    merchant: str | None = Field(None, max_length=200)
    note: str | None = Field(None, max_length=500)
    remember: bool = True  # a new category becomes the merchant's rule


class BudgetIn(BaseModel):
    monthly: float | None = None  # absent: unchanged; null: no monthly budget
    categories: dict[str, float | None] = {}  # null removes a category's budget


class BankLinkIn(BaseModel):
    bank: str
    country: str = Field("IT", pattern=r"^[A-Za-z]{2}$")
    server: str | None = None  # the app's server URL, for the callback when the server has none set


class InsightIn(BaseModel):
    kind: Literal["sleep", "recovery", "strain"]
    day: date | None = Field(None, alias="date")  # local date; omit for today


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


class LocationIn(BaseModel):
    lat: float
    lon: float
    accuracy: float | None = None  # metres
    at: datetime | None = None  # when the fix was taken, with its offset; default now


class TransitSettingsPatch(BaseModel):
    calendar: bool


class TransitAlertPatch(BaseModel):
    time: str | None = None
    days: list[int] | None = None
    minutes: int | None = None  # null: when it's time to leave
    enabled: bool | None = None


class LockIn(BaseModel):
    title: str
    minutes: int | None = None  # a one-off from now; else a schedule
    start: str | None = None  # HH:MM local
    end: str | None = None
    days: list[int] = []
    strict: bool = False


class LockPatch(BaseModel):
    title: str | None = None
    start: str | None = None
    end: str | None = None
    days: list[int] | None = None
    enabled: bool | None = None
    strict: bool | None = None


class UnlockIn(BaseModel):
    reason: str
    use_pass: bool = Field(False, alias="pass")  # an emergency pass, for a strict lock


class FocusIn(BaseModel):
    course_id: int
    focus_min: int = 25
    break_min: int = 5
    rounds: int = 4
    topic: str | None = None  # a notebook topic's id (t_…)
    topic_title: str | None = None
    strict: bool = True
    review: str | None = None  # the review session it's started from


class FocusEnd(BaseModel):
    reason: str | None = None  # needed in a focus round
    use_pass: bool = Field(False, alias="pass")  # an emergency pass, for a strict session's round


class FocusCheck(BaseModel):
    right: int
    total: int


class LimitIn(BaseModel):
    title: str
    minutes: int
    days: list[int] = []
    strict: bool = False


class LimitPatch(BaseModel):
    title: str | None = None
    minutes: int | None = None
    days: list[int] | None = None
    enabled: bool | None = None
    strict: bool | None = None


class UsageDayIn(BaseModel):
    date: str  # local
    minutes: int  # at least


class LimitHitIn(BaseModel):
    id: int
    date: str  # local
    at: str | None = None  # ISO, when it was reached


class UsageIn(BaseModel):
    days: list[UsageDayIn] = []
    limits: list[LimitHitIn] = []


class ErrandReplyIn(BaseModel):
    answer: str


class VideoIn(BaseModel):
    url: str  # a YouTube link, or text with one in it (what the share sheet gives)
    question: str | None = None
    conversation_id: str | None = None  # none: a new chat with Aide


class SiteIn(BaseModel):
    url: str  # a site (amazon.it) or a page on it, to log in there


class PasswordIn(BaseModel):
    """A saved login (Settings → Passwords). Secrets as SecretStr: they never show in a repr or an error."""
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=MAX_NAME)
    sites: list[str] = Field(min_length=1, max_length=MAX_SITES)
    username: SecretStr = Field(min_length=1, max_length=MAX_USERNAME)
    password: SecretStr = Field(min_length=1, max_length=MAX_PASSWORD)


class PasswordPatch(BaseModel):
    """Sites can't change: a password stays bound to the sites it was added for."""
    model_config = ConfigDict(extra="forbid")
    name: str | None = Field(default=None, min_length=1, max_length=MAX_NAME)
    username: SecretStr | None = Field(default=None, min_length=1, max_length=MAX_USERNAME)
    password: SecretStr | None = Field(default=None, min_length=1, max_length=MAX_PASSWORD)


class ScreenTimeDevice(BaseModel):
    authorized: bool
    allowed_apps: int = 0


class DeviceIn(BaseModel):
    token: str
    environment: str
    name: str = ""
    app: str = "ios"


class LiveTokenIn(BaseModel):
    kind: str
    token: str
    environment: str


class LiveSettingsPatch(BaseModel):
    events: bool | None = None
    locks: bool | None = None
    bedtime: bool | None = None
    focus: bool | None = None


class PriceWatchIn(BaseModel):
    url: str
    title: str
    below: float | None = None
    stock: bool = False
    every_hours: float | None = None
    conversation_id: str | None = None  # where it posts; none: the errand's chat, else Aide's main chat
    errand_id: int | None = None  # set up from one of this errand's product cards


class ProductBuyIn(BaseModel):
    url: str  # one of the errand's product cards
    size: str | None = None
    max_total: float | None = None


class PriceWatchPatch(BaseModel):
    title: str | None = None
    below: float | None = None
    stock: bool | None = None
    every_hours: float | None = None
    status: str | None = None  # active, ended


class ReleaseIn(BaseModel):
    query: str


class ReleasePicksIn(BaseModel):
    colourways: list[str]
    sizes: list[str] = []  # the sizes the user would take, the one they'd rather have first
    size: str | None = None  # the old field: one size
    max_total: float | None = None
    currency: str | None = None
    shops: list[str] = []
    mode: Literal["tell", "buy"] = "tell"


class LiveActivityIn(BaseModel):
    key: str = Field(min_length=1, max_length=200)
    token: str
    environment: str


class CompleteIn(BaseModel):
    completed: bool = True


class PlanItemsIn(BaseModel):
    items: list[str] | None = None  # the plan's item ids; None for every one still proposed


class EventMoveIn(BaseModel):
    start: str  # local YYYY-MM-DDTHH:MM (or with an offset), or YYYY-MM-DD for an all-day event
    end: str    # likewise; an all-day event's end is its last day


class SyncIn(BaseModel):
    cursor: str | None = None
    changes: list[ReminderChange] = []
    lists: list[str] | None = None  # the phone's Apple Reminders lists, by name
    default_list: str | None = None


UNAVAILABLE = "The assistant is unavailable right now. Try again."
PING = 15.0  # seconds of quiet on a stream before a keep-alive comment
MAX_EVENT_DAYS = 42  # GET /v1/events


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
               notebook: NotebookStore | None = None, engine: Engine | None = None,
               objectives: ObjectiveStore | None = None, planner: ObjectivePlanner | None = None,
               location: Location | None = None, transit_alerts: AlertStore | None = None,
               boards: Boards | None = None, drafts: Drafts | None = None,
               live: LiveActivities | None = None, leave: LeaveWatcher | None = None,
               quizzes: QuizStore | None = None, reviews: ReviewStore | None = None,
               locks: LockStore | None = None, errands: ErrandRunner | None = None,
               errand_store: ErrandStore | None = None, plans: PlanStore | None = None,
               foods: FoodDB | None = None, off: OpenFoodFacts | None = None,
               weights: WeightStore | None = None, videos: VideoWorker | None = None,
               lessons: LessonStore | None = None, finance: FinanceStore | None = None,
               banks: Banks | None = None, bank_redirect: str | None = None,
               bedtime: Bedtime | None = None, focus: FocusStore | None = None,
               focus_watch: FocusWatcher | None = None, watches: PriceWatches | None = None,
               releases: Releases | None = None, calls: LiveCalls | None = None,
               examplan: ExamPlan | None = None, passwords: PasswordStore | None = None,
               esse3: Esse3Reader | None = None, decider: Decider | None = None) -> FastAPI:
    db: Database = agent.db
    rated_replies = FeedbackStore(db.conn)
    calls = calls or LiveCalls(agent, db.conn)  # no voice to connect: calls are off
    push = push or Push(db.conn)  # no key: devices are kept, nothing is sent
    food = food or FoodStore(db.conn, tz)
    foods = foods or FoodDB(db.conn)
    off = off or OpenFoodFacts()
    habits = habits or HabitStore(db.conn, tz, food)
    locks = locks or LockStore(db.conn, tz)
    if habits.food is None:  # food habits tick from the food log
        habits.food = food
    health = health or HealthStore(db.conn, tz)
    nutrition = Nutrition(food, health)
    health.age = lambda: nutrition.targets()["profile"].get("age")
    weights = weights or WeightStore(db.conn, tz, health)
    finance = finance or FinanceStore(db.conn, tz)
    banks = banks or Banks(finance, None)  # no Enable Banking key: bank sync is off
    if habits.health_days is None:  # limit habits count from Apple Health
        habits.health_days = health
    digest = digest or DigestService(db.conn, agent.client, agent.model, tz, store, habits, calendar, health=health)
    wake = wake or WakeService(digest, health, tz, push=push)
    study = study or StudyStore(db, tz, calendar)
    moodle = moodle or MoodleSync(study, None, None)  # no AIDE_MOODLE_URL: enabled false
    passwords = passwords or PasswordStore(db.conn, None)  # no key: Passwords off
    notebook = notebook or NotebookStore(study)  # without a worker, nothing queued runs
    quizzes = quizzes or QuizStore(notebook)
    focus = focus or FocusStore(db.conn, tz, locks, study)

    async def lesson_ask(system: str, content: list[dict], max_tokens: int, fast: bool, live: bool) -> str:
        """A lesson's model call: through the engine (the Claude plan first, when it writes notes), never waiting at
        the plan's limit while the user is waiting; straight to OpenRouter without an engine."""
        if engine is not None:
            return await engine.ask(system, content, max_tokens, fast=fast, wait=not live)
        response = await agent.client.beta.messages.create(
            model=agent.model if fast else agent.smart_model, max_tokens=max_tokens, system=system,
            messages=[{"role": "user", "content": content}])
        return "".join(b.text for b in response.content if b.type == "text").strip()

    lessons = lessons or LessonStore(notebook, lesson_ask, engine.plan_blocked if engine else None, decider=decider)
    lessons.mastery = lessons.mastery or quizzes.mastery
    reviews = reviews or ReviewStore(db.conn, tz, calendar, study)
    plans = plans or PlanStore(db.conn, tz, calendar, reviews)
    objectives = objectives or ObjectiveStore(db.conn, tz, habits, food, health, store)
    location = location or Location(db.conn, push)
    live = live or LiveActivities(db.conn, push)
    drafts = drafts or Drafts(db.conn, tz)  # no mail account: none are made, and sending is a 503
    photos: PhotoStore | None = agent.photos
    errand_store = errands.store if errands else (errand_store or ErrandStore(db.conn, tz))
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
        return {"id": c["id"], "agent": c["agent"], "title": c["title"], "routine": c["routine"],
                "course": study.chat_course(c["id"]), "preview": c["preview"], "updated_at": local(c["updated_at"]),
                **({"working": True} if c["id"] in working else {}), **({"match": c["match"]} if "match" in c else {})}

    def team_json(t: dict) -> dict:
        return {**t, "ts": local(t["ts"])}

    def chat_json(conversation: str, turn: Turn) -> dict:
        return {"reply": turn.reply, "pending": pending(), "conversation_id": conversation,
                "message_id": agent.last_reply_id(CONVERSATION, conversation),
                "attachments": turn.attachments, "consulted": turn.consulted,
                "team": [team_json(t) for t in turn.team], **({"routed": turn.routed} if turn.routed else {})}

    turns: set[asyncio.Task] = set()  # streamed turns, held so they finish even if the app hangs up
    # conversation -> the chat turn running in it: the app that hung up on the stream asks for it in /v1/history
    working: dict[str, dict] = {}

    def streamed(run: Callable[[Callable[[str, dict], None]], Awaitable], done: Callable[[object], str],
                 hung_up: Callable[[], None] | None = None):
        """Run a turn as server-sent events: `run(emit)` emits events as they happen, `done(result)` is the last one.
        A comment every PING seconds keeps a quiet turn's connection open; `hung_up` is told if the app leaves first."""
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
            delivered = False
            try:
                while True:
                    try:
                        event = await asyncio.wait_for(events.get(), PING)
                    except asyncio.TimeoutError:
                        yield ": ping\n\n"
                        continue
                    if event is None:
                        break
                    yield event
                if task.cancelled() or task.exception():
                    error = task.cancelled() or task.exception()
                    yield sse("error", {"error": UNAVAILABLE if isinstance(error, anthropic.APIError)
                                        else "Something went wrong on the server. It's in the logs."})
                else:
                    yield done(task.result())
                delivered = True
            finally:
                if not delivered and hung_up:
                    hung_up()

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
        if not text and not body.photos and not body.files:
            raise HTTPException(400, "text is empty")
        agent.check_photos(body.photos)  # a plain 400, before a stream starts
        agent.check_files(body.files)
        conversation = body.conversation_id or CONVERSATION
        row = db.app_conversation(conversation) if conversation != CONVERSATION else None
        if conversation != CONVERSATION and row is None and body.stream:
            raise UnknownConversation(f"no conversation {conversation}")  # a plain 404, before the stream starts
        speaker = (row["agent"] if row else None) or ORCHESTRATOR
        activity_turn = live.turn(conversation, speaker)

        async def respond(on_team=None, on_text=None, on_step=None) -> Turn:
            mine = working[conversation] = {"agent": speaker, "text": text, "photos": body.photos, "files": body.files,
                                            "since": datetime.now(tz).replace(microsecond=0).isoformat()}

            def step(who: str, label: str | None, kind: str | None = None, page: str | None = None) -> None:
                if label is not None:
                    mine["step"] = label  # for an app that hung up and asks /v1/history
                if on_step:
                    on_step(who, label, kind, page)
            try:
                turn = await agent.respond(CONVERSATION, text, conversation, hooks(on_team, activity_turn.team),
                                           hooks(on_text, activity_turn.text) if on_text else None, body.photos,
                                           body.voice, step, body.files)
            except BaseException:
                activity_turn.failed()
                raise
            finally:
                if working.get(conversation) is mine:  # a second message, waiting its turn, may have taken the slot
                    working.pop(conversation)
            activity_turn.finished(turn.reply)
            return turn

        def hung_up() -> None:
            activity_turn.listening = False

        if not body.stream:
            return chat_json(conversation, await respond())
        return streamed(
            lambda emit: respond(lambda t: emit("team", team_json(t)),
                                 lambda delta, restart: emit("text", {"delta": delta, "restart": restart}),
                                 lambda who, label, kind=None, page=None:
                                 emit("page", {"agent": who, "jpeg": page}) if page else
                                 emit("step", {"agent": who, "text": label, **({"kind": kind} if kind else {})})),
            lambda turn: sse("reply", chat_json(conversation, turn)), hung_up)

    @app.post("/v1/confirm", dependencies=[Depends(auth)])
    async def confirm(body: ActionsIn | None = None):
        return {"result": await agent.confirm(CONVERSATION, body.ids if body else None,
                                              rest=bool(body and body.rest)), "pending": pending()}

    @app.post("/v1/cancel", dependencies=[Depends(auth)])
    async def cancel(body: ActionsIn | None = None):
        return {"result": await agent.cancel(CONVERSATION, body.ids if body else None), "pending": pending()}

    # -- activity and approvals ------------------------------------------------------------

    @app.get("/v1/activity", dependencies=[Depends(auth)])
    async def get_activity(agent_id: str | None = Query(None, alias="agent"), before: int | None = None,
                           limit: int = 100, kind: str | None = None, grouped: bool = False):
        limit = max(1, min(limit, 200))
        kinds = [k.strip() for k in kind.split(",") if k.strip()] if kind else None
        items = activity.recent(db.conn, check_agent(agent_id) if agent_id is not None else None, before, limit, kinds)
        rows = activity.grouped(items, tz) if grouped else items

        def out(i: dict) -> dict:
            row = {**i, "ts": local(i["ts"])}
            if "children" in i:
                row["children"] = [out(c) for c in i["children"]]
            return row
        return {"items": [out(i) for i in rows], "next": items[-1]["id"] if len(items) == limit else None}

    @app.get("/v1/approvals", dependencies=[Depends(auth)])
    async def approvals():
        actions = [{"id": a["id"], "summary": a["summary"], "agent": a["agent"] or "aide",
                    "conversation_id": a["conversation"] or CONVERSATION, "created_at": local(a["created_at"]),
                    "expires_at": local(a["expires_at"] or
                                        (datetime.fromisoformat(a["created_at"]) + PENDING_TTL).isoformat()),
                    **({"detail": a["detail"]} if a["detail"] else {})}
                   for a in db.pending_actions(CONVERSATION, PENDING_TTL)]
        today = objectives.today()
        plans = []
        for p in ("day", "week", "month"):  # each period's plan waiting, as one card
            block = objectives.block(p, today)
            if waiting_here := [o for o in block["objectives"] if o["status"] == "proposed"]:
                plans.append({**block, "objectives": waiting_here})
        proposed = [o for b in plans[::-1] for o in b["objectives"]]
        proposals = []
        for p in notebook.proposals(None, "pending"):
            course = study.course(p["course_id"]) or {}
            proposals.append({**notebook.proposal_json(p), "course_name": course.get("name"),
                              "conversation_id": p["chat"] or course.get("chat")})
        paused = engine.status()["paused"] if engine else None
        coming = sorted(((n, r) for r in routines.all() if (n := routines.next_run(r))), key=lambda x: x[0])
        replies = drafts.waiting()
        stuck = [errand_store.as_json(e) for e in errands.waiting()] if errands else []
        return {"waiting": len(actions) + len(plans) + len(proposals) + len(replies) + len(stuck)
                + (1 if paused else 0),
                "actions": actions, "plans": plans, "objectives": proposed, "proposals": proposals, "drafts": replies,
                "errands": stuck,
                "writer": paused, "upcoming": [routines.as_json(r) for _, r in coming[:5]]}

    # -- mail drafts ---------------------------------------------------------------------------

    def waiting_draft(draft_id: int) -> dict:
        d = drafts.get(draft_id)
        if d is None:
            raise HTTPException(404, "no such draft")
        if d["status"] != "waiting":
            raise HTTPException(409, f"the draft is {d['status']}")
        return d

    @app.get("/v1/mail/drafts", dependencies=[Depends(auth)])
    async def list_drafts():
        return {"drafts": drafts.waiting()}

    @app.patch("/v1/mail/drafts/{draft_id}", dependencies=[Depends(auth)])
    async def edit_draft(draft_id: int, body: DraftIn):
        waiting_draft(draft_id)
        if body.body is None or not body.body.strip():
            raise HTTPException(400, "body is empty")
        return drafts.revise(draft_id, body.body)

    @app.post("/v1/mail/drafts/{draft_id}/send", dependencies=[Depends(auth)])
    async def send_draft(draft_id: int, body: DraftIn | None = None):
        """The user's tap on Send: this is the confirmation, so it sends straight away."""
        waiting_draft(draft_id)
        text = body.body if body else None
        if text is not None and not text.strip():
            raise HTTPException(400, "body is empty")
        if drafts.gmail is None:
            raise HTTPException(503, "no mail account is connected")
        try:
            sent = await drafts.send(draft_id, text)
        except (RuntimeError, httpx.HTTPError) as e:
            log.warning("draft %d not sent: %s", draft_id, e)
            raise HTTPException(502, f"not sent: {e}") from None
        return {"ok": True, "draft": sent}

    @app.post("/v1/mail/drafts/{draft_id}/dismiss", dependencies=[Depends(auth)])
    async def dismiss_draft(draft_id: int):
        d = waiting_draft(draft_id)
        drafts.close(draft_id, "dismissed")
        activity.record(db.conn, d["agent"], "cancelled", f"Reply to {d['from']}: {d['subject']}")
        return {"ok": True}

    @app.post("/v1/mail/drafts/run", dependencies=[Depends(auth)])
    async def run_drafts():
        """The evening pass now: replies for the last days' mail that wants one."""
        if drafts.gmail is None:
            raise HTTPException(503, "no mail account is connected")
        try:
            made = await drafts.draft()
        except (ValueError, httpx.HTTPError, anthropic.APIError) as e:
            log.warning("drafting failed: %s", e)
            raise HTTPException(502, f"couldn't draft: {e}") from None
        return {"drafts": made, "waiting": drafts.waiting()}

    @app.post("/v1/new", dependencies=[Depends(auth)])
    async def new():
        agent.reset(CONVERSATION)
        return {"ok": True}

    @app.post("/v1/think", dependencies=[Depends(auth)])
    async def think(body: ThinkIn | None = None):
        body = body or ThinkIn()
        agent.think(CONVERSATION, body.conversation_id, body.on)
        return {"ok": True, "smart": body.on}

    @app.get("/v1/history", dependencies=[Depends(auth)])
    async def history(limit: int = 50, conversation_id: str | None = None):
        messages = agent.visible_history(CONVERSATION, max(1, min(limit, 500)), conversation_id)
        rated = rated_replies.ratings(agent._resolve(CONVERSATION, conversation_id))
        for m in messages:
            if m.get("id") in rated:
                m["feedback"] = rated[m["id"]]
            m["team"] = [team_json(t) for t in m["team"]]  # reminders as they are now, so a reload shows ticks made since
            for a in m["attachments"]:
                if a["type"] == "reminders":
                    a["reminders"] = [reminder_json(r, tz) if (r := store.get(old["id"])) else old
                                      for old in a["reminders"]]
                elif a["type"] == "events":  # a plan's items as they are now: added or dropped since
                    a["events"] = [plan_item(e) for e in a["events"]]
                elif a["type"] == "proposal" and notebook and (p := notebook.proposal(a["proposal"]["id"])):
                    a["proposal"] = notebook.proposal_json(p)  # applied or declined since
                elif a["type"] == "files":
                    a["files"] = [file_json(f) for old in a["files"] if (f := study.files.get(old["id"]))]
                elif a["type"] == "videos" and videos:  # a working card shows how far it got; deleted ones go
                    a["videos"] = [videos.store.card(v) for old in a["videos"] if (v := videos.store.get(old["id"]))]
            m["attachments"] = [a for a in m["attachments"] if a["type"] not in ("files", "videos") or a[a["type"]]]
        # A video's card shows once, on its latest message (the brief), not again on the "on it" before it.
        later: set[str] = set()
        for m in reversed(messages):
            for a in m["attachments"]:
                if a["type"] == "videos":
                    shown = {v["id"] for v in a["videos"]}
                    a["videos"] = [v for v in a["videos"] if v["id"] not in later]
                    later |= shown
            m["attachments"] = [a for a in m["attachments"] if a["type"] != "videos" or a["videos"]]
        # A turn still running here isn't in the history yet (it's saved when it ends): what was asked, and by whom.
        running = working.get(conversation_id or CONVERSATION)
        # The chat's live calls that ended after its first message shown (all of them when the whole chat is shown).
        since = (datetime.fromisoformat(messages[0]["ts"]).astimezone(timezone.utc).isoformat()
                 if messages and len(messages) >= limit and messages[0].get("ts") else None)
        call_rows = calls.store.since(conversation_id, since) if conversation_id else []
        return {"messages": messages, "smart": agent.thinking(CONVERSATION, conversation_id), "calls": call_rows,
                **({"working": running} if running else {})}

    @app.post("/v1/feedback", dependencies=[Depends(auth)])
    async def rate(body: FeedbackIn):
        try:
            saved = rated_replies.rate(agent._resolve(CONVERSATION, body.conversation_id), body.message_id, body.rating,
                                  body.note)
        except ValueError as e:
            raise HTTPException(400, str(e))
        return {"ok": True, "rating": saved["rating"] if saved else None}

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

        activity_turn = live.turn("team")

        async def answer(on_working=None, on_team=None) -> list[dict]:
            try:
                new = await agent.team_chat(CONVERSATION, text, hooks(on_working, activity_turn.working), on_team)
            except BaseException:
                activity_turn.failed()
                raise
            first = next((t for t in new if t["from"] in AGENTS and t["to"] == "team"), None)
            activity_turn.finished(first["text"] if first else "", first["from"] if first else None)
            return new

        if not body.stream:
            return team_body(await answer())
        return streamed(
            lambda emit: answer(lambda a: emit("working", {"agent": a}),
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

    # -- objectives ------------------------------------------------------------------

    def objective_or_404(public_id: str) -> dict:
        o = objectives.get(public_id)
        if o is None:
            raise HTTPException(404, f"no objective {public_id}")
        return o

    def objective_blocks(day: date | None) -> dict:
        day = day or objectives.today()
        return {p: objectives.block(p, day) for p in ("day", "week", "month")}

    @app.get("/v1/objectives", dependencies=[Depends(auth)])
    async def list_objectives(day: date | None = Query(None, alias="date")):
        return objective_blocks(day)

    @app.post("/v1/objectives", dependencies=[Depends(auth)], status_code=201)
    async def add_objective(body: ObjectiveIn):
        if body.agent not in AGENTS or AGENTS[body.agent].orchestrator:
            raise HTTPException(400, f"agent must be a specialist, not {body.agent!r}")
        o = objectives.add(body.agent, body.period, body.day or objectives.today(), body.title, body.why,
                           steps=body.steps)
        return objectives.as_json(o)

    @app.patch("/v1/objectives/{public_id}", dependencies=[Depends(auth)])
    async def edit_objective(public_id: str, body: ObjectivePatch):
        objective_or_404(public_id)
        return objectives.as_json(objectives.update(public_id, **body.model_dump(exclude_unset=True)))

    @app.post("/v1/objectives/accept", dependencies=[Depends(auth)])
    async def accept_objectives(body: ObjectivesAccept):
        day = body.day or objectives.today()
        try:
            objectives.accept(body.period, day, body.ids, drop=body.drop)
        except KeyError as e:
            raise HTTPException(404, e.args[0])
        return objectives.block(body.period, day)

    @app.post("/v1/objectives/plan", dependencies=[Depends(auth)])
    async def plan_objectives(body: ObjectivesPlan):
        if planner is None:
            raise HTTPException(409, "objectives can't be planned on this server")
        day = body.day or objectives.today()
        await planner.plan(body.period, day)
        return objectives.block(body.period, day)

    @app.get("/v1/conversations", dependencies=[Depends(auth)])
    async def conversations(q: str | None = None):
        return {"conversations": [conversation_json(c) for c in agent.conversations(CONVERSATION, q)]}

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

    def cadence(c: Cadence) -> dict:
        """The cadence as the store's per_week and max_count."""
        if c.type not in ("daily", "weekly", "limit"):
            raise HTTPException(400, "cadence type must be daily, weekly or limit")
        if c.type == "weekly" and c.per_week is None:
            raise HTTPException(400, "a weekly habit needs per_week")
        if c.type == "limit" and c.max is None:
            raise HTTPException(400, "a limit habit needs max")
        return {"per_week": c.per_week if c.type == "weekly" else None, "max_count": c.max if c.type == "limit" else None}

    @app.post("/v1/habits", dependencies=[Depends(auth)])
    async def add_habit(body: HabitIn):
        return habits.add(body.name, workouts=body.workouts, food=body.food, health=body.health,
                          minimum=body.minimum, **cadence(body.cadence)).as_json()

    @app.patch("/v1/habits/{habit_id}", dependencies=[Depends(auth)])
    async def edit_habit(habit_id: int, body: HabitPatch):
        if habits.get(habit_id) is None:
            raise HTTPException(404, f"no habit {habit_id}")
        changes = body.model_dump(exclude_unset=True, exclude={"cadence"})
        changes = {k: v for k, v in changes.items() if v is not None or k in ("food", "health", "minimum")}  # null stops it
        if body.cadence is not None:
            changes |= cadence(body.cadence)
        return habits.update(habit_id, **changes).as_json()

    @app.post("/v1/habits/{habit_id}/check", dependencies=[Depends(auth)])
    async def check_habit(habit_id: int, body: CheckIn | None = None):
        body = body or CheckIn()
        if habits.get(habit_id) is None:
            raise HTTPException(404, f"no habit {habit_id}")
        return habits.check(habit_id, body.day, body.done).as_json()

    @app.post("/v1/habits/{habit_id}/count", dependencies=[Depends(auth)])
    async def count_habit(habit_id: int, body: CountIn | None = None):
        body = body or CountIn()
        if habits.get(habit_id) is None:
            raise HTTPException(404, f"no habit {habit_id}")
        return habits.count(habit_id, body.add, body.day).as_json()

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

    async def food_day(d: date) -> dict:
        meals = food.day(d)
        day = nutrition.day(d)
        # goals are the day's targets (the base plus its workouts), so an older app's ring follows them
        quality = nutrition.meals(meals)
        return {"date": d.isoformat(), "meals": [food.as_json(m) | quality[m["id"]] for m in meals],
                "totals": totals(meals),
                "goals": day["targets"], "base": food.goals(), "left": day["left"], "bonus": day["bonus"],
                "score": day["score"], "line": day["line"]}

    @app.get("/v1/food", dependencies=[Depends(auth)])
    async def food_today(day: date | None = Query(None, alias="date")):
        return await food_day(day or food.today())

    @app.get("/v1/food/days", dependencies=[Depends(auth)])
    async def food_days(start: date | None = Query(None, alias="from"), end: date | None = Query(None, alias="to")):
        end = end or food.today()
        start = start or end - timedelta(days=6)
        if start > end or (end - start).days > 366:
            raise HTTPException(400, "from must be before to, at most a year apart")
        scores = nutrition.scores(start, end)
        return {"days": [{**d, "score": scores[d["date"]]} for d in food.days(start, end)]}

    @app.get("/v1/food/meals", dependencies=[Depends(auth)])
    async def food_meals(start: date | None = Query(None, alias="from"), end: date | None = Query(None, alias="to")):
        end = end or food.today()
        start = start or end - timedelta(days=6)
        if start > end or (end - start).days >= MAX_MEAL_DAYS:
            raise HTTPException(400, f"from must be before to, at most {MAX_MEAL_DAYS} days")
        return {"meals": [food.as_json(m) for m in food.between(start, end)]}

    def food_chat() -> str:
        """Coach's "Food log" chat: a new one each day (or when it was deleted), so a turn carries only the day's
        meals. The day before's is renamed "Food log, Thu 30 Oct"; the app finds today's by its title."""
        today = food.today()
        public_id, day = food.chat_day()
        old = db.app_conversation(public_id) if public_id else None
        if old is not None and day == today:
            return public_id
        if old is not None and old["title"] == "Food log":
            db.set_conversation_title(old["id"], f"Food log, {day or today - timedelta(days=1):%a %-d %b}")
        row = db.new_app_conversation("coach")
        db.set_conversation_title(row["id"], "Food log")
        food.set_chat(row["public_id"], today)
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
        if codes := list(dict.fromkeys(c for c in ("".join(b.split()) for b in body.barcodes) if c.isdigit())):
            text = "\n".join(filter(None, [text, f"(Barcodes the app read in the photos: {', '.join(codes)}. find_food "
                                                  "each one; one it doesn't have, save from its label in the photos "
                                                  "with that barcode.)"]))
        conversation = food_chat()
        turn = await agent.respond(CONVERSATION, text or "Log this.", conversation, photos=body.photos)
        meals = next((a["meals"] for a in turn.attachments if a["type"] == "meals"), [])
        return {"reply": turn.reply, "meals": meals, "conversation_id": conversation}

    # A scanned barcode: the saved food, else Open Food Facts' product (saved), else a photo of its label read once.
    # Logging one is the server's own sum, no model call.

    @app.get("/v1/food/barcode/{code}", dependencies=[Depends(auth)])
    async def food_by_barcode(code: str):
        code = code.strip()
        if not code.isdigit() or not 6 <= len(code) <= 14:
            raise HTTPException(400, "a barcode is 6–14 digits")
        if saved := foods.by_barcode(code):
            return {"food": foods.as_json(saved)}
        try:
            p = await off.barcode(code)
        except (RuntimeError, httpx.HTTPError) as e:
            log.warning("Open Food Facts: %s", e)
            raise HTTPException(502, f"couldn't reach Open Food Facts: {e}") from None
        if p is None:
            return {"food": None}
        return {"food": foods.as_json(save_product(foods, p, code))}

    async def ask_once(system: str, content: list[dict], max_tokens: int) -> str:
        if engine is not None:
            return await engine.ask(system, content, max_tokens, background=True)
        response = await agent.client.beta.messages.create(
            model=agent.smart_model, max_tokens=max_tokens, system=system,
            messages=[{"role": "user", "content": content}])
        return "".join(b.text for b in response.content if b.type == "text").strip()

    @app.post("/v1/food/label", dependencies=[Depends(auth)])
    async def food_label(body: LabelIn):
        code = body.barcode.strip()
        if not code.isdigit():
            raise HTTPException(400, "a barcode is digits only")
        if photos is None or (loaded := photos.load(body.photo)) is None:
            raise HTTPException(400, f"no photo {body.photo}")
        try:
            label = await read_label(ask_once, *loaded)
        except (httpx.HTTPError, anthropic.APIError) as e:
            log.warning("reading a label failed: %s", e)
            raise HTTPException(502, f"couldn't read the label: {e}") from None
        except ValueError as e:
            raise HTTPException(422, str(e)) from None
        name = (" ".join(body.name.split()) or label["name"] or f"Product {code}")[:MAX_FOOD_NAME]
        try:
            saved = foods.save(name, label["kcal_100g"], label["protein_100g"], label["carbs_100g"],
                               label["fat_100g"], "label", brand=label["brand"][:MAX_FOOD_NAME], barcode=code,
                               serving_g=label["serving_g"], source_ref=body.photo, **label["quality"])
        except ValueError as e:
            raise HTTPException(422, f"the label didn't read right ({e}); try another photo") from None
        return {"food": foods.as_json(saved)}

    def meal_time(day: date | None) -> datetime:
        """Now, or now's time on an earlier day."""
        today = food.today()
        if day and day > today:
            raise HTTPException(400, "a meal can't be in the future")
        when = datetime.now(tz)
        return datetime.combine(day, when.time(), tz) if day and day != today else when

    def food_name(rows: list[dict]) -> str:
        """One food: its name (and brand); more: "Yogurt greco, granola and banana"."""
        if len(rows) == 1:
            name, brand = rows[0]["name"], foods.get(rows[0]["food_id"])["brand"]
            return f"{name} ({brand})" if brand and brand.lower() not in name.lower() else name
        names = [r["name"] for r in rows]
        return (", ".join(names[:-1]) + " and " + names[-1])[:MAX_FOOD_NAME]

    async def logged(meal: dict, rows: list[dict], how: str, conversation_id: str | None) -> dict:
        """A meal the app logged without the model: in the activity feed and in Coach's chat (the one it was logged
        from, else the Food log), so it's seen there and Coach knows."""
        said = f"{meal['name']}, {rows[0]['grams']:g} g" if len(rows) == 1 else meal["name"]
        grams = said if len(rows) < 2 else ", ".join(f"{r['name']} {r['grams']:g} g" for r in rows)
        activity.record(db.conn, "coach", "action", "Logged a meal", f"{grams}, {how} in the app")
        row = db.app_conversation(conversation_id) if conversation_id else None
        note = (f"{SCANNED}: {grams}, logged by the app as meal {meal['id']}.]" if how == "scanned" else
                f"[Logged from history in the app: {grams}, as meal {meal['id']}.]")
        await agent.post(row["public_id"] if row and row["agent"] == "coach" else food_chat(), note,
                         f"Logged {said}: {meal['calories']} kcal.", [{"type": "meals", "meals": [food.as_json(meal)]}],
                         record=False)
        return {"meal": food.as_json(meal)}

    def from_items(items: list[dict]) -> tuple[list[dict], dict, str]:
        try:
            return foods.from_items(items, "")
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'"))
        except ValueError as e:
            raise HTTPException(400, str(e))

    @app.post("/v1/food/foods/{food_id}/log", dependencies=[Depends(auth)])
    async def log_one_food(food_id: int, body: FoodLogOne):
        if foods.get(food_id) is None:
            raise HTTPException(404, f"no food {food_id}")
        when = meal_time(body.day)
        rows, sums, notes = from_items([{"food_id": food_id, "grams": body.grams}])
        meal = food.add(food_name(rows), **sums, water_ml=foods.water(rows), eaten_at=when, notes=notes)
        foods.keep_items(meal["id"], rows, count=True)
        return await logged(meal, rows, "scanned", body.conversation_id)

    # What the user eats, to log it again: saved foods and past meals, no model call.
    @app.get("/v1/food/recent", dependencies=[Depends(auth)])
    async def food_recent(q: str = "", limit: int = Query(40, ge=1, le=100),
                          order: str = Query("usual", pattern="^(usual|latest)$")):
        return foods.latest(tz, q, limit) if order == "latest" else foods.recent(tz, q, limit)

    @app.post("/v1/food/foods/log", dependencies=[Depends(auth)])
    async def log_foods(body: FoodsLogIn):
        when = meal_time(body.day)
        rows, sums, notes = from_items([i.model_dump() for i in body.items])
        try:
            meal = food.add((body.name or "").strip() or food_name(rows), **sums, water_ml=foods.water(rows),
                            eaten_at=when, notes=notes)
        except ValueError as e:
            raise HTTPException(400, str(e))
        foods.keep_items(meal["id"], rows, count=True)
        return await logged(meal, rows, "from history", body.conversation_id)

    @app.post("/v1/food/meals/{meal_id}/again", dependencies=[Depends(auth)])
    async def meal_again(meal_id: int, body: MealAgainIn):
        """The same meal again: its items at the same grams (saved foods with today's numbers), else its totals."""
        old = meal_or_404(meal_id)
        when = meal_time(body.day)
        items = []
        for i in foods.items(meal_id):
            if i["food_id"] is not None and foods.get(i["food_id"]):
                items.append({"food_id": i["food_id"], "grams": i["grams"]})
            elif i["grams"]:  # an item estimated on its own: its numbers per 100 g from what it came to
                per = 100 / i["grams"]
                items.append({"name": i["name"], "grams": i["grams"], "kcal_100g": i["calories"] * per,
                              "protein_100g": i["protein_g"] * per, "carbs_100g": i["carbs_g"] * per,
                              "fat_100g": i["fat_g"] * per})
            else:
                items = None  # can't be rebuilt from its items: copy the totals
                break
        drinks = {k: old[k] for k in ("water_ml", "caffeine_mg")}
        if items:
            rows, sums, notes = from_items(items)
            # Its drinks' water plus the plain water it had (an older meal's water_ml was Coach's figure for both)
            drinks["water_ml"] = max(old["water_ml"], foods.water(rows))
            meal = food.add(old["name"], **sums, **drinks, eaten_at=when, notes=notes, emoji=old["emoji"])
            foods.keep_items(meal["id"], rows, count=True)
        else:
            rows = []
            meal = food.add(old["name"], **{k: old[k] for k in MACROS}, **drinks, eaten_at=when,
                            notes=free_notes(old["notes"]), emoji=old["emoji"])
        return await logged(meal, rows, "again", body.conversation_id)

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

    def proposer() -> dict:
        """Who answers Ask Coach: the model, and whether it runs on the Claude plan or is paid per token."""
        model = re.sub(r"(\d)-(\d)", r"\1.\2", agent.smart_model.split("/")[-1].removeprefix("claude-"))
        via = "plan" if engine is not None and engine.plan_for_background() else (
            "openrouter" if agent.smart_model.startswith("anthropic/") else "api")
        return {"model": "Claude " + model.replace("-", " ").title(), "via": via}

    @app.get("/v1/food/targets", dependencies=[Depends(auth)])
    async def food_targets():
        return nutrition.targets() | {"coach": proposer(), "weight": weights.summary()}

    @app.put("/v1/food/targets", dependencies=[Depends(auth)])
    async def set_food_targets(body: FoodTargetsIn):
        try:
            return nutrition.set_targets(
                base=body.base.model_dump() if body.base else None,
                workouts=body.workouts.model_dump(exclude_none=True) if body.workouts else None,
                profile=body.profile.model_dump(exclude_unset=True) if body.profile else None)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None

    @app.post("/v1/food/targets/propose", dependencies=[Depends(auth)])
    async def propose_food_targets(body: ProposeIn | None = None):
        """Coach's proposal from the profile, Apple Health and the food log (and the user's answers to its last
        questions); nothing is saved until a PUT."""
        from ..notebook import parse_json  # notebook imports a lot; only here
        today = food.today()
        answers = [a.model_dump() for a in body.answers if a.answer.strip()] if body else []
        text = proposal_input(nutrition, food.days(today - timedelta(days=14), today - timedelta(days=1)), answers,
                              weights)
        try:
            answer = await ask_once(PROPOSE_PROMPT, [{"type": "text", "text": text}], PROPOSE_TOKENS)
            proposal = parse_proposal(parse_json(answer))
            nutrition.coach_said(proposal, answers)  # remembered for the next one
            return proposal
        except (httpx.HTTPError, anthropic.APIError, RuntimeError) as e:
            log.warning("proposing food targets failed: %s", e)
            raise HTTPException(502, f"Coach couldn't answer: {e}") from None
        except ValueError as e:
            raise HTTPException(502, str(e)) from None

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
        def brief(cid: int) -> dict | None:
            if (summary := notebook.summary(cid)) is None:
                return None
            return summary | {"mastery": quizzes.mastery(cid), **quizzes.due_json(cid)}

        def exam(c: dict) -> dict:
            """The calendar's next exam, else the earliest exam or mid-term the course's own dates say is coming."""
            out = study.course_json(c)
            if out["next_exam"] is not None:
                return out | {"next_exam": out["next_exam"] | {"from": "calendar", "all_day": False}}
            today = datetime.now(tz).date()
            if notebook is not None and (d := next((d for d in notebook.dates(c["id"], since=today)
                                                    if d["kind"] in ("exam", "mid-term")), None)):
                at = datetime.fromisoformat(f"{d['date']}T{d['time'] or '00:00'}").replace(tzinfo=tz)
                return out | {"next_exam": {"date": at.isoformat(), "title": f"{c['name']} {d['what']}",
                                            "from": "course", "all_day": d["time"] is None}}
            return out

        return {"courses": [exam(c) | {"notebook": brief(c["id"])} for c in courses],
                "unfiled": study.unfiled(),
                "now": {"course": on[0]["id"], "name": on[0]["name"], "ends": on[1].astimezone(tz).isoformat()}
                if on else None,
                "transcription": worker is not None and worker.transcribe is not None}

    def dates_json(course_id: int, archived: bool = False) -> dict:
        today = datetime.now(tz).date().isoformat()

        def signup(d: dict) -> dict:
            if esse3 is None or d.get("by") != "esse3" or d["kind"] != "exam":
                return {}
            return {"signup": esse3.signup(d["id"])}

        return {"course": course_id, "items": [d | {"past": d["date"] < today} | signup(d)
                                               for d in notebook.dates(course_id, archived=archived)],
                "read_at": notebook.dates_read_at(course_id), "reading": notebook.dates_reading(course_id)}

    def dates_or_404(course_id: int) -> int:
        if study.course(course_id) is None:
            raise HTTPException(404, f"no course {course_id}")
        if notebook is None:
            raise HTTPException(404, "no notebooks on this server")
        return course_id

    async def dates_changed(course_id: int, archived: bool = False) -> dict:
        """After the user's change: the calendar checked again now, and a missing exam proposed in the chat."""
        await notebook.calendar_check(course_id)
        notebook.reread_dates(course_id)  # no model call when nothing it reads changed: only the proposal
        return dates_json(course_id, archived)

    @app.get("/v1/study/courses/{course_id}/dates", dependencies=[Depends(auth)])
    async def course_dates(course_id: int, archived: bool = False):
        return dates_json(dates_or_404(course_id), archived)

    @app.post("/v1/study/courses/{course_id}/dates/{date_id}/archive", dependencies=[Depends(auth)])
    async def archive_course_date(course_id: int, date_id: str):
        """Not taking this exam: out of the dates, the plan and the reminders (with its sign-up's dates), and
        never signed up for by Aide."""
        try:
            notebook.archive_date(dates_or_404(course_id), date_id)
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'\""))
        if esse3 is not None:
            esse3.forget(date_id)
        return dates_json(course_id, archived=True)

    @app.delete("/v1/study/courses/{course_id}/dates/{date_id}/archive", dependencies=[Depends(auth)])
    async def unarchive_course_date(course_id: int, date_id: str):
        try:
            notebook.unarchive_date(dates_or_404(course_id), date_id)
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'\""))
        return dates_json(course_id, archived=True)

    @app.post("/v1/study/courses/{course_id}/dates", dependencies=[Depends(auth)])
    async def add_course_date(course_id: int, body: CourseDateIn, archived: bool = False):
        try:
            item = notebook.add_date(dates_or_404(course_id), body.model_dump(exclude_none=True))
        except ValueError as e:
            raise HTTPException(400, f"a date needs what it is and a real date: {e}")
        return JSONResponse(await dates_changed(course_id, archived) | {"item": item["id"]}, status_code=201)

    @app.patch("/v1/study/courses/{course_id}/dates/{date_id}", dependencies=[Depends(auth)])
    async def edit_course_date(course_id: int, date_id: str, body: CourseDateIn, archived: bool = False):
        try:
            notebook.edit_date(dates_or_404(course_id), date_id, body.model_dump(exclude_unset=True))
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'\""))
        except ValueError as e:
            raise HTTPException(400, f"a date needs what it is and a real date: {e}")
        return await dates_changed(course_id, archived)

    @app.delete("/v1/study/courses/{course_id}/dates/{date_id}", dependencies=[Depends(auth)])
    async def hide_course_date(course_id: int, date_id: str, archived: bool = False):
        try:
            notebook.hide_date(dates_or_404(course_id), date_id)
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'\""))
        return dates_json(course_id, archived)

    @app.post("/v1/study/courses/{course_id}/dates/read", dependencies=[Depends(auth)])
    async def read_course_dates(course_id: int, archived: bool = False):
        """Professor reads the course's page and files for its dates again, even when nothing changed."""
        notebook.reread_dates(dates_or_404(course_id), force=True)
        return JSONResponse(dates_json(course_id, archived), status_code=202)

    def examplan_or_404() -> ExamPlan:
        if examplan is None:
            raise HTTPException(404, "the exam plan isn't set up")
        return examplan

    @app.get("/v1/study/plan", dependencies=[Depends(auth)])
    async def study_plan(fresh: bool = False):
        return await examplan_or_404().plan(fresh=fresh)

    @app.put("/v1/study/plan/courses/{course_id}", dependencies=[Depends(auth)])
    async def edit_study_plan(course_id: int, body: dict = Body(...)):
        """A course's likely exam date (`expected`, null to drop it) and which topics a target covers
        (`topics` with the target's `key`, null for all)."""
        plan = examplan_or_404()
        if study.course(course_id) is None:
            raise HTTPException(404, f"no course {course_id}")
        if unknown := set(body) - {"expected", "key", "topics"}:
            raise HTTPException(422, f"unknown fields: {', '.join(sorted(unknown))}")
        try:
            if "expected" in body:
                plan.set_expected(course_id, date.fromisoformat(body["expected"]) if body["expected"] else None)
            if "topics" in body:
                if not isinstance(body.get("key"), str) or not body["key"]:
                    raise ValueError("topics need the target's key")
                topics = body["topics"]
                if topics is not None and (not isinstance(topics, list) or not all(isinstance(t, str) for t in topics)):
                    raise ValueError("topics is a list of topic ids, or null")
                plan.set_topics(body["key"], topics, course_id)
        except (ValueError, TypeError) as e:
            raise HTTPException(422, str(e)) from None
        return await plan.plan(fresh=True)

    @app.get("/v1/study/settings", dependencies=[Depends(auth)])
    async def study_settings():
        return examplan_or_404().caps()

    @app.patch("/v1/study/settings", dependencies=[Depends(auth)])
    async def edit_study_settings(body: dict = Body(...)):
        try:
            return examplan_or_404().update_caps(**body)
        except ValueError as e:
            raise HTTPException(422, str(e)) from None

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
    async def get_lecture(lecture_id: str, transcript: bool = False, plain: bool = False, latex: bool = False,
                          inline: bool = False):
        out = study.as_json(lecture_or_404(lecture_id), full=True, transcript=transcript)
        if plain and out.get("notes"):
            out["notes"] = readable(out["notes"], latex, inline)
        return out

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
                       name: str = Query("Untitled.pdf", max_length=300), conversation_id: str | None = None,
                       from_: str | None = Query(None, alias="from")):
        kind = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if kind != "application/pdf":
            raise HTTPException(415, "send the file as application/pdf")
        course_id = course_or_400(course)
        target = lecture_or_404(lecture) if lecture else None
        if target is not None:
            course_id = target["course_id"] if course_id is None else course_id
        source = "upload"
        if from_ == "folder":  # the Mac's course folder (#73)
            source = "folder"
        elif from_ is not None:
            raise HTTPException(400, "from is folder")
        if conversation_id and course_id is None and target is None:  # for a chat message (#78)
            if conversation_id != CONVERSATION and db.app_conversation(conversation_id) is None:
                raise HTTPException(404, f"no conversation {conversation_id}")
            course_id = study.chat_course(conversation_id)  # a course chat's PDF is that course's material
            source = "upload" if course_id else "chat"
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
                if source == "folder" and (twin := await study.files.twin(tmp, course_id)):
                    return JSONResponse({**file_json(twin), "duplicate": True})
                f = await study.files.add(tmp, name, course_id, target["id"] if target else None,
                                          source=source, public_id=public_id)
            except PdfError as e:
                raise HTTPException(400, str(e))
        finally:
            tmp.unlink(missing_ok=True)
        if target is not None:
            study.rewrite(target["id"])
            if worker is not None:
                worker.kick()
        if notebook is not None and course_id is not None:
            notebook.maybe_dates(course_id, [f])
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

    @app.get("/v1/files/{file_id}/pages/{page}", dependencies=[Depends(auth)])
    async def get_file_page(file_id: str, page: int):
        """A page drawn as a JPEG: the app's figures in topic pages."""
        f = file_or_404(file_id)
        if not 1 <= page <= f["pages"]:
            raise HTTPException(404, f"{f['name']} has {f['pages']} pages")
        try:
            data = await page_image(study.files.path(f), page)
        except Exception:
            log.exception("couldn't draw %s p. %d", file_id, page)
            raise HTTPException(500, "couldn't draw the page")
        return Response(data, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400"})

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

    # -- passwords -------------------------------------------------------------------
    # Write-only: no route returns a password, and every change is in the activity feed and pushed, so one the user
    # didn't make shows at once.

    def password_error(e: PasswordError) -> HTTPException:
        if isinstance(e, Locked):
            return HTTPException(503, str(e))
        return HTTPException(429 if isinstance(e, TooMany) else 400, str(e))

    async def password_changed(title: str, body: str) -> None:
        activity.record(db.conn, "aide", "passwords", title)
        await push.send_passwords(title, body)

    @app.get("/v1/passwords", dependencies=[Depends(auth)])
    async def passwords_list():
        return passwords.status()

    @app.post("/v1/passwords", dependencies=[Depends(auth)], status_code=201)
    async def passwords_add(body: PasswordIn):
        try:
            entry = passwords.add(body.name, body.sites, body.username.get_secret_value(),
                                  body.password.get_secret_value())
        except PasswordError as e:
            raise password_error(e)
        await password_changed(f"Password for {entry['name']} added",
                               f"A password for {entry['name']} was saved in Aide.")
        if esse3 is not None:
            esse3.login_changed(entry["sites"])
        return entry

    @app.patch("/v1/passwords/{entry_id}", dependencies=[Depends(auth)])
    async def passwords_update(entry_id: str, body: PasswordPatch):
        try:
            entry = passwords.update(entry_id, body.name,
                                     body.username.get_secret_value() if body.username else None,
                                     body.password.get_secret_value() if body.password else None)
        except KeyError:
            raise HTTPException(404, "no such password")
        except PasswordError as e:
            raise password_error(e)
        what = "password" if body.password else "username" if body.username else "name"
        await password_changed(f"Password for {entry['name']} changed",
                               f"The {what} for {entry['name']} in Aide was changed.")
        if esse3 is not None and (body.username or body.password):
            esse3.login_changed(entry["sites"])
        return entry

    @app.delete("/v1/passwords/{entry_id}", dependencies=[Depends(auth)])
    async def passwords_delete(entry_id: str):
        try:
            gone = passwords.delete(entry_id)
        except KeyError:
            raise HTTPException(404, "no such password")
        except PasswordError as e:
            raise password_error(e)
        await password_changed(f"Password for {gone['name']} deleted",
                               f"The password for {gone['name']} was deleted from Aide.")
        return {"ok": True}

    # -- Esse3 -------------------------------------------------------------------------

    @app.get("/v1/esse3", dependencies=[Depends(auth)])
    async def esse3_get():
        if esse3 is None:
            return {"connected": False, "read_at": None, "error": None, "exams": [], "transcript": [],
                    "credits": {"passed": 0, "planned": 0}, "average": None}
        return esse3.json()

    @app.post("/v1/esse3/read", dependencies=[Depends(auth)])
    async def esse3_read():
        """Study opened: read now unless a read finished in the last 10 min. Waits for the read (~5–15 s)."""
        if esse3 is None:
            raise HTTPException(503, "Esse3 isn't on")
        await esse3.read_if_stale()
        return esse3.json()

    def esse3_or_503() -> Esse3Reader:
        if esse3 is None:
            raise HTTPException(503, "Esse3 isn't on")
        return esse3

    def esse3_answer(signup: dict) -> JSONResponse:
        """200 when it's settled; 202 while Aide's browser is on Esse3 (the outcome comes on the signup and by push)."""
        return JSONResponse({"signup": signup}, status_code=202 if signup.get("busy") else 200)

    @app.post("/v1/esse3/exams/{date_id}/signup", dependencies=[Depends(auth)])
    async def esse3_sign_up(date_id: str):
        """The user's Sign me up (the tap is the confirmation): an errand in Aide's browser when sign-up is open
        (202, a minute or two), else as soon as it opens. 409 when it can't start."""
        try:
            return esse3_answer(await esse3_or_503().sign_up(date_id))
        except KeyError:
            raise HTTPException(404, "not an Esse3 exam session")
        except SignUpFailed as e:
            return JSONResponse({"error": str(e), "kind": e.kind}, status_code=409)

    @app.delete("/v1/esse3/exams/{date_id}/signup", dependencies=[Depends(auth)])
    async def esse3_cancel(date_id: str):
        """The user's Cancel sign-up: an errand on Esse3 while its window is open (202), or the wish to sign up when it
        opens (and an errand signing up, stopped)."""
        try:
            return esse3_answer(await esse3_or_503().cancel(date_id))
        except KeyError:
            raise HTTPException(404, "not an Esse3 exam session")
        except SignUpFailed as e:
            return JSONResponse({"error": str(e), "kind": e.kind}, status_code=409)

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
    async def get_notebook(course: int, plain: bool = False, latex: bool = False, inline: bool = False):
        out = notebook.notebook_json(course_or_404(course))
        if plain and out["introduction"]:
            out["introduction"] = readable(out["introduction"], latex, inline)
        return out

    @app.get("/v1/notebook/formulas", dependencies=[Depends(auth)])
    async def get_formulas(course: int, plain: bool = False, latex: bool = False, inline: bool = False):
        """The formula sheet: every topic's Formulas, gathered as it's read."""
        body = notebook.formulas(course_or_404(course))
        return {"course": course, "body": readable(body, latex, inline) if plain else body}

    @app.post("/v1/notebook", dependencies=[Depends(auth)])
    async def start_notebook(course: int):
        try:
            notebook.start(course_or_404(course))
        except ValueError as e:
            raise HTTPException(409, str(e))
        return JSONResponse(notebook.notebook_json(course), status_code=202)

    @app.post("/v1/notebook/figures", dependencies=[Depends(auth)])
    async def find_figures(course: int):
        """Every slide looked at once, then figures added where the topics miss good ones."""
        if not notebook.topics(course_or_404(course)):
            raise HTTPException(409, "the notebook has no topics yet")
        notebook.enqueue(course, "figures", again=True)
        return JSONResponse(notebook.notebook_json(course), status_code=202)

    @app.get("/v1/notebook/exercises", dependencies=[Depends(auth)])
    async def list_exercises(course: int):
        return {"course": course, "sets": [notebook.exercise_json(e) for e in
                                           notebook.exercise_sets(course_or_404(course))]}

    @app.post("/v1/notebook/exercises", dependencies=[Depends(auth)])
    async def write_exercises(course: int, body: Exercises | None = None):
        """Solved exercises for the written topics (or those named), in the background."""
        try:
            notebook.write_exercises(course_or_404(course), body.topics if body else None)
        except KeyError as e:
            raise HTTPException(400, str(e).strip("'\""))
        except ValueError as e:
            raise HTTPException(409, str(e))
        return JSONResponse(notebook.notebook_json(course), status_code=202)

    @app.get("/v1/exercises/{set_id}", dependencies=[Depends(auth)])
    async def get_exercises(set_id: str, plain: bool = False, latex: bool = False, inline: bool = False):
        if (e := notebook.exercise_set(set_id)) is None:
            raise HTTPException(404, f"no exercises {set_id}")
        out = notebook.exercise_json(e, full=True)
        if plain:
            out["body"] = readable(out["body"], latex, inline)
        return out

    @app.get("/v1/notebook/mocks", dependencies=[Depends(auth)])
    async def list_mocks(course: int):
        return {"course": course, "mocks": quizzes.mocks_json(course_or_404(course))}

    @app.post("/v1/notebook/mocks", dependencies=[Depends(auth)])
    async def write_mock(course: int, past: bool = False):
        """A mock exam like the real one, in the background; `past`: the course's own papers copied instead."""
        try:
            notebook.write_mock(course_or_404(course), past=past)
        except ValueError as e:
            raise HTTPException(409, str(e))
        return JSONResponse(notebook.notebook_json(course), status_code=202)

    @app.get("/v1/mocks/{mock_id}", dependencies=[Depends(auth)])
    async def get_mock(mock_id: str, plain: bool = False):
        """The paper, without its answers."""
        if (m := notebook.mock(mock_id)) is None:
            raise HTTPException(404, f"no mock exam {mock_id}")
        out = notebook.mock_json(m, paper=True)
        if plain:
            out["body"] = readable(out["body"])
            for q in out["questions"]:
                q["text"] = readable(q["text"])
                q["options"] = [o | {"text": readable(o["text"])} for o in q["options"]]
        return out

    @app.get("/v1/topics/{topic_id}", dependencies=[Depends(auth)])
    async def get_topic(topic_id: str, plain: bool = False, latex: bool = False, inline: bool = False):
        if (t := notebook.topic(topic_id)) is None:
            raise HTTPException(404, f"no topic {topic_id}")
        out = notebook.topic_json(t, full=True)
        if plain:
            out["body"] = readable(out["body"], latex, inline)
            out["cards_list"] = [{"q": readable(c["q"]), "a": readable(c["a"])} for c in out["cards_list"]]
        return out

    def lesson_or_404(lesson_id: str) -> dict:
        if (lesson := lessons.lesson(lesson_id)) is None:
            raise HTTPException(404, f"no lesson {lesson_id}")
        return lesson

    def lesson_json(lesson: dict, plain: bool, latex: bool, inline: bool) -> dict:
        return lessons.json(lesson, (lambda s: readable(s, latex, inline)) if plain else (lambda s: s))

    @app.get("/v1/lessons", dependencies=[Depends(auth)])
    async def lesson_path(course: int):
        return lessons.path(course_or_404(course))

    @app.get("/v1/topics/{topic_id}/lesson", dependencies=[Depends(auth)])
    async def get_lesson(topic_id: str, plain: bool = False, latex: bool = False, inline: bool = False):
        if (t := notebook.topic(topic_id)) is None:
            raise HTTPException(404, f"no topic {topic_id}")
        if (lesson := lessons.for_topic(t["id"])) is None:
            raise HTTPException(404, "no lesson for this topic yet")
        return lesson_json(lesson, plain, latex, inline)

    @app.post("/v1/topics/{topic_id}/lesson", dependencies=[Depends(auth)])
    async def start_lesson(topic_id: str, body: LessonStart | None = None, plain: bool = False, latex: bool = False,
                           inline: bool = False):
        if (t := notebook.topic(topic_id)) is None:
            raise HTTPException(404, f"no topic {topic_id}")
        body = body or LessonStart()
        try:
            lesson = lessons.want(t, again=body.again)
        except ValueError as e:
            raise HTTPException(409, str(e))
        if body.restart and lesson["status"] == "ready":
            lesson = lessons.restart(lesson["public_id"])
        return JSONResponse(lesson_json(lesson, plain, latex, inline),
                            status_code=202 if lesson["status"] == "building" else 200)

    @app.post("/v1/lessons/{lesson_id}/progress", dependencies=[Depends(auth)])
    async def lesson_progress(lesson_id: str, body: LessonProgress):
        lesson_or_404(lesson_id)
        try:
            return lessons.brief(lessons.advance(lesson_id, body.at))
        except ValueError as e:
            raise HTTPException(409 if "written" in str(e) else 400, str(e))

    @app.post("/v1/lessons/{lesson_id}/check", dependencies=[Depends(auth)])
    async def lesson_check(lesson_id: str, body: LessonCheck, plain: bool = False, latex: bool = False,
                           inline: bool = False):
        lesson_or_404(lesson_id)
        try:
            out = await lessons.answer(lesson_id, body.step, body.check, body.answer)
        except LookupError as e:
            raise HTTPException(404, str(e))
        except ValueError as e:
            raise HTTPException(409 if "written" in str(e) else 400, str(e))
        except Exception as e:  # the mark couldn't be had: the app shows what was expected
            log.warning("lesson mark failed: %s", e)
            c = lessons._check(lessons.lesson(lesson_id), body.step, body.check)
            out = {"step": body.step, "check": body.check, "type": c["type"], "answer": body.answer.strip(),
                   "correct": None, "awarded": None, "key": None, "feedback": None, "key_why": None,
                   "expected": c.get("answer")}
        if plain:
            for k in ("feedback", "key_why", "expected"):
                if out.get(k):
                    out[k] = readable(out[k], latex, inline)
        return out

    @app.post("/v1/lessons/{lesson_id}/ask", dependencies=[Depends(auth)])
    async def lesson_question(lesson_id: str, body: LessonAsk, plain: bool = False, latex: bool = False,
                              inline: bool = False):
        lesson_or_404(lesson_id)
        try:
            answer = await lessons.ask_about(lesson_id, body.step, body.question, [h.model_dump() for h in body.history])
        except LookupError as e:
            raise HTTPException(404, str(e))
        except ValueError as e:
            raise HTTPException(409 if "written" in str(e) else 400, str(e))
        except Exception as e:
            log.warning("lesson question failed: %s", e)
            raise HTTPException(502, "Professor couldn't answer just now. Try again in a moment.")
        return {"answer": readable(answer, latex, inline) if plain else answer, "markdown": answer}

    @app.post("/v1/lessons/{lesson_id}/finish", dependencies=[Depends(auth)])
    async def lesson_finish(lesson_id: str, body: LessonFinish | None = None, plain: bool = False,
                            latex: bool = False, inline: bool = False):
        lesson_or_404(lesson_id)
        try:
            lesson = await lessons.finish(lesson_id, (body or LessonFinish()).explanation)
        except ValueError as e:
            raise HTTPException(409, str(e))
        except Exception as e:
            log.warning("lesson explanation failed: %s", e)
            raise HTTPException(502, "Professor couldn't read your explanation just now. Try again in a moment.")
        out = lesson_json(lesson, plain, latex, inline)
        nxt = lessons.next_topic(lesson["course_id"], after=lesson["topic_id"])
        out["next"] = {"id": nxt["public_id"], "title": nxt["title"]} if nxt else None
        return out

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

    # -- who writes the notes ------------------------------------------------------------

    def engine_or_404() -> Engine:
        if engine is None:
            raise HTTPException(404, "no writer on this server")
        return engine

    @app.get("/v1/writer", dependencies=[Depends(auth)])
    async def get_writer():
        return engine_or_404().status()

    @app.put("/v1/writer", dependencies=[Depends(auth)])
    async def set_writer(body: WriterIn):
        e = engine_or_404()
        if "claude" in (body.engine, body.background) and not e.available:
            raise HTTPException(409, "Claude Code isn't installed on the server")
        if body.engine:
            e.set_engine(body.engine)
        if body.background:
            e.set_background(body.background)
        return e.status()

    @app.post("/v1/writer/decide", dependencies=[Depends(auth)])
    async def decide_writer(body: WriterDecide):
        e = engine_or_404()
        try:
            e.decide(body.use)
        except LookupError as err:
            raise HTTPException(409, str(err))
        return e.status()

    # -- usage -----------------------------------------------------------------------------

    @app.get("/v1/usage", dependencies=[Depends(auth)])
    async def get_usage(days: int = Query(7, ge=1, le=180)):
        out = usage.summary(days)
        for c in out["conversations"]:  # a chat's name, where it has one
            row = db.app_conversation(c["key"]) if c["key"] and c["key"] != TEAM else None
            c["title"] = "Team chat" if c["key"] == TEAM else row["title"] if row else None
        return out

    # -- practice exams ----------------------------------------------------------------

    def quiz_or_404(quiz_id: str) -> dict:
        if (q := quizzes.quiz(quiz_id)) is None:
            raise HTTPException(404, f"no practice exam {quiz_id}")
        return q

    @app.get("/v1/quizzes", dependencies=[Depends(auth)])
    async def quiz_bank(course: int):
        return quizzes.bank_json(course_or_404(course))

    @app.post("/v1/quizzes", dependencies=[Depends(auth)])
    async def start_quiz(body: QuizStart):
        cid = course_or_404(body.course)
        try:
            if body.mock:
                if (m := notebook.mock(body.mock)) is None or m["course_id"] != cid:
                    raise HTTPException(404, f"no mock exam {body.mock} in this course")
                quiz = quizzes.start_mock(body.mock)
            elif body.due:
                quiz = quizzes.start_due(cid)
            else:
                quiz = quizzes.start(cid, body.count, body.minutes, body.topics, body.cards, body.exercises,
                                     body.kind, body.write)
        except ValueError as e:
            raise HTTPException(409, str(e))
        return JSONResponse(quizzes.quiz_json(quiz), status_code=201)

    @app.get("/v1/quizzes/{quiz_id}", dependencies=[Depends(auth)])
    async def get_quiz(quiz_id: str):
        return quizzes.quiz_json(quiz_or_404(quiz_id))

    def open_answer(a):
        if isinstance(a, OpenAnswer):
            return {"text": a.text, "photos": [p for p in a.photos if photos is not None and photos.exists(p)]}
        return a

    async def ask_fast(system: str, content: list[dict], max_tokens: int) -> str:
        """Straight to the fast model: the user is waiting on the Study page (the plan's Claude Code takes longer, so
        it's only the fallback, when OpenRouter says no)."""
        try:
            response = await agent.client.beta.messages.create(  # no thinking: it ran past max_tokens
                model=agent.model, max_tokens=max_tokens, system=system, thinking={"type": "disabled"},
                messages=[{"role": "user", "content": content}])
        except anthropic.APIError:
            if engine is None or not engine.plan_now():
                raise
            log.warning("OpenRouter refused a study mark; asking the plan")
            return await engine.ask(system, content, max_tokens, fast=True, wait=False)
        return "".join(b.text for b in response.content if b.type == "text").strip()

    @app.post("/v1/quizzes/{quiz_id}/check", dependencies=[Depends(auth)])
    async def check_quiz(quiz_id: str, body: QuizCheck):
        quiz_or_404(quiz_id)
        try:
            checked = quizzes.check(quiz_id, body.n, open_answer(body.answer), body.seconds)
        except LookupError as e:
            raise HTTPException(404, str(e))
        except ValueError as e:
            raise HTTPException(409, str(e))
        if (waiting := quizzes.to_mark(quiz_id, body.n)) is None:
            return checked
        try:  # a study session's open answer, marked while the user waits
            points, feedback = await mark_answer(ask_fast, *waiting, photos.load if photos is not None else None,
                                                 decider=decider)
        except Exception:
            log.exception("couldn't mark a study answer")
            raise HTTPException(502, "couldn't mark it: say yourself whether it was right") from None
        return quizzes.set_mark(quiz_id, body.n, points, feedback)

    @app.post("/v1/quizzes/{quiz_id}/mark", dependencies=[Depends(auth)])
    async def mark_quiz(quiz_id: str, body: QuizMark):
        quiz_or_404(quiz_id)
        try:
            q = quizzes.quiz(quiz_id)["questions"][body.n - 1] if body.n >= 1 else None
            points = (q or {}).get("points", 1.0) if body.correct else 0.0
            return quizzes.set_mark(quiz_id, body.n, points, None)
        except (LookupError, IndexError) as e:
            raise HTTPException(404, str(e))
        except ValueError as e:
            raise HTTPException(409, str(e))

    @app.post("/v1/quizzes/{quiz_id}/finish", dependencies=[Depends(auth)])
    async def finish_quiz(quiz_id: str, body: QuizFinish):
        quiz_or_404(quiz_id)
        answers = {n: open_answer(a) for n, a in body.answers.items()}
        try:
            quiz = quizzes.finish(quiz_id, answers)
        except ValueError as e:
            raise HTTPException(409, str(e))
        if quiz["kind"] == "study":  # the Study page shows how it went: nothing to post
            return quizzes.quiz_json(quiz)
        if quizzes.grading(quiz):  # the open answers are marked in the background, and the result posted then
            notebook.enqueue(quiz["course_id"], "grade", quiz=quiz_id)
            return quizzes.quiz_json(quiz)
        # Professor's note in the course chat; the missed questions go in the note it reads, for "go through them".
        try:
            await agent.post(study.chat(quiz["course_id"]), quizzes.note(quiz), quizzes.summary(quiz),
                             [quizzes.card(quiz)])
        except Exception:
            log.exception("couldn't post a practice exam's result")
        return quizzes.quiz_json(quiz)

    # -- review sessions ---------------------------------------------------------------

    @app.get("/v1/reviews", dependencies=[Depends(auth)])
    async def review_sessions(course: int | None = None):
        return {"sessions": [reviews.as_json(s) for s in reviews.upcoming(course_or_404(course) if course else None)]}

    @app.delete("/v1/reviews/{session_id}", dependencies=[Depends(auth)])
    async def cancel_review(session_id: str):
        try:
            await reviews.cancel(session_id)
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'\""))
        return {"ok": True}

    @app.get("/v1/vault", dependencies=[Depends(auth)])
    async def vault_setup():
        """What Obsidian's Remotely Save needs to sync the vault (webdav.py), or enabled false."""
        return {"enabled": True, **vault} if vault else {"enabled": False}

    @app.get("/v1/digest", dependencies=[Depends(auth)])
    async def latest_digest(kind: str = "daily"):
        if kind == "latest":  # whichever was made last
            kind = digest.newest_kind()
            if kind is None:
                raise HTTPException(404, "no digest yet")
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

    # -- plans and events (the week card) ---------------------------------------------

    def plan_item(e: dict) -> dict:
        if not e.get("plan") or (plan := plans.get(e["plan"])) is None:
            return e
        item = next((i for i in plan["items"] if i["id"] == e["id"]), None)
        return plans.item_json(plan, item) if item else e

    def find_plan(plan_id: str) -> dict:
        try:
            return plans.find(plan_id)
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'\""))

    def plan_note(plan: dict, verb: str, items: list[dict]) -> None:
        if items:
            lines = "\n".join(f"- {plans.line(i)}" for i in items)
            agent.note(plan["conversation"], f"[The user tapped {verb} on plan {plan['public_id']}:\n{lines}]")

    @app.post("/v1/plans/{plan_id}/add", dependencies=[Depends(auth)])
    async def add_plan(plan_id: str, body: PlanItemsIn | None = None):
        """The user's tap on Add (one item) or Add all: this is the confirmation, so they go in the calendar now."""
        find_plan(plan_id)
        if calendar is None:
            raise HTTPException(503, "there's no calendar on this server")
        try:
            plan, added = await plans.add(plan_id, body.items if body else None)
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'\""))
        plan_note(plan, "Add", added)
        if added:
            activity.record(db.conn, plan["agent"], "confirmed", f"Added {len(added)} proposed event(s)",
                            "; ".join(plans.line(i) for i in added), plan["conversation"] or CONVERSATION)
            if notebook and study and plan["conversation"] and (course_id := study.chat_course(plan["conversation"])):
                await notebook.calendar_check(course_id)  # a course's exam: its dates stop saying "not in your calendar"
        return {"events": plans.card_items(plan)}

    @app.post("/v1/plans/{plan_id}/drop", dependencies=[Depends(auth)])
    async def drop_plan(plan_id: str, body: PlanItemsIn | None = None):
        find_plan(plan_id)
        try:
            plan, dropped = plans.drop(plan_id, body.items if body else None)
        except KeyError as e:
            raise HTTPException(404, str(e).strip("'\""))
        plan_note(plan, "Remove", dropped)
        return {"events": plans.card_items(plan)}

    def need_calendar() -> CalendarBackend:
        if calendar is None:
            raise HTTPException(503, "there's no calendar on this server")
        return calendar

    async def own_event(uid: str) -> CalEvent:
        """An event the user may move or delete from the app: not a recurring one (as with the agents' tools)."""
        cal = need_calendar()
        ev = await asyncio.to_thread(cal.get, uid)
        if ev is None:
            raise HTTPException(404, f"no event {uid}")
        if ev.recurring:
            raise HTTPException(409, "recurring events can't be changed here yet; use the Calendar app")
        return ev

    @app.get("/v1/events", dependencies=[Depends(auth)])
    async def events_between(start: date | None = Query(None, alias="from"), days: int = 7):
        """Every calendar's events from a local day, for `days` days (at most 42): the week card's other events."""
        start = start or datetime.now(tz).date()
        days = max(1, min(days, MAX_EVENT_DAYS))
        begin = datetime.combine(start, time.min, tz)
        try:
            found = await asyncio.to_thread(need_calendar().events, begin, begin + timedelta(days=days))
        except HTTPException:
            raise
        except Exception:
            log.exception("calendar lookup failed")
            raise HTTPException(502, "iCloud Calendar is unavailable right now")
        return {"from": start.isoformat(), "days": days,
                "events": [event_json(e, tz) for e in sorted(found, key=lambda e: event_start(e, tz))]}

    def when(value: str) -> date | datetime:
        if len(value) == 10:
            return date.fromisoformat(value)
        dt = datetime.fromisoformat(value)
        return dt.replace(tzinfo=tz) if dt.tzinfo is None else dt.astimezone(tz)

    @app.patch("/v1/events/{uid}", dependencies=[Depends(auth)])
    async def move_event(uid: str, body: EventMoveIn):
        """The user's own move, from the event's sheet in the app."""
        ev = await own_event(uid)
        start, end = when(body.start), when(body.end)
        if isinstance(start, datetime) != isinstance(end, datetime):
            raise HTTPException(400, "start and end must both be dates or both be date-times")
        if isinstance(start, datetime) and end <= start or not isinstance(start, datetime) and end < start:
            raise HTTPException(400, "end must be after start")
        if not isinstance(start, datetime):
            end += timedelta(days=1)  # iCalendar's end is exclusive
        moved = await asyncio.to_thread(lambda: need_calendar().update(uid, start=start, end=end))
        activity.record(db.conn, "secretary", "confirmed", f"Moved {ev.title} (in the app)",
                        f"To {moved.start.astimezone(tz):%a %d %b %H:%M}" if isinstance(moved.start, datetime) else None)
        return event_json(moved, tz)

    @app.delete("/v1/events/{uid}", dependencies=[Depends(auth)])
    async def delete_event(uid: str):
        ev = await own_event(uid)
        await asyncio.to_thread(need_calendar().delete, uid)
        activity.record(db.conn, "secretary", "confirmed", f"Deleted {ev.title} (in the app)")
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

    @app.post("/v1/reminders/{reminder_id}/complete", dependencies=[Depends(auth)])
    async def complete_reminder(reminder_id: str, body: CompleteIn | None = None):
        try:
            rem = store.update(reminder_id, completed=body.completed if body else True)
        except KeyError:
            raise HTTPException(404, f"no reminder {reminder_id}") from None
        return reminder_json(rem, tz)

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

    @app.get("/v1/health/scores", dependencies=[Depends(auth)])
    async def health_scores(day: date | None = Query(None, alias="date")):
        return health.scores(day or datetime.now(tz).date())

    @app.get("/v1/health/scores/history", dependencies=[Depends(auth)])
    async def health_score_history(days: int = Query(30, ge=1, le=366), end: date | None = Query(None, alias="to")):
        end = end or datetime.now(tz).date()
        return {"days": health.score_history(end - timedelta(days=days - 1), end)}

    @app.post("/v1/health/insight", dependencies=[Depends(auth)])
    async def health_insight(body: InsightIn):
        """Coach's take on one of the day's scores, asked for from its page; nothing is stored."""
        from ..health import INSIGHT_PROMPT, INSIGHT_TOKENS, insight_input
        day = body.day or datetime.now(tz).date()
        text = insight_input(health, body.kind, day, [m["text"] for m in db.memories("coach")])
        try:
            answer = await ask_once(INSIGHT_PROMPT.format(kind=body.kind), [{"type": "text", "text": text}],
                                    INSIGHT_TOKENS)
        except (httpx.HTTPError, anthropic.APIError, RuntimeError) as e:
            log.warning("health insight failed: %s", e)
            raise HTTPException(502, f"Coach couldn't answer: {e}") from None
        return {"kind": body.kind, "date": day.isoformat(), "text": answer.strip()}

    @app.get("/v1/health/bedtime", dependencies=[Depends(auth)])
    async def health_bedtime():
        """Tonight's plan, the settings, the learnt wake times and the last week's nights against their plans."""
        if bedtime is None:
            raise HTTPException(404, "bedtime isn't set up")
        today = datetime.now(tz).date()
        return {"tonight": await bedtime.tonight(), "settings": bedtime.settings(), "usual": bedtime.usual(),
                "nights": bedtime.nights(today)}

    @app.patch("/v1/health/bedtime/settings", dependencies=[Depends(auth)])
    async def edit_health_bedtime(body: dict = Body(...)):
        if bedtime is None:
            raise HTTPException(404, "bedtime isn't set up")
        try:
            settings = bedtime.update_settings(**body)
        except ValueError as e:
            raise HTTPException(422, str(e)) from None
        return {"tonight": await bedtime.tonight(), "settings": settings, "usual": bedtime.usual()}

    @app.get("/v1/health/weight", dependencies=[Depends(auth)])
    async def weight(days: int = Query(90, ge=1, le=366)):
        today = weights.today()
        return {"readings": weights.readings(today - timedelta(days=days - 1), today), "summary": weights.summary(),
                "logged": weights.logged()}

    @app.post("/v1/health/weight", dependencies=[Depends(auth)])
    async def log_weight(body: WeightIn):
        if body.at is not None and body.at.tzinfo is None:
            raise HTTPException(400, "at needs a UTC offset")
        try:
            logged = weights.log(body.kg, body.at)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        return {"weight": logged, "summary": weights.summary()}

    @app.delete("/v1/health/weight/{weight_id}", dependencies=[Depends(auth)])
    async def delete_weight(weight_id: int):
        if not weights.delete(weight_id):
            raise HTTPException(404, "no such weight")
        return {"ok": True, "summary": weights.summary()}

    # -- Finance (docs/API.md, "Finance") ------------------------------------------------------------

    sorting: set[asyncio.Task] = set()

    def sort_soon() -> None:  # new merchants go to the model in the background; the Shortcut doesn't wait
        task = asyncio.create_task(finance.sort_pending())
        sorting.add(task)
        task.add_done_callback(sorting.discard)

    def payment(tx_id: int) -> dict:
        try:
            return finance.find(tx_id)
        except KeyError:
            raise HTTPException(404, "no such payment") from None

    @app.get("/v1/finance/categories", dependencies=[Depends(auth)])
    async def finance_categories():
        return {"categories": [{"id": k, "name": v[0], "spending": k not in NOT_SPENDING}
                               for k, v in FINANCE_CATEGORIES.items()]}

    @app.post("/v1/finance/payments", dependencies=[Depends(auth)])
    async def log_payment(body: PaymentIn):
        if body.at is not None and body.at.tzinfo is None:
            raise HTTPException(400, "at needs a UTC offset")
        try:
            amount = abs(parse_amount(body.amount) if isinstance(body.amount, str) else body.amount)
            tx, new = finance.add(amount if body.income else -amount, body.merchant, account=body.card, at=body.at,
                                  source=body.source, category=body.category or ("income" if body.income else None),
                                  place=body.place, lat=body.lat, lon=body.lon,
                                  raw=body.amount if isinstance(body.amount, str) else None, note=body.note)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        if new and tx["sorted_by"] == "none":
            sort_soon()
        return {"payment": tx, "new": new}

    @app.get("/v1/finance/payments", dependencies=[Depends(auth)])
    async def list_payments(limit: int = Query(50, ge=1, le=500), before: datetime | None = None,
                            category: str | None = None):
        if category is not None and category not in FINANCE_CATEGORIES:
            raise HTTPException(400, "unknown category")
        rows = finance.recent(limit + 1, before.astimezone(timezone.utc).isoformat() if before else None, category)
        return {"payments": rows[:limit], "more": len(rows) > limit}

    @app.get("/v1/finance/payments/{tx_id}", dependencies=[Depends(auth)])
    async def get_payment(tx_id: int):
        tx = payment(tx_id)
        return {"payment": tx, "merchant": finance.merchant_history(tx)}

    @app.patch("/v1/finance/payments/{tx_id}", dependencies=[Depends(auth)])
    async def patch_payment(tx_id: int, body: PaymentPatch):
        payment(tx_id)
        try:
            tx = finance.update(tx_id, category=body.category, merchant=body.merchant, note=body.note,
                                remember=body.remember)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        return {"payment": tx}

    @app.delete("/v1/finance/payments/{tx_id}", dependencies=[Depends(auth)])
    async def delete_payment(tx_id: int):
        if not finance.delete(tx_id):
            raise HTTPException(404, "no such payment")
        return {"ok": True}

    @app.get("/v1/finance/month", dependencies=[Depends(auth)])
    async def finance_month(month: str | None = Query(None, pattern=r"^\d{4}-\d{2}$")):
        try:
            return finance.month(month)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None

    @app.get("/v1/finance/accounts", dependencies=[Depends(auth)])
    async def finance_accounts():
        accounts = finance.accounts()
        held = [a["balance"] for a in accounts if a["balance"] is not None and a["kind"] == "account"
                and a["status"] != "unlinked" and not a["hidden"]]
        return {"accounts": accounts, "total": round(sum(held), 2) if held else None}

    class AccountPatch(BaseModel):
        hidden: bool | None = None
        owed: float | None = Field(None, ge=0, le=1_000_000)  # the credit card only: what's owed on it now
        last4: str | None = Field(None, pattern=r"^\d{4}$")

    @app.patch("/v1/finance/accounts/{account_id}", dependencies=[Depends(auth)])
    async def finance_account_patch(account_id: int, body: AccountPatch):
        account = next((a for a in finance.accounts() if a["id"] == account_id), None)
        if account is None:
            raise HTTPException(404, "no such account")
        if body.owed is not None or body.last4 is not None:
            if account["kind"] != "credit":
                raise HTTPException(400, "owed is only for the credit card")
            finance.set_owed(body.owed, body.last4)
            if banks is not None:
                banks.mark_card()
        if body.hidden is not None:
            finance.set_hidden(account_id, body.hidden)
        return {"account": next(a for a in finance.accounts() if a["id"] == account_id)}

    @app.get("/v1/finance/subscriptions", dependencies=[Depends(auth)])
    async def finance_subscriptions():
        return finance.subscriptions()

    class SubscriptionIn(BaseModel):
        merchant: str = Field(min_length=1, max_length=200)
        subscription: bool | None  # null: forget what the user said, back to what the charges show
        amount: float | None = Field(None, gt=0, le=100_000)
        period: Literal["week", "month", "year"] | None = None
        next: date | None = None

    @app.put("/v1/finance/subscriptions", dependencies=[Depends(auth)])
    async def put_subscription(body: SubscriptionIn):
        try:
            finance.set_subscription(body.merchant, body.subscription, body.amount, body.period, body.next)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        return finance.subscriptions()

    @app.get("/v1/finance/budget", dependencies=[Depends(auth)])
    async def get_budget():
        return finance.budget()

    @app.put("/v1/finance/budget", dependencies=[Depends(auth)])
    async def put_budget(body: BudgetIn):
        try:
            if "monthly" in body.model_fields_set:
                return finance.set_budget(body.monthly, body.categories)
            return finance.set_budget(categories=body.categories)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None

    # -- Banks (docs/API.md, "Finance", Banks) ---------------------------------------------------------

    def banks_on() -> None:
        if not banks.enabled:
            raise HTTPException(503, "bank sync isn't set up on the server (ENABLE_BANKING_APP_ID)")

    def psu(request: Request) -> dict:
        """The user is in the app: the bank may be read beyond its 4 unattended reads a day."""
        ip = (request.headers.get("x-forwarded-for") or (request.client.host if request.client else "")).split(",")[0]
        return {k: v for k, v in (("Psu-Ip-Address", ip.strip()),
                                  ("Psu-User-Agent", request.headers.get("user-agent", ""))) if v}

    @app.get("/v1/finance/banks", dependencies=[Depends(auth)])
    async def linked_banks():
        return {"enabled": banks.enabled, "banks": banks.linked()}

    @app.get("/v1/finance/banks/available", dependencies=[Depends(auth)])
    async def available_banks(country: str = Query("IT", pattern=r"^[A-Za-z]{2}$")):
        banks_on()
        try:
            return {"banks": await banks.banks(country)}
        except BankError as e:
            raise HTTPException(502, f"Enable Banking: {e}") from None

    @app.post("/v1/finance/banks/link", dependencies=[Depends(auth)])
    async def link_bank(body: BankLinkIn):
        banks_on()
        redirect = bank_redirect or (body.server.rstrip("/") + "/v1/finance/banks/callback"
                                     if body.server and body.server.startswith("https://") else None)
        if not redirect:
            raise HTTPException(400, "no callback URL: set ENABLE_BANKING_REDIRECT or send the server's https URL")
        try:
            return {"url": await banks.start_link(body.bank, body.country, redirect)}
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        except BankError as e:
            raise HTTPException(502, f"Enable Banking: {e}") from None

    @app.get("/v1/finance/banks/callback")  # the bank's page sends the browser here: no token, the state is the key
    async def bank_callback(request: Request, state: str = "", code: str = "", error: str = "",
                            error_description: str = ""):
        if not banks.enabled:
            return HTMLResponse("Bank sync is off on the server.", status_code=503)
        back = "aide://money/banks"
        if error or not code:
            log.info("bank link not finished: %s", error or "no code")
            return RedirectResponse(f"{back}?error={quote(error_description or error or 'cancelled')}", 302)
        try:
            linked = await banks.finish_link(state, code, psu(request))
        except (ValueError, BankError) as e:
            log.warning("bank link failed: %s", e)
            return RedirectResponse(f"{back}?error={quote(str(e)[:200])}", 302)
        return RedirectResponse(f"{back}?linked={linked['id']}", 302)

    @app.post("/v1/finance/banks/sync", dependencies=[Depends(auth)])
    async def sync_banks(request: Request, force: bool = False):
        if not banks.enabled:
            return {"new": 0, "banks": []}
        return await banks.sync_all(psu(request), force=force)

    @app.delete("/v1/finance/banks/{bank_id}", dependencies=[Depends(auth)])
    async def unlink_bank(bank_id: int):
        banks_on()
        if not await banks.unlink(bank_id):
            raise HTTPException(404, "no such bank")
        return {"ok": True}

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

    # -- location and tram alerts --------------------------------------------------------

    @app.post("/v1/location", dependencies=[Depends(auth)])
    async def save_location(body: LocationIn):
        if body.at is not None and body.at.tzinfo is None:
            raise HTTPException(400, "at needs a UTC offset")
        location.save(body.lat, body.lon, body.accuracy, body.at)
        return {"ok": True}

    def alerts_or_404() -> AlertStore:
        if transit_alerts is None:
            raise HTTPException(404, "GTT is off on this server (AIDE_GTT)")
        return transit_alerts

    def alert_or_404(alert_id: int) -> dict:
        try:
            return alerts_or_404().get(alert_id)
        except ValueError:
            raise HTTPException(404, f"no tram alert {alert_id}") from None

    @app.get("/v1/transit/alerts", dependencies=[Depends(auth)])
    async def list_transit_alerts():
        found = alerts_or_404()
        return {"alerts": [found.as_json(a) for a in found.all()]}

    @app.patch("/v1/transit/alerts/{alert_id}", dependencies=[Depends(auth)])
    async def edit_transit_alert(alert_id: int, body: TransitAlertPatch):
        alert_or_404(alert_id)
        changes = body.model_dump(exclude_unset=True)
        if "minutes" in changes and changes["minutes"] is None:
            changes["minutes"] = 0  # the store's "back to when it's time to leave"
        return transit_alerts.as_json(transit_alerts.update(alert_id, **changes))

    def leave_or_404() -> LeaveWatcher:
        if leave is None:
            raise HTTPException(404, "leave-now alerts need GTT, the calendar and Maps on this server")
        return leave

    @app.get("/v1/transit/settings", dependencies=[Depends(auth)])
    async def transit_settings():
        return leave_or_404().settings()

    @app.patch("/v1/transit/settings", dependencies=[Depends(auth)])
    async def edit_transit_settings(body: TransitSettingsPatch):
        return leave_or_404().update_settings(body.calendar)

    @app.get("/v1/transit/nearby", dependencies=[Depends(auth)])
    async def nearby():
        if boards is None:
            raise HTTPException(404, "GTT is off on this server (AIDE_GTT)")
        found, fix_at = await boards.nearby()
        return {"boards": found, "fix_at": local(fix_at.isoformat()) if fix_at else None}

    @app.get("/v1/transit/departures", dependencies=[Depends(auth)])
    async def departures(stop: str, line: str | None = None, to: str | None = None, to_name: str | None = None):
        """A departures card again, to keep it live in the app: `stop` and `to` are stop ids, as on the card."""
        if boards is None:
            raise HTTPException(404, "GTT is off on this server (AIDE_GTT)")
        found = boards.transit.timetable.stop(stop)
        if found is None:
            raise HTTPException(404, f"no GTT stop {stop}")
        dest = None
        if to:
            dest = {"name": to_name or "", "stops": [s for s in to.split(",") if s]}
        try:
            return await boards.board(found, line or None, dest)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None

    @app.delete("/v1/transit/alerts/{alert_id}", dependencies=[Depends(auth)])
    async def delete_transit_alert(alert_id: int):
        alert_or_404(alert_id)
        transit_alerts.delete(alert_id)
        return {"ok": True}

    @app.post("/v1/transit/alerts/{alert_id}/driving", dependencies=[Depends(auth)])
    async def driving_instead(alert_id: int):
        """The countdown's Driving button: the alert goes, its countdown ends, and leave-now learns the place."""
        alert_or_404(alert_id)
        learnt = bool(leave and leave.driving(alert_id, utcnow()))
        transit_alerts.dropped.add(alert_id)
        transit_alerts.delete(alert_id)
        return {"ok": True, "learnt": learnt}

    def lock_or_404(lock_id: int) -> dict:
        try:
            return locks.get(lock_id)
        except ValueError:
            raise HTTPException(404, f"no lock {lock_id}") from None

    @app.get("/v1/locks", dependencies=[Depends(auth)])
    async def list_locks():
        return {"locks": [locks.as_json(lock) for lock in locks.all()], "device": locks.device(),
                "passes": locks.passes(), "limits": [locks.limit_json(limit) for limit in locks.limits()],
                "line": locks.coach_line()}

    @app.post("/v1/locks", dependencies=[Depends(auth)])
    async def create_lock(body: LockIn):
        if body.minutes is not None:
            return locks.as_json(locks.lock_for(body.title, minutes=body.minutes, strict=body.strict))
        if body.start is None or body.end is None:
            raise HTTPException(400, "a lock needs minutes, or a start and an end")
        return locks.as_json(locks.schedule(body.title, body.start, body.end, body.days, strict=body.strict))

    @app.patch("/v1/locks/{lock_id}", dependencies=[Depends(auth)])
    async def edit_lock(lock_id: int, body: LockPatch):
        lock_or_404(lock_id)
        lock = locks.update(lock_id, title=body.title, start_time=body.start, end_time=body.end, days=body.days,
                            enabled=body.enabled, strict=body.strict)
        return locks.as_json(lock)

    @app.post("/v1/locks/{lock_id}/unlock", dependencies=[Depends(auth)])
    async def unlock(lock_id: int, body: UnlockIn):
        lock = lock_or_404(lock_id)
        if lock.get("focus") and focus is not None:  # a focus round: the whole session ends
            await end_focus(lock["focus"], FocusEnd(reason=body.reason, **{"pass": body.use_pass}))
            return {"lock": None}
        after = locks.unlock(lock_id, body.reason, use_pass=body.use_pass)
        used = " with an emergency pass" if lock["strict"] else ""
        activity.record(db.conn, "coach", "action", f"You unlocked '{lock['title']}' early{used}", body.reason)
        return {"lock": locks.as_json(after) if after else None}

    @app.delete("/v1/locks/{lock_id}", dependencies=[Depends(auth)])
    async def delete_lock(lock_id: int):
        lock_or_404(lock_id)
        locks.delete(lock_id)
        return {"ok": True}

    # -- focus sessions (#54) ---------------------------------------------------

    def focus_or_404(public_id: str) -> dict:
        if focus is None:
            raise HTTPException(404, "focus sessions are off")
        try:
            return focus.get(public_id)
        except KeyError:
            raise HTTPException(404, f"no focus session {public_id}") from None

    @app.get("/v1/focus", dependencies=[Depends(auth)])
    async def focus_now(days: int = 7, course: int | None = None):
        if focus is None:
            raise HTTPException(404, "focus sessions are off")
        now = datetime.now(timezone.utc)
        focus.finish_due(now)
        since = now - timedelta(days=max(1, min(days, 400)))
        current = focus.current(now)
        return {"current": focus.as_json(current, now) if current else None, "presets": FOCUS_PRESETS,
                "sessions": [focus.as_json(s, now) for s in focus.sessions(since, course)],
                "totals": focus.totals(since, now), "passes": locks.passes(now)}

    @app.post("/v1/focus", dependencies=[Depends(auth)])
    async def start_focus(body: FocusIn):
        if focus is None:
            raise HTTPException(404, "focus sessions are off")
        s = focus.start(body.course_id, body.focus_min, body.break_min, body.rounds, topic=body.topic,
                        topic_title=body.topic_title, strict=body.strict, review=body.review)
        return focus.as_json(s)

    @app.get("/v1/focus/{public_id}", dependencies=[Depends(auth)])
    async def focus_session(public_id: str):
        return focus.as_json(focus_or_404(public_id))

    @app.post("/v1/focus/{public_id}/end", dependencies=[Depends(auth)])
    async def end_focus(public_id: str, body: FocusEnd):
        s = focus_or_404(public_id)
        held = focus.round_lock(s, datetime.now(timezone.utc)) is not None
        after = focus.end(public_id, body.reason, use_pass=body.use_pass)
        used = " with an emergency pass" if held and s["strict"] else ""
        activity.record(db.conn, "professor", "action",
                        f"You ended the focus session on {focus.course_name(s['course_id'])} early{used}",
                        body.reason or None)
        return focus.as_json(after)

    @app.post("/v1/focus/{public_id}/check", dependencies=[Depends(auth)])
    async def focus_checked(public_id: str, body: FocusCheck):
        first = focus_or_404(public_id)["check_total"] is None
        s = focus.set_check(public_id, body.right, body.total)
        if first and focus_watch is not None:
            await focus_watch.checked(s)
        return focus.as_json(s)

    def limit_or_404(limit_id: int) -> dict:
        try:
            return locks.get_limit(limit_id)
        except ValueError:
            raise HTTPException(404, f"no limit {limit_id}") from None

    @app.post("/v1/limits", dependencies=[Depends(auth)])
    async def create_limit(body: LimitIn):
        return locks.limit_json(locks.add_limit(body.title, body.minutes, body.days, strict=body.strict))

    @app.patch("/v1/limits/{limit_id}", dependencies=[Depends(auth)])
    async def edit_limit(limit_id: int, body: LimitPatch):
        limit_or_404(limit_id)
        return locks.limit_json(locks.update_limit(limit_id, title=body.title, minutes=body.minutes, days=body.days,
                                                   enabled=body.enabled, strict=body.strict))

    @app.post("/v1/limits/{limit_id}/unlock", dependencies=[Depends(auth)])
    async def unlock_limit(limit_id: int, body: UnlockIn):
        limit = limit_or_404(limit_id)
        after = locks.unlock_limit(limit_id, body.reason, use_pass=body.use_pass)
        used = " with an emergency pass" if limit["strict"] else ""
        activity.record(db.conn, "coach", "action", f"You ended the limit '{limit['title']}' for today{used}",
                        body.reason)
        return locks.limit_json(after)

    @app.delete("/v1/limits/{limit_id}", dependencies=[Depends(auth)])
    async def delete_limit(limit_id: int):
        limit_or_404(limit_id)
        locks.delete_limit(limit_id)
        return {"ok": True}

    @app.put("/v1/screen/usage", dependencies=[Depends(auth)])
    async def screen_usage_in(body: UsageIn):
        locks.record_usage([(d.date, d.minutes) for d in body.days])
        for hit in body.limits:
            try:
                locks.limit_reached(hit.id, date.fromisoformat(hit.date).isoformat(),
                                    datetime.fromisoformat(hit.at) if hit.at else None)
            except ValueError:
                continue  # a limit deleted since
        return {"ok": True}

    @app.get("/v1/screen/usage", dependencies=[Depends(auth)])
    async def screen_usage_out(days: int = 30):
        today = datetime.now(tz).date()
        return {"days": locks.usage(today - timedelta(days=max(1, min(days, 400))), today)}

    @app.put("/v1/locks/device", dependencies=[Depends(auth)])
    async def screen_time_device(body: ScreenTimeDevice):
        return locks.set_device(body.authorized, body.allowed_apps)

    @app.post("/v1/devices", dependencies=[Depends(auth)])
    async def register_device(body: DeviceIn):
        push.register(body.token, body.environment, body.name.strip(), body.app)
        return {"ok": True}

    @app.get("/v1/devices", dependencies=[Depends(auth)])
    async def devices():
        return {"devices": [{"token": d["token"], "environment": d["environment"], "name": d["name"], "app": d["app"],
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

    # -- YouTube videos ---------------------------------------------------------

    def video_worker() -> VideoWorker:
        if videos is None:
            raise HTTPException(503, "videos aren't set up on the server")
        return videos

    def video_or_404(video_id: str) -> dict:
        v = video_worker().store.get(video_id)
        if v is None:
            raise HTTPException(404, f"no video {video_id}")
        return v

    @app.post("/v1/videos", dependencies=[Depends(auth)])
    async def start_video(body: VideoIn):
        """A video shared from the app (YouTube's Share): read in the background, its brief posted in the chat."""
        worker = video_worker()
        url = find_link(body.url)
        if url is None:
            raise HTTPException(400, "that isn't a YouTube video link")
        question = (body.question or "").strip() or None
        if body.conversation_id and db.app_conversation(body.conversation_id) is None:
            raise HTTPException(404, f"no conversation {body.conversation_id}")
        conversation = body.conversation_id or db.new_app_conversation(ORCHESTRATOR)["public_id"]
        v = worker.start(url, conversation, question)
        await agent.post(conversation, url + (f"\n\n{question}" if question else ""),
                         "Reading it now: the brief comes here in a few minutes.",
                         [{"type": "videos", "videos": [worker.store.card(v)]}], record=False)
        return {"video": worker.store.full(v), "conversation_id": conversation}

    @app.get("/v1/videos", dependencies=[Depends(auth)])
    async def list_videos(q: str | None = None, limit: int = 100):
        if videos is None:
            return {"videos": [], "enabled": False}
        return {"videos": [videos.store.card(v) for v in videos.store.search(q, max(1, min(limit, 500)))],
                "enabled": True}

    @app.get("/v1/videos/{video_id}", dependencies=[Depends(auth)])
    async def get_video(video_id: str):
        return video_worker().store.full(video_or_404(video_id))

    @app.delete("/v1/videos/{video_id}", dependencies=[Depends(auth)])
    async def delete_video(video_id: str):
        video_or_404(video_id)
        video_worker().delete(video_id)
        return {"ok": True}

    # -- browser errands -------------------------------------------------------

    def runner() -> ErrandRunner:
        if errands is None:
            raise HTTPException(503, "the browser isn't installed on the server")
        return errands

    def errand_or_404(errand_id: int) -> dict:
        e = errand_store.get(errand_id)
        if e is None:
            raise HTTPException(404, f"no errand {errand_id}")
        return e

    @app.get("/v1/errands", dependencies=[Depends(auth)])
    async def list_errands(open_only: bool = Query(False, alias="open"), limit: int = 30):
        rows = errand_store.recent(max(1, min(limit, 100)), open_only)
        return {"errands": [errand_store.as_json(e) for e in rows], "enabled": errands is not None}

    @app.get("/v1/errands/{errand_id}", dependencies=[Depends(auth)])
    async def get_errand(errand_id: int):
        e = errand_or_404(errand_id)
        return {**errand_store.as_json(e), "steps": [{**s, "ts": errand_store._local(s["ts"])} for s in e["steps"]]}

    @app.post("/v1/errands/{errand_id}/buy", dependencies=[Depends(auth)])
    async def buy_product(errand_id: int, body: ProductBuyIn):
        errand_or_404(errand_id)
        try:
            e = await runner().buy_product(errand_id, body.url, body.size, body.max_total)
        except ValueError as ex:
            raise HTTPException(422, str(ex)) from None
        return errand_store.as_json(e)

    @app.post("/v1/errands/{errand_id}/done", dependencies=[Depends(auth)])
    async def errand_done(errand_id: int):
        errand_or_404(errand_id)
        try:
            return errand_store.as_json(runner().done(errand_id))
        except ValueError as e:
            raise HTTPException(409, str(e)) from None

    @app.post("/v1/errands/{errand_id}/reply", dependencies=[Depends(auth)])
    async def errand_reply(errand_id: int, body: ErrandReplyIn):
        errand_or_404(errand_id)
        try:
            return errand_store.as_json(runner().reply(errand_id, body.answer))
        except ValueError as e:
            raise HTTPException(409, str(e)) from None

    @app.post("/v1/errands/{errand_id}/cancel", dependencies=[Depends(auth)])
    async def errand_cancel(errand_id: int):
        errand_or_404(errand_id)
        return errand_store.as_json(runner().cancel(errand_id))

    @app.get("/v1/errands/{errand_id}/frame", dependencies=[Depends(auth)])
    async def errand_frame(errand_id: int):
        errand_or_404(errand_id)
        frame = await runner().frame(errand_id)
        if frame is None:
            raise HTTPException(404, "the errand has no page open")
        return Response(frame, media_type="image/jpeg", headers={"Cache-Control": "no-store"})

    @app.get("/v1/browser/sites", dependencies=[Depends(auth)])
    async def browser_sites():
        return {"sites": runner().browser.sites() if errands else [], "enabled": errands is not None}

    @app.post("/v1/browser/sites", dependencies=[Depends(auth)])
    async def open_site(body: SiteIn):
        """Open a site to log in there from the app (then the live view with ?site=)."""
        url = full_url(body.url)
        site = site_of(url)
        try:
            await runner().browser.open(f"site:{site}", url)
        except BrowserError as e:
            raise HTTPException(502, str(e)) from None
        return {"site": site, "url": runner().browser.where(f"site:{site}")["url"]}

    @app.delete("/v1/browser/sites/{site}", dependencies=[Depends(auth)])
    async def forget_site(site: str):
        try:
            check_site(site)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        if not await runner().browser.forget(site):
            raise HTTPException(404, f"no profile for {site}")
        return {"ok": True}

    @app.get("/v1/purchases", dependencies=[Depends(auth)])
    async def list_purchases(days: int | None = None, site: str | None = None):
        since = datetime.now(tz) - timedelta(days=days) if days else None
        rows = errand_store.purchases(since, site)
        totals: dict[str, float] = {}
        for p in rows:
            if p["amount"] is not None and p["currency"]:
                totals[p["currency"]] = round(totals.get(p["currency"], 0) + p["amount"], 2)
        return {"purchases": rows, "totals": totals}

    def watch_store() -> PriceWatches:
        if watches is None:
            raise HTTPException(503, "the browser isn't installed on the server")
        return watches

    def watch_or_404(watch_id: int) -> dict:
        w = watch_store().get(watch_id)
        if w is None:
            raise HTTPException(404, f"no price watch {watch_id}")
        return w

    @app.get("/v1/pricewatches", dependencies=[Depends(auth)])
    async def list_price_watches(status: str | None = None):
        if watches is None:
            return {"price_watches": [], "enabled": False}
        return {"price_watches": [watches.as_json(w) for w in watches.all(status)], "enabled": True}

    @app.post("/v1/pricewatches", dependencies=[Depends(auth)])
    async def add_price_watch(body: PriceWatchIn):
        try:
            source = errand_store.get(body.errand_id) if body.errand_id else None
            w = watch_store().add(body.url, body.title, body.below, body.stock, body.every_hours,
                                  body.conversation_id or (source or {}).get("conversation") or CONVERSATION)
        except ValueError as e:
            raise HTTPException(422, str(e)) from None
        return watches.as_json(await watches.check(w["id"], post=False))

    @app.patch("/v1/pricewatches/{watch_id}", dependencies=[Depends(auth)])
    async def edit_price_watch(watch_id: int, body: PriceWatchPatch):
        watch_or_404(watch_id)
        try:
            return watches.as_json(watches.update(watch_id, **body.model_dump(exclude_unset=True)))
        except ValueError as e:
            raise HTTPException(422, str(e)) from None

    @app.delete("/v1/pricewatches/{watch_id}", dependencies=[Depends(auth)])
    async def delete_price_watch(watch_id: int):
        watch_or_404(watch_id)
        watches.delete(watch_id)
        return {"ok": True}

    @app.post("/v1/pricewatches/{watch_id}/check", dependencies=[Depends(auth)])
    async def check_price_watch(watch_id: int):
        watch_or_404(watch_id)
        return watches.as_json(await watches.check(watch_id))

    @app.post("/v1/pricewatches/{watch_id}/buy", dependencies=[Depends(auth)])
    async def buy_price_watch(watch_id: int):
        watch_or_404(watch_id)
        try:
            e = watches.buy(watch_id)
        except ValueError as ex:
            raise HTTPException(409, str(ex)) from None
        return errand_store.as_json(e)

    def release_or_404(release_id: int) -> dict:
        if releases is None:
            raise HTTPException(503, "the browser isn't installed on the server")
        r = releases.get(release_id)
        if r is None:
            raise HTTPException(404, f"no release tracker {release_id}")
        return r

    @app.get("/v1/releases", dependencies=[Depends(auth)])
    async def list_releases():
        if releases is None:
            return {"releases": [], "enabled": False}
        return {"releases": [releases.as_json(r) for r in releases.all()], "enabled": True}

    @app.post("/v1/releases", dependencies=[Depends(auth)])
    async def add_release(body: ReleaseIn):
        if releases is None:
            raise HTTPException(503, "the browser isn't installed on the server")
        try:
            return releases.as_json(releases.start(body.query, CONVERSATION))
        except ValueError as e:
            raise HTTPException(422, str(e)) from None

    @app.get("/v1/releases/{release_id}", dependencies=[Depends(auth)])
    async def get_release(release_id: int):
        return releases.as_json(release_or_404(release_id))

    @app.put("/v1/releases/{release_id}/picks", dependencies=[Depends(auth)])
    async def set_release_picks(release_id: int, body: ReleasePicksIn):
        release_or_404(release_id)
        try:
            r = releases.set_picks(release_id, body.colourways, body.size, body.max_total, body.shops, body.mode,
                                   body.currency, sizes=body.sizes or None)
        except ValueError as e:
            raise HTTPException(422, str(e)) from None
        await releases._act(r)
        return releases.as_json(releases.get(release_id))

    @app.post("/v1/releases/{release_id}/check", dependencies=[Depends(auth)])
    async def check_release(release_id: int):
        release_or_404(release_id)
        try:
            return releases.as_json(await releases.check(release_id))
        except ValueError as e:
            raise HTTPException(409, str(e)) from None

    @app.post("/v1/releases/{release_id}/stop", dependencies=[Depends(auth)])
    async def stop_release(release_id: int):
        release_or_404(release_id)
        return releases.as_json(releases.stop(release_id))

    @app.post("/v1/releases/{release_id}/resume", dependencies=[Depends(auth)])
    async def resume_release(release_id: int):
        release_or_404(release_id)
        return releases.as_json(releases.resume(release_id))

    @app.delete("/v1/releases/{release_id}", dependencies=[Depends(auth)])
    async def delete_release(release_id: int):
        release_or_404(release_id)
        releases.delete(release_id)
        return {"ok": True}

    @app.get("/v1/voice", dependencies=[Depends(auth)])
    async def voice_info():
        return {"live": calls.on}

    @app.websocket("/v1/voice/call")
    async def voice_call(ws: WebSocket, conversation: str):
        """A live call in a chat (#34): the phone's microphone in, the voice out (binary frames, PCM16 mono at
        `rate`), and what's going on as JSON. Each spoken request is a chat turn by voice."""
        scheme, _, given = ws.headers.get("authorization", "").partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(given.encode(), token.encode()):
            await ws.close(code=1008)
            return
        row = db.app_conversation(conversation)
        if row is None:
            await ws.close(code=1008)
            return
        if not calls.on:
            await ws.close(code=1011)
            return
        await ws.accept()
        speaker = row["agent"] or ORCHESTRATOR
        if old := calls.active.get(conversation):  # a second call in a chat ends the first
            await old.end("replaced")
        try:
            voice = await calls.connect(live_instructions(
                AGENTS[speaker].name, agent.visible_history(CONVERSATION, 8, conversation)))
        except Exception as e:
            log.exception("live call: couldn't open the voice")
            await ws.send_json({"type": "error", "message": f"The voice didn't start: {e}"})
            await ws.close(code=1011)
            return
        send_lock = asyncio.Lock()

        async def send_json(message: dict) -> None:
            async with send_lock:
                await ws.send_json(message)

        async def send_audio(pcm: bytes) -> None:
            async with send_lock:
                await ws.send_bytes(pcm)

        async def on_turn(said: str, turn: Turn) -> None:
            await send_json({"type": "turn", "text": said, **chat_json(conversation, turn)})

        call = LiveCall(agent, voice, calls.store, conversation, speaker, send_json, send_audio, on_turn,
                        calls.idle_minutes, team_json)
        calls.active[conversation] = call
        await send_json({"type": "started", "rate": voice.rate, "agent": speaker})

        async def listen() -> None:
            try:
                while True:
                    message = await ws.receive()
                    if message["type"] == "websocket.disconnect":
                        break
                    if (pcm := message.get("bytes")) is not None:
                        await call.audio_in(pcm)
                    elif text := message.get("text"):
                        event = json.loads(text)
                        if event.get("type") == "say" and (said := str(event.get("text") or "").strip()):
                            await call.typed(said)
                        elif event.get("type") == "end":
                            break
            except (WebSocketDisconnect, RuntimeError):
                pass
            except Exception:
                log.exception("live call: the phone's side failed")
            await call.end("hung up")

        listener = asyncio.create_task(listen())
        try:
            await call.run()
        finally:
            listener.cancel()
            if calls.active.get(conversation) is call:
                del calls.active[conversation]
            try:
                await ws.close()
            except Exception:
                pass

    @app.websocket("/v1/browser/live")
    async def browser_live(ws: WebSocket, errand: int | None = None, site: str | None = None, frames: bool = True):
        """The live view: the page's frames (unless `frames=false`) and its scene to the app, the user's taps,
        typing and the app's own login screen to the page. What the user types is never logged, stored or shown
        to the model."""
        scheme, _, given = ws.headers.get("authorization", "").partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(given.encode(), token.encode()):
            await ws.close(code=1008)
            return
        if errands is None or (errand is None) == (site is None):
            await ws.close(code=1008 if errands else 1011)
            return
        browser = errands.browser
        if errand is not None:
            if errand_store.get(errand) is None or not await errands.ensure_page(errand):
                await ws.close(code=1008)
                return
            owner = f"errand:{errand}"
        else:
            try:
                site = check_site(site)
            except ValueError:
                await ws.close(code=1008)
                return
            owner = f"site:{site}"
            if browser.page(owner) is None:
                try:
                    await browser.open(owner, f"https://www.{site}")
                except BrowserError:
                    await ws.close(code=1011)
                    return
        await ws.accept()
        queue: asyncio.Queue = asyncio.Queue(maxsize=1)

        def on_frame(data: str, width: int, height: int) -> None:
            if queue.full():
                queue.get_nowait()  # only the latest matters
            queue.put_nowait({"type": "frame", "data": data, "width": width, "height": height})

        def control() -> bool:
            return errand is None or errands.can_take_over(errand)

        def status() -> dict:
            if errand is None:
                where = browser.where(owner) or {}
                return {"type": "status", "status": "login", "step": None, "control": True, "url": where.get("url")}
            e = errand_store.get(errand)
            return {"type": "status", "status": e["status"], "step": e["step"], "control": control(),
                    "reason": e["reason"] if e["status"] in ("needs_you", "waiting_confirm") else None,
                    "url": (browser.where(owner) or {}).get("url") or e["url"]}

        async def no_frames() -> None:
            pass

        watching = {"page": browser.page(owner), "stop": no_frames, "on": frames}
        if frames:
            watching["stop"] = await browser.screencast(owner, on_frame)

        async def show_frames(on: bool) -> None:
            await watching["stop"]()
            watching.update(page=browser.page(owner), on=on, stop=no_frames)
            if on and watching["page"] is not None:
                watching["stop"] = await browser.screencast(owner, on_frame)

        # The last scene sent: the app's fill and press reach only the refs in it.
        shown: dict = {"scene": None, "again": True}

        def refs(scene: dict | None) -> tuple[set[str], set[str]]:
            """The refs the app may fill and press in a scene: its form's and its CAPTCHA's."""
            fill, press = set(), set()
            form, captcha = (scene or {}).get("form") or {}, (scene or {}).get("captcha") or {}
            fill |= {f["ref"] for f in form.get("fields") or []}
            press |= {c["ref"] for c in form.get("choices") or []}
            press |= {r for r in ((form.get("submit") or {}).get("ref"), form.get("remember")) if r}
            if captcha.get("input_ref"):
                fill.add(captcha["input_ref"])
            press |= {r for r in (captcha.get("submit_ref"), captcha.get("ref"), (scene or {}).get("signin")) if r}
            return fill, press

        async def send() -> None:
            last_status, last_focus, last_url, last_crop, checked = None, None, None, None, 0.0
            seen = (browser.last_action(owner) or {}).get("seq")  # only what it does from now on
            while True:
                try:
                    frame = await asyncio.wait_for(queue.get(), 0.5)
                    if watching["on"]:
                        await ws.send_json(frame)
                except asyncio.TimeoutError:
                    pass
                page = browser.page(owner)
                if page is not None and page is not watching["page"]:  # a click opened another tab
                    await show_frames(watching["on"])
                if (now := status()) != last_status:
                    await ws.send_json(now)
                    last_status = now
                act = browser.last_action(owner) if errand is not None else None
                if act and act["seq"] != seen:
                    await ws.send_json({"type": "action", **act})
                    seen = act["seq"]
                    shown["again"] = True
                # The scene: after an action, a new address, the user's press, and every 2 s for what pages do alone.
                url = (browser.where(owner) or {}).get("url") if page is not None else None
                clock = asyncio.get_running_loop().time()
                if page is not None and (shown["again"] or url != last_url or clock - checked >= 2):
                    shown["again"], last_url, checked = False, url, clock
                    scene = await browser.scene(owner)
                    if scene is not None and scene != shown["scene"]:
                        shown["scene"] = scene
                        await ws.send_json({"type": "scene", **scene})
                    # The CAPTCHA's picture, again when it changes (a grid's tiles change under your taps).
                    captcha = (shown["scene"] or {}).get("captcha") if scene is not None else None
                    crop = await browser.crop(owner, captcha["ref"]) if captcha else None
                    if crop and crop[0] != last_crop:
                        last_crop = crop[0]
                        await ws.send_json({"type": "crop", "data": base64.b64encode(crop[0]).decode(),
                                            "box": crop[1]})
                if watching["on"]:
                    focus = await browser.focus(owner) if page is not None and control() else {"field": None}
                    if focus != last_focus:
                        await ws.send_json({"type": "focus", **focus})
                        last_focus = focus

        sender = asyncio.create_task(send())
        try:
            while True:
                message = await ws.receive_json()
                kind = message.get("type")
                if kind == "done":
                    if errand is not None:
                        e = errand_store.get(errand)
                        if e["status"] in ("needs_you", "interrupted"):
                            errands.done(errand)
                    else:
                        await browser.close(owner)
                    break
                if kind == "frames":
                    await show_frames(bool(message.get("on")))
                    continue
                if not control() or browser.page(owner) is None:
                    continue  # Aide is working on the page: watching only
                try:
                    if kind == "fill":
                        if (ref := str(message["ref"])) in refs(shown["scene"])[0]:
                            await browser.put(owner, ref, str(message["text"])[:500])
                    elif kind == "press":
                        if (ref := str(message["ref"])) in refs(shown["scene"])[1]:
                            form = (shown["scene"] or {}).get("form") or {}
                            submit = (form.get("submit") or {}).get("ref")
                            # "Stay logged in", ticked for the user before sending the form.
                            tick = form.get("remember") if ref == submit and form.get("remembered") is False else None
                            await browser.press_ref(owner, ref, tick)
                            shown["again"] = True
                    elif kind == "tap":
                        await browser.tap(owner, float(message["x"]), float(message["y"]))
                        shown["again"] = True
                    elif kind == "scroll":
                        await browser.wheel(owner, float(message.get("x", 0.5)), float(message.get("y", 0.5)),
                                            float(message["dy"]))
                    elif kind == "text":
                        await browser.type_text(owner, str(message["text"])[:500])
                    elif kind == "key":
                        key = message.get("key")
                        if key == "Back":
                            await browser.back(owner)
                        elif key in ("Enter", "Tab", "Backspace", "Escape"):
                            await browser.key(owner, key)
                except (KeyError, TypeError, ValueError, BrowserError):
                    continue
                except Exception as e:  # never with the message: it may hold what the user typed
                    log.warning("live view: a %s didn't reach the page (%s)", kind, type(e).__name__)
        except (WebSocketDisconnect, RuntimeError, ValueError):
            pass
        finally:
            sender.cancel()
            await watching["stop"]()
            try:
                await ws.close()
            except RuntimeError:
                pass

    # -- Live Activities ---------------------------------------------------------

    @app.post("/v1/live/tokens", dependencies=[Depends(auth)])
    async def live_start_token(body: LiveTokenIn):
        live.set_start_token(body.kind, body.token, body.environment)
        return {"ok": True}

    @app.delete("/v1/live/tokens/{kind}", dependencies=[Depends(auth)])
    async def delete_live_start_token(kind: str):
        if kind not in LIVE_KINDS:
            raise HTTPException(404, f"no Live Activity kind {kind}")
        live.remove_start_token(kind)
        return {"ok": True}

    @app.get("/v1/live/settings", dependencies=[Depends(auth)])
    async def live_settings():
        return live.settings()

    @app.patch("/v1/live/settings", dependencies=[Depends(auth)])
    async def edit_live_settings(body: LiveSettingsPatch):
        return live.update_settings(events=body.events, locks=body.locks, bedtime=body.bedtime, focus=body.focus)

    @app.post("/v1/live/activities", dependencies=[Depends(auth)])
    async def live_activity(body: LiveActivityIn):
        live.register(body.key, body.token, body.environment)
        await live.registered(body.key)
        return {"ok": True}

    @app.delete("/v1/live/activities/{key}", dependencies=[Depends(auth)])
    async def delete_live_activity(key: str):
        live.dismiss(key)
        return {"ok": True}

    return app
