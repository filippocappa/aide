"""Background jobs. For now: push due reminders that never reached the phone."""

import asyncio
import logging
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from .push import Push
from .reminders import ReminderStore, utcnow

log = logging.getLogger(__name__)

TICK = 30  # seconds
LATE = timedelta(minutes=5)  # beyond this, say the reminder is late (e.g. the machine was off)
RETRY_FOR = timedelta(minutes=30)  # how long to keep trying a push that failed for a reason that can pass


async def reminder_fallback(store: ReminderStore, tz: ZoneInfo, push: Push | None = None) -> None:
    """Apple Reminders alerts for synced reminders; this covers the ones the phone never got. One try each, unless
    the push failed for a reason that can pass (no answer, throttled, APNs down): then every tick for up to
    RETRY_FOR. A reminder the push couldn't reach is still in the app."""
    failing: dict[str, datetime] = {}  # reminder id -> when its push first failed for a reason that can pass
    while True:
        try:
            now = utcnow()
            for rem in store.unsynced_due(now):
                late = f"was due {rem.due_at.astimezone(tz):%a %d %b %H:%M}" if now - rem.due_at > LATE else ""
                sent = await push.send_reminder(rem.id, rem.title, f"Late: {late}" if late else "") if push else False
                if sent is None and now - failing.setdefault(rem.id, now) < RETRY_FOR:
                    continue  # the next tick tries again
                if not sent:
                    log.warning("reminder %s not pushed; it's still in the app", rem.id)
                failing.pop(rem.id, None)
                store.mark_notified(rem.id)
        except Exception:
            log.exception("reminder fallback tick failed")
        await asyncio.sleep(TICK)
