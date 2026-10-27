"""Habit tools. Adding, checking and counting run immediately; deleting waits for the user's !yes."""

import datetime

from ..food import FOOD_METRICS
from ..habits import HEALTH_COUNTS, Habit, HabitStore
from . import Tool


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


FOOD = {"logged": "ticks itself on days with a meal logged", "protein_g": "ticks itself on days at the protein goal",
        "calories": "ticks itself on days at the calorie goal"}


def fmt(h: Habit, today: datetime.date) -> str:
    if h.max_count is not None:
        counts = dict(h.counts)
        week = [counts.get(today - datetime.timedelta(days=i), 0) for i in range(7, 0, -1)]
        streak = f"streak {h.streak} day{'s' if h.streak != 1 else ''} within the limit"
        source = " (counted from Apple Health too)" if h.health else ""
        return (f"[{h.id}] {h.name} · at most {h.max_count} a day{source} · {h.count} today"
                f"{' (over the limit)' if not h.done_today else ''} · last 7 days, oldest first: "
                f"{', '.join(map(str, week))} · {streak}")
    if h.per_week is None:
        cadence, unit = "daily", "day"
    else:
        cadence, unit = f"{h.per_week}×/week, {h.this_week} done this week", "week"
    streak = f"streak {h.streak} {unit}{'s' if h.streak != 1 else ''}"
    today = "done today" if h.done_today else "not done today"
    food = f" · {FOOD[h.food]}" if h.food else ""
    return f"[{h.id}] {h.name} · {cadence}{food} · {streak} · {today}"


def habit_tools(store: HabitStore) -> list[Tool]:
    async def add_habit(name: str, per_week: int | None = None, max: int | None = None,  # noqa: A002
                        food: str | None = None, health: str | None = None) -> str:
        return "Added: " + fmt(store.add(name, per_week, max_count=max, food=food, health=health), store.today())

    async def list_habits() -> str:
        habits = store.all()
        return "\n".join(fmt(h, store.today()) for h in habits) if habits else "No habits yet."

    async def check_habit(habit_id: int, date: str | None = None, done: bool = True) -> str:  # noqa: A002
        day = datetime.date.fromisoformat(date) if date else None
        habit = store.check(habit_id, day, done)
        return ("Checked: " if done else "Unchecked: ") + fmt(habit, store.today())

    async def count_habit(habit_id: int, add: int = 1, date: str | None = None) -> str:  # noqa: A002
        day = datetime.date.fromisoformat(date) if date else None
        return "Counted: " + fmt(store.count(habit_id, add, day), store.today())

    async def delete_habit(habit_id: int) -> str:
        habit = store.find(habit_id)
        store.delete(habit_id)
        return f"Deleted habit: {habit.name}"

    async def describe_delete(habit_id: int) -> str:
        habit = store.find(habit_id)
        return f"Delete habit '{habit.name}' and its {habit.streak}-{'week' if habit.per_week else 'day'} streak"

    hid = {"habit_id": {"type": "integer"}}
    date = {"date": {"type": "string", "description": "YYYY-MM-DD, default today; not in the future"}}
    return [
        Tool("add_habit", "Start tracking a habit. Daily unless per_week is given (times per Monday-to-Sunday "
             "week, 1–7). max makes it a limit habit: a daily count that has to stay at or under max (e.g. at most "
             "5 coffees a day), logged with count_habit; with health it also counts from that Apple Health number "
             "(inhaler_usage: the Inhaler Usage the user logs there). food makes it tick itself from the food log: logged (a "
             "meal logged), protein_g or calories (at that goal). Runs immediately.",
             _obj({"name": {"type": "string"}, "per_week": {"type": "integer"}, "max": {"type": "integer"},
                   "food": {"type": "string", "enum": list(FOOD_METRICS)},
                   "health": {"type": "string", "enum": list(HEALTH_COUNTS)}}, ["name"]), add_habit),
        Tool("list_habits", "List habits with their id in brackets, cadence, streak and whether today is done; for "
             "a limit habit, today's count and the last 7 days'.", _obj({}, []), list_habits),
        Tool("check_habit", "Mark a habit as done for a day (default today). done=false undoes it. Not for limit "
             "habits (count_habit). Runs immediately.",
             _obj({**hid, **date, "done": {"type": "boolean"}}, ["habit_id"]), check_habit),
        Tool("count_habit", "Log one (or add more) for a limit habit, e.g. the user had a coffee. add=-1 takes "
             "one back. For a habit that counts from Apple Health, the phone also writes it there (Inhaler Usage), "
             "so the user needn't log it twice. Runs immediately.",
             _obj({**hid, "add": {"type": "integer", "description": "default 1"}, **date}, ["habit_id"]),
             count_habit),
        Tool("delete_habit", "Stop tracking a habit and drop its history. Needs the user's confirmation: it is "
             "queued, and runs only when the user replies !yes.", _obj(hid, ["habit_id"]),
             delete_habit, confirm=True, describe=describe_delete, target_arg="habit_id"),
    ]
