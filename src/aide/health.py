"""Apple Health: one summary per local day, sent by the app. Contract in docs/API.md, "Apple Health".

The server keeps the days as sent (an upload replaces a day by date) and works out "usual" numbers from
the user's own past: medians over the 30 days before. Those comparisons are all it says about health; it
makes no medical claims.
"""

import json
import sqlite3
from collections.abc import Callable
from datetime import date, datetime, timedelta
from statistics import median
from zoneinfo import ZoneInfo

from . import scores
from .db import utcnow

SCHEMA = """
CREATE TABLE IF NOT EXISTS health_days (
    day        TEXT PRIMARY KEY,  -- local date, YYYY-MM-DD
    body       TEXT NOT NULL,     -- the Health day JSON, null fields dropped
    updated_at TEXT NOT NULL      -- UTC
);
"""

MAX_DAYS = 90  # per upload
WINDOW = 30  # days before, for "usual" numbers
MIN_SLEEP_NIGHTS = 7
MIN_RECOVERY_DAYS = 14
WORKOUT_TYPES = ("strength", "run", "walk", "hike", "cycle", "swim", "hiit", "yoga", "pilates", "core", "dance",
                 "climb", "row", "elliptical", "stairs", "cardio", "martial_arts", "sport", "other")


def _clean(value):
    """Drop null fields, recursively: missing and null both mean no data."""
    if isinstance(value, dict):
        return {k: _clean(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [_clean(v) for v in value if v is not None]
    return value


def check_day(raw: dict) -> dict:
    if not isinstance(raw, dict):
        raise ValueError("each day must be an object")
    day = _clean(raw)
    try:
        day["date"] = date.fromisoformat(str(day.get("date"))).isoformat()
    except ValueError:
        raise ValueError(f"date must be YYYY-MM-DD, not {raw.get('date')!r}") from None
    if "sleep" in day and not isinstance(day["sleep"], dict):
        raise ValueError(f"{day['date']}: sleep must be an object")
    workouts = day.get("workouts", [])
    if not isinstance(workouts, list) or not all(isinstance(w, dict) and w.get("id") for w in workouts):
        raise ValueError(f"{day['date']}: workouts must be a list of objects with an id")
    return day


def hours(value: float | None) -> str:
    """Minutes as hours: 412 -> '6h52'."""
    if value is None:
        return "?"
    m = round(value)
    return f"{m // 60}h{m % 60:02d}"


class HealthStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo):
        self.conn = conn
        self.tz = tz
        self.age: Callable[[], int | None] = lambda: None  # the food profile's age, for max heart rate (create_app)
        self.conn.executescript(SCHEMA)

    def today(self) -> date:
        return datetime.now(self.tz).date()

    def save(self, days: list[dict]) -> list[dict]:
        """Upsert by date. Returns the days as stored."""
        if len(days) > MAX_DAYS:
            raise ValueError(f"send at most {MAX_DAYS} days at a time")
        clean = [check_day(d) for d in days]
        with self.conn:
            self.conn.execute("BEGIN")
            for d in clean:
                self.conn.execute(
                    "INSERT INTO health_days (day, body, updated_at) VALUES (?, ?, ?) "
                    "ON CONFLICT(day) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at",
                    (d["date"], json.dumps(d), utcnow().isoformat()))
        return clean

    def get(self, day: date) -> dict | None:
        row = self.conn.execute("SELECT body FROM health_days WHERE day = ?", (day.isoformat(),)).fetchone()
        return json.loads(row["body"]) if row else None

    def between(self, start: date, end: date) -> list[dict]:
        """Stored days in [start, end], both included, newest first."""
        rows = self.conn.execute("SELECT body FROM health_days WHERE day >= ? AND day <= ? ORDER BY day DESC",
                                 (start.isoformat(), end.isoformat())).fetchall()
        return [json.loads(r["body"]) for r in rows]

    def _before(self, day: date) -> list[dict]:
        return self.between(day - timedelta(days=WINDOW), day - timedelta(days=1))

    # -- scores (scores.py) ----------------------------------------------------------

    def _window(self, start: date, end: date) -> dict[str, dict]:
        """The days the scores for start..end look at, by date."""
        return {d["date"]: d for d in self.between(start - timedelta(days=scores.MAX_WINDOW), end)}

    def scores(self, day: date) -> dict:
        return scores.day_scores(self._window(day, day), day, self.age())

    def score_history(self, start: date, end: date) -> list[dict]:
        """Each day's three scores (null where there's no data), newest first."""
        days, age, out = self._window(start, end), self.age(), []
        for i in range((end - start).days + 1):
            day = end - timedelta(days=i)
            sleep = scores.sleep_score(days, day)
            recovery = scores.recovery_score(days, day, sleep)
            strain = scores.strain_score(days, day, recovery, age)
            out.append({"date": day.isoformat(), "sleep": sleep and sleep["score"],
                        "recovery": recovery and recovery["score"], "strain": strain and strain["score"]})
        return out

    # -- digest sections -------------------------------------------------------

    def usual_asleep(self, day: date) -> int | None:
        nights = [d["sleep"]["asleep_min"] for d in self._before(day) if "asleep_min" in d.get("sleep", {})]
        return round(median(nights)) if len(nights) >= MIN_SLEEP_NIGHTS else None

    def sleep_section(self, day: date) -> dict | None:
        found = self.get(day)
        if not found or not found.get("sleep"):
            return None
        sleep = scores.sleep_score(self._window(day, day), day)
        return {"type": "sleep", "title": "Last night", "sleep": found["sleep"], "usual_asleep_min": self.usual_asleep(day),
                "score": sleep and sleep["score"]}

    def recovery_section(self, day: date) -> dict | None:
        found = self.get(day) or {}
        hrv, rhr = found.get("hrv_ms"), found.get("resting_hr")
        if hrv is None or rhr is None:
            return None
        past = [d for d in self._before(day) if d.get("hrv_ms") is not None and d.get("resting_hr") is not None]
        if len(past) < MIN_RECOVERY_DAYS:
            return None
        hrv_usual = median(d["hrv_ms"] for d in past)
        rhr_usual = median(d["resting_hr"] for d in past)
        level, summary = recovery(hrv, hrv_usual, rhr, rhr_usual)
        days = self._window(day, day)
        score = (scores.recovery_score(days, day, scores.sleep_score(days, day)) or {}).get("score")
        if score is not None:  # the score has the last word on the level
            level = scores.level(score)
        return {"type": "recovery", "title": "Recovery", "level": level, "summary": summary, "score": score,
                "hrv_ms": hrv, "hrv_usual_ms": round(hrv_usual, 1), "resting_hr": rhr,
                "resting_hr_usual": round(rhr_usual)}


def recovery(hrv: float, hrv_usual: float, rhr: float, rhr_usual: float) -> tuple[str, str]:
    """The level (thresholds as in docs/API.md) and one plain sentence comparing with the usual numbers."""
    if hrv < 0.85 * hrv_usual or rhr >= rhr_usual + 5:
        level = "low"
    elif hrv >= hrv_usual and rhr <= rhr_usual:
        level = "good"
    else:
        level = "normal"
    if hrv < 0.85 * hrv_usual:
        h = "well below your usual"
    elif hrv < hrv_usual:
        h = "a little below your usual"
    elif hrv > 1.05 * hrv_usual:
        h = "above your usual"
    else:
        h = "about your usual"
    diff = rhr - rhr_usual
    if diff >= 5:
        r = "well above your usual"
    elif diff > 1:
        r = "a little above your usual"
    elif diff < -1:
        r = "below your usual"
    else:
        r = "normal for you"
    return level, f"HRV {h}, resting heart rate {r}."


def workout_date(w: dict, day: str, tz: ZoneInfo) -> date:
    try:
        return datetime.fromisoformat(w["start"]).astimezone(tz).date()
    except (KeyError, TypeError, ValueError):
        return date.fromisoformat(day)


def workout_minutes(w: dict) -> float:
    if isinstance(w.get("minutes"), (int, float)):
        return w["minutes"]
    try:
        return (datetime.fromisoformat(w["end"]) - datetime.fromisoformat(w["start"])).total_seconds() / 60
    except (KeyError, TypeError, ValueError):
        return 0
