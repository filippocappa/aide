"""Reminder tools. Deleting waits for the user's !yes; everything else runs immediately."""

from datetime import datetime
from zoneinfo import ZoneInfo

from ..reminders import Reminder, ReminderStore
from ..shapes import reminder_json
from . import Tool, ToolOutput

DUE_HELP = "Local time as YYYY-MM-DDTHH:MM. Omit for a reminder with no time."
LIST_HELP = ("An Apple Reminders list by name, as list_reminders shows them (e.g. a shopping list). "
             "Omit for the default list.")


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
        listed = f" · {r.list}" if r.list and r.list != store.default_list() else ""
        line = f"[{r.id}] {when} · {r.title}{state}{listed}"
        return line + (f"\n    notes: {r.notes[:200]}" if r.notes else "")

    def find(reminder_id: str) -> Reminder:
        rem = store.get(reminder_id)
        if rem is None or rem.deleted:
            raise KeyError(f"no reminder with id {reminder_id}")
        return rem

    def cards(text: str, reminders: list[Reminder]) -> ToolOutput:
        return ToolOutput(text, {"type": "reminders", "reminders": [reminder_json(r, tz) for r in reminders]})

    def lists_line() -> str:
        known, default = store.lists(), store.default_list()
        return "Lists: " + ", ".join(f"{n} (default)" if n == default else n for n in known) if known else ""

    async def create_reminder(title: str, due: str | None = None, notes: str | None = None,
                              list: str | None = None) -> str:
        rem = store.create(title, parse_due(due), notes or "", store.resolve_list(list) if list else None)
        return cards("Created: " + fmt(rem), [rem])

    async def list_reminders(list: str | None = None) -> str:
        open_ = store.open(store.resolve_list(list) if list else None)
        head = lists_line()
        if not open_:
            return "\n".join(filter(None, [head, f"No open reminders in {list}." if list else "No open reminders."]))
        return cards("\n".join(filter(None, [head, *(fmt(r) for r in open_)])), open_)

    async def update_reminder(reminder_id: str, title: str | None = None, due: str | None = None,
                              notes: str | None = None, clear_due: bool = False, list: str | None = None) -> str:
        find(reminder_id)
        changes = {k: v for k, v in (("title", title), ("notes", notes)) if v is not None}
        if list:
            changes["list"] = store.resolve_list(list)
        if clear_due:
            changes["due_at"] = None
        elif due is not None:
            changes["due_at"] = parse_due(due)
        rem = store.update(reminder_id, **changes)
        return cards("Updated: " + fmt(rem), [rem])

    async def complete_reminder(reminder_id: str) -> str:
        find(reminder_id)
        rem = store.update(reminder_id, completed=True)
        return cards("Completed: " + fmt(rem), [rem])

    async def delete_reminder(reminder_id: str) -> str:
        rem = find(reminder_id)
        store.delete(reminder_id)
        return f"Deleted reminder: {rem.title}"

    async def describe_delete(reminder_id: str) -> str:
        rem = find(reminder_id)
        when = f" ({rem.due_at.astimezone(tz):%a %d %b %H:%M})" if rem.due_at else ""
        return f"Delete reminder '{rem.title}'{when}"

    rid = {"reminder_id": {"type": "string"}}
    in_list = {"list": {"type": "string", "description": LIST_HELP}}
    return [
        Tool("create_reminder", "Create a reminder. It goes to Apple Reminders on the user's iPhone, which alerts "
             "them at the due time. Things to buy go in their shopping list if they have one. Runs immediately.",
             _obj({"title": {"type": "string"}, "due": {"type": "string", "description": DUE_HELP},
                   "notes": {"type": "string"}, **in_list}, ["title"]), create_reminder),
        Tool("list_reminders", "List open (not completed) reminders, from every Apple Reminders list or just one, "
             "after the names of the lists. Each starts with its id in brackets; one outside the default list "
             "ends with its list.",
             _obj(in_list, []), list_reminders),
        Tool("update_reminder", "Change a reminder's title, time or notes, or move it to another list. "
             "Runs immediately.",
             _obj({**rid, "title": {"type": "string"}, "due": {"type": "string", "description": DUE_HELP},
                   "notes": {"type": "string"},
                   "clear_due": {"type": "boolean", "description": "Remove the due time"}, **in_list},
                  ["reminder_id"]),
             update_reminder),
        Tool("complete_reminder", "Mark a reminder as done. Runs immediately.", _obj(rid, ["reminder_id"]),
             complete_reminder),
        Tool("delete_reminder", "Delete a reminder. Needs the user's confirmation: it is queued, and runs only "
             "when the user replies !yes.", _obj(rid, ["reminder_id"]),
             delete_reminder, confirm=True, describe=describe_delete, target_arg="reminder_id"),
    ]
