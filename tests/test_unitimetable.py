"""The lecture timetable from the university's planner (unitimetable.py)."""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import httpx
import pytest

from aide.icloud import CalEvent
from aide.unitimetable import UniTimetable, course_for, parse, timetable_tools

ROME = ZoneInfo("Europe/Rome")


def item(name, start, end, room="Aula 01", teacher=("Marco", "Scarabelli"), state="P"):
    return {"nome": name, "dataInizio": start, "dataFine": end, "stato": state, "indisponibilita": False,
            "evento": {"tipoAttivita": {"descrizione": "Lezione"}},
            "risorse": [{"aula": {"descrizione": room}}, {"docente": {"nome": teacher[0], "cognome": teacher[1]}}]}


WEEK = [
    item("BUSINESS LAW", "2026-11-09T10:00:00.000Z", "2026-11-09T13:00:00.000Z"),
    item("MATHEMATICS FOR ECONOMICS II", "2026-11-09T13:00:00.000Z", "2026-11-09T16:00:00.000Z", "Aula Rosa",
         ("Paolo", "TURIGLIATTO")),
    item("MACROECONOMICS", "2026-11-10T07:00:00.000Z", "2026-11-10T10:00:00.000Z"),
    item("MACROECONOMICS", "2026-11-11T07:00:00.000Z", "2026-11-11T10:00:00.000Z", state="A"),
]


def test_parse_reads_times_rooms_and_teachers():
    first, maths, macro, cancelled = parse(WEEK, ROME)
    assert (first.name, first.start.hour, first.end.hour) == ("BUSINESS LAW", 11, 14)  # UTC to Rome
    assert maths.rooms == ("Aula Rosa",) and maths.teachers == ("Paolo Turigliatto",)
    assert not macro.cancelled and cancelled.cancelled


def test_a_planner_name_is_the_course_in_the_calendar():
    courses = ["business law", "maths for economics II", "macroeconomics", "Business law study"]
    assert course_for("MATHEMATICS FOR ECONOMICS II", courses) == "maths for economics II"
    assert course_for("BUSINESS LAW", courses) == "business law"
    assert course_for("MATHEMATICS FOR ECONOMICS I", courses) is None  # I isn't II
    assert course_for("PUBLIC LAW FOR ECONOMICS", courses) is None


class Study:
    study_calendar = "Work"

    async def courses(self):
        return [{"name": n} for n in ("business law", "maths for economics II", "macroeconomics")]


class Cal:
    def __init__(self, events=()):
        self.made, self.have = [], list(events)

    def events(self, start, end):
        return [e for e in self.have if start <= e.start < end]

    def create(self, calendar, title, start, end, location="", notes=""):
        ev = CalEvent(f"u{len(self.made)}", calendar, title, start, end, location, notes)
        self.made.append(ev)
        return ev


def planner(answer):
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200, json=answer)
    return UniTimetable("link1", ROME, httpx.AsyncClient(transport=httpx.MockTransport(handler))), seen


async def test_the_tool_reads_a_week_and_adds_what_is_missing():
    timetable, seen = planner(WEEK)
    business = datetime(2026, 11, 9, 11, tzinfo=ROME)
    cal = Cal([CalEvent("old", "Work", "business law", business, business + timedelta(hours=3), "", "")])
    (tool,) = timetable_tools(timetable, Study(), cal, ROME)
    out = await tool.handler(start_date="2026-11-09", add=True)
    body = seen[0].read().decode()
    assert '"linkCalendarioId":"link1"' in body.replace(" ", "") and "2026-11-08T23:00:00.000Z" in body
    assert "business law, Aula 01, Marco Scarabelli: already in the calendar" in out
    assert "Mon 09 Nov 14:00–17:00 maths for economics II (the planner: MATHEMATICS FOR ECONOMICS II)" in out
    assert "macroeconomics, Aula 01, Marco Scarabelli: CANCELLED" in out
    assert [(e.title, e.start.hour, e.notes) for e in cal.made] == [
        ("maths for economics II", 14, "Aula Rosa · Paolo Turigliatto"),
        ("macroeconomics", 8, "Aula 01 · Marco Scarabelli")]
    assert "Added 2 to the Work calendar; 1 were already there." in out
    assert [e["change"] for e in out.attachment["events"]] == ["created", "created"]


async def test_without_add_nothing_is_added():
    timetable, _ = planner(WEEK)
    cal = Cal()
    (tool,) = timetable_tools(timetable, Study(), cal, ROME)
    out = await tool.handler(start_date="2026-11-09")
    assert cal.made == [] and "added" not in out.lower()


async def test_an_empty_week_says_why():
    timetable, _ = planner([])
    (tool,) = timetable_tools(timetable, Study(), Cal(), ROME)
    assert "no lectures" in await tool.handler(start_date="2026-12-21")
