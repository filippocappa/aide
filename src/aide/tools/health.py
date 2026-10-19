"""The health tool: read-only, over the days the app uploads from Apple Health."""

from datetime import date, datetime, timedelta
from statistics import mean
from zoneinfo import ZoneInfo

from ..health import HealthStore, hours
from . import Tool

MAX_RANGE = 366  # days


def health_tools(store: HealthStore, tz: ZoneInfo) -> list[Tool]:
    def day_line(d: dict) -> str:
        parts = [f"{date.fromisoformat(d['date']):%a %d %b}"]
        if sleep := d.get("sleep"):
            when = ""
            if "bedtime" in sleep and "wake" in sleep:
                when = (f" ({datetime.fromisoformat(sleep['bedtime']).astimezone(tz):%H:%M}–"
                        f"{datetime.fromisoformat(sleep['wake']).astimezone(tz):%H:%M})")
            parts.append(f"slept {hours(sleep.get('asleep_min'))}{when}")
        for key, label in (("resting_hr", "resting HR {} bpm"), ("hrv_ms", "HRV {} ms"), ("steps", "{} steps"),
                           ("exercise_min", "{} exercise min")):
            if key in d:
                parts.append(label.format(d[key]))
        for w in d.get("workouts", []):
            parts.append(f"workout: {w.get('type', 'other')} {round(w['minutes']) if 'minutes' in w else '?'} min")
        return " · ".join(parts)

    async def health(from_date: str | None = None, to_date: str | None = None) -> str:
        end = date.fromisoformat(to_date) if to_date else datetime.now(tz).date()
        start = date.fromisoformat(from_date) if from_date else end - timedelta(days=6)
        if start > end:
            raise ValueError("from_date is after to_date")
        if (end - start).days >= MAX_RANGE:
            raise ValueError(f"ask for at most {MAX_RANGE} days at a time")
        days = store.between(start, end)
        if not days:
            return f"No health data from {start:%a %d %b} to {end:%a %d %b}."

        def avg(values: list, fmt) -> str:
            return f"{fmt(mean(values))} (over {len(values)} days)" if values else "no data"

        sleep = [d["sleep"]["asleep_min"] for d in days if "asleep_min" in d.get("sleep", {})]
        workouts = [w for d in days for w in d.get("workouts", [])]
        out = [f"Health from {start:%a %d %b} to {end:%a %d %b}, newest first:", *map(day_line, days), "",
               "Averages:",
               f"- sleep: {avg(sleep, hours)}",
               f"- resting HR: {avg([d['resting_hr'] for d in days if 'resting_hr' in d], lambda v: f'{v:.0f} bpm')}",
               f"- HRV: {avg([d['hrv_ms'] for d in days if 'hrv_ms' in d], lambda v: f'{v:.0f} ms')}",
               f"- steps: {avg([d['steps'] for d in days if 'steps' in d], lambda v: f'{v:.0f}')}",
               f"- workouts: {len(workouts)} in {len(days)} days with data"]
        return "\n".join(out)

    return [
        Tool("health", "Read the user's Apple Health summaries for a date range: sleep (time asleep, bedtime, "
             "wake), resting heart rate, HRV, steps, exercise minutes and workouts, per day and on average. "
             "Default: the last 7 days. Data arrives from the phone, so the latest day may be partial. Compare with "
             "the user's own numbers; don't make medical claims.",
             {"type": "object", "additionalProperties": False, "required": [], "properties": {
                 "from_date": {"type": "string", "description": "YYYY-MM-DD, first day (default 6 days before to_date)"},
                 "to_date": {"type": "string", "description": "YYYY-MM-DD, last day (default today)"}}},
             health),
    ]
