"""Habit tools. Adding and checking run immediately; deleting waits for the user's !yes."""

import datetime

from ..habits import Habit, HabitStore
from . import Tool


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def fmt(h: Habit) -> str:
    if h.per_week is None:
        cadence, unit = "daily", "day"
    else:
        cadence, unit = f"{h.per_week}×/week, {h.this_week} done this week", "week"
    streak = f"streak {h.streak} {unit}{'s' if h.streak != 1 else ''}"
    today = "done today" if h.done_today else "not done today"
    return f"[{h.id}] {h.name} · {cadence} · {streak} · {today}"


def habit_tools(store: HabitStore) -> list[Tool]:
    async def add_habit(name: str, per_week: int | None = None) -> str:
        return "Added: " + fmt(store.add(name, per_week))

    async def list_habits() -> str:
        habits = store.all()
        return "\n".join(fmt(h) for h in habits) if habits else "No habits yet."

    async def check_habit(habit_id: int, date: str | None = None, done: bool = True) -> str:  # noqa: A002
        day = datetime.date.fromisoformat(date) if date else None
        habit = store.check(habit_id, day, done)
        return ("Checked: " if done else "Unchecked: ") + fmt(habit)

    async def delete_habit(habit_id: int) -> str:
        habit = store.find(habit_id)
        store.delete(habit_id)
        return f"Deleted habit: {habit.name}"

    async def describe_delete(habit_id: int) -> str:
        habit = store.find(habit_id)
        return f"Delete habit '{habit.name}' and its {habit.streak}-{'day' if habit.per_week is None else 'week'} streak"

    hid = {"habit_id": {"type": "integer"}}
    return [
        Tool("add_habit", "Start tracking a habit. Daily unless per_week is given (times per Monday-to-Sunday "
             "week, 1–7). Runs immediately.",
             _obj({"name": {"type": "string"}, "per_week": {"type": "integer"}}, ["name"]), add_habit),
        Tool("list_habits", "List habits with their id in brackets, cadence, streak and whether today is done.",
             _obj({}, []), list_habits),
        Tool("check_habit", "Mark a habit as done for a day (default today). done=false undoes it. Runs immediately.",
             _obj({**hid, "date": {"type": "string", "description": "YYYY-MM-DD, default today; not in the future"},
                   "done": {"type": "boolean"}}, ["habit_id"]), check_habit),
        Tool("delete_habit", "Stop tracking a habit and drop its history. Needs the user's confirmation: it is "
             "queued, and runs only when the user replies !yes.", _obj(hid, ["habit_id"]),
             delete_habit, confirm=True, describe=describe_delete, target_arg="habit_id"),
    ]
