"""The user's lecture timetable, from the university's own planner: UniTo publishes each degree year's timetable as a
public calendar in University Planner (Cineca), read here through the planner's API with no login.

AIDE_UNITO_TIMETABLE is that calendar's link id: the `linkCalendarioId=…` at the end of the degree site's schedule
link (efds.unito.it → Timetable → "Second year schedule"). Each academic year the site links a new one.

`uni_timetable` reads a week of it and, when asked, adds the lectures that aren't there yet to the study calendar,
each titled with the course's name as the study calendar already has it (lectures are filed under it), so the
model never retypes a title or adds one twice.
"""

import asyncio
import difflib
import logging
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import httpx

log = logging.getLogger(__name__)

BASE = "https://unito.prod.up.cineca.it/api"
CLIENT = "5852fd1ab7305612a8354d51"  # UniTo in University Planner (/Clienti/cercaPerDominio)
MAX_DAYS = 14
SAME = 0.8  # how alike a planner name and a course's name must be to be the same course (difflib's ratio)


@dataclass(frozen=True)
class Lecture:
    name: str  # as the planner writes it: "MATHEMATICS FOR ECONOMICS II"
    start: datetime
    end: datetime
    rooms: tuple[str, ...]
    teachers: tuple[str, ...]
    cancelled: bool
    kind: str  # "Lezione", "Esercitazione", …


def parse(items: list[dict], tz: ZoneInfo) -> list[Lecture]:
    out = []
    for e in items:
        if e.get("indisponibilita"):
            continue
        ev = e.get("evento") or {}
        name = e.get("nome") or (ev.get("dettagliDidattici") or [{}])[0].get("nome") or "Lecture"
        rooms = tuple(dict.fromkeys(r["aula"]["descrizione"] for r in e.get("risorse") or [] if r.get("aula")))
        teachers = tuple(dict.fromkeys(
            " ".join(filter(None, (d.get("nome"), d.get("cognome")))).title()
            for r in e.get("risorse") or [] if (d := r.get("docente"))))
        at = [datetime.fromisoformat(e[k].replace("Z", "+00:00")).astimezone(tz) for k in ("dataInizio", "dataFine")]
        kind = ((ev.get("tipoAttivita") or {}).get("descrizione") or "").strip()
        out.append(Lecture(" ".join(name.split()), at[0], at[1], rooms, teachers, e.get("stato") == "A", kind))
    return sorted(out, key=lambda l: (l.start, l.name))


def course_for(name: str, courses: list[str]) -> str | None:
    """The course in the study calendar this planner name is ("MATHEMATICS FOR ECONOMICS II" is "maths for
    economics II"), or None. A Roman numeral at the end must match exactly: I and II are different courses."""
    def tail(s: str) -> str:
        last = s.split()[-1].casefold() if s.split() else ""
        return last if set(last) <= set("ivx") else ""

    want = name.casefold()
    best, score = None, 0.0
    for c in courses:
        if tail(c) != tail(name):
            continue
        r = difflib.SequenceMatcher(None, want, c.casefold()).ratio()
        if r > score:
            best, score = c, r
    return best if score >= SAME else None


class UniTimetable:
    def __init__(self, link: str, tz: ZoneInfo, http: httpx.AsyncClient | None = None):
        self.link, self.tz = link, tz
        self._http = http or httpx.AsyncClient(timeout=20)

    async def lectures(self, start: date, end: date) -> list[Lecture]:
        """The lectures from `start` to `end` (both included)."""
        first = datetime.combine(start, time.min, self.tz).astimezone(ZoneInfo("UTC"))
        last = datetime.combine(end + timedelta(days=1), time.min, self.tz).astimezone(ZoneInfo("UTC"))
        r = await self._http.post(f"{BASE}/Impegni/getImpegniCalendarioPubblico", json={
            "mostraImpegniAnnullati": True, "mostraIndisponibilitaTotali": False, "linkCalendarioId": self.link,
            "clienteId": CLIENT, "pianificazioneTemplate": False,
            "dataInizio": first.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "dataFine": last.strftime("%Y-%m-%dT%H:%M:%S.000Z")})
        r.raise_for_status()
        return parse(r.json(), self.tz)


def timetable_tools(timetable: UniTimetable, study, cal, tz: ZoneInfo):
    from .icloud import CalEvent
    from .tools import Tool, ToolOutput
    from .shapes import event_json

    def local(d):
        return d.astimezone(tz) if isinstance(d, datetime) and d.tzinfo else (
            d.replace(tzinfo=tz) if isinstance(d, datetime) else d)

    async def uni_timetable(start_date: str | None = None, days: int | None = None, add: bool = False) -> str:
        today = datetime.now(tz).date()
        start = date.fromisoformat(start_date) if start_date else today - timedelta(days=today.weekday())
        n = max(1, min(days or 7, MAX_DAYS))
        end = start + timedelta(days=n - 1)
        try:
            found = await timetable.lectures(start, end)
        except Exception as e:
            log.warning("uni timetable: %s", e)
            return (f"The university's timetable couldn't be read ({type(e).__name__}). Try again in a minute; "
                    "if it keeps failing, Aide can open it in its browser with an errand.")
        if not found:
            return (f"The university's timetable has no lectures from {start:%a %d %b} to {end:%a %d %b} "
                    "(a holiday, the exam period, or a new academic year: then the degree site links a new "
                    "timetable and AIDE_UNITO_TIMETABLE needs its id).")
        courses = [c["name"] for c in await study.courses()] if study else []
        have: list[CalEvent] = []
        if cal is not None:
            have = [e for e in await asyncio.to_thread(
                cal.events, datetime.combine(start, time.min, tz), datetime.combine(end + timedelta(days=1), time.min, tz))
                    if e.calendar == study.study_calendar and not e.all_day]

        def there(l: Lecture, title: str) -> bool:
            return any(abs(local(e.start) - l.start) < timedelta(minutes=30) and (
                e.title.casefold() == title.casefold() or course_for(l.name, [e.title])) for e in have)

        lines, added, skipped = [], [], 0
        for l in found:
            title = course_for(l.name, courses) or l.name.capitalize()
            where = ", ".join(l.rooms)
            line = (f"{l.start:%a %d %b} {l.start:%H:%M}–{l.end:%H:%M} {title}"
                    + (f" (the planner: {l.name})" if title.casefold() != l.name.casefold() else "")
                    + (f", {where}" if where else "") + (f", {', '.join(l.teachers)}" if l.teachers else "")
                    + (f", {l.kind.lower()}" if l.kind and l.kind != "Lezione" else ""))
            if l.cancelled:
                lines.append(line + ": CANCELLED")
                continue
            if there(l, title):
                lines.append(line + ": already in the calendar")
                skipped += 1
                continue
            if add and cal is not None:
                notes = " · ".join(filter(None, (where, ", ".join(l.teachers))))
                ev = await asyncio.to_thread(cal.create, study.study_calendar, title, l.start, l.end, "", notes)
                added.append(ev)
                lines.append(line + ": added")
            else:
                lines.append(line)
        head = f"The user's lectures from the university's timetable, {start:%a %d %b} to {end:%a %d %b}:"
        foot = []
        if added:
            foot.append(f"Added {len(added)} to the {study.study_calendar} calendar"
                        + (f"; {skipped} were already there." if skipped else "."))
        elif add:
            foot.append("Nothing to add: they're all in the calendar already.")
        text = "\n".join([head, *lines, *foot])
        if added:
            return ToolOutput(text, {"type": "events",
                                     "events": [{**event_json(e, tz), "change": "created"} for e in added]})
        return text

    return [Tool(
        "uni_timetable",
        "The user's lectures from their degree's official timetable (the university's own planner, their year of "
        "their degree): each with day, times, course, room and teachers, cancelled ones marked, and "
        "whether it's already in the study calendar. add=true also puts the missing ones in the study calendar "
        "(titled with the course's name, the room and teachers in the notes), never twice. Default: this week.",
        {"type": "object", "additionalProperties": False, "required": [], "properties": {
            "start_date": {"type": "string", "description": "YYYY-MM-DD, the first day (default: this Monday)"},
            "days": {"type": "integer", "description": f"how many days (default 7, at most {MAX_DAYS})"},
            "add": {"type": "boolean", "description": "true to add the missing lectures to the study calendar"},
        }},
        uni_timetable,
        step=lambda a: "Adding your lectures to the calendar" if a.get("add") else "Reading the uni timetable",
    )]
