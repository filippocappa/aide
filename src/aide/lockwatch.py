"""The Screen Time lock's Live Activity (docs/API.md, "Live Activities", `lock`): when a lock comes on (a schedule's
start, Lock now, Coach's one-off), the server push-starts a countdown to when it opens ("Bedtime · locked until
07:00"), with a bar filling up to the end; keeps it right when the lock's end moves, and ends it when the lock opens,
is unlocked early, switched off or deleted.

Locks start while the app is closed, so it's the server that starts them, like the event countdowns
(upcoming.EventWatcher). A change to the locks (`LockStore.on_change`) is looked at at once, so Lock now shows in
seconds, not at the next tick. Off with the `locks` setting (`/v1/live/settings`).
"""

import asyncio
import logging
import sqlite3
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .db import utcnow
from .live import LiveActivities, unix
from .locks import LockStore

log = logging.getLogger(__name__)

TICK = 60  # seconds between checks
SHOWN = timedelta(minutes=2)  # a lock that ran its course stays up this long, saying it's open
LEAST = timedelta(minutes=2)  # a lock with less than this left gets no countdown

SCHEMA = """
CREATE TABLE IF NOT EXISTS lock_activities (
    lock    INTEGER NOT NULL,  -- the lock's id
    starts  TEXT NOT NULL,     -- the window's start, UTC
    key     TEXT NOT NULL,     -- the activity's key
    state   TEXT NOT NULL,     -- on, or ended
    until   TEXT NOT NULL,     -- the end last sent, UTC
    at      TEXT NOT NULL,     -- UTC
    PRIMARY KEY (lock, starts)
);
"""


def key_for(lock_id: int, start: datetime) -> str:
    return f"lock:{lock_id}:{unix(start)}"


class LockWatcher:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, locks: LockStore, live: LiveActivities):
        self.conn, self.tz, self.locks, self.live = conn, tz, locks, live
        self.conn.executescript(SCHEMA)
        self._loop: asyncio.AbstractEventLoop | None = None
        self._poked: asyncio.Event | None = None

    def poke(self) -> None:
        """The locks changed: look now (from any thread; the API's handlers can run in a worker thread)."""
        if self._loop and self._poked:
            self._loop.call_soon_threadsafe(self._poked.set)

    async def run(self) -> None:
        self._loop, self._poked = asyncio.get_running_loop(), asyncio.Event()
        while True:
            try:
                await asyncio.wait_for(self._poked.wait(), TICK)
            except asyncio.TimeoutError:
                pass
            self._poked.clear()
            if not self.live.enabled:
                continue
            try:
                await self.tick(utcnow())
            except Exception:
                log.exception("lock activity tick failed")

    async def tick(self, now: datetime) -> None:
        locks = {lock["id"]: lock for lock in self.locks.all(now)}
        for row in [dict(r) for r in self.conn.execute("SELECT * FROM lock_activities WHERE state = 'on'")]:
            lock = locks.get(row["lock"])
            until = self.locks.locked_until(lock, now) if lock else None
            starts = datetime.fromisoformat(row["starts"])
            window = self.locks.window(lock, now) if lock else None
            if until is None or window is None or window[0] != starts:
                # Over: it ran its course (shown a moment longer), or was unlocked, switched off or deleted.
                done = datetime.fromisoformat(row["until"]) <= now
                await self._end(row, lock, now, now + SHOWN if done else now)
            elif until.isoformat() != row["until"]:
                await self._update(row, lock, until)
        if not self.live.settings()["locks"]:
            return
        began = {(r["lock"], r["starts"]) for r in self.conn.execute("SELECT lock, starts FROM lock_activities")}
        for lock in locks.values():
            until = self.locks.locked_until(lock, now)
            if until is None or until - now < LEAST:
                continue
            start = self.locks.window(lock, now)[0]
            if (lock["id"], start.isoformat()) not in began:
                await self._start(lock, start, until, now)
        self.conn.execute("DELETE FROM lock_activities WHERE state = 'ended' AND at < ?",
                          ((now - timedelta(days=2)).isoformat(),))

    def _state(self, lock: dict | None, start: datetime, until: datetime, over: bool = False) -> dict:
        return {"until": unix(until), "since": unix(start), "strict": bool(lock and lock["strict"]), "over": over}

    async def _start(self, lock: dict, start: datetime, until: datetime, now: datetime) -> None:
        key = key_for(lock["id"], start)
        local = until.astimezone(self.tz)
        when = f"{local:%H:%M}" if until - now < timedelta(hours=20) else f"{local:%a %H:%M}"  # bedtime: just 07:00
        body = f"Locked until {when}" + (", strict" if lock["strict"] else "")
        ok = await self.live.start("lock", {"key": key, "title": lock["title"]}, self._state(lock, start, until),
                                   {"title": lock["title"], "body": body}, stale=until)
        # Marked either way, so a start that didn't go out (no token) isn't tried every minute.
        self.conn.execute("INSERT OR REPLACE INTO lock_activities (lock, starts, key, state, until, at) "
                          "VALUES (?, ?, ?, ?, ?, ?)", (lock["id"], start.isoformat(), key, "on" if ok else "ended",
                                                        until.isoformat(), now.isoformat()))
        if ok:
            log.info("lock activity for %r started", lock["title"])

    async def _update(self, row: dict, lock: dict, until: datetime) -> None:
        await self.live.update(row["key"], self._state(lock, datetime.fromisoformat(row["starts"]), until), stale=until)
        self.conn.execute("UPDATE lock_activities SET until = ? WHERE lock = ? AND starts = ?",
                          (until.isoformat(), row["lock"], row["starts"]))

    async def _end(self, row: dict, lock: dict | None, now: datetime, dismiss: datetime) -> None:
        state = self._state(lock, datetime.fromisoformat(row["starts"]), min(datetime.fromisoformat(row["until"]), now),
                            over=True)
        await self.live.end(row["key"], state, dismiss)
        self.conn.execute("UPDATE lock_activities SET state = 'ended', at = ? WHERE lock = ? AND starts = ?",
                          (now.isoformat(), row["lock"], row["starts"]))
