"""Nudges from the devices (#84; docs/API.md, "Nudges").

Two kinds, both decided on the device, which knows whether you're there (the Mac's Aide Guard, the phone's Screen Time
monitor); the server says what's due and keeps what happened:

- **bedtime:** while still active near tonight's bedtime (bedtime.py), firmer as it comes: an hour before, half an
  hour before, ten minutes before, then every ten minutes up to three hours after it. Nudges only: Bedtime's own lock
  is never touched here.
- **offtask:** while a calendar event that asks for focus is on (anything in the study calendar, or an event with
  `#focus` in its title or notes) and what's in front is on the Work app list: one nudge per event, one more after
  fifteen minutes more off task.

`plan()` is what a device needs now; `log()` keeps each nudge shown and its answer, which Coach (the evening digest,
`sleep_plan`) and Professor (`study_plan`, the study week) see as data.
"""

import logging
import re
import sqlite3
from datetime import date, datetime, time, timedelta, timezone
from typing import Awaitable, Callable
from zoneinfo import ZoneInfo

from .db import utcnow

log = logging.getLogger(__name__)

BEDTIME_STEPS = (("hour", 60), ("half", 30), ("now", 10))  # minutes before the bedtime
LATE_EVERY = timedelta(minutes=10)  # after the last step, again this often
LATE_FOR = timedelta(hours=3)  # ... for this long after the bedtime
AHEAD = timedelta(hours=24)  # events a device is told about
FOCUS_TAG = "#focus"  # an event outside the study calendar that asks for the off-task nudges
WORK_LIST = "work"  # the app list (by name, any case) that's off task during a focus event
KINDS = {"bedtime": {"hour", "half", "now", "late"}, "offtask": {"first", "again"}}
ANSWERS = {"bedtime": {"snooze", "going"}, "offtask": {"back", "not_now"}}
DEVICES = {"mac", "phone"}
KEPT = timedelta(days=120)

SCHEMA = """
CREATE TABLE IF NOT EXISTS nudges (
    id          INTEGER PRIMARY KEY,
    key         TEXT NOT NULL UNIQUE, -- the device's, so a retry or an answer later is the same row
    device      TEXT NOT NULL,        -- mac, phone
    kind        TEXT NOT NULL,        -- bedtime, offtask
    step        TEXT NOT NULL,        -- bedtime: hour, half, now, late; offtask: first, again
    at          TEXT NOT NULL,        -- shown, UTC
    night       TEXT,                 -- bedtime: the morning the night ends on, local
    app         TEXT,                 -- what was in front: an app's name or a site
    event       TEXT,                 -- offtask: the event's title
    event_start TEXT,                 -- offtask: its start, UTC
    event_end   TEXT,
    course_id   INTEGER,
    answer      TEXT,                 -- bedtime: snooze, going; offtask: back, not_now; NULL: none
    answered_at TEXT
);
CREATE INDEX IF NOT EXISTS nudges_at ON nudges (at);
"""


def _clock(dt: datetime) -> str:
    return f"{dt.hour}:{dt.minute:02d}"


def _utc(value: str | None) -> str | None:
    """An ISO time from a device, as UTC; None for nothing or nonsense."""
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).astimezone(timezone.utc).isoformat()


def bedtime_steps(bed: datetime) -> list[dict]:
    """The evening's nudges for a bedtime (local): each with when it's due, until the next one, and its words."""
    bed_at = _clock(bed)
    texts = {
        "hour": ("An hour to bed", f"Start wrapping up: in bed by {bed_at}."),
        "half": ("Half an hour to bed", "Save and close what you're on."),
        "now": ("Bedtime in ten minutes", "It's time to sleep: stop what you're doing."),
    }
    steps = [{"step": step, "at": bed - timedelta(minutes=before), "title": texts[step][0], "body": texts[step][1]}
             for step, before in BEDTIME_STEPS]
    at = bed
    while at <= bed + LATE_FOR:
        late = int((at - bed).total_seconds() // 60)
        steps.append({"step": "late", "at": at, "title": "Past bedtime" if late else "Bedtime",
                      "body": (f"It's {_clock(at)}, {late} min past bedtime: stop what you're doing."
                               if late else f"It's {bed_at}: time to sleep. Stop what you're doing.")})
        at += LATE_EVERY
    for step, following in zip(steps, steps[1:] + [None]):
        step["until"] = following["at"] if following else bed + LATE_FOR + LATE_EVERY
    return [{**s, "at": s["at"].isoformat(), "until": s["until"].isoformat()} for s in steps]


def _words(text: str) -> list[str]:
    return [w for w in "".join(c if c.isalnum() else " " for c in text.casefold()).split()]


class Nudges:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, bedtime=None,
                 events: Callable[[datetime, datetime], Awaitable[list[dict] | None]] | None = None,
                 study_calendar: str = "Work", locks=None, focus=None):
        """`bedtime`: bedtime.Bedtime; `events(start, end)`: the calendar as event_json, None when it can't be read;
        `locks`: locks.LockStore (the Work list); `focus`: focus.FocusStore (a session on now)."""
        self.conn, self.tz, self.bedtime, self.events = conn, tz, bedtime, events
        self.study_calendar, self.locks, self.focus = study_calendar, locks, focus
        self.conn.executescript(SCHEMA)

    # -- what a device needs now ------------------------------------------------------------------------------

    async def plan(self, now: datetime | None = None) -> dict:
        now = now or utcnow()
        return {"bedtime": await self._bedtime(now), "events": await self._events(now), "list": self._list(),
                "focus": bool(self.focus and self.focus.current(now))}

    async def _bedtime(self, now: datetime) -> dict | None:
        if self.bedtime is None:
            return None
        try:
            plan = await self.bedtime.tonight(now)
        except Exception:
            log.warning("nudges: no bedtime plan", exc_info=True)
            return None
        if not plan:
            return None
        bed = datetime.fromisoformat(plan["bedtime"]).astimezone(self.tz)
        if now >= bed + LATE_FOR + LATE_EVERY:
            return None
        return {"date": plan["date"], "bedtime": plan["bedtime"], "wake": plan["wake"], "steps": bedtime_steps(bed)}

    async def _events(self, now: datetime) -> list[dict]:
        """Timed events on now or starting in the next day: `study` (the study calendar), `asked` (#focus) or
        `other` (they quiet the bedtime nudges while on)."""
        if self.events is None:
            return []
        try:
            found = await self.events(now - timedelta(hours=12), now + AHEAD)
        except Exception:
            log.warning("nudges: calendar lookup failed", exc_info=True)
            found = None
        out = []
        for e in found or []:
            if e.get("all_day") or not isinstance(e.get("start"), str) or "T" not in e["start"]:
                continue
            start, end = datetime.fromisoformat(e["start"]), datetime.fromisoformat(e["end"])
            if end <= now or end <= start:
                continue
            if e.get("calendar") == self.study_calendar:
                kind = "study"
            elif FOCUS_TAG in f"{e.get('title') or ''} {e.get('notes') or ''}".casefold():
                kind = "asked"
            else:
                kind = "other"
            title = " ".join(re.sub(re.escape(FOCUS_TAG), "", e.get("title") or "", flags=re.I).split()) or "Focus"
            course = self.course_for(title) if kind != "other" else None
            out.append({"id": e.get("id"), "title": title, "start": start.astimezone(self.tz).isoformat(),
                        "end": end.astimezone(self.tz).isoformat(), "kind": kind, "course": course})
        return sorted(out, key=lambda e: e["start"])

    def course_for(self, title: str) -> dict | None:
        """The course an event is about: its name ("Macroeconomics"), a review session of it, or a word of the title
        that starts a word of its name ("Study Macro")."""
        try:
            rows = self.conn.execute("SELECT id, name FROM courses").fetchall()
        except sqlite3.OperationalError:  # no study store yet
            return None
        words = [w for w in _words(title) if len(w) >= 4 and w not in ("study", "review", "lecture", "lezione")]
        text = " ".join(_words(title))
        best = None
        for course_id, name in rows:
            name_words = _words(name)
            if not name_words:
                continue
            if " ".join(name_words) in text:
                return {"id": course_id, "name": name}
            if best is None and any(n.startswith(w) for w in words for n in name_words):
                best = {"id": course_id, "name": name}
        return best

    def _list(self) -> dict | None:
        """The Work app list: off task while a focus event is on."""
        if self.locks is None:
            return None
        return next((l for l in self.locks.lists() if l["name"].strip().casefold() == WORK_LIST), None)

    # -- what happened --------------------------------------------------------------------------------------

    def log(self, body: dict, now: datetime | None = None) -> dict:
        """One nudge shown, or its answer (the same key again): kept once, the answer added when it comes."""
        now = now or utcnow()
        key = str(body.get("key") or "").strip()[:100]
        kind, step, device = body.get("kind"), body.get("step"), body.get("device")
        if not key:
            raise ValueError("key is required")
        if kind not in KINDS:
            raise ValueError(f"kind is one of {sorted(KINDS)}")
        if step not in KINDS[kind]:
            raise ValueError(f"a {kind} nudge's step is one of {sorted(KINDS[kind])}")
        if device not in DEVICES:
            raise ValueError(f"device is one of {sorted(DEVICES)}")
        answer = body.get("answer")
        if answer is not None and answer not in ANSWERS[kind]:
            raise ValueError(f"a {kind} nudge's answer is one of {sorted(ANSWERS[kind])}, or null")
        at = _utc(body.get("at")) or now.isoformat()
        text = lambda name, n=200: (str(body[name]).strip()[:n] or None) if body.get(name) else None  # noqa: E731
        course = body.get("course_id")
        course = int(course) if isinstance(course, int) or (isinstance(course, str) and course.isdigit()) else None
        night = body.get("night") if isinstance(body.get("night"), str) else None
        if night:
            try:
                night = date.fromisoformat(night).isoformat()
            except ValueError:
                night = None
        self.conn.execute(
            "INSERT INTO nudges (key, device, kind, step, at, night, app, event, event_start, event_end, course_id, "
            "answer, answered_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(key) DO UPDATE SET "
            "answer = COALESCE(excluded.answer, nudges.answer), "
            "answered_at = CASE WHEN excluded.answer IS NOT NULL THEN excluded.answered_at ELSE nudges.answered_at END",
            (key, device, kind, step, at, night, text("app"), text("event"), _utc(body.get("event_start")),
             _utc(body.get("event_end")), course, answer, now.isoformat() if answer else None))
        self.conn.execute("DELETE FROM nudges WHERE at < ?", ((now - KEPT).isoformat(),))
        return self.get(key)

    def get(self, key: str) -> dict:
        row = self.conn.execute("SELECT * FROM nudges WHERE key = ?", (key,)).fetchone()
        return self._row(row)

    def _row(self, row) -> dict:
        names = [d[0] for d in self.conn.execute("SELECT * FROM nudges LIMIT 0").description]
        return dict(zip(names, row))

    def since(self, since: datetime, kind: str | None = None) -> list[dict]:
        rows = self.conn.execute("SELECT * FROM nudges WHERE at >= ? AND (? IS NULL OR kind = ?) ORDER BY at",
                                 (since.astimezone(timezone.utc).isoformat(), kind, kind)).fetchall()
        return [self._row(r) for r in rows]

    # -- for the agents -------------------------------------------------------------------------------------

    def _local(self, value: str) -> datetime:
        return datetime.fromisoformat(value).astimezone(self.tz)

    _ANSWER = {"snooze": "snoozed", "going": "said they were going", "back": "went back to it",
               "not_now": "said not now", None: "no answer"}

    def night_line(self, night: str) -> str | None:
        """A night's bedtime nudges: 'Mac 23:00, 23:30 (snoozed), 23:50; phone 23:52; last 0:20.'"""
        rows = self.conn.execute("SELECT * FROM nudges WHERE kind = 'bedtime' AND night = ? ORDER BY at",
                                 (night,)).fetchall()
        rows = [self._row(r) for r in rows]
        if not rows:
            return None
        parts = []
        for device in ("mac", "phone"):
            mine = [r for r in rows if r["device"] == device]
            if mine:
                parts.append(f"{'Mac' if device == 'mac' else 'phone'} " + ", ".join(
                    _clock(self._local(r["at"])) + (f" ({self._ANSWER[r['answer']]})" if r["answer"] else "")
                    + (f" on {r['app']}" if r["app"] and device == "mac" else "") for r in mine))
        return (f"{len(rows)} bedtime nudge{'s' if len(rows) != 1 else ''} while still active: " + "; ".join(parts)
                + f"; the last at {_clock(self._local(rows[-1]['at']))}.")

    def offtask_lines(self, since: datetime, course_id: int | None = None) -> list[str]:
        """Each focus event that had off-task nudges: 'Mon 23 Nov, Study Macro 15:00–17:00: on YouTube at 15:20
        (went back to it); again at 15:41 (no answer).'"""
        rows = [r for r in self.since(since, "offtask") if course_id is None or r["course_id"] == course_id]
        by: dict[tuple, list[dict]] = {}
        for r in rows:
            by.setdefault((r["event"], r["event_start"], r["event_end"]), []).append(r)
        out = []
        for (event, start, end), items in by.items():
            first = items[0]
            when = self._local(start or first["at"])
            span = f" {_clock(when)}–{_clock(self._local(end))}" if start and end else ""
            seen = "; ".join(
                f"{'again ' if r['step'] == 'again' else ''}on {r['app'] or 'something off the list'} at "
                f"{_clock(self._local(r['at']))} on the {r['device']} ({self._ANSWER[r['answer']]})" for r in items)
            out.append(f"{when:%a %d %b}, {event or 'a focus event'}{span}: {seen}.")
        return out

    def evening_lines(self, now: datetime | None = None) -> list[str]:
        """For the evening digest: today's off-task nudges and last night's bedtime ones."""
        now = now or utcnow()
        local = now.astimezone(self.tz)
        midnight = datetime.combine(local.date(), time.min, self.tz)
        out = self.offtask_lines(midnight)
        if line := self.night_line(local.date().isoformat()):
            out.append("Last night: " + line)
        return out

    def study_text(self, now: datetime | None = None, days: int = 7, course_id: int | None = None) -> str | None:
        """For Professor: the last week's off-task nudges during study events."""
        now = now or utcnow()
        lines = self.offtask_lines(now - timedelta(days=days), course_id)
        if not lines:
            return None
        return (f"Off-task nudges during study events, last {days} days (a Work-list app or site in front while the "
                "calendar said study; data, not a verdict):\n" + "\n".join(f"- {l}" for l in lines))

    def week_nights(self, nights: list[str]) -> list[str]:
        """For Coach's sleep_plan: the bedtime nudges of these nights (mornings)."""
        return [f"- {date.fromisoformat(n):%a %d %b}: {line}" for n in nights if (line := self.night_line(n))]
