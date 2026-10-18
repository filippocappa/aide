"""Background jobs. For now: send due reminders that never reached the phone to Discord."""

import asyncio
import logging
from datetime import timedelta
from typing import Awaitable, Callable
from zoneinfo import ZoneInfo

from .reminders import ReminderStore, utcnow

log = logging.getLogger(__name__)

TICK = 30  # seconds
LATE = timedelta(minutes=5)  # beyond this, say the reminder is late (e.g. the machine was off)


async def reminder_fallback(store: ReminderStore, notify: Callable[[str], Awaitable[bool]], tz: ZoneInfo) -> None:
    """Apple Reminders alerts for synced reminders; this covers the ones the phone never got."""
    while True:
        try:
            now = utcnow()
            for rem in store.unsynced_due(now):
                text = f"⏰ {rem.title}"
                if now - rem.due_at > LATE:
                    text += f"\n(late: was due {rem.due_at.astimezone(tz):%a %d %b %H:%M})"
                if await notify(text):  # if it failed, the next tick retries
                    store.mark_notified(rem.id)
        except Exception:
            log.exception("reminder fallback tick failed")
        await asyncio.sleep(TICK)
