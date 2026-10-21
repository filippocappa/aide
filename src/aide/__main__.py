"""Entry point: `aide` or `python -m aide`."""

import asyncio
import logging
import threading
from datetime import timedelta

import anthropic
import uvicorn

from .agent import CONVERSATION, Agent
from .channels.api import create_app
from .transcribe import Transcriber
from .config import OPENROUTER_BASE_URL, load_settings
from .db import Database
from .digest import DigestService, digest_schedule
from .gmail import Gmail
from .food import FoodStore
from .habits import HabitStore
from .health import HealthStore
from .photos import PhotoStore
from .icloud import ICloudCalendar
from .push import Push
from .reminders import ReminderStore
from .routines import routine_schedule
from .scheduler import reminder_fallback
from .study import StudyStore, StudyWorker, whisper_transcribe
from .vault import Vault
from .webdav import USER as WEBDAV_USER
from .tools import ToolRegistry
from .tools.calendar import calendar_tools
from .tools.clock import clock_tool
from .tools.food import food_tools
from .tools.habits import habit_tools
from .tools.health import health_tools
from .tools.mail import mail_tools
from .tools.maps import GoogleMaps, maps_tools
from .tools.reminders import reminder_tools
from .tools.search import Tavily, search_tools
from .tools.study import study_tools
from .wake import WakeService
from .whisper import available as whisper_available

log = logging.getLogger(__name__)


def main() -> None:
    # No timestamps: journald adds its own.
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx2").setLevel(logging.WARNING)  # one line per API call is noise
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
    tools += study_tools(study, settings.timezone, audio_dir)
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
    maps = None
    if settings.google_maps_api_key:
        maps = GoogleMaps(settings.google_maps_api_key)
        tools += maps_tools(maps, settings.timezone, settings.home_address)
        if not settings.home_address:
            log.warning("AIDE_HOME_ADDRESS not set: Maps tools need an explicit origin")
    else:
        log.warning("GOOGLE_MAPS_API_KEY not set: Maps tools disabled")

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
    )
    if added := agent.routines.add_starting_watches():
        log.info("set up the starting watches: %s", ", ".join(r["title"] for r in added))
    digest = DigestService(db.conn, client, settings.model, settings.timezone, reminders, habits, cal, gmail,
                           health, maps, settings.home_address)

    if not whisper_available():
        log.warning("faster-whisper not installed (uv sync --extra whisper): lecture recordings not accepted")
    worker = StudyWorker(study, agent, push, audio_dir, whisper_transcribe if whisper_available() else None)
    vault, vault_info = None, None
    if settings.webdav_password:
        vault = Vault(settings.vault_dir / settings.vault_name, study)
        vault_info = {"url": settings.webdav_url, "user": WEBDAV_USER, "password": settings.webdav_password,
                      "vault": settings.vault_name}
    else:
        log.info("AIDE_WEBDAV_PASSWORD not set: no Obsidian vault")

    async def run() -> None:
        wake = WakeService(digest, health, settings.timezone, push)
        jobs = [
            reminder_fallback(reminders, settings.timezone, push),
            digest_schedule(digest, push),
            routine_schedule(agent, CONVERSATION, push),
            worker.run(),
            *([vault.run()] if vault else []),
        ]
        if settings.api_token:
            transcriber = (Transcriber(settings.openrouter_api_key, settings.transcribe_model)
                           if settings.openrouter_api_key else None)
            app = create_app(agent, reminders, cal, settings.timezone, settings.api_token, habits, digest, push,
                             health, wake, transcriber, food, study, worker, vault_info)
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
