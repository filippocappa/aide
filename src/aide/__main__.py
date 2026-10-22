"""Entry point: `aide` or `python -m aide`."""

import asyncio
import logging
import threading
from datetime import datetime, timedelta
from pathlib import Path

import anthropic
import uvicorn

from .agent import CONVERSATION, Agent
from .channels.api import create_app
from .transcribe import Transcriber
from .config import OPENROUTER_BASE_URL, load_settings, save_env
from .db import Database
from .digest import DigestService, digest_schedule
from .engine import Engine
from .gmail import Gmail
from .food import FoodStore
from .objectives import ObjectivePlanner, ObjectiveStore, StudyReplanner
from .habits import HabitStore
from .health import HealthStore
from .photos import PhotoStore
from .icloud import ICloudCalendar
from .push import Push
from .reminders import ReminderStore
from .routines import routine_schedule
from .scheduler import reminder_fallback
from .material import PageReader
from .moodle import MoodleSync
from .notebook import NotebookStore, NotebookWorker
from .study import StudyStore, StudyWorker, whisper_transcribe
from .vault import Vault
from .webdav import USER as WEBDAV_USER
from .tools import ToolRegistry
from .tools.calendar import calendar_tools
from .tools.clock import clock_tool
from .tools.food import food_tools
from .tools.objectives import objective_tools
from .tools.habits import habit_tools
from .tools.health import health_tools
from .tools.mail import mail_tools
from .tools.maps import GoogleMaps, maps_tools
from .tools.reminders import reminder_tools
from .tools.search import Tavily, search_tools
from .tools.study import study_tools
from .tools.transit import transit_tools
from .transit import AlertStore, AlertWatcher, Boards, Live, Location, Timetable, Transit, Walks, Whereabouts
from .wake import WakeService
from .whisper import available as whisper_available

log = logging.getLogger(__name__)


def main() -> None:
    # No timestamps: journald adds its own.
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # one line per call is noise, and Moodle URLs carry its token
    logging.getLogger("caldav").setLevel(logging.ERROR)  # its warnings dump raw event data
    settings = load_settings()

    if settings.openrouter_api_key:
        # OpenRouter speaks the Anthropic Messages format; the key goes in as a bearer token.
        client = anthropic.AsyncAnthropic(
            base_url=OPENROUTER_BASE_URL, auth_token=settings.openrouter_api_key, api_key=None
        )
    else:
        client = anthropic.AsyncAnthropic(api_key=settings.anthropic_api_key)

    db = Database(settings.db_path)
    reminders = ReminderStore(db.conn)
    habits = HabitStore(db.conn, settings.timezone)
    health = HealthStore(db.conn, settings.timezone)
    food = FoodStore(db.conn, settings.timezone)
    photos = PhotoStore(settings.db_path.parent / "photos")
    push = Push(db.conn, settings.apns_key_path, settings.apns_key_id, settings.apns_team_id, settings.apns_bundle_id)
    if push.enabled:
        reminders.on_change.append(push.request_sync)
    elif not (settings.apns_key_path and settings.apns_key_id and settings.apns_team_id):
        log.warning("APNS_KEY_PATH / APNS_KEY_ID / APNS_TEAM_ID not set: push notifications off")

    tools = [clock_tool(settings.timezone), *reminder_tools(reminders, settings.timezone), *habit_tools(habits),
             *health_tools(health, settings.timezone), *food_tools(food, photos, settings.timezone)]
    cal = None
    if settings.icloud_email and settings.icloud_app_password:
        cal = ICloudCalendar(settings.icloud_email, settings.icloud_app_password)
        # Find the calendars in the background so the first request doesn't wait for it.
        threading.Thread(target=cal.calendars, daemon=True).start()
        tools += calendar_tools(cal, settings.timezone, settings.default_calendar)
    else:
        log.warning("ICLOUD_EMAIL / ICLOUD_APP_PASSWORD not set: calendar tools disabled")
    study = StudyStore(db, settings.timezone, cal, settings.study_calendar, settings.exam_calendar,
                       settings.study_skip, settings.db_path.parent / "files")
    audio_dir = settings.db_path.parent / "audio"
    notebook = NotebookStore(study)
    engine = Engine(db.conn, client, settings.model, settings.smart_model, workdir=settings.db_path.parent / "claude")
    if not engine.available:
        log.info("Claude Code not found: notes are written through OpenRouter only")
    tools += study_tools(study, settings.timezone, audio_dir, notebook, engine)
    gmail = None
    if settings.gmail_client_id and settings.gmail_client_secret and settings.gmail_refresh_token:
        gmail = Gmail(settings.gmail_client_id, settings.gmail_client_secret, settings.gmail_refresh_token)
        tools += mail_tools(gmail, settings.timezone)
    else:
        log.warning("GMAIL_CLIENT_ID / GMAIL_CLIENT_SECRET / GMAIL_REFRESH_TOKEN not set: mail tools disabled")
    if settings.tavily_api_key:
        tools += search_tools(Tavily(settings.tavily_api_key), settings.timezone)
    else:
        log.warning("TAVILY_API_KEY not set: web search disabled")
    location = Location(db.conn, push)
    maps = None
    if settings.google_maps_api_key:
        maps = GoogleMaps(settings.google_maps_api_key)
        tools += maps_tools(maps, settings.timezone, settings.home_address, location.here)
        if not settings.home_address:
            log.warning("AIDE_HOME_ADDRESS not set: Maps tools need an explicit origin")
    else:
        log.warning("GOOGLE_MAPS_API_KEY not set: Maps tools disabled")
    transit = alerts = watcher = boards = None
    if settings.gtt:
        timetable = Timetable(settings.db_path.parent / "gtt.db", settings.timezone)
        transit = Transit(timetable, Live())
        alerts = AlertStore(db.conn, settings.timezone, timetable)
        walks = Walks(maps)
        watcher = AlertWatcher(alerts, transit, location, walks, push)
        boards = Boards(transit, location, walks)
        tools += transit_tools(transit, alerts, location, boards)
    else:
        log.info("AIDE_GTT off: no GTT tools or tram alerts")

    objectives = ObjectiveStore(db.conn, settings.timezone, habits, food, health, reminders)
    planner = ObjectivePlanner(objectives, engine, db, cal, study, notebook)
    replanner = StudyReplanner(planner)  # Professor's proposals follow the notes and dates as they change
    notebook.on_change.append(replanner.changed)
    agent = Agent(
        client=client,
        db=db,
        tools=ToolRegistry(tools),
        model=settings.model,
        smart_model=settings.smart_model,
        effort=settings.effort,
        idle=timedelta(hours=settings.idle_hours),
        tz=settings.timezone,
        server_fallback=not settings.openrouter_api_key,
        photos=photos,
        agent_tools=lambda agent_id, any_agent: objective_tools(objectives, planner, agent_id, any_agent),
    )
    if maps is not None:
        agent.whereabouts = Whereabouts(location, maps).describe
    if added := agent.routines.add_starting_watches():
        log.info("set up the starting watches: %s", ", ".join(r["title"] for r in added))
    digest = DigestService(db.conn, client, settings.model, settings.timezone, reminders, habits, cal, gmail,
                           health, maps, settings.home_address)
    digest.objectives, digest.planner = objectives, planner

    if not whisper_available():
        log.warning("faster-whisper not installed (uv sync --extra whisper): lecture recordings not accepted")
    worker = StudyWorker(study, agent, push, audio_dir, whisper_transcribe if whisper_available() else None)
    worker.notebook = notebook
    notes = NotebookWorker(notebook, agent, push)
    reader = PageReader(study.files, agent)  # scans, read once with the model
    worker.engine = notes.engine = reader.engine = engine

    async def plan_limit(paused: dict) -> None:
        """The plan's limit, mid-job: asked in the job's course chat (Professor), with a push."""
        course = study.course(paused["course"]) if paused["course"] else None
        when = ""
        if paused["resets_at"]:
            resets = datetime.fromisoformat(paused["resets_at"]).astimezone(settings.timezone)
            today = resets.date() == datetime.now(settings.timezone).date()
            when = f" It resets at {resets:%H:%M}" + ("" if today else f" on {resets:%a %d %b}") + "."
        text = (f"I've hit your Claude plan's limit while writing notes.{when} Shall I wait for it, or finish on "
                "OpenRouter (paid) until then? The job is paused until you say.")
        note = ("[The Claude plan's limit is reached and a notes job is paused. When the user answers, call "
                "notes_writer with limit_answer \"wait\" or \"openrouter\".]")
        if course is not None:
            await notes._post(course, note, text, push=True)
        else:
            log.warning("Claude plan limit reached during a job with no course: waiting for the reset")
    engine.on_pause = plan_limit
    moodle = MoodleSync(study, settings.moodle_url, settings.moodle_token, push=push, worker=worker,
                        save_token=lambda token: save_env(Path(".env"), "MOODLE_TOKEN", token), notebook=notebook)
    vault, vault_info = None, None
    if settings.webdav_password:
        vault = Vault(settings.vault_dir / settings.vault_name, study, notebook)
        notes.vault = vault
        vault_info = {"url": settings.webdav_url, "user": WEBDAV_USER, "password": settings.webdav_password,
                      "vault": settings.vault_name}
    else:
        log.info("AIDE_WEBDAV_PASSWORD not set: no Obsidian vault")

    async def run() -> None:
        replanner.start()
        wake = WakeService(digest, health, settings.timezone, push)
        jobs = [
            reminder_fallback(reminders, settings.timezone, push),
            digest_schedule(digest, push),
            routine_schedule(agent, CONVERSATION, push),
            worker.run(),
            notes.run(),
            reader.run(),
            *([vault.run()] if vault else []),
            *([moodle.run()] if settings.moodle_url else []),
            *([transit.timetable.run(), watcher.run()] if transit else []),
        ]
        if settings.api_token:
            transcriber = (Transcriber(settings.openrouter_api_key, settings.transcribe_model)
                           if settings.openrouter_api_key else None)
            app = create_app(agent, reminders, cal, settings.timezone, settings.api_token, habits, digest, push,
                             health, wake, transcriber, food, study, worker, vault_info, moodle,
                             notebook, engine, objectives, planner, location, alerts, boards)
            # Localhost only: `tailscale serve` publishes it to the tailnet over HTTPS.
            config = uvicorn.Config(app, host="127.0.0.1", port=settings.api_port, log_level="warning")
            jobs.append(uvicorn.Server(config).serve())
            log.info("API on http://127.0.0.1:%d", settings.api_port)
        else:
            log.warning("AIDE_API_TOKEN not set: HTTP API for the iOS app disabled")
        try:
            await asyncio.gather(*jobs)
        finally:
            await push.close()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
    finally:
        db.close()


if __name__ == "__main__":
    main()
