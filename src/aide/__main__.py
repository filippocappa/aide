"""Entry point: `aide` or `python -m aide`."""

import logging
from datetime import timedelta

import anthropic

from .agent import Agent
from .channels.discord_bot import AideBot
from .config import load_settings
from .db import Database
from .tools import ToolRegistry
from .tools.clock import clock_tool


def main() -> None:
    # No timestamps: journald adds its own.
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    settings = load_settings()

    db = Database(settings.db_path)
    agent = Agent(
        client=anthropic.AsyncAnthropic(api_key=settings.anthropic_api_key),
        db=db,
        tools=ToolRegistry([clock_tool(settings.timezone)]),
        model=settings.model,
        effort=settings.effort,
        idle=timedelta(hours=settings.idle_hours),
    )
    bot = AideBot(agent, settings.discord_owner_id)
    try:
        bot.run(settings.discord_token, log_handler=None)  # use our logging config
    finally:
        db.close()


if __name__ == "__main__":
    main()
