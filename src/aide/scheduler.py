"""Background jobs. For now: push due reminders that never reached the phone."""

import asyncio
import logging
from datetime import timedelta
from zoneinfo import ZoneInfo

from .push import Push
from .reminders import ReminderStore, utcnow

log = logging.getLogger(__name__)

TICK = 30  # seconds
LATE = timedelta(minutes=5)  # beyond this, say the reminder is late (e.g. the machine was off)


async def reminder_fallback(store: ReminderStore, tz: ZoneInfo, push: Push | None = None) -> None:
    """Apple Reminders alerts for synced reminders; this covers the ones the phone never got. One try each: a
    reminder the push couldn't reach is still in the app."""
    while True:
        try:
            now = utcnow()
            for rem in store.unsynced_due(now):
                late = f"was due {rem.due_at.astimezone(tz):%a %d %b %H:%M}" if now - rem.due_at > LATE else ""
                if not (push and await push.send_reminder(rem.id, rem.title, f"Late: {late}" if late else "")):
                    log.warning("reminder %s not pushed; it's still in the app", rem.id)
                store.mark_notified(rem.id)
        except Exception:
            log.exception("reminder fallback tick failed")
        await asyncio.sleep(TICK)
