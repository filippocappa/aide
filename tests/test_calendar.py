from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import icalendar
import pytest

from aide.agent import Agent
from aide.db import Database
from aide.icloud import CalEvent, RecurringEventError, _event_from_component
from aide.tools import ToolRegistry
from aide.tools.calendar import calendar_tools

ROME = ZoneInfo("Europe/Rome")


class FakeCalendar:
    """In-memory CalendarBackend."""

    def __init__(self, events=()):
        self.store = {e.uid: e for e in events}

    def calendars(self):
        return ["Home", "Work"]

    def events(self, start, end):
        def as_dt(d):
            return d if isinstance(d, datetime) else datetime.combine(d, datetime.min.time(), ROME)
        return [e for e in self.store.values() if as_dt(e.start) < end and as_dt(e.end) > start]

    def get(self, uid):
        return self.store.get(uid)

    def create(self, calendar, title, start, end, location="", notes=""):
        ev = CalEvent(f"new-{len(self.store)}", calendar, title, start, end, location, notes)
        self.store[ev.uid] = ev
        return ev

    def move(self, uid, start, end):
        if self.store[uid].recurring:
            raise RecurringEventError("recurring")
        self.store[uid] = replace(self.store[uid], start=start, end=end)
        return self.store[uid]

    def delete(self, uid):
        del self.store[uid]


def at(day, hour, minute=0):
    return datetime(2026, 10, day, hour, minute, tzinfo=ROME)


DENTIST = CalEvent("d1", "Home", "Dentist", at(20, 15), at(20, 16), location="Via Roma 1")
STANDUP = CalEvent("s1", "Work", "Standup", at(20, 9), at(20, 9, 15), recurring=True)
TRIP = CalEvent("t1", "Home", "Trip", date(2026, 10, 22), date(2026, 10, 25))


@pytest.fixture
def cal():
    return FakeCalendar([DENTIST, STANDUP, TRIP])


@pytest.fixture
def tools(cal):
    return ToolRegistry(calendar_tools(cal, ROME, default_calendar="Home"))


async def test_list_events_sorted_and_formatted(tools):
    out = await tools.call("list_events", {"start_date": "2026-10-20", "end_date": "2026-10-23"})
    lines = [l for l in out.splitlines() if l.startswith("[")]
    assert lines == [
        "[s1] Tue 20 Oct 09:00–09:15 Standup (Work) · recurring",
        "[d1] Tue 20 Oct 15:00–16:00 Dentist (Home) @ Via Roma 1",
        "[t1] Thu 22 Oct–Sat 24 Oct (all day) Trip (Home)",
    ]


def test_create_event_requires_calendar(tools):
    schema = next(d for d in tools.definitions() if d["name"] == "create_event")["input_schema"]
    assert "calendar" in schema["required"]


async def test_list_events_rejects_huge_range(tools):
    with pytest.raises(ValueError, match="at most"):
        await tools.call("list_events", {"start_date": "2026-01-01", "end_date": "2026-12-31"})


async def test_list_calendars_marks_default(tools):
    assert await tools.call("list_calendars", {}) == "Home (default)\nWork"


async def test_create_uses_local_time(tools, cal):
    out = await tools.call("create_event", {"title": "Gym", "start": "2026-10-21T18:00", "end": "2026-10-21T19:00",
                                            "calendar": "Home"})
    ev = cal.store["new-3"]
    assert ev.calendar == "Home" and ev.start == at(21, 18)
    assert out == "Created: [new-3] Wed 21 Oct 18:00–19:00 Gym (Home)"


async def test_single_all_day_event_end_is_inclusive(tools, cal):
    await tools.call("create_event", {"title": "Holiday", "start": "2026-11-01", "end": "2026-11-01", "calendar": "Home"})
    ev = cal.store["new-3"]
    assert (ev.start, ev.end) == (date(2026, 11, 1), date(2026, 11, 2))


async def test_create_rejects_end_before_start(tools):
    with pytest.raises(ValueError):
        await tools.call("create_event", {"title": "x", "start": "2026-10-21T18:00", "end": "2026-10-21T17:00", "calendar": "Home"})


# -- confirmation flow through the agent ---------------------------------------


class Block(SimpleNamespace):
    def to_dict(self):
        return dict(vars(self))


class FakeClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    async def _create(self, **kwargs):
        self.requests.append(kwargs)
        stop_reason, content = self.responses.pop(0)
        return SimpleNamespace(stop_reason=stop_reason, content=content)


def agent_with(tools, responses):
    db = Database(":memory:")
    return Agent(FakeClient(responses), db, tools, model="m"), db


def call(name, **input):
    return [Block(type="tool_use", id="t1", name=name, input=input)]


def done(text="ok"):
    return ("end_turn", [Block(type="text", text=text)])


async def test_delete_waits_for_yes(tools, cal):
    agent, db = agent_with(tools, [("tool_use", call("delete_event", event_id="d1")), done("Queued.")])
    await agent.reply("discord", "delete the dentist")
    assert "d1" in cal.store  # not deleted yet
    assert agent.pending("discord") == ["Delete 'Dentist' on Tue 20 Oct 15:00–16:00 (Home)"]

    result = await agent.confirm("discord")
    assert result == "✓ Deleted: Dentist, Tue 20 Oct 15:00–16:00"
    assert "d1" not in cal.store
    assert agent.pending("discord") == []


async def test_no_cancels(tools, cal):
    agent, _ = agent_with(tools, [("tool_use", call("move_event", event_id="d1", new_start="2026-10-21T10:00",
                                                     new_end="2026-10-21T11:00")), done()])
    await agent.reply("discord", "move it")
    assert agent.pending("discord") == ["Move 'Dentist' from Tue 20 Oct 15:00–16:00 to Wed 21 Oct 10:00–11:00"]
    assert await agent.cancel("discord") == "Cancelled. Nothing was changed."
    assert cal.store["d1"].start == at(20, 15)
    assert await agent.confirm("discord") == "Nothing is waiting for confirmation."


async def test_recurring_event_is_refused_before_queueing(tools):
    agent, _ = agent_with(tools, [("tool_use", call("delete_event", event_id="s1")), done()])
    await agent.reply("discord", "delete standup")
    assert agent.pending("discord") == []
    result = agent.client.requests[1]["messages"][-1]["content"][0]
    assert result["is_error"] and "recurring" in result["content"]


async def test_pending_actions_expire(tools, cal):
    agent, db = agent_with(tools, [("tool_use", call("delete_event", event_id="d1")), done()])
    await agent.reply("discord", "delete")
    old = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    db.conn.execute("UPDATE pending_actions SET created_at = ?", (old,))
    assert agent.pending("discord") == []
    assert await agent.confirm("discord") == "Nothing is waiting for confirmation."
    assert "d1" in cal.store


async def test_confirmation_is_recorded_in_history(tools):
    agent, db = agent_with(tools, [("tool_use", call("delete_event", event_id="d1")), done()])
    await agent.reply("discord", "delete")
    await agent.confirm("discord")
    conv = db.current_conversation("discord", timedelta(hours=1))
    assert db.history(conv)[-1]["content"].startswith("[The user replied !yes.")


# -- iCalendar parsing ------------------------------------------------------------


def test_parse_component_with_duration_and_rrule():
    ev = icalendar.Event()
    ev.add("uid", "abc")
    ev.add("summary", "Yoga")
    ev.add("dtstart", at(19, 7))
    ev.add("duration", timedelta(minutes=45))
    ev.add("rrule", {"freq": "weekly"})
    parsed = _event_from_component(ev, "Home")
    assert parsed.end == at(19, 7, 45) and parsed.recurring and parsed.title == "Yoga"


async def test_new_move_replaces_earlier_queued_move(tools, cal):
    move = lambda start, end: ("tool_use", call("move_event", event_id="d1", new_start=start, new_end=end))
    agent, db = agent_with(tools, [move("2026-10-21T10:00", "2026-10-21T11:00"), done(),
                                   move("2026-10-21T14:00", "2026-10-21T15:00"), done()])
    await agent.reply("discord", "move dentist to 10")
    await agent.reply("discord", "no, make it 2pm")
    assert agent.pending("discord") == ["Move 'Dentist' from Tue 20 Oct 15:00–16:00 to Wed 21 Oct 14:00–15:00"]
    result = agent.client.requests[3]["messages"][-1]["content"][0]["content"]
    assert "replaces the change queued earlier" in result
    await agent.confirm("discord")
    assert cal.store["d1"].start == at(21, 14)


def test_migration_backfills_target(tmp_path):
    import sqlite3
    path = tmp_path / "old.db"
    old = sqlite3.connect(path)
    old.execute("CREATE TABLE pending_actions (id INTEGER PRIMARY KEY, channel TEXT NOT NULL, tool TEXT NOT NULL, "
                "args TEXT NOT NULL, summary TEXT NOT NULL, created_at TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending')")
    old.execute("INSERT INTO pending_actions (channel, tool, args, summary, created_at) VALUES "
                "('discord', 'move_event', '{\"event_id\": \"d1\"}', 's', '2026-01-01')")
    old.commit(); old.close()
    db = Database(path)
    assert db.conn.execute("SELECT target FROM pending_actions").fetchone()[0] == "d1"
