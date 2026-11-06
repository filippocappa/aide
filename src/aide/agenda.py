"""Today's and tomorrow's calendar for a spoken turn's stamp (#71): "what's on tomorrow" by voice is then one model
round, not a list_events call and a second round (~1.5 s). Kept between turns and read again in the background, so
a turn doesn't wait for iCloud; every write through Aide drops what's kept (WatchedCalendar), and an event added on
the phone shows within FRESH."""

import asyncio
import logging
from datetime import date, datetime, time, timedelta
from typing import Callable
from zoneinfo import ZoneInfo

from .icloud import CalEvent, unread

log = logging.getLogger(__name__)

FRESH = timedelta(minutes=2)  # older than this: used, and read again for the next turn
USABLE = timedelta(minutes=15)  # older than this: read again before the turn
WAIT = 2.0  # seconds a turn waits for a read when nothing usable is kept (iCloud takes ~0.5 s)
PER_DAY = 25
PLACE_LIMIT = 60


class WatchedCalendar:
    """A calendar backend that says when it's written to: the creates, edits and deletes of every part of Aide
    (the tools, review sessions, plans) go through it. Called from worker threads."""

    def __init__(self, cal, on_change: Callable[[], None]):
        self._cal, self._on_change = cal, on_change

    def __getattr__(self, name):
        return getattr(self._cal, name)

    def create(self, *args, **kwargs):
        try:
            return self._cal.create(*args, **kwargs)
        finally:
            self._on_change()

    def update(self, *args, **kwargs):
        try:
            return self._cal.update(*args, **kwargs)
        finally:
            self._on_change()

    def delete(self, *args, **kwargs):
        try:
            return self._cal.delete(*args, **kwargs)
        finally:
            self._on_change()


class Agenda:
    def __init__(self, cal, tz: ZoneInfo, default_calendar: str | None = None,
                 now: Callable[[], datetime] | None = None):
        self.cal, self.tz, self.default = cal, tz, default_calendar
        self._now = now or (lambda: datetime.now(tz))
        self._kept: tuple[datetime, date, str] | None = None  # read at, the day it's for, the line
        self._reading: asyncio.Task | None = None
        self._changes = 0

    def changed(self) -> None:
        """Something was written to the calendar: what's kept is out of date. Safe from any thread."""
        self._changes += 1
        self._kept = None

    def warm(self) -> None:
        """Read it now in the background (a call is opening), unless what's kept is fresh."""
        now = self._now()
        kept = self._kept
        if kept is None or kept[1] != now.date() or now - kept[0] >= FRESH:
            self._start()

    async def line(self) -> str | None:
        """The calendar for the stamp ("calendar, read just now: today …; tomorrow …; calendars: …"), or None when
        it can't be read in time: the model then uses list_events as before."""
        now = self._now()
        kept = self._kept
        if kept is not None and kept[1] == now.date() and now - kept[0] < USABLE:
            if now - kept[0] >= FRESH:
                self._start()
            return _aged(kept, now)
        try:
            kept = await asyncio.wait_for(asyncio.shield(self._start()), WAIT)
        except asyncio.TimeoutError:
            log.warning("agenda: the calendar took over %.0f s; the turn goes without it", WAIT)
            return None
        except Exception:
            log.warning("agenda: the calendar read failed", exc_info=True)
            return None
        return _aged(kept, self._now()) if kept else None

    def _start(self) -> asyncio.Task:
        if self._reading is None or self._reading.done():
            self._reading = asyncio.create_task(self._read())
            self._reading.add_done_callback(_quiet)
        return self._reading

    async def _read(self) -> tuple[datetime, date, str]:
        changes, at = self._changes, self._now()
        text = await asyncio.to_thread(self._build, at)
        kept = (at, at.date(), text)
        if changes == self._changes:  # else a write came during the read: use it once, don't keep it
            self._kept = kept
        return kept

    def _build(self, now: datetime) -> str:
        today = now.date()
        start = datetime.combine(today, time.min, self.tz)
        found = self.cal.events(start, datetime.combine(today + timedelta(days=2), time.min, self.tz))
        days = [f"{label} {d:%a %d %b}: {self._day(found, d)}"
                for label, d in (("today", today), ("tomorrow", today + timedelta(days=1)))]
        parts = ["; ".join(days)]
        if missing := unread(found):
            parts.append(f"couldn't read {', '.join(sorted(missing))} just now")
        try:
            names = self.cal.calendars()
        except Exception:
            names = []
        if names:
            default = self.default if self.default in names else names[0]
            parts.append("calendars: " + ", ".join(f"{n} (default)" if n == default else n for n in
                                                    [default, *(n for n in names if n != default)]))
        return " | ".join(parts).replace("[", "(").replace("]", ")").replace("\n", " ")

    def _day(self, events: list[CalEvent], day: date) -> str:
        begin = datetime.combine(day, time.min, self.tz)
        end = begin + timedelta(days=1)
        lines = []
        for ev in sorted(events, key=self._key):
            if ev.all_day:
                last = max(ev.end, ev.start + timedelta(days=1))
                if ev.start <= day < last:
                    lines.append(f"all day {ev.title}{self._where(ev)}")
                continue
            s, e = ev.start.astimezone(self.tz), ev.end.astimezone(self.tz)
            if s < end and (e > begin or s >= begin):
                frm = f"{s:%H:%M}" if s >= begin else "(from before)"
                to = f"{e:%H:%M}" if e <= end else "(on after)"
                lines.append(f"{frm}–{to} {ev.title}{self._where(ev)}")
        if not lines:
            return "nothing"
        more = len(lines) - PER_DAY
        return ", ".join(lines[:PER_DAY]) + (f", and {more} more" if more > 0 else "")

    def _where(self, ev: CalEvent) -> str:
        place = ev.location.replace("\n", " ").strip()
        if len(place) > PLACE_LIMIT:
            place = place[:PLACE_LIMIT] + "…"
        return f" ({ev.calendar}{', at ' + place if place else ''})"

    def _key(self, ev: CalEvent) -> datetime:
        if ev.all_day:
            return datetime.combine(ev.start, time.min, self.tz)
        return ev.start.astimezone(self.tz)


def _aged(kept: tuple[datetime, date, str], now: datetime) -> str:
    minutes = int((now - kept[0]).total_seconds() // 60)
    age = "just now" if minutes < 1 else f"{minutes} min ago"
    return f"calendar, read {age}: {kept[2]}"


def _quiet(task: asyncio.Task) -> None:
    if not task.cancelled() and task.exception() is not None:
        log.warning("agenda: the calendar read failed: %s", task.exception())
