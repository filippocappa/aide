import asyncio
import threading
from datetime import date, datetime, timedelta

from aide import agenda as agenda_mod
from aide.agenda import Agenda, WatchedCalendar
from aide.icloud import CalEvent, Events
from aide.tools import Tool, ToolRegistry
from test_calendar import ROME, FakeCalendar


def at(day, hour, minute=0):
    return datetime(2026, 11, day, hour, minute, tzinfo=ROME)


class Counting(FakeCalendar):
    def __init__(self, events=(), delay=0.0):
        super().__init__(events)
        self.reads, self.delay = 0, delay

    def events(self, start, end):
        self.reads += 1
        if self.delay:
            threading.Event().wait(self.delay)
        return super().events(start, end)


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


LECTURE = CalEvent("l1", "Work", "Macro [lecture]", at(6, 14), at(6, 15, 30), location="Campus Einaudi\nAula 3")
EARLY = CalEvent("e1", "Work", "Gym", at(7, 7), at(7, 8))
NIGHT = CalEvent("n1", "Home", "Night train", at(5, 23), at(6, 7))
TRIP = CalEvent("t1", "Home", "Trip", date(2026, 11, 7), date(2026, 11, 9))
LATER = CalEvent("x1", "Home", "Dinner", at(8, 20), at(8, 22))


async def test_the_line_has_today_tomorrow_and_the_calendars():
    cal = Counting([LECTURE, EARLY, NIGHT, TRIP, LATER])
    agenda = Agenda(cal, ROME, "Work", now=Clock(at(6, 10)))
    line = await agenda.line()
    assert line == ("calendar, read just now: today Fri 06 Nov: (from before)–07:00 Night train (Home), "
                    "14:00–15:30 Macro (lecture) (Work, at Campus Einaudi Aula 3); "
                    "tomorrow Sat 07 Nov: all day Trip (Home), 07:00–08:00 Gym (Work) | "
                    "calendars: Work (default), Home")
    assert "Dinner" not in line and "]" not in line and "\n" not in line


async def test_an_empty_day_says_nothing_and_unread_calendars_are_named():
    class Partial(FakeCalendar):
        def events(self, start, end):
            return Events(super().events(start, end), unread={"Exam"})

    line = await Agenda(Partial(), ROME, now=Clock(at(6, 10))).line()
    assert "today Fri 06 Nov: nothing; tomorrow Sat 07 Nov: nothing | couldn't read Exam just now" in line
    assert line.endswith("calendars: Home (default), Work")


async def test_it_is_kept_and_read_again_in_the_background_when_old():
    cal, clock = Counting([LECTURE]), Clock(at(6, 10))
    agenda = Agenda(cal, ROME, now=clock)
    await agenda.line()
    await agenda.line()
    assert cal.reads == 1
    clock.now += timedelta(minutes=3)  # past FRESH: used, and read again for the next turn
    cal.store[EARLY.uid] = EARLY
    line = await agenda.line()
    assert line.startswith("calendar, read 3 min ago") and "Gym" not in line
    await agenda._reading
    assert cal.reads == 2 and "Gym" in await agenda.line()
    clock.now += timedelta(minutes=20)  # past USABLE: read before the turn
    assert (await agenda.line()).startswith("calendar, read just now") and cal.reads == 3


async def test_a_write_through_aide_drops_what_is_kept():
    cal = Counting([LECTURE])
    agenda = Agenda(cal, ROME, now=Clock(at(6, 10)))
    watched = WatchedCalendar(cal, agenda.changed)
    await agenda.line()
    await asyncio.to_thread(watched.create, "Home", "Dentist", at(7, 9), at(7, 10))
    assert "Dentist" in await agenda.line() and cal.reads == 2
    await asyncio.to_thread(watched.delete, "l1")
    assert "Macro" not in await agenda.line()
    assert watched.calendars() == ["Home", "Work"]  # the rest goes through


async def test_a_new_day_is_read_again():
    cal, clock = Counting([LECTURE]), Clock(at(6, 23, 59))
    agenda = Agenda(cal, ROME, now=clock)
    await agenda.line()
    clock.now = at(7, 0, 1)
    assert "today Sat 07 Nov" in await agenda.line() and cal.reads == 2


async def test_a_slow_calendar_leaves_the_turn_without_it(monkeypatch):
    monkeypatch.setattr(agenda_mod, "WAIT", 0.05)
    cal = Counting([LECTURE], delay=0.3)
    agenda = Agenda(cal, ROME, now=Clock(at(6, 10)))
    assert await agenda.line() is None
    await agenda._reading  # the read goes on and is kept for the next turn
    cal.delay = 0
    assert "Macro" in await agenda.line() and cal.reads == 1


async def test_a_failing_calendar_leaves_the_turn_without_it():
    class Down(FakeCalendar):
        def events(self, start, end):
            raise OSError("iCloud down")

    assert await Agenda(Down(), ROME, now=Clock(at(6, 10))).line() is None


async def test_warm_reads_once_ahead_of_the_call():
    cal = Counting([LECTURE])
    agenda = Agenda(cal, ROME, now=Clock(at(6, 10)))
    agenda.warm()
    await agenda._reading
    agenda.warm()  # fresh: not again
    await agenda.line()
    assert cal.reads == 1


async def list_events(start_date: str, end_date: str) -> str:
    return "No events."


async def test_only_a_spoken_turn_with_the_calendar_gets_it():
    from aide.agent import Agent
    from aide.db import Database
    from test_agent import FakeClient, text

    def done(t):
        return ("end_turn", [text(t)])

    db = Database(":memory:")
    client = FakeClient([done("Macro at 2."), done("title"), done("ok"), done("ok"), done("title")])
    tools = ToolRegistry([Tool("list_events", "Events", {"type": "object", "properties": {}, "required": [],
                                                          "additionalProperties": False}, list_events)])
    agent = Agent(client, db, tools, model="m", delegate=False, tz=ROME)
    agent.agenda = Agenda(Counting([LECTURE]), ROME, now=Clock(at(6, 10)))
    chat = agent.new_conversation(agent="secretary")["id"]

    def stamp(i):
        content = client.requests[i]["messages"][-1]["content"]
        return content if isinstance(content, str) else content[0]["text"]

    await agent.respond("app", "what's on today", chat, voice=True)
    assert "calendar, read just now: today Fri 06 Nov: 14:00–15:30 Macro" in stamp(0)
    await asyncio.gather(*agent._titling)
    await agent.respond("app", "thanks", chat)  # typed: no
    assert "calendar, read" not in stamp(2)
    money = agent.new_conversation(agent="finance")["id"]  # no calendar tools
    await agent.respond("app", "how much this month", money, voice=True)
    assert "calendar, read" not in stamp(3)
    db.close()
