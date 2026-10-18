"""Reminder tools. Deleting waits for the user's !yes; everything else runs immediately."""

from datetime import datetime
from zoneinfo import ZoneInfo

from ..reminders import Reminder, ReminderStore
from . import Tool

DUE_HELP = "Local time as YYYY-MM-DDTHH:MM. Omit for a reminder with no time."


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def reminder_tools(store: ReminderStore, tz: ZoneInfo) -> list[Tool]:
    def parse_due(value: str | None) -> datetime | None:
        if value is None:
            return None
        dt = datetime.fromisoformat(value)
        return dt.replace(tzinfo=tz) if dt.tzinfo is None else dt

    def fmt(r: Reminder) -> str:
        when = f"{r.due_at.astimezone(tz):%a %d %b %H:%M}" if r.due_at else "no time"
        state = " · done" if r.completed else ""
        line = f"[{r.id}] {when} · {r.title}{state}"
        return line + (f"\n    notes: {r.notes[:200]}" if r.notes else "")

    def find(reminder_id: str) -> Reminder:
        rem = store.get(reminder_id)
        if rem is None or rem.deleted:
            raise KeyError(f"no reminder with id {reminder_id}")
        return rem

    async def create_reminder(title: str, due: str | None = None, notes: str | None = None) -> str:
        return "Created: " + fmt(store.create(title, parse_due(due), notes or ""))

    async def list_reminders() -> str:
        open_ = store.open()
        return "\n".join(fmt(r) for r in open_) if open_ else "No open reminders."

    async def update_reminder(reminder_id: str, title: str | None = None, due: str | None = None,
                              notes: str | None = None, clear_due: bool = False) -> str:
        find(reminder_id)
        changes = {k: v for k, v in (("title", title), ("notes", notes)) if v is not None}
        if clear_due:
            changes["due_at"] = None
        elif due is not None:
            changes["due_at"] = parse_due(due)
        return "Updated: " + fmt(store.update(reminder_id, **changes))

    async def complete_reminder(reminder_id: str) -> str:
        find(reminder_id)
        return "Completed: " + fmt(store.update(reminder_id, completed=True))

    async def delete_reminder(reminder_id: str) -> str:
        rem = find(reminder_id)
        store.delete(reminder_id)
        return f"Deleted reminder: {rem.title}"

    async def describe_delete(reminder_id: str) -> str:
        rem = find(reminder_id)
        when = f" ({rem.due_at.astimezone(tz):%a %d %b %H:%M})" if rem.due_at else ""
        return f"Delete reminder '{rem.title}'{when}"

    rid = {"reminder_id": {"type": "string"}}
    return [
        Tool("create_reminder", "Create a reminder. It goes to Apple Reminders on the user's iPhone, which alerts "
             "them at the due time. Runs immediately.",
             _obj({"title": {"type": "string"}, "due": {"type": "string", "description": DUE_HELP},
                   "notes": {"type": "string"}}, ["title"]), create_reminder),
        Tool("list_reminders", "List open (not completed) reminders. Each starts with its id in brackets.",
             _obj({}, []), list_reminders),
        Tool("update_reminder", "Change a reminder's title, time or notes. Runs immediately.",
             _obj({**rid, "title": {"type": "string"}, "due": {"type": "string", "description": DUE_HELP},
                   "notes": {"type": "string"},
                   "clear_due": {"type": "boolean", "description": "Remove the due time"}}, ["reminder_id"]),
             update_reminder),
        Tool("complete_reminder", "Mark a reminder as done. Runs immediately.", _obj(rid, ["reminder_id"]),
             complete_reminder),
        Tool("delete_reminder", "Delete a reminder. Needs the user's confirmation: it is queued, and runs only "
             "when the user replies !yes.", _obj(rid, ["reminder_id"]),
             delete_reminder, confirm=True, describe=describe_delete, target_arg="reminder_id"),
    ]
