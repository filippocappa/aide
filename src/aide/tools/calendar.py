"""Calendar tools. Moving and deleting events wait for the user's !yes."""

import asyncio
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from ..icloud import CalendarBackend, CalEvent
from ..shapes import event_json
from . import Tool, ToolOutput

MAX_RANGE_DAYS = 62
SEARCH_BACK, SEARCH_AHEAD = timedelta(days=30), timedelta(days=365)
NOTES_LIMIT = 200

DATETIME_HELP = "Local time as YYYY-MM-DDTHH:MM, or YYYY-MM-DD for an all-day event."


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def calendar_tools(cal: CalendarBackend, tz: ZoneInfo, default_calendar: str | None = None) -> list[Tool]:
    def parse(value: str) -> date | datetime:
        if len(value) == 10:
            return date.fromisoformat(value)
        dt = datetime.fromisoformat(value)
        return dt.replace(tzinfo=tz) if dt.tzinfo is None else dt.astimezone(tz)

    def parse_range(start: str, end: str) -> tuple[date | datetime, date | datetime]:
        s, e = parse(start), parse(end)
        if isinstance(s, datetime) != isinstance(e, datetime):
            raise ValueError("start and end must both be dates (all-day) or both be date-times")
        if isinstance(s, datetime):
            if e <= s:
                raise ValueError("end must be after start")
            return s, e
        if e < s:
            raise ValueError("end date is before start date")
        return s, e + timedelta(days=1)  # the user's end date is inclusive; iCalendar's is exclusive

    def local(d: date | datetime) -> date | datetime:
        return d.astimezone(tz) if isinstance(d, datetime) else d

    def when(ev: CalEvent) -> str:
        if ev.all_day:
            last = ev.end - timedelta(days=1)
            return f"{ev.start:%a %d %b} (all day)" if last <= ev.start else f"{ev.start:%a %d %b}–{last:%a %d %b} (all day)"
        s, e = local(ev.start), local(ev.end)
        end = f"{e:%H:%M}" if e.date() == s.date() else f"{e:%a %d %b %H:%M}"
        return f"{s:%a %d %b %H:%M}–{end}"

    def fmt(ev: CalEvent) -> str:
        parts = [f"[{ev.uid}]", when(ev), ev.title, f"({ev.calendar})"]
        if ev.location:
            parts.append(f"@ {ev.location}")
        if ev.recurring:
            parts.append("· recurring")
        line = " ".join(parts)
        if ev.notes:
            notes = ev.notes.replace("\n", " ")
            line += f"\n    notes: {notes[:NOTES_LIMIT]}{'…' if len(notes) > NOTES_LIMIT else ''}"
        return line

    def sort_key(ev: CalEvent) -> datetime:
        s = ev.start if isinstance(ev.start, datetime) else datetime.combine(ev.start, time.min, tz)
        return s.astimezone(tz)

    def cards(events: list[CalEvent]) -> ToolOutput:
        return ToolOutput("\n".join(fmt(ev) for ev in events),
                          {"type": "events", "events": [event_json(ev, tz) for ev in events]})

    def day_start(d: date) -> datetime:
        return datetime.combine(d, time.min, tz)

    async def lookup(event_id: str) -> CalEvent:
        ev = await asyncio.to_thread(cal.get, event_id)
        if ev is None:
            raise KeyError(f"no event with id {event_id}")
        return ev

    # -- handlers ------------------------------------------------------------

    async def list_calendars() -> str:
        names = await asyncio.to_thread(cal.calendars)
        default = default_calendar or (names[0] if names else None)
        return "\n".join(f"{n}{' (default)' if n == default else ''}" for n in names) or "No calendars found."

    async def list_events(start_date: str, end_date: str) -> str:
        s, e = date.fromisoformat(start_date), date.fromisoformat(end_date)
        if e < s:
            raise ValueError("end_date is before start_date")
        if (e - s).days > MAX_RANGE_DAYS:
            raise ValueError(f"range too long; ask for at most {MAX_RANGE_DAYS} days at a time")
        events = await asyncio.to_thread(cal.events, day_start(s), day_start(e + timedelta(days=1)))
        if not events:
            return "No events."
        return cards(sorted(events, key=sort_key))

    async def search_events(query: str) -> str:
        now = datetime.now(tz)
        events = await asyncio.to_thread(cal.events, now - SEARCH_BACK, now + SEARCH_AHEAD)
        q = query.casefold()
        hits = [ev for ev in events if q in f"{ev.title} {ev.location} {ev.notes}".casefold()]
        if not hits:
            return f"No events matching {query!r} between {SEARCH_BACK.days} days ago and a year ahead."
        return cards(sorted(hits, key=sort_key)[:30])

    async def create_event(title: str, start: str, end: str, calendar: str,
                           location: str | None = None, notes: str | None = None) -> str:
        s, e = parse_range(start, end)
        ev = await asyncio.to_thread(cal.create, calendar, title, s, e, location or "", notes or "")
        return "Created: " + fmt(ev)

    async def move_event(event_id: str, new_start: str, new_end: str) -> str:
        s, e = parse_range(new_start, new_end)
        ev = await asyncio.to_thread(cal.move, event_id, s, e)
        return "Moved: " + fmt(ev)

    async def describe_move(event_id: str, new_start: str, new_end: str) -> str:
        ev = await lookup(event_id)
        if ev.recurring:
            raise ValueError("recurring events can't be changed by Aide yet; edit it on your iPhone")
        s, e = parse_range(new_start, new_end)
        target = CalEvent(ev.uid, ev.calendar, ev.title, s, e)
        return f"Move '{ev.title}' from {when(ev)} to {when(target)}"

    async def delete_event(event_id: str) -> str:
        ev = await lookup(event_id)
        await asyncio.to_thread(cal.delete, event_id)
        return f"Deleted: {ev.title}, {when(ev)}"

    async def describe_delete(event_id: str) -> str:
        ev = await lookup(event_id)
        if ev.recurring:
            raise ValueError("recurring events can't be deleted by Aide yet; delete it on your iPhone")
        return f"Delete '{ev.title}' on {when(ev)} ({ev.calendar})"

    return [
        Tool("list_calendars", "List the user's calendars. The one marked (default) is where they usually "
             "put events.", _obj({}, []), list_calendars),
        Tool("list_events", "List calendar events between two local dates (inclusive), across all calendars. "
             "Each event starts with its id in brackets.",
             _obj({"start_date": {"type": "string", "description": "YYYY-MM-DD"},
                   "end_date": {"type": "string", "description": "YYYY-MM-DD, inclusive"}},
                  ["start_date", "end_date"]), list_events),
        Tool("search_events", "Find events whose title, location or notes contain some text, "
             "from 30 days ago to a year ahead.",
             _obj({"query": {"type": "string"}}, ["query"]), search_events),
        Tool("create_event", "Create a calendar event. Runs immediately.",
             _obj({"title": {"type": "string"},
                   "start": {"type": "string", "description": DATETIME_HELP},
                   "end": {"type": "string", "description": DATETIME_HELP + " For a single all-day event, "
                           "use the same date as start."},
                   "calendar": {"type": "string", "description": "Exact calendar name from list_calendars. "
                                "Use one only if it clearly fits the event, or the user named it; otherwise "
                                "ask the user first."},
                   "location": {"type": "string"},
                   "notes": {"type": "string"}},
                  ["title", "start", "end", "calendar"]), create_event),
        Tool("move_event", "Move an event to a new time. Needs the user's confirmation: it is queued, "
             "and runs only when the user replies !yes.",
             _obj({"event_id": {"type": "string"},
                   "new_start": {"type": "string", "description": DATETIME_HELP},
                   "new_end": {"type": "string", "description": DATETIME_HELP}},
                  ["event_id", "new_start", "new_end"]),
             move_event, confirm=True, describe=describe_move, target_arg="event_id"),
        Tool("delete_event", "Delete an event. Needs the user's confirmation: it is queued, "
             "and runs only when the user replies !yes.",
             _obj({"event_id": {"type": "string"}}, ["event_id"]),
             delete_event, confirm=True, describe=describe_delete, target_arg="event_id"),
    ]
