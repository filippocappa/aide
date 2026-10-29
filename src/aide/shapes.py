"""JSON objects from docs/API.md that more than one part of the server sends (the API, the digest)."""

from datetime import datetime, time
from zoneinfo import ZoneInfo

from .icloud import CalEvent
from .reminders import Reminder


def reminder_json(r: Reminder, tz: ZoneInfo) -> dict:
    return {
        "id": r.id, "title": r.title, "notes": r.notes,
        "due_at": r.due_at.astimezone(tz).isoformat() if r.due_at else None,
        "completed": r.completed, "apple_id": r.apple_id,
        "modified_at": r.modified_at.isoformat().replace("+00:00", "Z"), "deleted": r.deleted, "list": r.list,
    }


def event_json(e: CalEvent, tz: ZoneInfo) -> dict:
    def t(d):
        return d.astimezone(tz).isoformat() if isinstance(d, datetime) else d.isoformat()
    return {"id": e.uid, "title": e.title, "calendar": e.calendar, "start": t(e.start), "end": t(e.end),
            "all_day": e.all_day, "location": e.location, "notes": e.notes, "recurring": e.recurring}


def event_start(e: CalEvent, tz: ZoneInfo) -> datetime:
    """Sort key: all-day events count from local midnight."""
    s = e.start if isinstance(e.start, datetime) else datetime.combine(e.start, time.min, tz)
    return s.astimezone(tz)
