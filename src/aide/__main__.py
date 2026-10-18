"""Entry point: `aide` or `python -m aide`."""

import asyncio
import logging
import threading
from datetime import timedelta

import anthropic
import uvicorn

from .agent import Agent
from .channels.api import create_app
from .channels.discord_bot import AideBot
from .config import OPENROUTER_BASE_URL, load_settings
from .db import Database
from .icloud import ICloudCalendar
from .reminders import ReminderStore
from .scheduler import reminder_fallback
from .tools import ToolRegistry
from .tools.calendar import calendar_tools
from .tools.clock import clock_tool
from .tools.reminders import reminder_tools

log = logging.getLogger(__name__)


def main() -> None:
    # No timestamps: journald adds its own.
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx2").setLevel(logging.WARNING)  # one line per API call is noise
    logging.getLogger("caldav").setLevel(logging.ERROR)  # its warnings dump raw event data
    logging.getLogger("discord.client").addFilter(  # Aide doesn't use voice
        lambda record: "voice will NOT be supported" not in record.getMessage()
    )
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

    tools = [clock_tool(settings.timezone), *reminder_tools(reminders, settings.timezone)]
    cal = None
    if settings.icloud_email and settings.icloud_app_password:
        cal = ICloudCalendar(settings.icloud_email, settings.icloud_app_password)
        # Find the calendars in the background so the first request doesn't wait for it.
        threading.Thread(target=cal.calendars, daemon=True).start()
        tools += calendar_tools(cal, settings.timezone, settings.default_calendar)
    else:
        log.warning("ICLOUD_EMAIL / ICLOUD_APP_PASSWORD not set: calendar tools disabled")

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
    )
    bot = AideBot(agent, settings.discord_owner_id)

    async def run() -> None:
        jobs = [
            bot.start(settings.discord_token),
            reminder_fallback(reminders, bot.notify_owner, settings.timezone),
        ]
        if settings.api_token:
            app = create_app(agent, reminders, cal, settings.timezone, settings.api_token)
            # Localhost only: `tailscale serve` publishes it to the tailnet over HTTPS.
            config = uvicorn.Config(app, host="127.0.0.1", port=settings.api_port, log_level="warning")
            jobs.append(uvicorn.Server(config).serve())
            log.info("API on http://127.0.0.1:%d", settings.api_port)
        else:
            log.warning("AIDE_API_TOKEN not set: HTTP API for the iOS app disabled")
        try:
            await asyncio.gather(*jobs)
        finally:
            await bot.close()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
    finally:
        db.close()


if __name__ == "__main__":
    main()
