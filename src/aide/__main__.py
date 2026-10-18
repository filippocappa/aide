"""Entry point: `aide` or `python -m aide`."""

import logging
import threading
from datetime import timedelta

import anthropic

from .agent import Agent
from .channels.discord_bot import AideBot
from .config import OPENROUTER_BASE_URL, load_settings
from .db import Database
from .icloud import ICloudCalendar
from .tools import ToolRegistry
from .tools.calendar import calendar_tools
from .tools.clock import clock_tool

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

    tools = [clock_tool(settings.timezone)]
    if settings.icloud_email and settings.icloud_app_password:
        cal = ICloudCalendar(settings.icloud_email, settings.icloud_app_password)
        # Find the calendars in the background so the first request doesn't wait for it.
        threading.Thread(target=cal.calendars, daemon=True).start()
        tools += calendar_tools(cal, settings.timezone, settings.default_calendar)
    else:
        log.warning("ICLOUD_EMAIL / ICLOUD_APP_PASSWORD not set: calendar tools disabled")

    db = Database(settings.db_path)
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
    try:
        bot.run(settings.discord_token, log_handler=None)  # use our logging config
    finally:
        db.close()


if __name__ == "__main__":
    main()
