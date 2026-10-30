"""Review sessions on the calendar (#4). The contract is docs/API.md, "Quizzes and review sessions".

Professor plans them with the user in the course chat (when, how long, which topics: the weakest first, working back
from the exam) and puts each in the study calendar as "Review: Macroeconomics", with the topics in its notes, once
the user agrees. Creating an event runs at once, as it does for Secretary; cancelling one is queued in the chat, or
the user's own tap in the app.

When a session starts, Professor says so in the course chat, with a push, and offers to quiz the user on its topics.
The calendar is the truth: a session moved there is followed, and one deleted there is dropped.
"""

import asyncio
import json
import logging
import re
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .db import utcnow
from .icloud import CalendarBackend
from .study import REVIEW_PREFIX, StudyStore

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS review_sessions (
    id           INTEGER PRIMARY KEY,
    public_id    TEXT NOT NULL UNIQUE,  -- v_…
    course_id    INTEGER NOT NULL,
    event_uid    TEXT NOT NULL,         -- its calendar event
    starts_at    TEXT NOT NULL,         -- UTC, as last seen in the calendar
    minutes      INTEGER NOT NULL,
    topics       TEXT NOT NULL,         -- JSON: the topics' titles
    created_at   TEXT NOT NULL,
    announced_at TEXT,                  -- when Professor said it's time
    cancelled_at TEXT
);
CREATE INDEX IF NOT EXISTS review_sessions_start ON review_sessions (starts_at);
"""

TICK = 60  # seconds
STALE = timedelta(minutes=30)  # a start missed by more than this (the server was off) isn't announced
SHORTEST, LONGEST = 15, 240  # minutes
_ID = re.compile(r"^v_[0-9a-f]{12}$")


class ReviewStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, cal: CalendarBackend | None, study: StudyStore):
        self.conn, self.tz, self.cal, self.study = conn, tz, cal, study
        self.conn.executescript(SCHEMA)

    async def add(self, course_id: int, start: datetime, minutes: int, topics: list[str]) -> dict:
        """A session in the study calendar, from `start` (local or aware) for `minutes`, on the topics named."""
        if self.cal is None:
            raise RuntimeError("There's no calendar on this server.")
        course = self.study.course(course_id)
        if course is None:
            raise KeyError(f"no course {course_id}")
        if not SHORTEST <= minutes <= LONGEST:
            raise ValueError(f"a session is {SHORTEST} to {LONGEST} minutes")
        start = start.replace(tzinfo=self.tz) if start.tzinfo is None else start.astimezone(self.tz)
        if start < datetime.now(self.tz) - timedelta(minutes=5):
            raise ValueError("that time has passed")
        name = course["name"][:1].upper() + course["name"][1:]
        notes = "Review with Professor in Aide." + ("\nTopics: " + "; ".join(topics) if topics else "")
        ev = await asyncio.to_thread(self.cal.create, self.study.study_calendar, REVIEW_PREFIX + name, start,
                                     start + timedelta(minutes=minutes), "", notes)
        public_id = "v_" + secrets.token_hex(6)
        self.conn.execute(
            "INSERT INTO review_sessions (public_id, course_id, event_uid, starts_at, minutes, topics, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)", (public_id, course_id, ev.uid, start.astimezone(timezone.utc).isoformat(),
                                             minutes, json.dumps(topics), utcnow().isoformat()))
        return self.get(public_id)

    def get(self, public_id: str) -> dict | None:
        if not _ID.match(public_id or ""):
            return None
        row = self.conn.execute("SELECT * FROM review_sessions WHERE public_id = ?", (public_id,)).fetchone()
        return self._row(row) if row else None

    def find(self, public_id: str) -> dict:
        if (s := self.get(public_id)) is None or s["cancelled_at"]:
            raise KeyError(f"no review session {public_id}")
        return s

    def upcoming(self, course_id: int | None = None, now: datetime | None = None) -> list[dict]:
        """Sessions not yet over, soonest first."""
        now = now or utcnow()
        rows = self.conn.execute(
            "SELECT * FROM review_sessions WHERE cancelled_at IS NULL AND (? IS NULL OR course_id = ?) "
            "ORDER BY starts_at", (course_id, course_id)).fetchall()
        return [s for s in map(self._row, rows) if s["ends"] > now]

    async def cancel(self, public_id: str) -> dict:
        """Takes the session off the calendar."""
        s = self.find(public_id)
        if self.cal is not None:
            try:
                await asyncio.to_thread(self.cal.delete, s["event_uid"])
            except Exception:  # already gone from the calendar
                log.info("review session %s: its event was already gone", public_id)
        self.conn.execute("UPDATE review_sessions SET cancelled_at = ? WHERE id = ?", (utcnow().isoformat(), s["id"]))
        return s

    async def due(self, now: datetime | None = None) -> list[dict]:
        """Sessions starting now that weren't announced, checked against the calendar first: a moved one follows
        its event (and waits if it's later now), a deleted one is dropped."""
        now = now or utcnow()
        out = []
        rows = self.conn.execute(
            "SELECT * FROM review_sessions WHERE cancelled_at IS NULL AND announced_at IS NULL AND starts_at <= ?",
            ((now + timedelta(minutes=1)).isoformat(),)).fetchall()
        for s in map(self._row, rows):
            ev = await asyncio.to_thread(self.cal.get, s["event_uid"]) if self.cal is not None else None
            if self.cal is not None and ev is None:
                self.conn.execute("UPDATE review_sessions SET cancelled_at = ? WHERE id = ?", (now.isoformat(), s["id"]))
                continue
            if ev is not None and isinstance(ev.start, datetime):
                start = (ev.start if ev.start.tzinfo else ev.start.replace(tzinfo=self.tz)).astimezone(timezone.utc)
                minutes = max(SHORTEST, round((ev.end - ev.start).total_seconds() / 60))
                if start != s["start"] or minutes != s["minutes"]:
                    self.conn.execute("UPDATE review_sessions SET starts_at = ?, minutes = ? WHERE id = ?",
                                      (start.isoformat(), minutes, s["id"]))
                    s = self.get(s["public_id"])
                if s["start"] > now + timedelta(minutes=1):
                    continue
            self.conn.execute("UPDATE review_sessions SET announced_at = ? WHERE id = ?", (now.isoformat(), s["id"]))
            if now - s["start"] <= STALE:
                out.append(s)
        return out

    def _row(self, row) -> dict:
        s = dict(row)
        s["topics"] = json.loads(s["topics"])
        s["start"] = datetime.fromisoformat(s["starts_at"])
        s["ends"] = s["start"] + timedelta(minutes=s["minutes"])
        return s

    def line(self, s: dict) -> str:
        start = s["start"].astimezone(self.tz)
        course = (self.study.course(s["course_id"]) or {}).get("name", "?")
        return (f"[{s['public_id']}] {start:%a %d %b %H:%M}, {s['minutes']} min · {course}" +
                (f" · {'; '.join(s['topics'])}" if s["topics"] else ""))

    def as_json(self, s: dict) -> dict:
        return {"id": s["public_id"], "course": s["course_id"],
                "start": s["start"].astimezone(self.tz).isoformat(), "minutes": s["minutes"], "topics": s["topics"]}


class ReviewWatcher:
    """Says it's time in the course chat when a session starts, with a push."""

    def __init__(self, store: ReviewStore, agent, push=None):
        self.store, self.agent, self.push = store, agent, push

    async def run(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:
                log.exception("review sessions tick failed")
            await asyncio.sleep(TICK)

    async def tick(self, now: datetime | None = None) -> None:
        for s in await self.store.due(now):
            course = self.store.study.course(s["course_id"])
            if course is None:
                continue
            name = course["name"][:1].upper() + course["name"][1:]
            topics = ", ".join(s["topics"])
            alert = (f"Time for your {name} review ({s['minutes']} min)" + (f": {topics}." if topics else ".") +
                     " Shall I quiz you?")
            text = f"Time for your {name} review. Shall I quiz you" + (" on these?" if topics else "?")
            note = (f"[Review session {s['public_id']} starts now: {name}, {s['minutes']} min" +
                    (f", topics {topics}" if topics else "") + ". When the user wants the quiz, quiz_me on these "
                    "topics.]")
            chat = self.store.study.chat(s["course_id"])
            card = {"type": "review", "review": self.store.as_json(s) | {"name": name}}
            await self.agent.post(chat, note, text, [card])
            if self.push is not None:
                try:
                    await self.push.send_message(chat, f"Professor · {name}", alert[:180])
                except Exception:
                    log.exception("couldn't push a review session")
