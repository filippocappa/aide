"""Habits: things to do every day, or a number of times a week, with a streak. Contract in docs/API.md.

A check is one done day. The streak counts consecutive scheduled periods (days, or Monday-to-Sunday
weeks with enough checks) back from now. Today, or this week, counts once it's done, and doesn't
break the streak while it's still in progress.
"""

import sqlite3
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from .db import utcnow

SCHEMA = """
CREATE TABLE IF NOT EXISTS habits (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    per_week   INTEGER,  -- NULL: daily; otherwise times per Monday-to-Sunday week
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS habit_checks (
    habit_id INTEGER NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    day      TEXT NOT NULL,  -- local date, YYYY-MM-DD
    PRIMARY KEY (habit_id, day)
);
"""

MAX_NAME = 100


@dataclass(frozen=True)
class Habit:
    id: int
    name: str
    per_week: int | None
    streak: int
    done_today: bool
    last_done: date | None
    this_week: int  # checks since Monday, for weekly habits

    @property
    def cadence(self) -> dict:
        return {"type": "daily"} if self.per_week is None else {"type": "weekly", "per_week": self.per_week}

    def as_json(self) -> dict:
        return {"id": self.id, "name": self.name, "cadence": self.cadence, "streak": self.streak,
                "done_today": self.done_today, "last_done": self.last_done.isoformat() if self.last_done else None}


def monday(d: date) -> date:
    return d - timedelta(days=d.weekday())


def streak(days: set[date], per_week: int | None, today: date) -> int:
    if per_week is None:
        d = today if today in days else today - timedelta(days=1)
        count = 0
        while d in days:
            count, d = count + 1, d - timedelta(days=1)
        return count
    weeks: dict[date, int] = {}
    for d in days:
        weeks[monday(d)] = weeks.get(monday(d), 0) + 1
    w = monday(today)
    if weeks.get(w, 0) < per_week:
        w -= timedelta(weeks=1)
    count = 0
    while weeks.get(w, 0) >= per_week:
        count, w = count + 1, w - timedelta(weeks=1)
    return count


class HabitStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo):
        self.conn = conn
        self.tz = tz
        self.conn.executescript(SCHEMA)

    def today(self) -> date:
        return datetime.now(self.tz).date()

    def _habit(self, row) -> Habit:
        days = {date.fromisoformat(r["day"]) for r in
                self.conn.execute("SELECT day FROM habit_checks WHERE habit_id = ?", (row["id"],))}
        today = self.today()
        return Habit(
            id=row["id"], name=row["name"], per_week=row["per_week"],
            streak=streak(days, row["per_week"], today), done_today=today in days,
            last_done=max((d for d in days if d <= today), default=None),
            this_week=sum(1 for d in days if monday(today) <= d <= today),
        )

    def get(self, habit_id: int) -> Habit | None:
        row = self.conn.execute("SELECT * FROM habits WHERE id = ?", (habit_id,)).fetchone()
        return self._habit(row) if row else None

    def find(self, habit_id: int) -> Habit:
        habit = self.get(habit_id)
        if habit is None:
            raise KeyError(f"no habit with id {habit_id}")
        return habit

    def all(self) -> list[Habit]:
        return [self._habit(r) for r in self.conn.execute("SELECT * FROM habits ORDER BY id")]

    def add(self, name: str, per_week: int | None = None) -> Habit:
        name = " ".join(name.split())
        if not name:
            raise ValueError("the habit needs a name")
        if len(name) > MAX_NAME:
            raise ValueError(f"keep the name under {MAX_NAME} characters")
        if per_week is not None and not 1 <= per_week <= 7:
            raise ValueError("per_week must be between 1 and 7")
        if self.conn.execute("SELECT 1 FROM habits WHERE lower(name) = lower(?)", (name,)).fetchone():
            raise ValueError(f"there is already a habit called {name!r}")
        cur = self.conn.execute("INSERT INTO habits (name, per_week, created_at) VALUES (?, ?, ?)",
                                (name, per_week, utcnow().isoformat()))
        return self.find(cur.lastrowid)

    def check(self, habit_id: int, day: date | None = None, done: bool = True) -> Habit:
        self.find(habit_id)
        day = day or self.today()
        if day > self.today():
            raise ValueError("can't check a habit for a day that hasn't come yet")
        if done:
            self.conn.execute("INSERT OR IGNORE INTO habit_checks (habit_id, day) VALUES (?, ?)",
                              (habit_id, day.isoformat()))
        else:
            self.conn.execute("DELETE FROM habit_checks WHERE habit_id = ? AND day = ?", (habit_id, day.isoformat()))
        return self.find(habit_id)

    def delete(self, habit_id: int) -> bool:
        return self.conn.execute("DELETE FROM habits WHERE id = ?", (habit_id,)).rowcount > 0
