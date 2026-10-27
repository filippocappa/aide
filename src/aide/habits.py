"""Habits: things to do every day, or a number of times a week, with a streak. Contract in docs/API.md.

A check is one done day. The streak counts consecutive scheduled periods (days, or Monday-to-Sunday
weeks with enough checks) back from now. Today, or this week, counts once it's done, and doesn't
break the streak while it's still in progress.

A food habit is also done on the days the food log meets its metric (worked out on every read). A limit habit
is a daily count that has to stay at or under its max: a day is done once it has ended within the limit, from the
day it became a limit habit; nothing logged is 0. A limit habit can also count from Apple Health (`health`, e.g.
inhaler_usage, the field of the health day the app uploads): a day's count is then the larger of Health's number and
what was logged here, so one logged in both places counts once. What's logged here is also written to Health by the
phone (`health_logged`: each day's net count logged through Aide, which the phone's own Health samples follow).
"""

import json
import sqlite3
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from .db import utcnow
from .food import FOOD_METRICS
from .health import WORKOUT_TYPES

SCHEMA = """
CREATE TABLE IF NOT EXISTS habits (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    per_week   INTEGER,  -- NULL: daily; otherwise times per Monday-to-Sunday week
    created_at TEXT NOT NULL,
    workouts   TEXT NOT NULL DEFAULT '[]', -- JSON list of Apple Health workout types that check it ("any": all)
    max_count  INTEGER,  -- a limit habit: the most a day may count; NULL otherwise
    since      TEXT,     -- a limit habit: the local date it became one (days before don't count)
    food       TEXT,     -- logged, protein_g or calories: done on the days the food log meets it
    health     TEXT      -- a limit habit: the health day's field it also counts from (inhaler_usage)
);
CREATE TABLE IF NOT EXISTS habit_checks (
    habit_id INTEGER NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    day      TEXT NOT NULL,  -- local date, YYYY-MM-DD
    PRIMARY KEY (habit_id, day)
);
-- A limit habit's count per local day (no row: 0).
CREATE TABLE IF NOT EXISTS habit_counts (
    habit_id INTEGER NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    day      TEXT NOT NULL,
    count    INTEGER NOT NULL,
    logged   INTEGER NOT NULL DEFAULT 0, -- of it, logged through Aide (net): the phone writes these to Health
    PRIMARY KEY (habit_id, day)
);
-- Workouts that already checked a habit, so undoing the check isn't redone by the next upload.
CREATE TABLE IF NOT EXISTS habit_workouts (
    habit_id   INTEGER NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    workout_id TEXT NOT NULL,
    PRIMARY KEY (habit_id, workout_id)
);
"""

MAX_NAME = 100
HISTORY_DAYS = 182  # 26 weeks, for the app's grid
MIN_WORKOUT = 10  # minutes a workout must last to check a habit
MAX_LIMIT = 100
HEALTH_COUNTS = ("inhaler_usage",)  # health day fields a limit habit can count from
HEALTH_WRITE_DAYS = 7  # the days the phone keeps Health's samples in line with what was logged here


@dataclass(frozen=True)
class Habit:
    id: int
    name: str
    per_week: int | None
    streak: int
    done_today: bool
    last_done: date | None
    this_week: int  # checks since Monday, for weekly habits
    history: tuple[date, ...] = ()  # checked days in the last HISTORY_DAYS, newest first
    workouts: tuple[str, ...] = ()  # workout types that check it
    max_count: int | None = None  # a limit habit: the most a day may count
    food: str | None = None  # the food log metric that ticks it
    count: int | None = None  # a limit habit: today's count
    counts: tuple[tuple[date, int], ...] = ()  # a limit habit: days over 0 in the last HISTORY_DAYS, newest first
    health: str | None = None  # a limit habit: the Apple Health count it follows
    health_logged: tuple[tuple[date, int], ...] = ()  # with health: logged here in the last HEALTH_WRITE_DAYS

    @property
    def cadence(self) -> dict:
        if self.max_count is not None:
            return {"type": "limit", "max": self.max_count}
        return {"type": "daily"} if self.per_week is None else {"type": "weekly", "per_week": self.per_week}

    def as_json(self) -> dict:
        return {"id": self.id, "name": self.name, "cadence": self.cadence, "streak": self.streak,
                "done_today": self.done_today, "last_done": self.last_done.isoformat() if self.last_done else None,
                "history": [d.isoformat() for d in self.history], "workouts": list(self.workouts),
                "food": self.food, "count": self.count, "counts": {d.isoformat(): n for d, n in self.counts},
                "health": self.health,
                **({"health_logged": {d.isoformat(): n for d, n in self.health_logged}} if self.health else {})}


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
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, food=None, health=None):
        self.conn = conn
        self.tz = tz
        self.food = food  # food.FoodStore: food habits tick from it; without it they're ticked by hand only
        self.health_days = health  # health.HealthStore: limit habits with `health` count from it
        self.on_health_count: list = []  # called when a habit with `health` is counted (the phone writes it to Health)
        if self.conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'habits'").fetchone():
            have = {c["name"] for c in self.conn.execute("PRAGMA table_info(habits)")}
            for column, kind in (("workouts", "TEXT NOT NULL DEFAULT '[]'"), ("max_count", "INTEGER"),
                                 ("since", "TEXT"), ("food", "TEXT"), ("health", "TEXT")):
                if column not in have:
                    self.conn.execute(f"ALTER TABLE habits ADD COLUMN {column} {kind}")
        self.conn.executescript(SCHEMA)
        if "logged" not in {c["name"] for c in self.conn.execute("PRAGMA table_info(habit_counts)")}:
            self.conn.execute("ALTER TABLE habit_counts ADD COLUMN logged INTEGER NOT NULL DEFAULT 0")

    def today(self) -> date:
        return datetime.now(self.tz).date()

    def _counts(self, row, first: date, last: date) -> dict[date, int]:
        """A limit habit's days over 0 in first..last: what was logged here, or Health's number when larger."""
        counts = {date.fromisoformat(r["day"]): r["count"] for r in self.conn.execute(
            "SELECT day, count FROM habit_counts WHERE habit_id = ? AND day >= ? AND day <= ? AND count > 0",
            (row["id"], first.isoformat(), last.isoformat()))}
        if row["health"] and self.health_days:
            for d in self.health_days.between(first, last):
                n = d.get(row["health"])
                if isinstance(n, (int, float)) and n > 0:
                    day = date.fromisoformat(d["date"])
                    counts[day] = max(counts.get(day, 0), int(n))
        return counts

    def _first_day(self, row) -> date | None:
        """The earliest day the habit can have been done, or None if it never was."""
        if row["max_count"] is not None:
            return date.fromisoformat(row["since"])
        found = self.conn.execute("SELECT MIN(day) FROM habit_checks WHERE habit_id = ?", (row["id"],)).fetchone()[0]
        days = [date.fromisoformat(found)] if found else []
        if row["food"] and self.food:
            first_meal = self.food.first_day()
            days += [first_meal] if first_meal else []
        return min(days, default=None)

    def _done(self, row, first: date, last: date) -> set[date]:
        """The days first..last (both included) the habit was done."""
        today = self.today()
        if row["max_count"] is not None:  # a day is done once it's over, within the limit
            first, last = max(first, date.fromisoformat(row["since"])), min(last, today - timedelta(days=1))
            counts = self._counts(row, first, last)
            return {first + timedelta(days=i) for i in range((last - first).days + 1)
                    if counts.get(first + timedelta(days=i), 0) <= row["max_count"]}
        days = {date.fromisoformat(r["day"]) for r in self.conn.execute(
            "SELECT day FROM habit_checks WHERE habit_id = ? AND day >= ? AND day <= ?",
            (row["id"], first.isoformat(), last.isoformat()))}
        if row["food"] and self.food and first <= min(last, today):
            days |= self.food.met_days(row["food"], first, min(last, today))
        return days

    def done_days(self, habit_id: int, first: date, last: date) -> set[date]:
        """The days first..last (both included) the habit was done: checked, met from the food log, or (a limit
        habit) ended within the limit. Empty for an unknown habit."""
        row = self.conn.execute("SELECT * FROM habits WHERE id = ?", (habit_id,)).fetchone()
        return self._done(row, first, last) if row else set()

    def _habit(self, row) -> Habit:
        today = self.today()
        start = self._first_day(row)
        days = self._done(row, start, today) if start else set()
        window = today - timedelta(days=HISTORY_DAYS)
        history = tuple(sorted((d for d in days if window < d <= today), reverse=True))
        count, counts = None, ()
        if row["max_count"] is not None:
            found = self._counts(row, window + timedelta(days=1), today)
            count = found.get(today, 0)
            counts = tuple(sorted(found.items(), reverse=True))
            within = count <= row["max_count"]
            run, d = 0, today - timedelta(days=1)
            while within and d in days:
                run, d = run + 1, d - timedelta(days=1)
            logged = tuple(self.conn.execute(
                "SELECT day, logged FROM habit_counts WHERE habit_id = ? AND day > ? AND logged > 0 ORDER BY day DESC",
                (row["id"], (today - timedelta(days=HEALTH_WRITE_DAYS)).isoformat())).fetchall()) if row["health"] else ()
            return Habit(id=row["id"], name=row["name"], per_week=None, streak=run, done_today=within,
                         last_done=max(days, default=None), this_week=0, history=history,
                         workouts=tuple(json.loads(row["workouts"])), max_count=row["max_count"], count=count,
                         counts=counts, health=row["health"],
                         health_logged=tuple((date.fromisoformat(d), n) for d, n in logged))
        return Habit(
            id=row["id"], name=row["name"], per_week=row["per_week"],
            streak=streak(days, row["per_week"], today), done_today=today in days,
            last_done=max((d for d in days if d <= today), default=None),
            this_week=sum(1 for d in days if monday(today) <= d <= today),
            history=history, workouts=tuple(json.loads(row["workouts"])), food=row["food"],
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

    def _name(self, name: str, habit_id: int | None = None) -> str:
        name = " ".join(name.split())
        if not name:
            raise ValueError("the habit needs a name")
        if len(name) > MAX_NAME:
            raise ValueError(f"keep the name under {MAX_NAME} characters")
        if self.conn.execute("SELECT 1 FROM habits WHERE lower(name) = lower(?) AND id IS NOT ?",
                             (name, habit_id)).fetchone():
            raise ValueError(f"there is already a habit called {name!r}")
        return name

    @staticmethod
    def _per_week(per_week: int | None) -> int | None:
        if per_week is not None and not 1 <= per_week <= 7:
            raise ValueError("per_week must be between 1 and 7")
        return per_week

    @staticmethod
    def _max(max_count: int | None) -> int | None:
        if max_count is not None and not (isinstance(max_count, int) and 1 <= max_count <= MAX_LIMIT):
            raise ValueError(f"a limit must be between 1 and {MAX_LIMIT} a day")
        return max_count

    @staticmethod
    def _food(food: str | None) -> str | None:
        if food is not None and food not in FOOD_METRICS:
            raise ValueError(f"food must be one of {', '.join(FOOD_METRICS)}, or null")
        return food

    @staticmethod
    def _health(health: str | None) -> str | None:
        if health is not None and health not in HEALTH_COUNTS:
            raise ValueError(f"health must be one of {', '.join(HEALTH_COUNTS)}, or null")
        return health

    @staticmethod
    def _workouts(workouts: list[str] | None) -> str:
        if not isinstance(workouts, list) or not all(isinstance(w, str) and w.strip() for w in workouts):
            raise ValueError("workouts must be a list of workout types")
        return json.dumps(list(dict.fromkeys(w.strip().lower() for w in workouts)))

    @staticmethod
    def _kind(per_week: int | None, max_count: int | None, food: str | None, health: str | None = None) -> None:
        if per_week is not None and max_count is not None:
            raise ValueError("a habit is weekly or a limit, not both")
        if max_count is not None and food is not None:
            raise ValueError("a limit habit is counted, not ticked from the food log")
        if health is not None and max_count is None:
            raise ValueError("only a limit habit counts from Apple Health")

    def add(self, name: str, per_week: int | None = None, workouts: list[str] | None = None,
            max_count: int | None = None, food: str | None = None, health: str | None = None) -> Habit:
        self._kind(self._per_week(per_week), self._max(max_count), self._food(food), self._health(health))
        cur = self.conn.execute(
            "INSERT INTO habits (name, per_week, created_at, workouts, max_count, since, food, health) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (self._name(name), per_week, utcnow().isoformat(), self._workouts(workouts or []), max_count,
             self.today().isoformat() if max_count is not None else None, food, health))
        return self.find(cur.lastrowid)

    def update(self, habit_id: int, **changes) -> Habit:
        """Change any of name, per_week (None: daily), max_count (None: not a limit habit), food, health and
        workouts."""
        row = self.conn.execute("SELECT * FROM habits WHERE id = ?", (self.find(habit_id).id,)).fetchone()
        columns = {}
        if "name" in changes:
            columns["name"] = self._name(changes["name"], habit_id)
        if "per_week" in changes:
            columns["per_week"] = self._per_week(changes["per_week"])
        if "max_count" in changes:
            columns["max_count"] = self._max(changes["max_count"])
            if columns["max_count"] is None:
                columns["since"] = columns["health"] = None
            elif row["max_count"] is None:  # it becomes a limit habit today
                columns["since"] = self.today().isoformat()
        if "food" in changes:
            columns["food"] = self._food(changes["food"])
        elif columns.get("max_count") is not None:  # a limit habit is counted, not ticked from the food log
            columns["food"] = None
        if "health" in changes and (columns.get("max_count", row["max_count"]) is not None or changes["health"]):
            columns["health"] = self._health(changes["health"])
        if "workouts" in changes:
            columns["workouts"] = self._workouts(changes["workouts"])
        self._kind(*(columns[c] if c in columns else row[c] for c in ("per_week", "max_count", "food", "health")))
        if columns:
            self.conn.execute(f"UPDATE habits SET {', '.join(f'{c} = ?' for c in columns)} WHERE id = ?",
                              (*columns.values(), habit_id))
        return self.find(habit_id)

    def check_workouts(self, workouts: list[tuple[str, str, float, date]]) -> list[Habit]:
        """Check habits from workouts given as (id, type, minutes, local date). Returns the habits checked.

        A habit matches a type it lists, "any", or "other" for a type it doesn't know. Each workout checks
        a habit at most once, ever.
        """
        checked: dict[int, None] = {}
        rows = self.conn.execute("SELECT id, workouts FROM habits WHERE workouts != '[]' AND max_count IS NULL").fetchall()
        for workout_id, kind, length, day in workouts:
            if length < MIN_WORKOUT or day > self.today():
                continue
            for row in rows:
                wanted = set(json.loads(row["workouts"]))
                if not ("any" in wanted or kind in wanted or (kind not in WORKOUT_TYPES and "other" in wanted)):
                    continue
                if self.conn.execute("INSERT OR IGNORE INTO habit_workouts (habit_id, workout_id) VALUES (?, ?)",
                                     (row["id"], workout_id)).rowcount:
                    self.conn.execute("INSERT OR IGNORE INTO habit_checks (habit_id, day) VALUES (?, ?)",
                                      (row["id"], day.isoformat()))
                    checked[row["id"]] = None
        return [self.find(h) for h in checked]

    def check(self, habit_id: int, day: date | None = None, done: bool = True) -> Habit:
        if self.find(habit_id).max_count is not None:
            raise ValueError("a limit habit isn't checked: log each one with its count")
        day = day or self.today()
        if day > self.today():
            raise ValueError("can't check a habit for a day that hasn't come yet")
        if done:
            self.conn.execute("INSERT OR IGNORE INTO habit_checks (habit_id, day) VALUES (?, ?)",
                              (habit_id, day.isoformat()))
        else:
            self.conn.execute("DELETE FROM habit_checks WHERE habit_id = ? AND day = ?", (habit_id, day.isoformat()))
        return self.find(habit_id)

    def count(self, habit_id: int, add: int = 1, day: date | None = None) -> Habit:
        """Add to a limit habit's count for a day (default today); a negative `add` takes some back, never below 0.
        It adds to the day's count as shown, Health's included; taking back can't go under Health's number.
        Only what was logged here can be taken back from Health: the phone deletes its own samples, not the user's."""
        if self.find(habit_id).max_count is None:
            raise ValueError("only a limit habit has a count: check this one instead")
        day = day or self.today()
        if day > self.today():
            raise ValueError("can't count for a day that hasn't come yet")
        row = self.conn.execute("SELECT * FROM habits WHERE id = ?", (habit_id,)).fetchone()
        new = max(0, self._counts(row, day, day).get(day, 0) + int(add))
        before = self.conn.execute("SELECT logged FROM habit_counts WHERE habit_id = ? AND day = ?",
                                   (habit_id, day.isoformat())).fetchone()
        logged = min(new, max(0, (before["logged"] if before else 0) + int(add)))
        if new:
            self.conn.execute("INSERT INTO habit_counts (habit_id, day, count, logged) VALUES (?, ?, ?, ?) "
                              "ON CONFLICT(habit_id, day) DO UPDATE SET count = excluded.count, logged = excluded.logged",
                              (habit_id, day.isoformat(), new, logged))
        else:
            self.conn.execute("DELETE FROM habit_counts WHERE habit_id = ? AND day = ?", (habit_id, day.isoformat()))
        if row["health"]:
            for callback in self.on_health_count:
                callback()
        return self.find(habit_id)

    def delete(self, habit_id: int) -> bool:
        return self.conn.execute("DELETE FROM habits WHERE id = ?", (habit_id,)).rowcount > 0
