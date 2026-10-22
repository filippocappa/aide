"""Study files: PDFs of slides, handouts and the professor's notes. The contract is docs/API.md, "Study files".

A file belongs to a course. Attached to a lecture it is that lecture's slides, and the lecture's notes are written
(or rewritten) with it; otherwise it is course material, which Professor searches and reads. Files come from the
app or from Moodle (moodle.py). Their text is taken out page by page with poppler's pdftotext, so a search can
name the page; the notes see a deck's most visual pages as images too (pdftoppm).
"""

import asyncio
import logging
import re
import secrets
import shutil
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from .db import Database, utcnow

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS study_files (
    id          INTEGER PRIMARY KEY,
    public_id   TEXT NOT NULL UNIQUE,
    course_id   INTEGER REFERENCES courses(id),  -- NULL: unfiled
    lecture_id  INTEGER REFERENCES lectures(id) ON DELETE SET NULL,  -- its slides; NULL: course material
    name        TEXT NOT NULL,  -- the file name shown, "Lecture 5 - IS-LM.pdf"
    section     TEXT NOT NULL DEFAULT '',  -- where it was on Moodle, "Week 3"
    size        INTEGER NOT NULL,
    pages       INTEGER NOT NULL,
    scanned     INTEGER NOT NULL DEFAULT 0,  -- no text layer: pages only as images
    source      TEXT NOT NULL DEFAULT 'upload',  -- upload, moodle
    source_key  TEXT UNIQUE,  -- Moodle: the file's URL without the token
    source_time INTEGER,  -- Moodle: when it was last changed there (epoch seconds)
    added_at    TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS study_files_course ON study_files(course_id);
CREATE TABLE IF NOT EXISTS study_pages (
    file_id INTEGER NOT NULL REFERENCES study_files(id) ON DELETE CASCADE,
    page    INTEGER NOT NULL,  -- from 1
    text    TEXT NOT NULL,
    PRIMARY KEY (file_id, page)
);
CREATE VIRTUAL TABLE IF NOT EXISTS study_pages_fts USING fts5(text, file_id UNINDEXED, page UNINDEXED,
    tokenize = 'unicode61 remove_diacritics 2');
"""

MAX_FILE = 100 * 1024 * 1024
MAX_NAME = 150
SCANNED_CHARS = 40  # a page with less text than this, on average, means a scan
IMAGE_PAGES = 20  # at most this many pages go to the notes as images: the ones with the least text
IMAGE_SIDE = 1400  # pixels, the longest side of a page image
NOTES_FILE_CHARS = 150_000  # the slides' text the notes see, at most
SLIDES_WINDOW = timedelta(hours=36)  # a Moodle file this close to a lecture is that lecture's slides
SLIDES_PER_LECTURE = 3  # at most this many are attached by themselves (a term's worth at once isn't slides)
PICTURE_SIDE = 100  # pixels: a smaller embedded image is an icon, not a picture
DRAWN_SHAPES = 6  # a page with at least this many drawn shapes may hold a diagram, a chart or a table
DRAWN_OVER_USUAL = 1.3  # ... and at least this many times its file's usual page (a template's boxes repeat)

_ID = re.compile(r"^f_[0-9a-f]{12}$")
_WORD = re.compile(r"\w+")


class PdfError(ValueError):
    pass


async def _run(*args: str, timeout: float = 120) -> bytes:
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise PdfError("reading the PDF took too long")
    if proc.returncode != 0:
        log.warning("%s failed: %s", args[0], err.decode(errors="replace")[-500:])
        raise PdfError("that isn't a PDF the server can read")
    return out


async def pdf_pages(path: Path) -> list[str]:
    """Each page's text, in reading order."""
    out = await _run("pdftotext", "-enc", "UTF-8", str(path), "-")
    pages = out.decode("utf-8", errors="replace").split("\f")
    if pages and not pages[-1].strip():
        pages.pop()  # pdftotext ends every page with a form feed
    return [re.sub(r"[ \t]+\n", "\n", re.sub(r"\n{3,}", "\n\n", p)).strip() for p in pages]


async def page_image(path: Path, page: int, side: int = IMAGE_SIDE) -> bytes:
    """One page as a JPEG, `side` pixels on its longest side. pdftoppm writes to a file: given "-" for the
    name, it makes a file called "-.jpg" rather than writing to stdout."""
    with tempfile.TemporaryDirectory(prefix="aide-page-") as tmp:
        out = Path(tmp) / "page"
        await _run("pdftoppm", "-jpeg", "-jpegopt", "quality=80", "-scale-to", str(side),
                   "-f", str(page), "-l", str(page), "-singlefile", str(path), str(out))
        try:
            return out.with_suffix(".jpg").read_bytes()
        except FileNotFoundError:
            raise PdfError(f"page {page} couldn't be drawn") from None


async def visual_pages(path: Path, pages: int) -> set[int]:
    """The pages that may hold a figure, told from the PDF itself, without a model: an embedded picture (not an
    icon, nor a logo repeated over the file), or more drawn shapes than the file's usual page (a diagram, a chart
    or a table drawn in lines and boxes; a bullet list has only its template's). pdfimages lists the pictures;
    pdftocairo draws the file as SVG, where text is glyphs in <defs> and shapes are <path>s on each <page>."""
    on: dict[tuple[str, str], set[int]] = {}
    for row in (await _run("pdfimages", "-list", str(path))).decode(errors="replace").splitlines()[2:]:
        cols = row.split()
        if len(cols) >= 12 and cols[2] == "image" and int(cols[3]) >= PICTURE_SIDE and int(cols[4]) >= PICTURE_SIDE:
            on.setdefault((cols[10], cols[11]), set()).add(int(cols[0]))
    found = {n for shown in on.values() if len(shown) <= max(3, pages // 4) for n in shown}
    with tempfile.TemporaryDirectory(prefix="aide-svg-") as tmp:
        out = Path(tmp) / "pages.svg"
        await _run("pdftocairo", "-svg", str(path), str(out))
        svg = out.read_text(errors="replace")
    shapes = [len(re.findall(r"<path\b", re.sub(r"<(defs|clipPath|mask|pattern)\b.*?</\1>", "", page, flags=re.S)))
              for page in re.findall(r"<page>(.*?)</page>", svg, flags=re.S)]
    if len(shapes) != pages:
        raise PdfError(f"the SVG has {len(shapes)} pages, not {pages}")
    usual = sorted(shapes)[len(shapes) // 2] if shapes else 0
    return found | {n for n, count in enumerate(shapes, 1) if count >= max(DRAWN_SHAPES, DRAWN_OVER_USUAL * usual)}


class FileStore:
    def __init__(self, db: Database, tz: ZoneInfo, folder: Path | None = None):
        self.conn = db.conn
        self.tz = tz
        self.folder = folder or Path(tempfile.mkdtemp(prefix="aide-files-"))  # tests
        self.folder.mkdir(parents=True, exist_ok=True)
        self.conn.executescript(SCHEMA)

    @staticmethod
    def new_id() -> str:
        return "f_" + secrets.token_hex(6)

    def path(self, f: dict) -> Path:
        return self.folder / f"{f['public_id']}.pdf"

    async def add(self, tmp: Path, name: str, course_id: int | None = None, lecture_id: int | None = None,
                  section: str = "", source: str = "upload", source_key: str | None = None,
                  source_time: int | None = None, public_id: str | None = None) -> dict:
        """Files the PDF at `tmp` (moved into the folder) and indexes its pages. With `source_key` already known,
        the file there is replaced, keeping its id."""
        pages = await pdf_pages(tmp)
        if not pages:
            raise PdfError("the PDF has no pages")
        name = _name(name)
        scanned = sum(len(p) for p in pages) < SCANNED_CHARS * len(pages)
        now = utcnow().isoformat()
        old = self.by_key(source_key) if source_key else None
        if old:
            self.conn.execute("UPDATE study_files SET name = ?, section = ?, size = ?, pages = ?, scanned = ?, "
                              "source_time = ?, updated_at = ? WHERE id = ?",
                              (name, section, tmp.stat().st_size, len(pages), scanned, source_time, now, old["id"]))
            row_id = old["id"]
        else:
            row_id = self.conn.execute(
                "INSERT INTO study_files (public_id, course_id, lecture_id, name, section, size, pages, scanned, "
                "source, source_key, source_time, added_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (public_id or self.new_id(), course_id, lecture_id, name, section, tmp.stat().st_size, len(pages),
                 scanned, source, source_key, source_time, now, now)).lastrowid
        f = self._row(row_id)
        shutil.move(tmp, self.path(f))
        self.conn.execute("DELETE FROM study_pages WHERE file_id = ?", (row_id,))
        self.conn.execute("DELETE FROM study_pages_fts WHERE file_id = ?", (row_id,))
        for i, text in enumerate(pages, 1):
            self.conn.execute("INSERT INTO study_pages (file_id, page, text) VALUES (?, ?, ?)", (row_id, i, text))
            if text:
                self.conn.execute("INSERT INTO study_pages_fts (text, file_id, page) VALUES (?, ?, ?)",
                                  (text, row_id, i))
        return f

    def _row(self, row_id: int) -> dict:
        return dict(self.conn.execute("SELECT * FROM study_files WHERE id = ?", (row_id,)).fetchone())

    def get(self, public_id: str) -> dict | None:
        if not _ID.match(public_id or ""):
            return None
        row = self.conn.execute("SELECT * FROM study_files WHERE public_id = ?", (public_id,)).fetchone()
        return dict(row) if row else None

    def find(self, public_id: str) -> dict:
        if (f := self.get(public_id)) is None:
            raise KeyError(f"no file {public_id}")
        return f

    def by_key(self, source_key: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM study_files WHERE source_key = ?", (source_key,)).fetchone()
        return dict(row) if row else None

    def files(self, course_id: int | None = None, lecture_id: int | None = None, material: bool = False) -> list[dict]:
        """A lecture's slides, a course's files (only its material with `material`), or all; by section, then
        oldest first, the order a course is taught."""
        where = {"lecture_id = ?": lecture_id, "course_id = ?": course_id}
        where = {k: v for k, v in where.items() if v is not None}
        sql = " AND ".join([*where, *(["lecture_id IS NULL"] if material else [])])
        return [dict(r) for r in self.conn.execute(
            "SELECT * FROM study_files" + (f" WHERE {sql}" if sql else "")
            + " ORDER BY COALESCE(source_time, CAST(strftime('%s', added_at) AS INTEGER)), id", tuple(where.values()))]

    def count(self, course_id: int) -> int:
        return self.conn.execute("SELECT COUNT(*) FROM study_files WHERE course_id = ?", (course_id,)).fetchone()[0]

    def update(self, public_id: str, **fields) -> dict:
        """name, course_id or lecture_id (None detaches it: course material)."""
        f = self.find(public_id)
        if "name" in fields:
            fields["name"] = _name(fields["name"])
        if fields:
            self.conn.execute(f"UPDATE study_files SET {', '.join(f'{k} = ?' for k in fields)}, updated_at = ? "
                              "WHERE id = ?", (*fields.values(), utcnow().isoformat(), f["id"]))
        return self._row(f["id"])

    def delete(self, public_id: str) -> dict | None:
        f = self.get(public_id)
        if f is None:
            return None
        self.conn.execute("DELETE FROM study_pages_fts WHERE file_id = ?", (f["id"],))
        self.conn.execute("DELETE FROM study_files WHERE id = ?", (f["id"],))
        self.path(f).unlink(missing_ok=True)
        return f

    def pages(self, f: dict, first: int = 1, last: int | None = None) -> list[tuple[int, str]]:
        return [(r["page"], r["text"]) for r in self.conn.execute(
            "SELECT page, text FROM study_pages WHERE file_id = ? AND page >= ? AND page <= ? ORDER BY page",
            (f["id"], first, last or f["pages"]))]

    def text(self, f: dict, first: int = 1, last: int | None = None) -> str:
        """The pages' text, each page starting with its mark: [p. 3]."""
        return "\n\n".join(f"[p. {n}]\n{t}" for n, t in self.pages(f, first, last))

    def search(self, query: str, course_id: int | None = None, limit: int = 8) -> list[dict]:
        """Pages matching every word of `query`, best first: the file's row with `page` and `snippet`."""
        words = _WORD.findall(query)
        if not words:
            return []
        match = " ".join(f'"{w}"' for w in words)
        rows = self.conn.execute(
            "SELECT f.*, p.page AS page, snippet(study_pages_fts, 0, '«', '»', '…', 24) AS snippet "
            "FROM study_pages_fts p JOIN study_files f ON f.id = p.file_id WHERE study_pages_fts MATCH ? "
            + ("AND f.course_id = ? " if course_id is not None else "") + "ORDER BY rank LIMIT ?",
            (match, *((course_id,) if course_id is not None else ()), limit)).fetchall()
        return [dict(r) for r in rows]

    def slides_for(self, course_id: int, recorded_at: datetime) -> list[dict]:
        """Moodle files of the course, not yet anyone's slides, put up within SLIDES_WINDOW of the lecture."""
        lo, hi = (int((recorded_at + d).timestamp()) for d in (-SLIDES_WINDOW, SLIDES_WINDOW))
        rows = self.conn.execute(
            "SELECT * FROM study_files WHERE course_id = ? AND lecture_id IS NULL AND source = 'moodle' "
            "AND source_time BETWEEN ? AND ? ORDER BY source_time", (course_id, lo, hi)).fetchall()
        return [dict(r) for r in rows] if 0 < len(rows) <= SLIDES_PER_LECTURE else []

    async def for_notes(self, f: dict, budget: int = NOTES_FILE_CHARS) -> tuple[str, list[bytes]]:
        """A lecture's slides for the notes: their text (cut at `budget` characters) and the pages with the least
        text as images, at most IMAGE_PAGES (all of them, up to that, for a scan)."""
        pages = self.pages(f)
        text = self.text(f)[:budget]
        visual = sorted(pages, key=lambda p: len(p[1]))[:IMAGE_PAGES]
        images = []
        for n, _ in sorted(visual):
            try:
                images.append(await page_image(self.path(f), n))
            except PdfError:
                log.warning("couldn't render page %d of %s", n, f["public_id"])
        return text, images

    def local(self, utc_iso: str) -> str:
        return datetime.fromisoformat(utc_iso).astimezone(self.tz).replace(microsecond=0).isoformat()

    def as_json(self, f: dict, lecture_public_id: str | None = None) -> dict:
        return {"id": f["public_id"], "course": f["course_id"], "lecture": lecture_public_id, "name": f["name"],
                "section": f["section"], "size": f["size"], "pages": f["pages"], "scanned": bool(f["scanned"]),
                "source": f["source"],
                "added_at": self.local(datetime.fromtimestamp(f["source_time"], timezone.utc).isoformat()
                                       if f["source_time"] else f["added_at"])}


def _name(name: str) -> str:
    name = " ".join((name or "").replace("/", "-").split()) or "Untitled.pdf"
    if not name.lower().endswith(".pdf"):
        name += ".pdf"
    if len(name) > MAX_NAME:
        name = name[:MAX_NAME - 4].rstrip() + ".pdf"
    return name

