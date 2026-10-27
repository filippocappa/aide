"""Screen Time locks: the phone's apps shielded on a schedule or for a while. The contract is docs/API.md, "Screen Time".

The server keeps the locks; the phone sets them itself (Apple's DeviceActivity and ManagedSettings), so they start
and end on time with the app closed. A change here sends a sync push and the app picks up the list. What gets
shielded is chosen on the phone: Apple doesn't let it leave there.

A strict lock can't be ended early with a reason, from the app or through Coach: only with an emergency pass, of
which there are PASSES a month. While one is on, the app locks its Screen Time page too.
"""

import json
import sqlite3
from datetime import date, datetime, time, timedelta, timezone
from typing import Callable
from zoneinfo import ZoneInfo

from .agents import AGENTS
from .db import utcnow
from .routines import check_days, check_time, days_text

SHORTEST = timedelta(minutes=15)  # DeviceActivity won't watch a shorter interval
LONGEST = timedelta(hours=24)  # a one-off
AHEAD = timedelta(days=7)  # how far ahead a one-off can start
UNLOCKS_SHOWN = timedelta(days=7)  # unlocks the agents see with the list
PASSES = 3  # emergency passes a month (local calendar month), the only way to end a strict lock early

SCHEMA = """
CREATE TABLE IF NOT EXISTS screen_locks (
    id         INTEGER PRIMARY KEY,
    title      TEXT NOT NULL,
    start_time TEXT,              -- HH:MM local, a schedule's
    end_time   TEXT,              -- HH:MM local; before start_time: the next day
    days       TEXT,              -- JSON ISO weekdays it starts on, [] every day; NULL: a one-off
    starts_at  TEXT,              -- UTC, a one-off's
    ends_at    TEXT,              -- UTC, a one-off's
    enabled    INTEGER NOT NULL DEFAULT 1,
    strict     INTEGER NOT NULL DEFAULT 0, -- ends early only with an emergency pass
    open_until TEXT,              -- UTC: unlocked early, open until the end of that time
    agent      TEXT,              -- who set it; NULL: the user, in the app
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS screen_unlocks (
    id      INTEGER PRIMARY KEY,
    lock_id INTEGER NOT NULL,
    title   TEXT NOT NULL,
    reason  TEXT NOT NULL,
    at      TEXT NOT NULL,        -- UTC
    pass    INTEGER NOT NULL DEFAULT 0 -- an emergency pass was used
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def _title(value: str | None) -> str:
    value = (value or "").strip()
    if not value:
        raise ValueError("a lock needs a title, like Bedtime or Focus")
    return value[:60]


def _minutes(start: str, end: str) -> int:
    """A schedule's length in minutes, overnight when the end is before the start."""
    (sh, sm), (eh, em) = (map(int, start.split(":")), map(int, end.split(":")))
    return (eh * 60 + em - sh * 60 - sm) % (24 * 60)


def _check_length(start: str, end: str) -> None:
    if start == end:
        raise ValueError("the start and the end are the same time")
    if _minutes(start, end) < SHORTEST.total_seconds() / 60:
        raise ValueError("a lock lasts at least 15 minutes (Screen Time won't watch a shorter one)")


class LockStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo):
        self.conn, self.tz = conn, tz
        self.conn.executescript(SCHEMA)
        if "strict" not in {r[1] for r in self.conn.execute("PRAGMA table_info(screen_locks)")}:
            self.conn.execute("ALTER TABLE screen_locks ADD COLUMN strict INTEGER NOT NULL DEFAULT 0")
        if "pass" not in {r[1] for r in self.conn.execute("PRAGMA table_info(screen_unlocks)")}:
            self.conn.execute("ALTER TABLE screen_unlocks ADD COLUMN pass INTEGER NOT NULL DEFAULT 0")
        self.on_change: list[Callable[[], None]] = []  # the sync push, so the phone picks the change up

    def _changed(self) -> None:
        for hook in self.on_change:
            hook()

    def _row(self, row) -> dict:
        lock = dict(row)
        lock["days"] = json.loads(lock["days"]) if lock["days"] is not None else None
        lock["enabled"] = bool(lock["enabled"])
        lock["strict"] = bool(lock["strict"])
        return lock

    # -- the locks -----------------------------------------------------------

    def all(self, now: datetime | None = None) -> list[dict]:
        """Every lock; one-offs that have ended are dropped."""
        now = now or utcnow()
        self.conn.execute("DELETE FROM screen_locks WHERE days IS NULL AND ends_at <= ?", (now.isoformat(),))
        return [self._row(r) for r in self.conn.execute("SELECT * FROM screen_locks ORDER BY id")]

    def get(self, lock_id: int) -> dict:
        row = self.conn.execute("SELECT * FROM screen_locks WHERE id = ?", (lock_id,)).fetchone()
        if row is None:
            raise ValueError(f"no lock {lock_id}")
        return self._row(row)

    def lock_for(self, title: str, minutes: int | None = None, until: datetime | None = None,
                 start: datetime | None = None, agent: str | None = None, strict: bool = False,
                 now: datetime | None = None) -> dict:
        """A one-off: from `start` (default now) for `minutes`, or until `until`."""
        now = (now or utcnow()).replace(microsecond=0)
        start = max(start or now, now)
        if (minutes is None) == (until is None):
            raise ValueError("give the minutes or the end, not both")
        end = start + timedelta(minutes=minutes) if minutes is not None else until
        if end - start < SHORTEST:
            raise ValueError("a lock lasts at least 15 minutes (Screen Time won't watch a shorter one)")
        if end - start > LONGEST:
            raise ValueError("a one-off lasts at most 24 hours; for every night, make a schedule")
        if start - now > AHEAD:
            raise ValueError("a one-off starts within the next 7 days")
        cur = self.conn.execute(
            "INSERT INTO screen_locks (title, starts_at, ends_at, agent, strict, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (_title(title), start.astimezone(timezone.utc).isoformat(), end.astimezone(timezone.utc).isoformat(),
             agent, int(strict), now.isoformat()))
        self._changed()
        return self.get(cur.lastrowid)

    def schedule(self, title: str, start: str, end: str, days: list[int] | None = None, agent: str | None = None,
                 strict: bool = False, now: datetime | None = None) -> dict:
        """Every week: from `start` to `end` (the next morning when it's earlier) on `days` ([] every day)."""
        start, end, days = check_time(start), check_time(end), check_days(days or [])
        _check_length(start, end)
        cur = self.conn.execute(
            "INSERT INTO screen_locks (title, start_time, end_time, days, agent, strict, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (_title(title), start, end, json.dumps(days), agent, int(strict), (now or utcnow()).isoformat()))
        self._changed()
        return self.get(cur.lastrowid)

    def update(self, lock_id: int, now: datetime | None = None, **changes) -> dict:
        """A schedule's title, start, end, days, enabled or strict; a one-off's title or strict. Turning off, moving
        or loosening a lock that's on now is refused: that's unlocking early (`unlock`), which takes a reason. Making
        it strict is fine any time."""
        now = now or utcnow()
        lock = self.get(lock_id)
        changes = {k: v for k, v in changes.items() if v is not None}
        if changes.get("strict") == lock["strict"]:
            del changes["strict"]
        free = {"title"} | ({"strict"} if changes.get("strict") else set())  # a stricter lock is never a way out
        if lock["days"] is None and set(changes) - free:
            raise ValueError("only a one-off's title can change, or it can be made strict; end it and set a new one "
                             "instead")
        if set(changes) - free and self.locked_until(lock, now):
            raise ValueError(f"'{lock['title']}' is on now; it can change once it's over, or be ended early with a "
                             "reason")
        lock.update(changes)
        title = _title(lock["title"])
        if lock["days"] is not None:
            start, end = check_time(lock["start_time"]), check_time(lock["end_time"])
            _check_length(start, end)
            self.conn.execute(
                "UPDATE screen_locks SET title = ?, start_time = ?, end_time = ?, days = ?, enabled = ?, strict = ? "
                "WHERE id = ?",
                (title, start, end, json.dumps(check_days(lock["days"])), int(bool(lock["enabled"])),
                 int(bool(lock["strict"])), lock_id))
        else:
            self.conn.execute("UPDATE screen_locks SET title = ?, strict = ? WHERE id = ?",
                              (title, int(bool(lock["strict"])), lock_id))
        self._changed()
        return self.get(lock_id)

    def delete(self, lock_id: int, now: datetime | None = None) -> None:
        lock = self.get(lock_id)
        if lock["strict"] and self.locked_until(lock, now or utcnow()):
            raise ValueError(f"'{lock['title']}' is strict and on now: it can't be deleted until it's over, only "
                             "ended with an emergency pass in the app")
        self.conn.execute("DELETE FROM screen_locks WHERE id = ?", (lock_id,))
        self._changed()

    def unlock(self, lock_id: int, reason: str, use_pass: bool = False, now: datetime | None = None) -> dict | None:
        """Ends a lock that's on now, early, with the user's reason: a one-off is gone, a schedule opens until this
        time's end and comes back next time. A strict lock takes an emergency pass too (`use_pass`); a pass offered
        for another lock isn't spent. Returns the schedule, or None for a one-off."""
        now = now or utcnow()
        lock = self.get(lock_id)
        reason = (reason or "").strip()
        if not reason:
            raise ValueError("unlocking early needs a reason")
        until = self.locked_until(lock, now)
        if until is None:
            raise ValueError(f"'{lock['title']}' isn't on now")
        if lock["strict"]:
            if not use_pass:
                raise ValueError(f"'{lock['title']}' is strict: only an emergency pass, used in the app, ends it early")
            if self.passes(now)["left"] <= 0:
                raise ValueError(f"no emergency passes left this month ({PASSES} a month); '{lock['title']}' opens "
                                 f"at {self._when(until, now)}")
        self.conn.execute("INSERT INTO screen_unlocks (lock_id, title, reason, at, pass) VALUES (?, ?, ?, ?, ?)",
                          (lock_id, lock["title"], reason[:280], now.isoformat(), int(lock["strict"])))
        if lock["days"] is None:
            self.conn.execute("DELETE FROM screen_locks WHERE id = ?", (lock_id,))
            self._changed()
            return None
        self.conn.execute("UPDATE screen_locks SET open_until = ? WHERE id = ?", (until.isoformat(), lock_id))
        self._changed()
        return self.get(lock_id)

    def unlocks(self, since: datetime) -> list[dict]:
        rows = self.conn.execute("SELECT * FROM screen_unlocks WHERE at >= ? ORDER BY id", (since.isoformat(),))
        return [{**dict(r), "pass": bool(r["pass"])} for r in rows]

    def passes(self, now: datetime | None = None) -> dict:
        """This month's emergency passes: how many are left, and the ones used (title, reason, when)."""
        now = now or utcnow()
        local = now.astimezone(self.tz)
        month = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        following = (month + timedelta(days=32)).replace(day=1)
        used = [u for u in self.unlocks(month.astimezone(timezone.utc)) if u["pass"]]
        return {"left": max(PASSES - len(used), 0), "month": PASSES,
                "renews": following.date().isoformat(),
                "used": [{"title": u["title"], "reason": u["reason"],
                          "at": self._local(datetime.fromisoformat(u["at"]))} for u in used]}

    # -- when ----------------------------------------------------------------

    def _times(self, lock: dict, day: date) -> tuple[datetime, datetime]:
        start = datetime.combine(day, time.fromisoformat(lock["start_time"]), self.tz)
        return start, start + timedelta(minutes=_minutes(lock["start_time"], lock["end_time"]))

    def window(self, lock: dict, now: datetime) -> tuple[datetime, datetime] | None:
        """The time the lock covers now (UTC), whether or not it's on or was unlocked early; None outside it."""
        if lock["days"] is None:
            start, end = datetime.fromisoformat(lock["starts_at"]), datetime.fromisoformat(lock["ends_at"])
            return (start, end) if start <= now < end else None
        today = now.astimezone(self.tz).date()
        for day in (today - timedelta(days=1), today):
            if lock["days"] and day.isoweekday() not in lock["days"]:
                continue
            start, end = self._times(lock, day)
            if start <= now < end:
                return start.astimezone(timezone.utc), end.astimezone(timezone.utc)
        return None

    def locked_until(self, lock: dict, now: datetime) -> datetime | None:
        """When the lock opens, if it's on now (UTC)."""
        if not lock["enabled"] or (window := self.window(lock, now)) is None:
            return None
        if lock["open_until"] and datetime.fromisoformat(lock["open_until"]) >= window[1]:
            return None  # unlocked early this time
        return window[1]

    def next_start(self, lock: dict, now: datetime) -> datetime | None:
        """The next time it starts, after now (UTC); None for a one-off that has started or a schedule that's off."""
        if lock["days"] is None:
            start = datetime.fromisoformat(lock["starts_at"])
            return start if start > now else None
        if not lock["enabled"]:
            return None
        today = now.astimezone(self.tz).date()
        for n in range(8):
            day = today + timedelta(days=n)
            if lock["days"] and day.isoweekday() not in lock["days"]:
                continue
            start, _ = self._times(lock, day)
            if start > now:
                return start.astimezone(timezone.utc)
        return None

    # -- the phone -----------------------------------------------------------

    def device(self) -> dict:
        """What the phone last said: whether Aide may use Screen Time, and how many apps stay open in a lock."""
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'screen_time'").fetchone()
        return json.loads(row["value"]) if row else {"authorized": False, "allowed_apps": 0, "at": None}

    def set_device(self, authorized: bool, allowed_apps: int, now: datetime | None = None) -> dict:
        value = {"authorized": authorized, "allowed_apps": allowed_apps, "at": (now or utcnow()).isoformat()}
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('screen_time', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps(value),))
        return value

    # -- shapes --------------------------------------------------------------

    def _local(self, dt: datetime | None) -> str | None:
        return dt.astimezone(self.tz).replace(microsecond=0).isoformat() if dt else None

    def _when(self, dt: datetime, now: datetime) -> str:
        local, today = dt.astimezone(self.tz), now.astimezone(self.tz).date()
        if local.date() == today:
            return f"{local:%H:%M}"
        if local.date() == today + timedelta(days=1):
            return f"{local:%H:%M} tomorrow"
        return f"{local:%a %d %b %H:%M}"

    def summary(self, lock: dict, now: datetime) -> str:
        """'Every day 22:30–07:00', or 'From 15:10 to 16:10'."""
        if lock["days"] is not None:
            days = days_text(lock["days"])
            return f"{days[:1].upper()}{days[1:]} {lock['start_time']}–{lock['end_time']}"
        start, end = datetime.fromisoformat(lock["starts_at"]), datetime.fromisoformat(lock["ends_at"])
        return f"From {self._when(start, now)} to {self._when(end, now)}"

    def as_json(self, lock: dict, now: datetime | None = None) -> dict:
        now = now or utcnow()
        until = self.locked_until(lock, now)
        window = self.window(lock, now)
        opened = window is not None and until is None and lock["enabled"]
        return {"id": lock["id"], "title": lock["title"], "once": lock["days"] is None,
                "start": lock["start_time"], "end": lock["end_time"], "days": lock["days"],
                "starts_at": self._local(datetime.fromisoformat(lock["starts_at"])) if lock["starts_at"] else None,
                "ends_at": self._local(datetime.fromisoformat(lock["ends_at"])) if lock["ends_at"] else None,
                "enabled": lock["enabled"], "strict": lock["strict"], "agent": lock["agent"],
                "locked": until is not None, "until": self._local(until),
                "open_until": self._local(window[1]) if opened else None,
                "next": self._local(self.next_start(lock, now)), "summary": self.summary(lock, now)}

    def line(self, lock: dict, now: datetime) -> str:
        """'[3] Bedtime · every day 22:30–07:00 · on now, until 07:00 · set by Coach', for the agents."""
        text = f"[{lock['id']}] {lock['title']} · {self.summary(lock, now)}" + (" · strict" if lock["strict"] else "")
        if until := self.locked_until(lock, now):
            text += f" · on now, until {self._when(until, now)}"
        elif not lock["enabled"]:
            text += " · off"
        elif self.window(lock, now):
            text += " · unlocked early this time"
        elif start := self.next_start(lock, now):
            text += f" · next {self._when(start, now)}"
        who = AGENTS[lock["agent"]].name if lock["agent"] in AGENTS else "the user"
        return text + f" · set by {who}"
