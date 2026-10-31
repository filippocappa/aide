"""Study: courses from the calendar, lectures and their notes. The contract is docs/API.md, "Study".

A lecture is a recording, photos of slides or notes, or text, or a mix. It goes queued → transcribing (only with a
recording) → writing → ready, or failed. StudyWorker takes one at a time: Whisper on the GPU in its own process
(whisper.py), then one model call writes the notes, which are posted in the course's Professor chat.

Courses are the event titles that repeat in the study calendar (AIDE_STUDY_CALENDAR, "Work"), less the skipped ones
(AIDE_STUDY_SKIP, "study"), and a recording is filed under the one on when it started. Exams come from AIDE_EXAM_CALENDAR ("Exam"): an exam is a course's when its title
contains the course's name.
"""

import asyncio
import base64
import json
import logging
import os
import re
import secrets
import sys
import time as clock
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Awaitable, Callable
from zoneinfo import ZoneInfo

from . import usage
from .db import Database, utcnow
from .engine import course_var
from .icloud import CalendarBackend, CalEvent
from .material import FileStore
from .photos import PhotoStore
from .whisper import cuda_libs

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS courses (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE,  -- the event title in the study calendar
    chat TEXT  -- public id of the course's Professor chat, made when first needed
);
CREATE TABLE IF NOT EXISTS course_chats (  -- the course's other Professor chats (one per notebook proposal)
    chat      TEXT PRIMARY KEY,  -- the conversation's public id
    course_id INTEGER NOT NULL REFERENCES courses(id)
);
CREATE TABLE IF NOT EXISTS lectures (
    id          INTEGER PRIMARY KEY,
    public_id   TEXT NOT NULL UNIQUE,
    course_id   INTEGER REFERENCES courses(id),  -- NULL: unfiled
    title       TEXT NOT NULL DEFAULT '',
    recorded_at TEXT NOT NULL,  -- UTC
    duration_s  INTEGER,
    audio       TEXT,  -- file name in the audio folder, NULL without a recording
    photos      TEXT NOT NULL DEFAULT '[]',  -- photo ids (photos.py)
    text        TEXT NOT NULL DEFAULT '',  -- what the user typed or pasted with it
    status      TEXT NOT NULL,
    error       TEXT,
    language    TEXT,
    transcript  TEXT NOT NULL DEFAULT '',
    notes       TEXT NOT NULL DEFAULT '',
    notes_prev  TEXT,  -- the notes before the last change, kept for one undo
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS lectures_course ON lectures(course_id, recorded_at);
CREATE VIRTUAL TABLE IF NOT EXISTS lectures_fts USING fts5(title, notes, transcript,
    tokenize = 'unicode61 remove_diacritics 2');
"""

STATUSES = ("queued", "transcribing", "writing", "ready", "failed")
AUDIO_TYPES = {"audio/mp4": ".m4a", "audio/m4a": ".m4a", "audio/x-m4a": ".m4a", "audio/aac": ".aac",
               "audio/mpeg": ".mp3", "audio/wav": ".wav", "audio/x-wav": ".wav"}
MAX_AUDIO = 400 * 1024 * 1024  # about 4 hours of AAC at 128 kbps; the app records at 32
MAX_PHOTOS = 10
MAX_TEXT = 100_000
MAX_TITLE = 100
COURSE_RANGE = timedelta(days=120)  # courses are the titles of study events this far back and ahead
MIN_EVENTS = 3  # a study-calendar title is a course when it has at least this many events in COURSE_RANGE
EARLY = timedelta(minutes=15)  # a recording started this long before a lecture is filed under it
CACHE = 600  # seconds the calendar's courses and exams are kept
WHISPER_TIMEOUT = 3600

_ID = re.compile(r"^l_[0-9a-f]{12}$")
_WORD = re.compile(r"\w+")

Transcribe = Callable[[Path], Awaitable[tuple[str, str | None, int | None]]]


def stamp(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


async def whisper_transcribe(path: Path) -> tuple[str, str | None, int | None]:
    """Run whisper.py on the recording. Returns the transcript, with a [m:ss] mark starting a paragraph about every
    minute, the language and the duration in seconds."""
    env = dict(os.environ)
    if libs := cuda_libs():
        env["LD_LIBRARY_PATH"] = os.pathsep.join(filter(None, [libs, env.get("LD_LIBRARY_PATH")]))
    started = clock.monotonic()
    proc = await asyncio.create_subprocess_exec(sys.executable, "-m", "aide.whisper", str(path), env=env,
                                                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), WHISPER_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        raise RuntimeError("transcription took over an hour")
    ms = round((clock.monotonic() - started) * 1000)
    if proc.returncode != 0:
        log.error("whisper failed: %s", err.decode(errors="replace")[-2000:])
        usage.record("gpu", "whisper", ms=ms, ok=False)
        raise RuntimeError("transcription failed")
    info = next((json.loads(line) for line in reversed(out.decode().splitlines()) if line.startswith("{")), {})
    usage.record("gpu", info.get("model") or "whisper", ms=ms)
    return paragraphs(out.decode())


def paragraphs(output: str) -> tuple[str, str | None, int | None]:
    """whisper.py's output as (transcript, language, duration): a paragraph about every minute, each starting with
    its time mark."""
    paras: list[str] = []
    info: dict = {}
    mark = -60.0
    for line in output.splitlines():
        item = json.loads(line)
        if isinstance(item, dict):
            info = item
        elif item[0] - mark >= 60 or not paras:
            mark = item[0]
            paras.append(f"[{stamp(item[0])}] {item[1]}")
        else:
            paras[-1] += " " + item[1]
    return "\n\n".join(paras), info.get("language"), info.get("duration")


class StudyStore:
    def __init__(self, db: Database, tz: ZoneInfo, calendar: CalendarBackend | None = None,
                 study_calendar: str = "Work", exam_calendar: str = "Exam", skip: tuple[str, ...] = ("study",),
                 files_dir: Path | None = None):
        self.db = db
        self.conn = db.conn
        self.tz = tz
        self.calendar = calendar
        self.study_calendar = study_calendar
        self.exam_calendar = exam_calendar
        self.skip = {s.casefold() for s in skip}
        self._cached: tuple[float, list[CalEvent]] | None = None
        self.conn.executescript(SCHEMA)
        self.files = FileStore(db, tz, files_dir)  # after SCHEMA: its tables point at courses and lectures

    # -- the calendar ----------------------------------------------------------

    async def _events(self) -> list[CalEvent]:
        """Study and exam events from COURSE_RANGE back to COURSE_RANGE ahead, cached for CACHE seconds."""
        if self._cached and clock.monotonic() - self._cached[0] < CACHE:
            return self._cached[1]
        if self.calendar is None:
            return []
        now = datetime.now(timezone.utc)
        try:
            found = await asyncio.to_thread(self.calendar.events, now - COURSE_RANGE, now + COURSE_RANGE)
        except Exception:
            log.exception("couldn't read the calendar for courses")
            return self._cached[1] if self._cached else []
        events = [e if e.start.tzinfo else replace(e, start=e.start.replace(tzinfo=self.tz),
                                                   end=e.end.replace(tzinfo=self.tz))  # floating times are local
                  for e in found if e.calendar in (self.study_calendar, self.exam_calendar) and not e.all_day]
        self._cached = (clock.monotonic(), events)
        return events

    def _lectures(self, events: list[CalEvent]) -> list[CalEvent]:
        """The study calendar's lectures: titles that come back at least MIN_EVENTS times (a one-off appointment
        isn't a course), minus the skipped ones (the user's own "study" blocks) and the review sessions."""
        counts: dict[str, int] = {}
        for e in events:
            if e.calendar == self.study_calendar:
                counts[_name(e.title).casefold()] = counts.get(_name(e.title).casefold(), 0) + 1
        return [e for e in events if e.calendar == self.study_calendar and _name(e.title)
                and counts[_name(e.title).casefold()] >= MIN_EVENTS and _name(e.title).casefold() not in self.skip
                and not _name(e.title).startswith(REVIEW_PREFIX)]

    async def courses(self) -> list[dict]:
        """Every course: the calendar's (added to the table as they appear) and the stored ones with lectures."""
        events = await self._events()
        names = {_name(e.title).casefold(): _name(e.title) for e in self._lectures(events)}
        for name in names.values():
            self.conn.execute("INSERT INTO courses (name) VALUES (?) ON CONFLICT(name) DO NOTHING", (name,))
        rows = self.conn.execute(
            "SELECT c.*, COUNT(l.id) AS lectures, MAX(l.recorded_at) AS last_lecture FROM courses c "
            "LEFT JOIN lectures l ON l.course_id = c.id GROUP BY c.id ORDER BY c.name COLLATE NOCASE").fetchall()
        now = datetime.now(timezone.utc)
        exams = sorted((e for e in events if e.calendar == self.exam_calendar and e.start >= now),
                       key=lambda e: e.start)
        out = []
        for r in rows:
            if r["lectures"] or r["name"].casefold() in names:
                exam = next((e for e in exams if r["name"].casefold() in e.title.casefold()), None)
                out.append({**dict(r), "next_exam": exam})
        return out

    async def _on(self, at: datetime) -> tuple[dict, datetime] | None:
        """The course whose lecture is on at `at` (or starts within EARLY of it), and when that lecture ends."""
        for e in self._lectures(await self._events()):
            if e.start - EARLY <= at < e.end:
                await self.courses()  # makes sure the course is in the table
                if course := self.course_by_name(e.title):
                    return course, e.end
        return None

    async def match(self, at: datetime) -> dict | None:
        on = await self._on(at)
        return on[0] if on else None

    async def now(self) -> tuple[dict, datetime] | None:
        return await self._on(datetime.now(timezone.utc))

    # -- courses -----------------------------------------------------------------

    def course(self, course_id: int) -> dict | None:
        row = self.conn.execute("SELECT * FROM courses WHERE id = ?", (course_id,)).fetchone()
        return dict(row) if row else None

    def course_by_name(self, name: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM courses WHERE name = ?", (_name(name),)).fetchone()
        return dict(row) if row else None

    def chat(self, course_id: int) -> str:
        """The course's Professor chat, made the first time it's needed; made again if it was deleted."""
        course = self.course(course_id)
        if course is None:
            raise KeyError(f"no course {course_id}")
        if course["chat"] and self.db.app_conversation(course["chat"]) is not None:
            return course["chat"]
        row = self.db.new_app_conversation("professor")
        self.db.set_conversation_title(row["id"], course["name"][:1].upper() + course["name"][1:])
        self.conn.execute("UPDATE courses SET chat = ? WHERE id = ?", (row["public_id"], course_id))
        return row["public_id"]

    def new_chat(self, course_id: int, title: str) -> str:
        """Another Professor chat about the course, for one subject (new material and what to do with it)."""
        row = self.db.new_app_conversation("professor")
        self.db.set_conversation_title(row["id"], title)
        self.conn.execute("INSERT INTO course_chats (chat, course_id) VALUES (?, ?)", (row["public_id"], course_id))
        return row["public_id"]

    def chat_course(self, chat: str) -> int | None:
        """The course a chat is about: its main chat or one of the others."""
        row = self.conn.execute("SELECT id FROM courses WHERE chat = ? UNION ALL "
                                "SELECT course_id FROM course_chats WHERE chat = ?", (chat, chat)).fetchone()
        return row[0] if row else None

    def course_chat(self, course: dict) -> str | None:
        """The chat's id if it still exists, without making one."""
        return course["chat"] if course["chat"] and self.db.app_conversation(course["chat"]) else None

    # -- lectures ----------------------------------------------------------------

    @staticmethod
    def new_id() -> str:
        return "l_" + secrets.token_hex(6)

    def add(self, recorded_at: datetime, course_id: int | None = None, title: str = "", audio: str | None = None,
            photos: list[str] | tuple[str, ...] = (), text: str = "", public_id: str | None = None,
            files: list[str] | tuple[str, ...] = ()) -> dict:
        """A new lecture, queued. `files` are ids of PDFs that become its slides."""
        if course_id is not None and self.course(course_id) is None:
            raise ValueError(f"no course {course_id}")
        if not (audio or photos or text.strip() or files):
            raise ValueError("a lecture needs a recording, photos, files or text")
        slides = [self.files.find(f) for f in files]
        if len(photos) > MAX_PHOTOS:
            raise ValueError(f"at most {MAX_PHOTOS} photos per lecture")
        if len(text) > MAX_TEXT:
            raise ValueError("the text is too long")
        if recorded_at.tzinfo is None:
            raise ValueError("recorded_at needs a UTC offset")
        now = utcnow().isoformat()
        cur = self.conn.execute(
            "INSERT INTO lectures (public_id, course_id, title, recorded_at, audio, photos, text, status, created_at, "
            "updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?)",
            (public_id or self.new_id(), course_id, _title(title), recorded_at.astimezone(timezone.utc).isoformat(),
             audio, json.dumps(list(photos)), text.strip(), now, now))
        lecture = self._row(cur.lastrowid)
        for f in slides:
            self.files.update(f["public_id"], lecture_id=lecture["id"],
                              course_id=f["course_id"] if course_id is None else course_id)
        self._index(lecture)
        return lecture

    def _row(self, row_id: int) -> dict:
        return dict(self.conn.execute("SELECT * FROM lectures WHERE id = ?", (row_id,)).fetchone())

    def lecture_row(self, row_id: int) -> dict | None:
        row = self.conn.execute("SELECT * FROM lectures WHERE id = ?", (row_id,)).fetchone()
        return dict(row) if row else None

    def get(self, public_id: str) -> dict | None:
        if not _ID.match(public_id or ""):
            return None
        row = self.conn.execute("SELECT * FROM lectures WHERE public_id = ?", (public_id,)).fetchone()
        return dict(row) if row else None

    def find(self, public_id: str) -> dict:
        if (lecture := self.get(public_id)) is None:
            raise KeyError(f"no lecture {public_id}")
        return lecture

    def lectures(self, course_id: int | None = None, unfiled: bool = False, limit: int = 200) -> list[dict]:
        """Newest first: one course's, the unfiled ones, or all."""
        where, args = ("WHERE course_id IS NULL", ()) if unfiled else \
            ("WHERE course_id = ?", (course_id,)) if course_id is not None else ("", ())
        return [dict(r) for r in self.conn.execute(
            f"SELECT * FROM lectures {where} ORDER BY recorded_at DESC, id DESC LIMIT ?", (*args, limit))]

    def unfiled(self) -> int:
        return self.conn.execute("SELECT COUNT(*) FROM lectures WHERE course_id IS NULL").fetchone()[0]

    def _set(self, lecture_id: int, **fields) -> dict:
        self.conn.execute(f"UPDATE lectures SET {', '.join(f'{k} = ?' for k in fields)}, updated_at = ? WHERE id = ?",
                          (*fields.values(), utcnow().isoformat(), lecture_id))
        lecture = self._row(lecture_id)
        if fields.keys() & {"title", "notes", "transcript"}:
            self._index(lecture)
        return lecture

    def set_status(self, lecture_id: int, status: str, error: str | None = None) -> dict:
        assert status in STATUSES
        return self._set(lecture_id, status=status, error=error)

    def set_transcript(self, lecture_id: int, transcript: str, language: str | None, duration: int | None) -> dict:
        return self._set(lecture_id, transcript=transcript, language=language, duration_s=duration)

    def set_notes(self, lecture_id: int, notes: str, title: str | None = None) -> dict:
        """The worker's notes, and the title they suggest when the lecture has none. Notes written again keep
        the old ones in notes_prev."""
        old = self._row(lecture_id)
        fields = {"notes": tidy_math(notes.strip()), "status": "ready", "error": None}
        if old["notes"]:
            fields["notes_prev"] = old["notes"]
        if title and not old["title"]:
            fields["title"] = _title(title)
        return self._set(lecture_id, **fields)

    def update(self, public_id: str, title: str | None = None, course_id: int | None = None,
               move: bool = False, notes: str | None = None) -> dict:
        """The user's (or Professor's) changes. `move` with course_id None files it as unfiled.
        New notes keep the old ones in notes_prev."""
        lecture = self.find(public_id)
        fields: dict = {}
        if title is not None:
            fields["title"] = _title(title)
        if move or course_id is not None:
            if course_id is not None and self.course(course_id) is None:
                raise ValueError(f"no course {course_id}")
            fields["course_id"] = course_id
        if notes is not None:
            if not notes.strip():
                raise ValueError("the notes are empty")
            if len(notes) > MAX_TEXT:
                raise ValueError("the notes are too long")
            fields |= {"notes_prev": lecture["notes"], "notes": notes.strip()}
        return self._set(lecture["id"], **fields) if fields else lecture

    def retry(self, public_id: str) -> dict:
        lecture = self.find(public_id)
        if lecture["status"] != "failed":
            raise ValueError("only a failed lecture can be retried")
        return self.set_status(lecture["id"], "queued")

    def rewrite(self, lecture_id: int) -> dict:
        """New slides for a lecture whose notes are done (or failed): its notes are written again, from the
        transcript it has; one in progress picks them up anyway."""
        lecture = self._row(lecture_id)
        if lecture["status"] in ("ready", "failed"):
            lecture = self.set_status(lecture_id, "queued")
        return lecture

    def delete(self, public_id: str) -> dict | None:
        """Removes the lecture; returns it (the caller removes its recording), None if there was none. Its
        slides stay, as course material."""
        lecture = self.get(public_id)
        if lecture is None:
            return None
        self.conn.execute("DELETE FROM lectures WHERE id = ?", (lecture["id"],))
        self.conn.execute("DELETE FROM lectures_fts WHERE rowid = ?", (lecture["id"],))
        return lecture

    def next_queued(self) -> dict | None:
        row = self.conn.execute("SELECT * FROM lectures WHERE status = 'queued' ORDER BY id LIMIT 1").fetchone()
        return dict(row) if row else None

    def requeue(self) -> int:
        """After a restart: lectures cut off mid-way start over."""
        return self.conn.execute("UPDATE lectures SET status = 'queued' WHERE status IN ('transcribing', 'writing')"
                                 ).rowcount

    # -- search ------------------------------------------------------------------

    def _index(self, lecture: dict) -> None:
        self.conn.execute("DELETE FROM lectures_fts WHERE rowid = ?", (lecture["id"],))
        self.conn.execute("INSERT INTO lectures_fts (rowid, title, notes, transcript) VALUES (?, ?, ?, ?)",
                          (lecture["id"], lecture["title"], lecture["notes"], lecture["transcript"]))

    def search(self, query: str, course_id: int | None = None, limit: int = 8) -> list[dict]:
        """Lectures matching every word of `query` (any order, accents ignored), best first, each with a snippet."""
        words = _WORD.findall(query)
        if not words:
            return []
        match = " ".join(f'"{w}"' for w in words)  # quoted, so words like AND or NEAR aren't operators
        rows = self.conn.execute(
            "SELECT l.*, snippet(lectures_fts, -1, '«', '»', '…', 24) AS snippet FROM lectures_fts f "
            "JOIN lectures l ON l.id = f.rowid WHERE lectures_fts MATCH ? "
            + ("AND l.course_id = ? " if course_id is not None else "") + "ORDER BY rank LIMIT ?",
            (match, *((course_id,) if course_id is not None else ()), limit)).fetchall()
        return [dict(r) for r in rows]

    # -- shapes ------------------------------------------------------------------

    def local(self, utc_iso: str) -> str:
        return datetime.fromisoformat(utc_iso).astimezone(self.tz).replace(microsecond=0).isoformat()

    def as_json(self, lecture: dict, full: bool = False, transcript: bool = False) -> dict:
        out = {"id": lecture["public_id"], "course": lecture["course_id"], "title": lecture["title"],
               "recorded_at": self.local(lecture["recorded_at"]), "duration_s": lecture["duration_s"],
               "photos": json.loads(lecture["photos"]), "has_audio": lecture["audio"] is not None,
               "status": lecture["status"], "error": lecture["error"], "summary": summary(lecture["notes"]),
               "files": [f["public_id"] for f in self.files.files(lecture_id=lecture["id"])],
               "updated_at": self.local(lecture["updated_at"])}
        if full:
            out |= {"notes": lecture["notes"], "text": lecture["text"], "language": lecture["language"]}
        if transcript:
            out["transcript"] = lecture["transcript"]
        return out

    def course_json(self, c: dict) -> dict:
        exam: CalEvent | None = c["next_exam"]
        return {"id": c["id"], "name": c["name"], "lectures": c["lectures"], "files": self.files.count(c["id"]),
                "last_lecture": self.local(c["last_lecture"]) if c["last_lecture"] else None,
                "next_exam": {"date": exam.start.astimezone(self.tz).isoformat(), "title": exam.title} if exam else None,
                "chat": self.course_chat(c)}


REVIEW_PREFIX = "Review: "  # review sessions (reviews.py) in the study calendar: never a course


def _name(title: str) -> str:
    return " ".join(title.split())


def _title(title: str | None) -> str:
    title = " ".join((title or "").split())
    if len(title) > MAX_TITLE:
        raise ValueError(f"the title is over {MAX_TITLE} characters")
    return title


# A $ before an amount ($13.5 trillion, $9,700, $10k, $5–$10): money, not the start of a formula.
_MONEY = re.compile(r"(?<![\\$])\$(?=\d[\d,]*(?:\.\d+)?(?:bn|tn|[kKmMbB])?(?:\s+[A-Za-z(]|[.,;:!?)\]]*(?:\s|$)|[–-]\\?\$))")
_DISPLAY = re.compile(r"(?<!\\)\$\$(?=\S)([^$\n]+?)(?<=\S)(?<!\\)\$\$")


def tidy_math(text: str) -> str:
    """Markdown from the model made safe for Obsidian's maths: a dollar for money escaped (\\$13.5 trillion), else
    it pairs with the next $ and the words between become a formula; a $$…$$ inside a sentence made inline, since
    Obsidian draws it as a centred block that splits the sentence."""
    out = []
    for line in _MONEY.sub(r"\\$", text).split("\n"):
        bare = line.lstrip("> \t")
        if not (bare.startswith("$$") and bare.rstrip().endswith("$$")):
            line = _DISPLAY.sub(r"$\1$", line)
        out.append(line)
    return "\n".join(out)


def summary(notes: str) -> str | None:
    """The notes' first plain line: the one-sentence summary they start with."""
    return next((line.strip() for line in notes.splitlines() if line.strip() and not line.lstrip().startswith("#")),
                None)


# -- notes ---------------------------------------------------------------------------

NOTES_PROMPT = """You write study notes for a university student from one lecture: a transcript made by speech \
recognition, the lecture's slides (their text page by page, marked [p. 3], and their most visual pages as images), \
photos of slides, a board or their own notes, and what they typed, in any mix. Write the notes in the language of \
the lecture.

Start with a line "# " and a title of two to six words for the topic, then one sentence saying what the lecture \
covered. Then these sections, as "## " headings, in this order, leaving out any with nothing in it:

## Summary
A few short paragraphs: the thread of the lecture, in the order it was taught.
## Key concepts
A list: each concept in bold, then what it means and why it matters, in a line or two.
## Definitions
A list of the terms defined, word for word where the lecturer was precise.
## Formulas and examples
Formulas in plain text (Y = C + I + G), what each symbol is, and the worked examples, step by step. Money with \
its dollar escaped, \\$13.5 trillion: a bare $ starts a formula in Obsidian.
## Questions to check yourself
Five to eight questions an exam could ask about this lecture, from recall to applying it. No answers.
## Unclear in the recording
Words or passages the transcript got wrong or cut, and what they probably were. Leave it out if all was clear.

Speech recognition mishears names, symbols and numbers: fix the obvious slips silently and list only the real \
doubts; where there are slides, take terms, formulas and figures from them. With both, the slides give the \
structure and the transcript what the lecturer explained and stressed beyond them: keep that. Where it helps the \
student find a passage, put the transcript's time mark (12:30) or the slide (p. 14) after a point. \
Use what the lecturer said and showed; add nothing from outside the lecture, except to fix an evident mistake, \
which you then point out. Plain markdown: headings, lists, bold. No tables."""

PART_PROMPT = """You get one part of a long lecture's transcript. Write dense working notes on it for the person \
who will write the final notes from all the parts: every concept, definition, formula, example and announcement \
(an exam topic, a deadline), in order, with the transcript's time marks. No introduction."""

PART_CHARS = 120_000  # a transcript longer than this is noted in parts first, then the parts are written up


class StudyWorker:
    """Turns queued lectures into notes, one at a time."""

    def __init__(self, store: StudyStore, agent, push, audio_dir: Path, transcribe: Transcribe | None = None):
        self.store = store
        self.agent = agent  # the model client and the smart model, and posting in the course chat
        self.push = push
        self.audio_dir = audio_dir
        self.transcribe = transcribe  # None: no Whisper on this server, so recordings aren't accepted
        self.photos: PhotoStore | None = agent.photos
        self.notebook = None  # NotebookStore, set after: a lecture's first notes are offered to its course's notebook
        self.engine = None  # Engine, set after: OpenRouter or the user's Claude plan; None calls OpenRouter directly
        self.live = None  # LiveActivities, set after: a course's lecture being written shows on the Lock Screen
        self._wake = asyncio.Event()
        audio_dir.mkdir(parents=True, exist_ok=True)

    def kick(self) -> None:
        self._wake.set()

    async def run(self) -> None:
        if n := self.store.requeue():
            log.info("requeued %d lecture(s) cut off by a restart", n)
        while True:
            lecture = self.store.next_queued()
            if lecture is None:
                await self._wake.wait()
                self._wake.clear()
                continue
            await self.process(lecture)

    async def process(self, lecture: dict) -> dict:
        lid = lecture["id"]
        started = clock.monotonic()
        course_var.set(lecture["course_id"])
        run = None
        if self.live is not None and (name := self._course_name(lecture)):
            run = self.live.notes(f"notes:{lecture['public_id']}", self.store.chat(lecture["course_id"]),
                                  f"{name[:1].upper()}{name[1:]}")
        try:
            if lecture["audio"] and not lecture["transcript"]:  # a rewrite with new slides has one
                if self.transcribe is None:
                    raise RuntimeError("transcription isn't set up on the server")
                lecture = self.store.set_status(lid, "transcribing")
                if run:
                    run.start("Transcribing the lecture")
                text, language, duration = await self.transcribe(self.audio_dir / lecture["audio"])
                if not text.strip():
                    raise RuntimeError("no speech found in the recording")
                self.store.set_transcript(lid, text, language, duration)
                log.info("lecture %s transcribed in %.0f s", lecture["public_id"], clock.monotonic() - started)
            lecture = self.store.set_status(lid, "writing")
            if run and run.detail:
                run.step("Writing the notes")
            elif run:
                run.start("Writing the notes")
            if lecture["course_id"] and not self.store.files.files(lecture_id=lid):
                for f in self.store.files.slides_for(lecture["course_id"], datetime.fromisoformat(lecture["recorded_at"])):
                    self.store.files.update(f["public_id"], lecture_id=lid)  # the slides Moodle had for it
            rewrite = bool(lecture["notes"])
            title, notes = await self.write_notes(lecture)
            lecture = self.store.set_notes(lid, notes, title)
        except Exception as e:
            log.exception("lecture %s failed", lecture["public_id"])
            lecture = self.store.set_status(lid, "failed", str(e)[:200] if isinstance(e, RuntimeError)
                                            else "Something went wrong on the server. It's in the logs.")
            if run:
                run.failed(lecture["error"])
            await self._alert(lecture, f"Couldn't make notes from this lecture: {lecture['error']}")
            return lecture
        log.info("lecture %s ready in %.0f s", lecture["public_id"], clock.monotonic() - started)
        if run:
            run.finished(f"Notes ready: {lecture['title']}" if lecture["title"] else "Notes ready")
        await self._post(lecture, rewrite)
        if self.notebook is not None and lecture["course_id"] and not rewrite:
            self.notebook.new_material(lecture["course_id"], [{"lecture": lecture["public_id"]}])
        return lecture

    def _course_name(self, lecture: dict) -> str | None:
        course = self.store.course(lecture["course_id"]) if lecture["course_id"] else None
        return course["name"] if course else None

    async def write_notes(self, lecture: dict) -> tuple[str | None, str]:
        """(title, notes) from the model; the title is the notes' "# " line."""
        when = datetime.fromisoformat(lecture["recorded_at"]).astimezone(self.store.tz)
        head = [f"Course: {self._course_name(lecture) or 'unknown'}", f"Recorded: {when:%A %d %B %Y, %H:%M}"]
        if lecture["title"]:
            head.append(f"Title: {lecture['title']}")
        transcript = lecture["transcript"]
        if len(transcript) > PART_CHARS:
            parts = _split(transcript, PART_CHARS)
            noted = [await self._ask(PART_PROMPT, [{"type": "text", "text": f"Part {i + 1} of {len(parts)}:\n\n{p}"}])
                     for i, p in enumerate(parts)]
            transcript = "\n\n".join(f"(Working notes, part {i + 1})\n{n}" for i, n in enumerate(noted))
        content: list[dict] = [*self._images(json.loads(lecture["photos"]))]
        body = "\n".join(head)
        for f in self.store.files.files(lecture_id=lecture["id"]):
            text, images = await self.store.files.for_notes(f)
            content += [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                     "data": base64.b64encode(i).decode()}} for i in images]
            body += f"\n\nSlides, {f['name']} ({f['pages']} pages; the images above include its most visual " \
                    f"pages):\n{text or '(no text layer: a scan, read the images)'}"
        if lecture["text"]:
            body += f"\n\nWhat the student typed:\n{lecture['text']}"
        if transcript:
            body += f"\n\nTranscript:\n{transcript}"
        content.append({"type": "text", "text": body})
        notes = await self._ask(NOTES_PROMPT, content)
        first, _, rest = notes.strip().partition("\n")
        if first.startswith("# "):
            return first[2:].strip(), rest.strip()
        return None, notes.strip()

    def _images(self, photo_ids: list[str]) -> list[dict]:
        out = []
        for photo_id in photo_ids:
            if self.photos and (loaded := self.photos.load(photo_id)):
                data, kind = loaded
                out.append({"type": "image", "source": {"type": "base64", "media_type": kind,
                                                        "data": base64.b64encode(data).decode()}})
        return out

    async def _ask(self, system: str, content: list[dict]) -> str:
        if self.engine is not None:
            return await self.engine.ask(system, content, 16000)
        response = await self.agent.client.beta.messages.create(
            model=self.agent.smart_model, max_tokens=16000, system=system,
            messages=[{"role": "user", "content": content}])
        text = "".join(b.text for b in response.content if b.type == "text").strip()
        if not text:
            raise RuntimeError("the notes came back empty")
        return text

    async def _post(self, lecture: dict, rewrite: bool = False) -> None:
        """A note in the course's Professor chat, and a push that opens the lecture."""
        name = self._course_name(lecture)
        when = datetime.fromisoformat(lecture["recorded_at"]).astimezone(self.store.tz)
        what = lecture["title"] or "the lecture"
        if rewrite:
            which = f"{when:%A}'s {name} lecture" if name else f"the {when:%A} lecture"
            text = f"I rewrote the notes of {which}, \"{what}\", with the slides."
            if lecture["course_id"]:
                await self.agent.post(self.store.chat(lecture["course_id"]),
                                      f"[Lecture notes ready: lecture {lecture['public_id']} rewritten with its slides.]",
                                      text)
            await self._alert(lecture, text)
            return
        if lecture["course_id"]:
            line = summary(lecture["notes"]) or ""
            text = f"Notes from {when:%A}'s {name} lecture, \"{what}\", are ready. {line}".strip()
            note = (f"[Lecture notes ready: lecture {lecture['public_id']}, {name}, {when:%a %d %b %H:%M}, "
                    f"\"{what}\". The user can ask about it here; read it with read_lecture.]")
            await self.agent.post(self.store.chat(lecture["course_id"]), note, text)
        await self._alert(lecture, summary(lecture["notes"]) or f"Notes for {what} are ready.")

    async def _alert(self, lecture: dict, body: str) -> None:
        name = self._course_name(lecture)
        try:
            await self.push.send_lecture(lecture["public_id"], f"Professor · {name}" if name else "Professor", body)
        except Exception:
            log.exception("couldn't push lecture %s", lecture["public_id"])


def _split(transcript: str, size: int) -> list[str]:
    """Parts of about `size` characters, cut between paragraphs (each starts at a time mark)."""
    parts, current = [], ""
    for para in transcript.split("\n\n"):
        if current and len(current) + len(para) > size:
            parts.append(current)
            current = ""
        current = f"{current}\n\n{para}" if current else para
    return [*parts, current] if current else parts
