"""The next event's Live Activity (docs/API.md, "Live Activities", `event`): LEAD before a timed event on the Work
calendar (CALENDARS), the
server push-starts a countdown to it ("Macroeconomics in 8 min · Aula 5"), with a bar filling up to the start, its
notes' first line and what comes after it today; keeps it right when the event moves or changes place, and ends it
when the event starts (it stays up for SHOWN after) or goes.

Not for an event leave-now has set a tram alert for: the tram's countdown is the one to watch then, and one that
comes while the event's is on ends it. Off with the `events` setting (`/v1/live/settings`).
"""

import asyncio
import hashlib
import logging
import sqlite3
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .db import utcnow
from .live import LiveActivities, unix

log = logging.getLogger(__name__)

TICK = 60  # seconds between checks
LEAD = timedelta(minutes=10)  # the countdown starts this long before the event
CALENDARS = {"work"}  # only events on these calendars (lowercased) get one; what comes after can be on any
AHEAD = timedelta(hours=8)  # how far on the calendar is read, for what comes after the event
NOTES_MAX = 80
EVENTS_EVERY = timedelta(minutes=5)  # the calendar is read at most this often
SHOWN = timedelta(minutes=10)  # an event that has started stays on the Lock Screen this long

SCHEMA = """
CREATE TABLE IF NOT EXISTS event_activities (
    event   TEXT NOT NULL,  -- the calendar event's uid
    starts  TEXT NOT NULL,  -- its start when the activity began, UTC
    key     TEXT NOT NULL,  -- the activity's key
    state   TEXT NOT NULL,  -- on, or ended
    place   TEXT,           -- the last place sent
    at      TEXT NOT NULL,  -- UTC
    PRIMARY KEY (event, starts)
);
"""


def counts(e) -> bool:
    """On a calendar that gets a countdown."""
    return e.calendar.strip().lower() in CALENDARS


def key_for(uid: str, start: datetime) -> str:
    return f"event:{hashlib.sha1(uid.encode()).hexdigest()[:12]}:{unix(start)}"


class EventWatcher:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, cal, live: LiveActivities):
        self.conn, self.tz, self.cal, self.live = conn, tz, cal, live
        self.conn.executescript(SCHEMA)
        self._events: tuple[datetime, list] | None = None

    async def run(self) -> None:
        while True:
            await asyncio.sleep(TICK)
            if not self.live.enabled:
                continue
            try:
                await self.tick(utcnow())
            except Exception:
                log.exception("event activity tick failed")

    async def tick(self, now: datetime) -> None:
        events = await self._upcoming(now)
        if events is None:
            return
        on = {r["event"]: dict(r) for r in self.conn.execute("SELECT * FROM event_activities WHERE state = 'on'")}
        by_uid = {e.uid: e for e in events}
        for uid, row in on.items():
            e = by_uid.get(uid)
            if e is None or not counts(e) or self._tram(e):
                await self._end(row, now, now)  # gone, or the tram's countdown takes over
            elif e.start.astimezone(timezone.utc) <= now:
                await self._end(row, now, e.start.astimezone(timezone.utc) + SHOWN, e, events)
            elif e.start.astimezone(timezone.utc).isoformat() != row["starts"] or (e.location.strip() or None) != row["place"]:
                await self._update(row, e, events)
        if not self.live.settings()["events"]:
            return
        began = {(r["event"], r["starts"]) for r in self.conn.execute("SELECT event, starts FROM event_activities")}
        for e in events:
            start = e.start.astimezone(timezone.utc)
            if (counts(e) and e.uid not in on and (e.uid, start.isoformat()) not in began and now < start <= now + LEAD
                    and not self._tram(e)):
                await self._start(e, now, events)
        self.conn.execute("DELETE FROM event_activities WHERE starts < ?", ((now - timedelta(days=2)).isoformat(),))

    async def _upcoming(self, now: datetime) -> list | None:
        """Timed events from just before now to LEAD ahead (a moved one keeps its activity); None when the calendar
        can't be read."""
        if self._events is None or now - self._events[0] >= EVENTS_EVERY:
            try:
                found = await asyncio.to_thread(self.cal.events, now - SHOWN, now + AHEAD)
            except Exception:
                log.warning("event activities: couldn't read the calendar", exc_info=True)
                return None
            self._events = (now, [e for e in found if not e.all_day])
        return self._events[1]

    def _tram(self, e) -> bool:
        """Leave-now set a tram alert for it."""
        try:
            return self.conn.execute("SELECT 1 FROM leave_plans WHERE event = ? AND starts = ? AND state = 'alert'",
                                     (e.uid, e.start.astimezone(timezone.utc).isoformat())).fetchone() is not None
        except sqlite3.OperationalError:  # no leave-now on this server
            return False

    def _state(self, e, events: list, since: datetime, started: bool = False) -> dict:
        notes = next((line.strip() for line in (e.notes or "").splitlines() if line.strip()), None)
        if notes and len(notes) > NOTES_MAX:
            notes = notes[:NOTES_MAX - 1].rstrip() + "…"
        local = e.start.astimezone(self.tz).date()
        later = [x for x in events if x.uid != e.uid and x.start > e.start and x.start.astimezone(self.tz).date() == local]
        then = min(later, key=lambda x: x.start, default=None)
        return {"start": unix(e.start), "end": unix(e.end) if isinstance(e.end, datetime) else None,
                "place": e.location.strip() or None, "started": started, "since": unix(since), "notes": notes,
                "then": {"title": then.title, "start": unix(then.start)} if then else None}

    async def _start(self, e, now: datetime, events: list) -> None:
        start = e.start.astimezone(timezone.utc)
        key = key_for(e.uid, start)
        place = e.location.strip() or None
        minutes = max(1, round((start - now).total_seconds() / 60))
        ok = await self.live.start("event", {"key": key, "title": e.title, "calendar": e.calendar},
                                   self._state(e, events, now),
                                   {"title": f"{e.title} in {minutes} min", "body": place or f"At {e.start.astimezone(self.tz):%H:%M}"},
                                   stale=start + SHOWN)
        # Marked either way, so a start that didn't go out (no token) isn't tried every minute.
        self.conn.execute("INSERT OR REPLACE INTO event_activities (event, starts, key, state, place, at) "
                          "VALUES (?, ?, ?, ?, ?, ?)", (e.uid, start.isoformat(), key, "on" if ok else "ended",
                                                        place, now.isoformat()))
        if ok:
            log.info("event activity for %r started", e.title)

    async def _update(self, row: dict, e, events: list) -> None:
        start = e.start.astimezone(timezone.utc)
        await self.live.update(row["key"], self._state(e, events, datetime.fromisoformat(row["at"])),
                               stale=start + SHOWN)
        self.conn.execute("UPDATE event_activities SET starts = ?, place = ? WHERE event = ? AND starts = ?",
                          (start.isoformat(), e.location.strip() or None, row["event"], row["starts"]))

    async def _end(self, row: dict, now: datetime, dismiss: datetime, e=None, events: list = ()) -> None:
        since = datetime.fromisoformat(row["at"])
        state = self._state(e, list(events), since, started=True) if e else {
            "start": unix(datetime.fromisoformat(row["starts"])), "end": None, "place": row["place"], "started": False,
            "since": unix(since), "notes": None, "then": None}
        await self.live.end(row["key"], state, dismiss)
        self.conn.execute("UPDATE event_activities SET state = 'ended', at = ? WHERE event = ? AND starts = ?",
                          (now.isoformat(), row["event"], row["starts"]))
