"""Esse3, the university's own record (#74, read-only): exam sessions with their sign-up windows, what the user is
signed up for, and the transcript. Read through `unito.py` with the login saved in Settings → Passwords, no model
(the fast model reads a page once only when the parser finds nothing on a page that has dates).

Three pages, four times a day (and when the app asks, at most every 10 min):
- `Appelli/Appelli.do`: the sessions of every course in the study plan, each with its sign-up window and whether
  sign-up is open now (the row links to the booking page then);
- `Appelli/BachecaPrenotazioni.do`: the sessions signed up for;
- `Libretto/LibrettoHome.do`: the transcript (code, credits, passed or planned, grade and date).

Each session becomes official dates of its Aide course (`NotebookStore.set_official_dates`): the exam, and the
sign-up's opening and closing, so the exam plan and Professor see them; the course page shows the exam, and the
opening and closing become reminders (`datereminders.py`; none once signed up). Esse3's course is matched to an Aide
course through Moodle's (the same course code), else by its name's words. A sign-up seen open with no reminder for its
opening (open already on the first read) is pushed once.

Signing up and cancelling (since 2026-11-07) happen only on the user's tap in the app (`sign_up`, `cancel`), as a
browser errand (#75, `ErrandRunner.start_esse3`): the server's own login handed to Aide's browser as cookies (the
password never reaches the model), the model clicking through Esse3's pages with reading and clicking tools only, and
the tap as the Confirm for at most two clicks that commit, each on a page showing that session (`esse3_mismatch`).
However the errand ends, the bookings page is read here in plain HTTP to decide (`errand_ended`), the browser's UniTo
profile deleted, and the result pushed. Never tried again by itself. A session whose sign-up isn't open
yet is kept as wanted and signed up for on the first read after it opens (reads every 15 min from its opening day),
with a push either way. An exam the user isn't taking (archived in the course's dates) is never signed up for or pushed.
"""

import asyncio
import hashlib
import json
import logging
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from html.parser import HTMLParser
from html import unescape
from urllib.parse import parse_qs, urljoin, urlparse
from zoneinfo import ZoneInfo

from . import activity
from .db import utcnow
from .moodle import MoodleSync
from .tools.pages import open_card
from .unito import SITE, LoginFailed, NoLogin, UnitoSession

log = logging.getLogger(__name__)

OPEN_ERRAND = ("queued", "running", "needs_you", "waiting_confirm", "scheduled", "interrupted")  # errands.OPEN

BASE = "https://esse3.unito.it/"
EXAMS = BASE + "auth/studente/Appelli/Appelli.do"
BOOKED = BASE + "auth/studente/Appelli/BachecaPrenotazioni.do"
TRANSCRIPT = BASE + "auth/studente/Libretto/LibrettoHome.do"
EVERY = timedelta(hours=6)
ASKED = timedelta(minutes=10)  # the app's "read now" when one was this recent: what's kept
WANTED_EVERY = timedelta(minutes=15)  # reads while a wanted session's sign-up has opened today or before

SCHEMA = """
CREATE TABLE IF NOT EXISTS esse3_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS esse3_errands (  -- the errand signing up for or cancelling a session, running or last run
    key       TEXT PRIMARY KEY,
    errand_id INTEGER NOT NULL,
    action    TEXT NOT NULL,     -- book or cancel
    auto      INTEGER NOT NULL DEFAULT 0,  -- started from a wish, when the sign-up opened
    told      TEXT,              -- what the user was last told: done or failed
    chat      TEXT,              -- the chat it was asked from (Professor's sign_up_for_exam): told there too
    at        TEXT NOT NULL
);
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
    link      TEXT,              -- the booking page's address, while sign-up is open
    app_id    TEXT               -- Esse3's id of the session (from that address), kept once seen
);
CREATE TABLE IF NOT EXISTS esse3_wants (  -- sessions to sign up for as soon as the sign-up opens (the user's tap)
    key   TEXT PRIMARY KEY,
    at    TEXT NOT NULL,
    error TEXT                   -- why the last try failed; no more tries until the user taps again
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
                        "link": urljoin(BASE, booking) if booking else None,
                        "app_id": (parse_qs(urlparse(unescape(booking)).query).get("APP_ID") or [None])[0]
                        if booking else None})
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


READ_PROMPT = """You read a page of Esse3, an Italian university's student records, as plain text. Answer with JSON \
only, no prose. For an exams page (Appelli): {"exams": [{"course": "<the course's name as written>", "day": \
"YYYY-MM-DD", "time": "HH:MM" or null, "opens": "YYYY-MM-DD" or null, "closes": "YYYY-MM-DD" or null, "open": \
<true when the page offers to sign up now>}]}. For a bookings page (Bacheca prenotazioni): {"booked": [{"course": \
"<name>", "day": "YYYY-MM-DD"}]}. Only what the page says; an empty list when it lists none."""


def _text(html: str) -> str:
    return re.sub(r"\s+", " ", unescape(re.sub(r"<[^>]+>", " ", re.sub(r"(?s)<(script|style).*?</\1>", "", html))))


def _json(text: str) -> dict:
    m = re.search(r"\{.*\}", text or "", re.S)
    try:
        return json.loads(m.group(0)) if m else {}
    except ValueError:
        return {}


def _iso(day) -> str | None:
    return day if isinstance(day, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", day) else None


class SignUpFailed(Exception):
    """Signing up or cancelling couldn't start; the message is for the user."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind  # closed, page, login


def _key(e: dict) -> str:
    return f"{e['course'].casefold()}|{e['day']}"


def _short(day: str) -> str:
    d = date.fromisoformat(day)
    return f"{d.day} {d:%b}"


# -- the reader ---------------------------------------------------------------------------


class Esse3Reader:
    def __init__(self, session: UnitoSession, study, notebook=None, push=None, tz=ZoneInfo("Europe/Rome"),
                 ask=None):
        self.session = session
        self.ask = ask  # async (system, text) -> str: the fast model, for a page the parser can't read
        self.errands = None  # ErrandRunner: signing up and cancelling (set once the browser is there)
        self.post = None  # Agent.post: a sign-up asked for in a chat is followed and answered there
        self.study = study
        self.notebook = notebook  # NotebookStore: the sessions become official course dates
        self.push = push
        self.tz = tz
        self.conn = study.conn
        self.conn.executescript(SCHEMA)
        for table, column in (("esse3_exams", "app_id"), ("esse3_errands", "chat")):
            try:
                self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} TEXT")
            except sqlite3.OperationalError:
                pass
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
            since = datetime.now(timezone.utc) - datetime.fromisoformat(last) if last else None
            due = since is None or since >= EVERY or (since >= WANTED_EVERY and self._wanted_open())
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
            if await self._read():
                await self._sign_up_wanted()
            return self.status()

    async def _read(self) -> bool:
        """One read of the three pages; True when it went through."""
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
            return False
        except LoginFailed as e:
            self._set("error", json.dumps({"kind": e.kind, "message": str(e)}))
            return False
        exams = read_exams(exams_html) or await self._read_by_model(exams_html, "exams")
        booked = await self._booked(booked_html, exams)
        transcript = read_transcript(transcript_html)
        if not exams and not transcript:
            self._set("error", json.dumps({"kind": "page", "message": "Esse3's pages had nothing Aide can read"}))
            log.warning("esse3: pages without the tables")
            return False
        await self._save(exams, booked, transcript)
        self._set("last_read", utcnow().isoformat())
        self._set("error", None)
        log.info("esse3: %d sessions, %d signed up, %d courses", len(exams), len(booked), len(transcript))
        return True

    async def _read_by_model(self, html: str, what: str) -> list:
        """The fast model's reading of a page the parser found nothing on, when it has dates and doesn't say it's
        empty: the exams in `read_exams`' shape (no booking link: the errand starts from Appelli), or the bookings
        as [{course, day}]. [] without a model or when it fails."""
        text = _text(html)
        if (self.ask is None or not _DAY.search(text) or "nessun appello" in text.casefold()
                or "non ci sono appelli" in text.casefold()):
            return []
        try:
            answer = _json(await self.ask(READ_PROMPT, text[:30000]))
        except Exception:
            log.warning("esse3: the model couldn't read the %s page", what, exc_info=True)
            return []
        log.warning("esse3: the %s page read by the model (the parser found nothing)", what)
        if what == "booked":
            return [{"course": str(b.get("course") or ""), "day": _iso(b.get("day"))}
                    for b in answer.get("booked") or [] if isinstance(b, dict) and b.get("course") and _iso(b.get("day"))]
        out = []
        for e in answer.get("exams") or []:
            if not isinstance(e, dict) or not e.get("course") or not _iso(e.get("day")):
                continue
            is_open = bool(e.get("open"))
            out.append({"course": " ".join(str(e["course"]).split()), "day": e["day"],
                        "time": e["time"] if isinstance(e.get("time"), str) and _TIME.fullmatch(e["time"]) else None,
                        "opens": _iso(e.get("opens")), "closes": _iso(e.get("closes")), "open": is_open,
                        "teachers": "", "link": EXAMS if is_open else None, "app_id": None})
        return out

    async def _booked(self, html: str, exams: list[dict]) -> set[str]:
        """The keys of `exams` signed up for on a bookings page: parsed, else read by the model."""
        found = read_booked(html, exams)
        if found or "nessun appello prenotato" in _text(html).casefold():
            return found
        rows = await self._read_by_model(html, "booked")
        return {_key(e) for e in exams for b in rows
                if b["day"] == e["day"] and b["course"].casefold() in (e["course"].casefold(), (e.get("code") or "").casefold())
                or (b["day"] == e["day"] and e["course"].casefold() in b["course"].casefold())}

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
                "booked, teachers, link, app_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (_key(e), e["course"], codes.get(e["course"].casefold()), ids.get(e["course"]), e["day"], e["time"],
                 e["opens"], e["closes"], int(e["open"]), int(_key(e) in booked), e["teachers"], e["link"],
                 e.get("app_id") or (before.get(_key(e)) or {}).get("app_id")))
        self.conn.execute("DELETE FROM esse3_wants WHERE key NOT IN (SELECT key FROM esse3_exams WHERE booked = 0)")
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
        wants = self.wants()
        exams = self.exams()
        for e in exams:
            if e["course_id"] is None:
                continue
            # Not booked or queued while a later sitting is: the user takes that one (as `signup`'s `instead`).
            later = None if e["booked"] or e["key"] in wants else next(
                (x["day"] for x in exams if x["course"] == e["course"] and x["day"] > e["day"]
                 and (x["booked"] or x["key"] in wants)), None)
            skip = {"skipped": later} if later else {}
            items = by_course.setdefault(e["course_id"], [])
            when = _short(e["day"])
            teachers = f"Teachers: {e['teachers']}." if e["teachers"] else ""
            window = (f" Sign-up on MyUniTo {_short(e['opens'])}–{_short(e['closes'])}."
                      if e["opens"] and e["closes"] else "")
            wanted = e["key"] in wants and not e["booked"]
            you = (f"Not taking it: you're on the {_short(later)} one" if later else
                   "Signed up on Esse3" if e["booked"] else
                   f"Aide signs you up when sign-up opens ({_short(e['opens'])})" if wanted and e["opens"] else
                   f"Sign-up open on MyUniTo until {_short(e['closes'])}" if e["open"] and e["closes"] else
                   "Sign-up open on MyUniTo" if e["open"] else None)
            items.append({"id": _id("exam", e), "what": "Exam", "kind": "exam", "date": e["day"], "time": e["time"],
                          "you": you, "details": (teachers + window).strip(), "source": "Esse3", **skip})
            if e["opens"]:
                items.append({"id": _id("opens", e), "what": f"Sign-up opens for the {when} exam", "kind": "other",
                              "date": e["opens"], "of": _id("exam", e),
                              "you": "Signed up" if e["booked"] else "Aide signs you up" if wanted else None,
                              "details": "On MyUniTo, Appelli disponibili.", "source": "Esse3", **skip})
            if e["closes"]:
                items.append({"id": _id("closes", e), "what": f"Sign-up closes for the {when} exam",
                              "kind": "deadline", "date": e["closes"], "of": _id("exam", e),
                              "you": "Signed up" if e["booked"] else "Aide signs you up" if wanted else None,
                              "details": "On MyUniTo, Appelli disponibili.", "source": "Esse3", **skip})
        known = {r[0] for r in self.conn.execute("SELECT course_id FROM official_dates")}
        for course_id in known | set(by_course):
            self.notebook.set_official_dates(course_id, by_course.get(course_id, []))

    async def _tell(self, before: dict[str, dict]) -> None:
        """A push the first time a session's sign-up is seen open (and not signed up for)."""
        told = set(json.loads(self._get("told") or "[]"))
        for e in self.exams():
            if not e["open"] or e["booked"] or e["key"] in told or self._archived(e):
                continue
            told.add(e["key"])
            if self._reminded(e) or e["key"] in self.wants():  # its opening's reminder said so, or Aide signs up
                continue
            name = self._name(e)
            title = f"Sign-up open: {name}"
            body = (f"The {_short(e['day'])} exam" + (f", until {_short(e['closes'])}" if e["closes"] else "")
                    + ". Tap Sign me up on the course page.")
            activity.record(self.conn, "professor", "study", f"Sign-up open for {name}'s {_short(e['day'])} exam")
            if self.push is not None:
                try:
                    await self.push.send_esse3(title, body, e["course_id"])
                except Exception:
                    log.exception("esse3: push failed")
        keep = {r[0] for r in self.conn.execute("SELECT key FROM esse3_exams")}
        self._set("told", json.dumps(sorted(told & keep)))

    def _reminded(self, e: dict) -> bool:
        try:
            return self.conn.execute("SELECT 1 FROM date_reminders WHERE course_id = ? AND date_id = ?",
                                     (e["course_id"], _id("opens", e))).fetchone() is not None
        except sqlite3.OperationalError:  # no date reminders on this server
            return False

    def _name(self, e: dict) -> str:
        course = self.study.course(e["course_id"]) if e.get("course_id") else None
        name = course["name"] if course else e["course"].title()
        return name[:1].upper() + name[1:]

    def _archived(self, e: dict) -> bool:
        return (self.notebook is not None and e.get("course_id") is not None
                and _id("exam", e) in self.notebook.archived_ids(e["course_id"]))

    # -- signing up and cancelling (only on the user's tap) -------------------------------

    def exam_for(self, date_id: str) -> dict | None:
        """The session behind an exam's course date."""
        return next((e for e in self.exams() if _id("exam", e) == date_id), None)

    def wants(self) -> dict[str, str | None]:
        return {r["key"]: r["error"] for r in self.conn.execute("SELECT key, error FROM esse3_wants")}

    def _today(self) -> str:
        return datetime.now(self.tz).date().isoformat()

    def _wanted_open(self) -> bool:
        today = self._today()
        return any(e["key"] in (w := self.wants()) and w[e["key"]] is None and not e["booked"]
                   and e["opens"] and e["opens"] <= today for e in self.exams())

    def _errand(self, key: str) -> tuple[dict | None, dict | None]:
        """The errand signing up for or cancelling a session (its row here, the errand), if any."""
        row = self.conn.execute("SELECT * FROM esse3_errands WHERE key = ?", (key,)).fetchone()
        if row is None or self.errands is None:
            return (dict(row) if row else None), None
        return dict(row), self.errands.store.get(row["errand_id"])

    def signup(self, date_id: str) -> dict | None:
        """An exam date's sign-up for the app: {state: booked, open, soon or closed, opens, closes, auto, busy,
        error, can_cancel, errand_id, step}; None when it isn't an Esse3 session."""
        if (e := self.exam_for(date_id)) is None:
            return None
        today = self._today()
        wants = self.wants()
        state = ("booked" if e["booked"] else "open" if e["open"] else
                 "soon" if e["opens"] and e["opens"] > today else "closed")
        row, errand = self._errand(e["key"])
        working = errand is not None and errand["status"] in ("queued", "running", "scheduled")
        live = errand is not None and errand["status"] in OPEN_ERRAND
        # Not booked while a later sitting of the course is booked or wanted: the user takes that one instead, and
        # an old failed try here is no longer news.
        instead = None if e["booked"] or e["key"] in wants or working else next(
            (x["day"] for x in self.exams()
             if x["course"] == e["course"] and x["day"] > e["day"] and (x["booked"] or x["key"] in wants)), None)
        return {"state": state, "opens": e["opens"], "closes": e["closes"], "auto": e["key"] in wants,
                "busy": ("signing up" if row["action"] == "book" else "cancelling") if working else None,
                "error": None if working or instead else wants.get(e["key"]) or self._get(f"error:{e['key']}"),
                "instead": instead,
                "can_cancel": e["booked"] and (e["closes"] is None or e["closes"] >= today),
                "errand_id": errand["id"] if live else None,
                "step": (errand["reason"] if errand["status"] == "needs_you" else errand["step"]) if live else None}

    async def sign_up(self, date_id: str, chat: str | None = None) -> dict:
        """The user's Sign me up: an errand now when sign-up is open (its result comes later: `errand_ended`), else
        as soon as it opens. SignUpFailed when it can't start. `chat`: asked for there (Professor), so its card and
        result are posted there too."""
        async with self._lock:
            e = self._session(date_id)
            if e["booked"] or self._working(e["key"]):
                return self.signup(date_id)
            if not e["open"]:
                if e["closes"] and e["closes"] < self._today():
                    raise SignUpFailed("closed", "The sign-up for this exam has closed.")
                self.conn.execute("INSERT INTO esse3_wants (key, at) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET "
                                  "error = NULL", (e["key"], utcnow().isoformat()))
                self._set(f"error:{e['key']}", None)
                activity.record(self.conn, "professor", "study",
                                f"Will sign up for {self._name(e)}'s {_short(e['day'])} exam when it opens")
                self._redate()
                return self.signup(date_id)
            await self._start(e, "book", chat=chat)
            return self.signup(date_id)

    async def cancel(self, date_id: str, chat: str | None = None) -> dict:
        """The user's Cancel: the sign-up on Esse3 as an errand (while its window is open), or the wish to sign up
        (and an errand signing up that hasn't got there, stopped)."""
        async with self._lock:
            e = self._session(date_id)
            row, errand = self._errand(e["key"])
            if not e["booked"]:
                self.conn.execute("DELETE FROM esse3_wants WHERE key = ?", (e["key"],))
                self._set(f"error:{e['key']}", None)
                if errand is not None and row["action"] == "book" and errand["status"] in OPEN_ERRAND:
                    self.conn.execute("UPDATE esse3_errands SET told = 'stopped' WHERE key = ?", (e["key"],))
                    self.errands.cancel(errand["id"])
                self._redate()
                return self.signup(date_id)
            if self._working(e["key"]):
                return self.signup(date_id)
            await self._start(e, "cancel", chat=chat)
            return self.signup(date_id)

    def _working(self, key: str) -> bool:
        _, errand = self._errand(key)
        return errand is not None and errand["status"] in ("queued", "running", "scheduled")

    def forget(self, date_id: str) -> None:
        """The exam was archived: no sign-up for it later."""
        if (e := self.exam_for(date_id)) is not None:
            self.conn.execute("DELETE FROM esse3_wants WHERE key = ?", (e["key"],))
            self._redate()  # an earlier sitting skipped for this one is back

    def _session(self, date_id: str) -> dict:
        if (e := self.exam_for(date_id)) is None:
            raise KeyError("not an Esse3 session")
        return e

    def _redate(self) -> None:
        if self.notebook is not None:
            self._dates()

    async def _start(self, e: dict, action: str, auto: bool = False, chat: str | None = None) -> dict:
        """The errand that signs up for (or cancels) a session: the login made here and handed over as cookies."""
        if self.errands is None:
            raise SignUpFailed("page", "Aide's browser isn't installed on the server, so it can't use Esse3: do it on "
                                       "MyUniTo this time.")
        if action == "book" and not e["link"]:
            raise SignUpFailed("closed", "Esse3 isn't taking sign-ups for this exam now.")
        _, old = self._errand(e["key"])
        if old is not None and old["status"] in OPEN_ERRAND:  # one left waiting for the user: this tap replaces it
            self.conn.execute("UPDATE esse3_errands SET told = 'stopped' WHERE key = ?", (e["key"],))
            self.errands.cancel(old["id"])
        try:
            cookies = await self.session.handoff(BOOKED, await self.errands.browser.user_agent())
        except LoginFailed as x:
            raise SignUpFailed("login", f"Couldn't get into Esse3: {x}.") from None
        except NoLogin:
            raise SignUpFailed("login", "Aide has no UniTo login: add it in Settings → Passwords.") from None
        d = date.fromisoformat(e["day"])
        others = [[x["course"], date.fromisoformat(x["day"]).strftime("%d/%m/%Y")] for x in self.exams()
                  if x["booked"] and x["key"] != e["key"]]
        target = {"action": action, "key": e["key"], "course": e["course"], "code": e["code"], "day": e["day"],
                  "day_it": d.strftime("%d/%m/%Y"), "time": e["time"], "app_id": e.get("app_id"),
                  "name": self._name(e), "start_url": e["link"] if action == "book" else BOOKED, "others": others}
        errand = await self.errands.start_esse3(target, cookies)
        self.conn.execute("INSERT OR REPLACE INTO esse3_errands (key, errand_id, action, auto, told, chat, at) "
                          "VALUES (?, ?, ?, ?, NULL, ?, ?)", (e["key"], errand["id"], action, int(auto), chat,
                                                              utcnow().isoformat()))
        self._set(f"error:{e['key']}", None)
        log.info("esse3: errand %s to %s", errand["id"], action)
        if chat:  # the errand's card in the chat, its steps live (Watch, Take over); posted once the turn lets go
            verb = "Signing you up for" if action == "book" else "Cancelling your sign-up for"
            text = f"{verb} {target['name']}'s {_short(e['day'])} exam on Esse3 now. It takes a minute or two."
            card = {"type": "errands", "errands": [self.errands.store.as_json(errand)]}
            asyncio.get_running_loop().create_task(self._to_chat(chat, errand["id"], "started", text, [card]))
        return errand

    async def _to_chat(self, chat: str, errand_id: int, note: str, text: str, attachments: list[dict]) -> None:
        if self.post is None:
            return
        try:
            await self.post(chat, f"[Esse3 errand #{errand_id}: {note}]", text, attachments, record=False)
        except Exception:
            log.exception("esse3: couldn't post in the chat")

    async def errand_ended(self, errand: dict, kind: str, args: dict) -> None:
        """An Esse3 errand stopped (`kind`: finish, need_user, failed, cancelled). The bookings page decides, read
        here; the browser's UniTo profile goes unless the user may still take over; the user is told once."""
        t = errand["esse3"]
        async with self._lock:
            row = self.conn.execute("SELECT * FROM esse3_errands WHERE key = ?", (t["key"],)).fetchone()
            if row is None or row["errand_id"] != errand["id"]:
                return  # replaced by a newer tap: that errand's end clears the browser
            if row["told"] == "stopped":  # the user stopped it
                if self.errands is not None:
                    await self.errands.browser.forget(SITE)
                return
            try:
                booked = await self._is_booked(t)
            except (LoginFailed, NoLogin) as x:
                log.warning("esse3: couldn't check the bookings after errand %s (%s)", errand["id"], x)
                booked = None
            if kind != "need_user" and self.errands is not None:
                await self.errands.browser.forget(SITE)
            await self._read()
            row = dict(self.conn.execute("SELECT * FROM esse3_errands WHERE key = ?", (t["key"],)).fetchone())
            book = t["action"] == "book"
            done = booked is not None and booked == book
            name, day = t.get("name") or t["course"].title(), _short(t["day"])
            if not done and kind == "cancelled" and row["told"] == "failed":
                return  # told already, and the user never took over
            if done:
                self.conn.execute("DELETE FROM esse3_wants WHERE key = ?", (t["key"],))
                self._set(f"error:{t['key']}", None)
                told = "done"
                what = f"Signed up for {name}'s {day} exam" if book else f"Cancelled the sign-up for {name}'s {day} exam"
                title = f"Signed up: {name}" if book else f"Sign-up cancelled: {name}"
                body = (f"The {day} exam, as soon as the sign-up opened." if row["auto"] else
                        f"The {day} exam, on Esse3." if book else f"The {day} exam: you're no longer signed up.")
                activity.record(self.conn, "professor", "study", what)
            else:
                told = "failed"
                said = args.get("reason") if kind == "need_user" else args.get("result")
                said = " ".join(str(said or "").split())[:200]
                message = (said if said and (kind == "need_user" or args.get("ok") is False) else
                           "Aide couldn't check Esse3 afterwards. Look on MyUniTo." if booked is None else
                           "Esse3 didn't list the sign-up afterwards. Check on MyUniTo." if book else
                           "Esse3 still lists the sign-up. Cancel it on MyUniTo.")
                if kind == "need_user":
                    message += " You can take over in the app."
                self._set(f"error:{t['key']}", message)
                self.conn.execute("UPDATE esse3_wants SET error = ? WHERE key = ?", (message, t["key"]))
                title = f"Couldn't sign you up: {name}" if book else f"Couldn't cancel: {name}"
                body = f"The {day} exam. {message}"
                activity.record(self.conn, "professor", "study",
                                f"Couldn't {'sign up for' if book else 'cancel'} {name}'s {day} exam", message)
                log.warning("esse3: errand %s didn't %s (%s)", errand["id"], t["action"], kind)
            again = not done and kind == "need_user" and row["told"] == "failed"
            self.conn.execute("UPDATE esse3_errands SET told = ? WHERE key = ?", (told, t["key"]))
            self._redate()
            if again:
                return  # stuck again after the user took over: told once already
        course = self.exam_for(_id("exam", t))
        if row["chat"]:
            text = (f"Done: {what[0].lower() + what[1:]}. Esse3 lists it." if done and book else
                    f"Done: {what[0].lower() + what[1:]}." if done else f"{title}. {message}")
            cards = []
            if kind == "need_user":
                cards.append({"type": "errands", "errands": [self.errands.store.as_json(errand)]})
            if (course or {}).get("course_id"):
                cards.append(open_card(t.get("name") or t["course"].title(), f"Exam {day}",
                                       f"aide://study/{course['course_id']}"))
            await self._to_chat(row["chat"], errand["id"], "done" if done else "didn't work", text, cards)
        if self.push is not None:
            try:
                await self.push.send_esse3(title, body, (course or {}).get("course_id"))
            except Exception:
                log.exception("esse3: push failed")

    async def _is_booked(self, e: dict) -> bool:
        return _key(e) in await self._booked((await self.session.get(BOOKED)).text, [e])

    async def _sign_up_wanted(self) -> None:
        """After a read: each wanted session whose sign-up is open now, an errand to sign up (its result pushed when
        it ends); a push now only when it can't start."""
        wants = self.wants()
        for e in self.exams():
            if e["key"] not in wants or wants[e["key"]] is not None or e["booked"] or not e["open"]:
                continue
            if self._archived(e):
                self.conn.execute("DELETE FROM esse3_wants WHERE key = ?", (e["key"],))
                continue
            row, errand = self._errand(e["key"])
            if errand is not None and errand["status"] in OPEN_ERRAND:
                continue
            try:
                await self._start(e, "book", auto=True)
            except SignUpFailed as x:
                name, day = self._name(e), _short(e["day"])
                self.conn.execute("UPDATE esse3_wants SET error = ? WHERE key = ?", (str(x), e["key"]))
                self._redate()
                activity.record(self.conn, "professor", "study", f"Couldn't sign up for {name}'s {day} exam", str(x))
                if self.push is not None:
                    try:
                        await self.push.send_esse3(f"Couldn't sign you up: {name}", f"The {day} exam. {x}",
                                                   e["course_id"])
                    except Exception:
                        log.exception("esse3: push failed")

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
                "exams": [{"id": _id("exam", e), **{k: e[k] for k in ("course", "code", "course_id", "day", "time",
                                                                      "opens", "closes", "open", "booked", "teachers")},
                           "signup": self.signup(_id("exam", e))} for e in self.exams()],
                "transcript": [{k: t[k] for k in ("code", "name", "year", "credits", "status", "grade", "passed_on",
                                                  "attended", "course_id")} for t in transcript],
                "credits": {"passed": sum(t["credits"] or 0 for t in passed),
                            "total": sum(t["credits"] or 0 for t in transcript)},
                "average": average}


def _id(what: str, e: dict) -> str:
    return "d_e3" + hashlib.sha256(f"{what}|{_key(e)}".encode()).hexdigest()[:10]
