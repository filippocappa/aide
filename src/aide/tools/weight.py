"""Weight tools: log a reading (the phone writes it to Apple Health) and read the trend."""

from datetime import timedelta

from ..weight import WeightStore, describe
from . import Tool

MAX_DAYS = 366


def weight_tools(store: WeightStore) -> list[Tool]:
    def trend() -> str:
        return describe(store.summary())

    async def log_weight(kg: float, weighed_at: str | None = None) -> str:
        w = store.log(kg, weighed_at)
        return f"Logged {w['kg']} kg [weight {w['id']}]. {trend()}"

    async def weight_trend(days: int = 28) -> str:
        days = max(1, min(int(days), MAX_DAYS))
        today = store.today()
        readings = store.readings(today - timedelta(days=days - 1), today)
        lines = [trend()]
        if readings:
            lines.append(f"Readings, last {days} days (newest first):")
            lines += [f"- {r['date']}: {r['kg']} kg" + (f" [weight {r['id']}, logged through Aide]"
                                                        if r["source"] == "aide" else "")
                      for r in reversed(readings)]
        return "\n".join(lines)

    async def delete_weight(weight_id: int) -> str:
        w = store.find(weight_id)
        store.delete(weight_id)
        return f"Deleted the {w['kg']} kg reading."

    async def describe_delete(weight_id: int) -> str:
        w = store.find(weight_id)
        return f"Delete the {w['kg']} kg weight logged {store.local(w['at']):%a %d %b %H:%M}"

    return [
        Tool("log_weight", "Log the user's body weight when they tell you it (\"72.4 this morning\"). The phone "
             "writes it to Apple Health. Returns the trend. Runs immediately.",
             {"type": "object", "properties": {
                 "kg": {"type": "number", "description": "Kilograms (convert from pounds: lb × 0.4536)"},
                 "weighed_at": {"type": "string", "description": "Local time as YYYY-MM-DDTHH:MM. Omit for now."}},
              "required": ["kg"], "additionalProperties": False}, log_weight),
        Tool("weight_trend", "The user's weight: the latest reading, the 7-day average, the change over 3 weeks, the "
             "trend a week against the pace their food goal wants, and the day's readings (Apple Health's and the "
             "ones logged through Aide).",
             {"type": "object", "properties": {"days": {"type": "integer", "description": "Readings for this many "
                                                         "days back (default 28)"}},
              "additionalProperties": False}, weight_trend),
        Tool("delete_weight", "Delete a weight logged through Aide by mistake ([weight N] from weight_trend). Needs "
             "the user's confirmation: it is queued, and runs only when the user replies !yes.",
             {"type": "object", "properties": {"weight_id": {"type": "integer"}}, "required": ["weight_id"],
              "additionalProperties": False}, delete_weight, confirm=True, describe=describe_delete,
             target_arg="weight_id"),
    ]
