"""Body weight: readings from Apple Health and the ones logged through Aide, and the trend. Contract in docs/API.md,
"Apple Health" (Weight).

A day's reading is the last one logged through Aide that day, else Health's (the day's `weight_kg`). The phone writes
Aide's readings to Health itself (`logged`, like a limit habit's counts), so they show up there too. The trend is the
7-day average and the rate from a straight line through the last 28 days, against the pace the food goal wants.
"""

import json
import sqlite3
from datetime import date, datetime, time, timedelta, timezone
from statistics import mean
from zoneinfo import ZoneInfo

from .db import utcnow
from .health import HealthStore

SCHEMA = """
CREATE TABLE IF NOT EXISTS weights (
    id         INTEGER PRIMARY KEY,
    at         TEXT NOT NULL,  -- UTC, when weighed
    kg         REAL NOT NULL,
    created_at TEXT NOT NULL   -- UTC
);
CREATE INDEX IF NOT EXISTS weights_at ON weights (at);
"""

MIN_KG, MAX_KG = 25, 300
AVERAGE_DAYS = 7
TREND_DAYS = 28
MIN_TREND_READINGS = 3
MIN_TREND_SPAN = 14  # days between the first and last reading in the trend
CHANGE_WEEKS = 3  # the 7-day average against the one this many weeks before
MIRROR_DAYS = 90  # how far back the phone keeps Aide's readings in Health
# The pace each food goal wants, in % of body weight a week: (low, high). Gain is 0.25–0.5% a month.
PACE = {"gain": (0.06, 0.12), "lose": (-0.75, -0.25), "keep": (-0.06, 0.06), "perform": (-0.06, 0.06)}
SLACK = 0.06  # % a week either side of the pace still counts as on track (scales and water are noisy)


class WeightStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, health: HealthStore | None = None):
        self.conn = conn
        self.tz = tz
        self.health = health
        self.on_change: list = []  # the phone writes Aide's readings to Health
        self.conn.executescript(SCHEMA)

    def today(self) -> date:
        return datetime.now(self.tz).date()

    def _changed(self) -> None:
        for hook in self.on_change:
            hook()

    def local(self, at: str) -> datetime:
        return datetime.fromisoformat(at).astimezone(self.tz)

    def as_json(self, row) -> dict:
        return {"id": row["id"], "at": row["at"], "kg": row["kg"]}

    def log(self, kg: float, at: datetime | str | None = None) -> dict:
        kg = round(float(kg), 2)
        if not MIN_KG <= kg <= MAX_KG:
            raise ValueError(f"weight must be between {MIN_KG} and {MAX_KG} kg")
        when = datetime.fromisoformat(at) if isinstance(at, str) else (at or utcnow())
        when = when.replace(tzinfo=self.tz) if when.tzinfo is None else when
        if when > utcnow() + timedelta(hours=1):
            raise ValueError("a weight can't be in the future")
        now = utcnow().isoformat()
        cur = self.conn.execute("INSERT INTO weights (at, kg, created_at) VALUES (?, ?, ?)",
                                (when.astimezone(timezone.utc).isoformat(), kg, now))
        self._changed()
        return self.find(cur.lastrowid)

    def find(self, weight_id: int) -> dict:
        row = self.conn.execute("SELECT * FROM weights WHERE id = ?", (weight_id,)).fetchone()
        if not row:
            raise KeyError(f"no weight {weight_id}")
        return self.as_json(row)

    def delete(self, weight_id: int) -> bool:
        gone = self.conn.execute("DELETE FROM weights WHERE id = ?", (weight_id,)).rowcount > 0
        if gone:
            self._changed()
        return gone

    def logged(self, days: int = MIRROR_DAYS) -> list[dict]:
        """Readings logged through Aide in the last `days` days, oldest first: what the phone keeps in Health."""
        since = datetime.combine(self.today() - timedelta(days=days - 1), time(), self.tz)
        rows = self.conn.execute("SELECT * FROM weights WHERE at >= ? ORDER BY at",
                                 (since.astimezone(timezone.utc).isoformat(),)).fetchall()
        return [self.as_json(r) for r in rows]

    def readings(self, start: date, end: date) -> list[dict]:
        """One reading a day from start to end, oldest first: {date, kg, source ("aide" or "health"), id (Aide's)}."""
        out: dict[str, dict] = {}
        for d in reversed(self.health.between(start, end) if self.health else []):
            if d.get("weight_kg"):
                out[d["date"]] = {"date": d["date"], "kg": round(float(d["weight_kg"]), 2), "source": "health"}
        lo = datetime.combine(start, time(), self.tz).astimezone(timezone.utc).isoformat()
        hi = datetime.combine(end + timedelta(days=1), time(), self.tz).astimezone(timezone.utc).isoformat()
        for r in self.conn.execute("SELECT * FROM weights WHERE at >= ? AND at < ? ORDER BY at", (lo, hi)):
            day = self.local(r["at"]).date().isoformat()  # ordered by time: the day's last one wins
            out[day] = {"date": day, "kg": r["kg"], "source": "aide", "id": r["id"]}
        return [out[k] for k in sorted(out)]

    def goal(self) -> str | None:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'food_targets'").fetchone()
        return (json.loads(row["value"]).get("profile") or {}).get("goal") if row else None

    def summary(self, today: date | None = None) -> dict:
        """The latest reading, the 7-day average, the change over 3 weeks, the rate a week from the last 28 days,
        the pace the goal wants and whether the rate is below, on or above it (null without enough readings)."""
        today = today or self.today()
        span = TREND_DAYS + CHANGE_WEEKS * 7
        readings = self.readings(today - timedelta(days=span), today)
        latest = readings[-1] if readings else None
        if latest is None:  # the last reading may be older than the window
            before = self.readings(today - timedelta(days=365), today - timedelta(days=span + 1))
            latest = before[-1] if before else None

        def average(end: date) -> float | None:
            kgs = [r["kg"] for r in readings if end - timedelta(days=AVERAGE_DAYS) < date.fromisoformat(r["date"]) <= end]
            return round(mean(kgs), 2) if kgs else None

        avg = average(today)
        then = average(today - timedelta(days=CHANGE_WEEKS * 7))
        trend = [r for r in readings if date.fromisoformat(r["date"]) > today - timedelta(days=TREND_DAYS)]
        rate = None
        if len(trend) >= MIN_TREND_READINGS:
            xs = [(date.fromisoformat(r["date"]) - today).days for r in trend]
            if xs[-1] - xs[0] >= MIN_TREND_SPAN:
                mx, my = mean(xs), mean(r["kg"] for r in trend)
                slope = (sum((x - mx) * (r["kg"] - my) for x, r in zip(xs, trend))
                         / sum((x - mx) ** 2 for x in xs))
                rate = round(slope * 7, 2)
        goal = self.goal()
        base = avg or (latest["kg"] if latest else None)
        pace = verdict = None
        if goal in PACE and base:
            lo, hi = PACE[goal]
            pace = {"low_kg": round(base * lo / 100, 2), "high_kg": round(base * hi / 100, 2)}
            if rate is not None:
                slack = base * SLACK / 100
                verdict = ("below" if rate < pace["low_kg"] - slack else
                           "above" if rate > pace["high_kg"] + slack else "on_track")
        return {"latest": latest and {"date": latest["date"], "kg": latest["kg"]},
                "days_since": (today - date.fromisoformat(latest["date"])).days if latest else None,
                "average_kg": avg, "change_kg": round(avg - then, 2) if avg is not None and then is not None else None,
                "rate_kg_week": rate, "goal": goal, "pace_kg_week": pace, "verdict": verdict}


def describe(summary: dict) -> str:
    """The trend in a line or two, for Coach."""
    s = summary
    if not s["latest"]:
        return "No weight readings yet."
    parts = [f"Latest weight {s['latest']['kg']} kg on {s['latest']['date']} ({s['days_since']} days ago)"]
    if s["average_kg"] is not None:
        parts.append(f"7-day average {s['average_kg']} kg")
    if s["change_kg"] is not None:
        parts.append(f"{s['change_kg']:+.2f} kg against the average {CHANGE_WEEKS} weeks before")
    if s["rate_kg_week"] is not None:
        parts.append(f"trend {s['rate_kg_week']:+.2f} kg a week over the last {TREND_DAYS} days")
    else:
        parts.append(f"not enough readings for a trend (it needs {MIN_TREND_READINGS} over {MIN_TREND_SPAN}+ days)")
    line = ", ".join(parts) + "."
    if s["pace_kg_week"]:
        p = s["pace_kg_week"]
        line += f" The goal ({s['goal']}) wants {p['low_kg']:+.2f} to {p['high_kg']:+.2f} kg a week"
        line += {"below": ": the trend is below it.", "above": ": the trend is above it.",
                 "on_track": ": the trend is on track."}.get(s["verdict"], ".")
    return line
