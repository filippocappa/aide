"""Calendar tools. Changing and deleting events wait for the user's !yes."""

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
FREE_FROM, FREE_UNTIL = time(8, 30), time(21, 0)  # the waking day free_time looks in
FREE_GAP = timedelta(minutes=15)  # kept clear around events
FREE_DAYS = 21


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

    def cards(events: list[CalEvent], change: str | None = None, text: str | None = None) -> ToolOutput:
        """`change` marks them on the card: "found" by a search, "created" this turn."""
        mark = {"change": change} if change else {}
        return ToolOutput(text or "\n".join(fmt(ev) for ev in events),
                          {"type": "events", "events": [{**event_json(ev, tz), **mark} for ev in events]})

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
        return cards(sorted(hits, key=sort_key)[:30], "found")

    async def free_time(start_date: str, end_date: str, minutes: int = 60) -> str:
        s, e = date.fromisoformat(start_date), date.fromisoformat(end_date)
        if e < s:
            raise ValueError("end_date is before start_date")
        if (e - s).days >= FREE_DAYS:
            raise ValueError(f"ask for at most {FREE_DAYS} days at a time")
        events = await asyncio.to_thread(cal.events, day_start(s), day_start(e + timedelta(days=1)))
        busy = sorted((local(ev.start) - FREE_GAP, local(ev.end) + FREE_GAP) for ev in events if not ev.all_day)
        now, need, lines = datetime.now(tz), timedelta(minutes=max(15, minutes)), []
        for i in range((e - s).days + 1):
            day = s + timedelta(days=i)
            cursor, until = datetime.combine(day, FREE_FROM, tz), datetime.combine(day, FREE_UNTIL, tz)
            cursor = max(cursor, now.replace(second=0, microsecond=0)) if day == now.date() else cursor
            slots = []
            for b_start, b_end in busy:
                if b_end <= cursor or b_start >= until:
                    continue
                if b_start - cursor >= need:
                    slots.append((cursor, b_start))
                cursor = max(cursor, b_end)
            if until - cursor >= need:
                slots.append((cursor, until))
            if slots:
                lines.append(f"{day:%a %d %b}: " + ", ".join(f"{a:%H:%M}–{b:%H:%M}" for a, b in slots))
        return "\n".join(lines) or f"No free stretch of {minutes} min in those days."

    async def create_event(title: str, start: str, end: str, calendar: str,
                           location: str | None = None, notes: str | None = None) -> str:
        s, e = parse_range(start, end)
        ev = await asyncio.to_thread(cal.create, calendar, title, s, e, location or "", notes or "")
        return cards([ev], "created", "Created: " + fmt(ev))

    def edits(new_start, new_end, calendar, title, location, notes) -> dict:
        changes = {k: v for k, v in (("calendar", calendar), ("title", title), ("location", location),
                                     ("notes", notes)) if v is not None}
        if (new_start is None) != (new_end is None):
            raise ValueError("give both new_start and new_end, or neither")
        if new_start is not None:
            changes["start"], changes["end"] = parse_range(new_start, new_end)
        if not changes:
            raise ValueError("nothing to change")
        return changes

    async def edit_event(event_id: str, new_start: str | None = None, new_end: str | None = None,
                         calendar: str | None = None, title: str | None = None, location: str | None = None,
                         notes: str | None = None) -> str:
        changes = edits(new_start, new_end, calendar, title, location, notes)
        ev = await asyncio.to_thread(lambda: cal.update(event_id, **changes))
        return "Changed: " + fmt(ev)

    async def describe_edit(event_id: str, new_start: str | None = None, new_end: str | None = None,
                            calendar: str | None = None, title: str | None = None, location: str | None = None,
                            notes: str | None = None) -> str:
        ev = await lookup(event_id)
        if ev.recurring:
            raise ValueError("recurring events can't be changed by Aide yet; edit it on your iPhone")
        changes = edits(new_start, new_end, calendar, title, location, notes)
        if calendar is not None and calendar not in await asyncio.to_thread(cal.calendars):
            raise ValueError(f"no calendar named {calendar!r}; see list_calendars")
        target = CalEvent(ev.uid, ev.calendar, ev.title, changes["start"], changes["end"]) if "start" in changes else None
        if set(changes) == {"start", "end"}:
            return f"Move '{ev.title}' from {when(ev)} to {when(target)}"
        parts = [f"time to {when(target)}"] if target else []
        if calendar is not None and calendar != ev.calendar:
            parts.append(f"from {ev.calendar} to {calendar}")
        if title is not None:
            parts.append(f"title to '{title}'")
        if location is not None:
            parts.append(f"place to {location}" if location else "no place")
        if notes is not None:
            parts.append("new notes" if notes else "no notes")
        return f"Change '{ev.title}' on {when(ev)}: {', '.join(parts) or 'nothing'}"

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
        Tool("free_time", f"The free stretches between two local dates (inclusive, at most {FREE_DAYS} days), "
             f"{FREE_FROM:%H:%M}–{FREE_UNTIL:%H:%M} each day, at least `minutes` long, keeping "
             f"{FREE_GAP.seconds // 60} min clear around timed events (all-day ones don't count). For finding when "
             "something fits.",
             _obj({"start_date": {"type": "string", "description": "YYYY-MM-DD"},
                   "end_date": {"type": "string", "description": "YYYY-MM-DD, inclusive"},
                   "minutes": {"type": "integer", "description": "The shortest stretch worth listing; default 60"}},
                  ["start_date", "end_date"]), free_time),
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
        Tool("edit_event", "Change an event: its time, its calendar (moves it to another calendar), title, "
             "place or notes. Give only what changes. Needs the user's confirmation: it is queued, and runs only "
             "when the user replies !yes.",
             _obj({"event_id": {"type": "string"},
                   "new_start": {"type": "string", "description": DATETIME_HELP + " With new_end."},
                   "new_end": {"type": "string", "description": DATETIME_HELP + " With new_start."},
                   "calendar": {"type": "string", "description": "Exact calendar name from list_calendars."},
                   "title": {"type": "string"},
                   "location": {"type": "string", "description": "The place; an empty string removes it."},
                   "notes": {"type": "string", "description": "Replaces the notes; an empty string removes them."}},
                  ["event_id"]),
             edit_event, confirm=True, describe=describe_edit, target_arg="event_id"),
        Tool("delete_event", "Delete an event. Needs the user's confirmation: it is queued, "
             "and runs only when the user replies !yes.",
             _obj({"event_id": {"type": "string"}}, ["event_id"]),
             delete_event, confirm=True, describe=describe_delete, target_arg="event_id"),
    ]
