"""Esse3, the university's own record (#74, read-only): exam sessions with their sign-up windows, what the user is
signed up for, and the transcript. Read through `unito.py` with the login saved in Settings → Passwords, no model.

Three pages, four times a day (and when the app asks, at most every 10 min):
- `Appelli/Appelli.do`: the sessions of every course in the study plan, each with its sign-up window and whether
  sign-up is open now (the row links to the booking page then);
- `Appelli/BachecaPrenotazioni.do`: the sessions signed up for;
- `Libretto/LibrettoHome.do`: the transcript (code, credits, passed or planned, grade and date).

Each session becomes official dates of its Aide course (`NotebookStore.set_official_dates`): the exam, and the
sign-up's opening and closing, so the exam plan, Professor and the course page see them. Esse3's course is matched to
an Aide course through Moodle's (the same course code), else by its name's words. When a session's sign-up opens, a
push says so once. Booking is a later step, behind Confirm.
"""

import asyncio
import hashlib
import json
import logging
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from html.parser import HTMLParser
from urllib.parse import urljoin

from . import activity
from .db import utcnow
from .moodle import MoodleSync
from .unito import SITE, LoginFailed, NoLogin, UnitoSession

log = logging.getLogger(__name__)

BASE = "https://esse3.unito.it/"
EXAMS = BASE + "auth/studente/Appelli/Appelli.do"
BOOKED = BASE + "auth/studente/Appelli/BachecaPrenotazioni.do"
TRANSCRIPT = BASE + "auth/studente/Libretto/LibrettoHome.do"
EVERY = timedelta(hours=6)
ASKED = timedelta(minutes=10)  # the app's "read now" when one was this recent: what's kept

SCHEMA = """
CREATE TABLE IF NOT EXISTS esse3_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS esse3_exams (  -- the sessions Esse3 lists now, replaced on every read
    key       TEXT PRIMARY KEY,  -- the course's name and the date
    course    TEXT NOT NULL,     -- Esse3's name, "MATHEMATICS FOR ECONOMICS II"
    code      TEXT,              -- "SEM0251", from the transcript
    course_id INTEGER,           -- the Aide course
    day       TEXT NOT NULL,     -- "2026-12-04"
    time      TEXT,
    opens     TEXT,              -- the sign-up window, days
    closes    TEXT,
    open      INTEGER NOT NULL DEFAULT 0,
    booked    INTEGER NOT NULL DEFAULT 0,
    teachers  TEXT NOT NULL DEFAULT '',
    link      TEXT               -- the booking page's address, while sign-up is open
);
CREATE TABLE IF NOT EXISTS esse3_courses (  -- the transcript
    code      TEXT PRIMARY KEY,  -- "SEM0251"
    name      TEXT NOT NULL,
    year      INTEGER,
    credits   REAL,
    status    TEXT NOT NULL,     -- passed, planned, attended, or Esse3's word
    grade     TEXT,              -- "28", "30L", "IDO"
    passed_on TEXT,              -- "2026-01-30"
    attended  TEXT,              -- the academic year attended, "2025/2026"
    course_id INTEGER
);
"""

STATUSES = {"superata": "passed", "pianificata": "planned", "frequentata": "attended"}
_DAY = re.compile(r"(\d{2})/(\d{2})/(\d{4})")
_TIME = re.compile(r"\b(\d{1,2})[:.](\d{2})\b")
_CODE = re.compile(r"^\s*([A-Z]{2,}[0-9][0-9A-Z]*)\s*-\s*(.+?)\s*$")


# -- reading the pages --------------------------------------------------------------------


@dataclass
class Cell:
    text: str = ""
    links: list[str] = field(default_factory=list)
    imgs: list[str] = field(default_factory=list)  # alt or title


@dataclass
class Table:
    id: str | None
    rows: list[list[Cell]] = field(default_factory=list)
    header: list[str] = field(default_factory=list)


class _Tables(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables: list[Table] = []
        self._stack: list[Table] = []
        self._row: list[Cell] | None = None
        self._cell: Cell | None = None
        self._head = False
        self._skip = 0  # inside script or style

    def handle_starttag(self, tag, attrs):
        a = {k: v or "" for k, v in attrs}
        if tag in ("script", "style"):
            self._skip += 1
        elif tag == "table":
            self._stack.append(Table(a.get("id") or None))
            self.tables.append(self._stack[-1])
        elif not self._stack:
            return
        elif tag == "tr":
            self._row, self._head = [], False
        elif tag in ("td", "th") and self._row is not None:
            self._cell = Cell()
            self._head = self._head or tag == "th"
        elif self._cell is not None:
            if tag == "br":
                self._cell.text += "\n"
            elif tag == "a" and a.get("href"):
                self._cell.links.append(a["href"])
            elif tag == "img" and (a.get("alt") or a.get("title")):
                self._cell.imgs.append(a.get("alt") or a.get("title"))

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = max(0, self._skip - 1)
        elif tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._cell.text = "\n".join(" ".join(line.split()) for line in self._cell.text.split("\n")).strip()
            self._row.append(self._cell)
            self._cell = None
        elif tag == "tr" and self._row is not None and self._stack:
            if self._head and not self._stack[-1].header:
                self._stack[-1].header = [" ".join(c.text.split()).casefold() for c in self._row]
            elif self._row:
                self._stack[-1].rows.append(self._row)
            self._row = None
        elif tag == "table" and self._stack:
            self._stack.pop()

    def handle_data(self, data):
        if self._cell is not None and not self._skip:
            self._cell.text += data.replace("​", "")


def tables(html: str) -> list[Table]:
    p = _Tables()
    p.feed(html)
    p.close()
    return p.tables


def _col(table: Table, *names: str) -> int | None:
    return next((i for i, h in enumerate(table.header) if any(h.startswith(n) for n in names)), None)


def _cell(row: list[Cell], i: int | None) -> Cell:
    return row[i] if i is not None and i < len(row) else Cell()


def _days(text: str) -> list[str]:
    return [f"{y}-{m}-{d}" for d, m, y in _DAY.findall(text)]


def _clock(text: str) -> str | None:
    m = _TIME.search(_DAY.sub("", text))
    return f"{int(m[1]):02d}:{m[2]}" if m and int(m[1]) < 24 and int(m[2]) < 60 else None


def read_exams(html: str) -> list[dict]:
    """Appelli.do: [{course, day, time, opens, closes, open, teachers, link}]."""
    out = []
    for t in tables(html):
        course_i, day_i = _col(t, "attività didattica"), _col(t, "appello")
        if course_i is None or day_i is None:
            continue
        signup_i, teachers_i = _col(t, "iscrizione"), _col(t, "docenti")
        for row in t.rows:
            course, when = _cell(row, course_i).text, _cell(row, day_i).text
            if not course or not (days := _days(when)):
                continue
            window = _days(_cell(row, signup_i).text)
            booking = next((link for c in row for link in c.links if "DatiPrenotazioneAppello" in link), None)
            out.append({"course": " ".join(course.split()), "day": days[0], "time": _clock(when),
                        "opens": window[0] if window else None, "closes": window[1] if len(window) > 1 else None,
                        "open": booking is not None, "teachers": " ".join(_cell(row, teachers_i).text.split()),
                        "link": urljoin(BASE, booking) if booking else None})
    return out


def read_booked(html: str, exams: list[dict]) -> set[str]:
    """BachecaPrenotazioni.do: the keys of the sessions signed up for. Every row (or block) naming a listed course
    and its date counts; the page says "Nessun appello prenotato" when there are none."""
    text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", re.sub(r"(?s)<(script|style).*?</\1>", "", html))).casefold()
    if "nessun appello prenotato" in text:
        return set()
    found = set()
    for t in tables(html):
        for row in t.rows:
            line = " ".join(c.text for c in row).casefold()
            for e in exams:
                if e["course"].casefold() in line and e["day"] in _days(line):
                    found.add(_key(e))
    return found


def read_transcript(html: str) -> list[dict]:
    """LibrettoHome.do: [{code, name, year, credits, status, grade, passed_on, attended}]."""
    out = []
    for t in tables(html):
        name_i = _col(t, "attività didattiche", "attività didattica")
        if name_i is None or _col(t, "stato") is None:
            continue
        year_i, credits_i, status_i = _col(t, "anno"), _col(t, "peso"), _col(t, "stato")
        attended_i, grade_i = _col(t, "aa freq"), _col(t, "voto")
        for row in t.rows:
            m = _CODE.match(_cell(row, name_i).text.split("\n")[0])
            if not m:
                continue
            status = (_cell(row, status_i).imgs or [_cell(row, status_i).text] or [""])[0].strip()
            graded = _cell(row, grade_i).text.replace("\xa0", " ")
            days = _days(graded)
            grade = graded.split(" - ")[0].strip() if days else (graded.strip() or None)
            year, credits = _cell(row, year_i).text, _cell(row, credits_i).text.replace(",", ".")
            out.append({"code": m[1], "name": " ".join(m[2].split()),
                        "year": int(year) if year.isdigit() else None,
                        "credits": float(credits) if re.fullmatch(r"\d+(\.\d+)?", credits) else None,
                        "status": STATUSES.get(status.casefold(), status.casefold() or "unknown"),
                        "grade": grade or None, "passed_on": days[0] if days else None,
                        "attended": _cell(row, attended_i).text.strip() or None})
    return out


def _key(e: dict) -> str:
    return f"{e['course'].casefold()}|{e['day']}"


def _short(day: str) -> str:
    d = date.fromisoformat(day)
    return f"{d.day} {d:%b}"


# -- the reader ---------------------------------------------------------------------------


class Esse3Reader:
    def __init__(self, session: UnitoSession, study, notebook=None, push=None):
        self.session = session
        self.study = study
        self.notebook = notebook  # NotebookStore: the sessions become official course dates
        self.push = push
        self.conn = study.conn
        self.conn.executescript(SCHEMA)
        self._wake = asyncio.Event()
        self._lock = asyncio.Lock()

    def _get(self, key: str) -> str | None:
        row = self.conn.execute("SELECT value FROM esse3_state WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else None

    def _set(self, key: str, value: str | None) -> None:
        if value is None:
            self.conn.execute("DELETE FROM esse3_state WHERE key = ?", (key,))
        else:
            self.conn.execute("INSERT INTO esse3_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET "
                              "value = excluded.value", (key, value))

    def kick(self) -> None:
        self._wake.set()

    def login_changed(self, sites: list[str]) -> None:
        """A password was saved or changed: when it's UniTo's, log in afresh and read now."""
        if SITE in sites:
            self.session.reset()
            self.kick()

    def ready(self) -> bool:
        try:
            self.session.entry()
        except NoLogin:
            return False
        return True

    async def run(self) -> None:
        while True:
            woken = self._wake.is_set()
            self._wake.clear()
            last = self._get("last_try")
            due = not last or datetime.now(timezone.utc) - datetime.fromisoformat(last) >= EVERY
            if (due or woken) and self.ready():
                try:
                    await self.read()
                except Exception:
                    log.exception("Esse3 read failed")
            try:
                await asyncio.wait_for(self._wake.wait(), 600)
            except asyncio.TimeoutError:
                pass

    async def read_if_stale(self) -> dict:
        """The app's read now (Study opening): read unless one finished in the last 10 min."""
        last = self._get("last_read")
        if last and datetime.now(timezone.utc) - datetime.fromisoformat(last) < ASKED:
            return self.status()
        if self.ready():
            await self.read()
        return self.status()

    async def read(self) -> dict:
        async with self._lock:
            self._set("last_try", utcnow().isoformat())
            try:
                was_in = self.session.logged_in
                exams_html = (await self.session.get(EXAMS)).text
                if not was_in:  # a login may land on Esse3's home rather than the page asked for
                    exams_html = (await self.session.get(EXAMS)).text
                booked_html = (await self.session.get(BOOKED)).text
                transcript_html = (await self.session.get(TRANSCRIPT)).text
            except NoLogin:
                self._set("error", None)
                return self.status()
            except LoginFailed as e:
                self._set("error", json.dumps({"kind": e.kind, "message": str(e)}))
                return self.status()
            exams = read_exams(exams_html)
            booked = read_booked(booked_html, exams)
            transcript = read_transcript(transcript_html)
            if not exams and not transcript:
                self._set("error", json.dumps({"kind": "page", "message": "Esse3's pages had nothing Aide can read"}))
                log.warning("esse3: pages without the tables")
                return self.status()
            await self._save(exams, booked, transcript)
            self._set("last_read", utcnow().isoformat())
            self._set("error", None)
            log.info("esse3: %d sessions, %d signed up, %d courses", len(exams), len(booked), len(transcript))
            return self.status()

    # -- saving ----------------------------------------------------------------------------

    async def _course_ids(self, names: list[str], transcript: list[dict]) -> dict[str, int | None]:
        """Esse3's course names to Aide courses: through the Moodle course with the same code, else by words."""
        codes = {t["name"].casefold(): t["code"] for t in transcript}
        try:
            moodle = [dict(r) for r in self.conn.execute(
                "SELECT name, course_id FROM moodle_courses WHERE course_id IS NOT NULL")]
        except Exception:  # no Moodle tables
            moodle = []
        try:
            aide = await self.study.courses()
        except Exception:
            log.exception("esse3: couldn't list the courses")
            aide = []
        out = {}
        for name in names:
            code = codes.get(name.casefold())
            by_code = [m["course_id"] for m in moodle if code and re.search(rf"\b{re.escape(code)}\b", m["name"])]
            out[name] = (by_code[0] if len(set(by_code)) == 1
                         else MoodleSync._guess({"name": name, "short": code or ""}, aide))
        return out

    async def _save(self, exams: list[dict], booked: set[str], transcript: list[dict]) -> None:
        ids = await self._course_ids(sorted({e["course"] for e in exams} | {t["name"] for t in transcript}),
                                     transcript)
        codes = {t["name"].casefold(): t["code"] for t in transcript}
        before = {r["key"]: dict(r) for r in self.conn.execute("SELECT * FROM esse3_exams")}
        self.conn.execute("DELETE FROM esse3_exams")
        for e in exams:
            self.conn.execute(
                "INSERT OR REPLACE INTO esse3_exams (key, course, code, course_id, day, time, opens, closes, open, "
                "booked, teachers, link) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (_key(e), e["course"], codes.get(e["course"].casefold()), ids.get(e["course"]), e["day"], e["time"],
                 e["opens"], e["closes"], int(e["open"]), int(_key(e) in booked), e["teachers"], e["link"]))
        self.conn.execute("DELETE FROM esse3_courses")
        for t in transcript:
            self.conn.execute(
                "INSERT OR REPLACE INTO esse3_courses (code, name, year, credits, status, grade, passed_on, attended, "
                "course_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (t["code"], t["name"], t["year"], t["credits"], t["status"], t["grade"], t["passed_on"],
                 t["attended"], ids.get(t["name"])))
        if self.notebook is not None:
            self._dates()
        await self._tell(before)

    def _dates(self) -> None:
        """Every Aide course's sessions as official dates (a course with none left gets an empty list)."""
        by_course: dict[int, list[dict]] = {}
        for e in self.exams():
            if e["course_id"] is None:
                continue
            items = by_course.setdefault(e["course_id"], [])
            when = _short(e["day"])
            teachers = f"Teachers: {e['teachers']}." if e["teachers"] else ""
            window = (f" Sign-up on MyUniTo {_short(e['opens'])}–{_short(e['closes'])}."
                      if e["opens"] and e["closes"] else "")
            you = ("Signed up on Esse3" if e["booked"] else
                   f"Sign-up open on MyUniTo until {_short(e['closes'])}" if e["open"] and e["closes"] else
                   "Sign-up open on MyUniTo" if e["open"] else None)
            items.append({"id": _id("exam", e), "what": "Exam", "kind": "exam", "date": e["day"], "time": e["time"],
                          "you": you, "details": (teachers + window).strip(), "source": "Esse3"})
            if e["opens"]:
                items.append({"id": _id("opens", e), "what": f"Sign-up opens for the {when} exam", "kind": "other",
                              "date": e["opens"], "details": "On MyUniTo, Appelli disponibili.", "source": "Esse3"})
            if e["closes"]:
                items.append({"id": _id("closes", e), "what": f"Sign-up closes for the {when} exam",
                              "kind": "deadline", "date": e["closes"],
                              "you": "Signed up" if e["booked"] else None,
                              "details": "On MyUniTo, Appelli disponibili.", "source": "Esse3"})
        known = {r[0] for r in self.conn.execute("SELECT course_id FROM official_dates")}
        for course_id in known | set(by_course):
            self.notebook.set_official_dates(course_id, by_course.get(course_id, []))

    async def _tell(self, before: dict[str, dict]) -> None:
        """A push the first time a session's sign-up is seen open (and not signed up for)."""
        told = set(json.loads(self._get("told") or "[]"))
        for e in self.exams():
            if not e["open"] or e["booked"] or e["key"] in told:
                continue
            told.add(e["key"])
            name = self._name(e)
            title = f"Sign-up open: {name}"
            body = (f"The {_short(e['day'])} exam" + (f", until {_short(e['closes'])}" if e["closes"] else "")
                    + ". Sign up on MyUniTo.")
            activity.record(self.conn, "professor", "study", f"Sign-up open for {name}'s {_short(e['day'])} exam")
            if self.push is not None:
                try:
                    await self.push.send_esse3(title, body, e["course_id"])
                except Exception:
                    log.exception("esse3: push failed")
        keep = {r[0] for r in self.conn.execute("SELECT key FROM esse3_exams")}
        self._set("told", json.dumps(sorted(told & keep)))

    def _name(self, e: dict) -> str:
        course = self.study.course(e["course_id"]) if e.get("course_id") else None
        name = course["name"] if course else e["course"].title()
        return name[:1].upper() + name[1:]

    # -- what's kept -----------------------------------------------------------------------

    def exams(self) -> list[dict]:
        return [dict(r) | {"open": bool(r["open"]), "booked": bool(r["booked"])} for r in self.conn.execute(
            "SELECT * FROM esse3_exams ORDER BY day, course")]

    def transcript(self) -> list[dict]:
        return [dict(r) for r in self.conn.execute("SELECT * FROM esse3_courses ORDER BY year, name")]

    def status(self) -> dict:
        """{connected: a UniTo password is saved, read_at, error: {kind, message} or None}."""
        error = json.loads(self._get("error") or "null")
        try:
            entry = self.session.entry()
        except NoLogin:
            entry = None
        if entry is not None and entry["status"] in ("wrong", "needs_you") and not error:
            error = {"kind": entry["status"], "message": "the UniTo login needs you (Settings → Passwords)"}
        return {"connected": entry is not None, "read_at": self._get("last_read"), "error": error}

    def json(self) -> dict:
        transcript = self.transcript()
        passed = [t for t in transcript if t["status"] == "passed"]
        graded = [int(t["grade"][:2]) for t in passed if t["grade"] and t["grade"][:2].isdigit()]
        weights = [t["credits"] or 0 for t in passed if t["grade"] and t["grade"][:2].isdigit()]
        average = (round(sum(g * w for g, w in zip(graded, weights)) / sum(weights), 2) if sum(weights) else None)
        return {**self.status(),
                "exams": [{k: e[k] for k in ("course", "code", "course_id", "day", "time", "opens", "closes", "open",
                                             "booked", "teachers")} for e in self.exams()],
                "transcript": [{k: t[k] for k in ("code", "name", "year", "credits", "status", "grade", "passed_on",
                                                  "attended", "course_id")} for t in transcript],
                "credits": {"passed": sum(t["credits"] or 0 for t in passed),
                            "total": sum(t["credits"] or 0 for t in transcript)},
                "average": average}


def _id(what: str, e: dict) -> str:
    return "d_e3" + hashlib.sha256(f"{what}|{_key(e)}".encode()).hexdigest()[:10]
