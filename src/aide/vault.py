"""The Obsidian vault on this server: Aide writes the study notes and files into it as markdown and PDFs, and
webdav.py serves it, so Obsidian on the phone and the Mac syncs it (the Remotely Save plugin, over Tailscale).

Everything Aide writes is under Aide/ in the vault: one folder per course, with a page per lecture, an index page
and the course's files. Aide only changes what it wrote: a file the user edited (its hash isn't the one Aide wrote)
or deleted is theirs from then on, and Aide leaves it alone. Renamed or deleted lectures move or remove their page,
when it's unedited.
"""

import asyncio
import hashlib
import logging
import os
import re
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .study import StudyStore

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS vault_files (
    path TEXT PRIMARY KEY,  -- relative to the vault
    ref  TEXT NOT NULL,  -- what it shows: a lecture, file or course id
    sha  TEXT NOT NULL  -- of what Aide wrote (a PDF: its version, size and time)
);
"""

ROOT = "Aide"
INTERVAL = 60  # seconds between syncs when nothing kicks one
_BAD = re.compile(r'[\\/:*?"<>|#^\[\]]+')  # not in file names, or they break Obsidian's links


@dataclass
class Item:
    path: str
    ref: str
    text: str | None = None  # markdown, or
    source: Path | None = None  # a PDF to copy
    version: str = ""  # the PDF's


def _file_name(name: str) -> str:
    return " ".join(_BAD.sub(" ", name).split()).strip(". ")[:120] or "Untitled"


def _tag(name: str) -> str:
    return re.sub(r"[^\w-]+", "-", name.casefold()).strip("-") or "course"


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _quote(text: str) -> str:
    return "\n".join(f"> {line}" if line.strip() else ">" for line in text.splitlines())


def _link(path: str, label: str) -> str:
    return f"[[{path.removesuffix('.md')}|{label}]]"


class Vault:
    def __init__(self, folder: Path, study: StudyStore):
        self.folder = folder
        self.study = study
        self.conn = study.conn
        self.conn.executescript(SCHEMA)
        self._wake = asyncio.Event()
        folder.mkdir(parents=True, exist_ok=True)

    def kick(self) -> None:
        self._wake.set()

    async def run(self) -> None:
        while True:
            try:
                await self.sync()
            except Exception:
                log.exception("vault sync failed")
            try:
                await asyncio.wait_for(self._wake.wait(), INTERVAL)
            except asyncio.TimeoutError:
                pass
            self._wake.clear()

    # -- what the vault should hold ----------------------------------------------------

    async def render(self) -> list[Item]:
        study, tz = self.study, self.study.tz
        # Folders come from the stored courses, so a calendar that's briefly unreachable moves nothing; the
        # calendar only adds the next exam.
        live = {c["id"]: c for c in await study.courses()}
        rows = [lec for lec in study.lectures(limit=100_000) if lec["notes"]]
        all_files = study.files.files()
        courses = {}
        for cid in sorted({r["course_id"] for r in (*rows, *all_files)} - {None}):
            if stored := study.course(cid):
                courses[cid] = {"next_exam": None, **stored, **live.get(cid, {})}
        folders = {cid: f"{ROOT}/{_file_name(c['name'])}" for cid, c in courses.items()}
        items: list[Item] = []
        file_paths: dict[int, str] = {}
        taken: dict[str, set[str]] = {}
        for f in all_files:
            folder = folders.get(f["course_id"], f"{ROOT}/Unfiled")
            seen = taken.setdefault(folder, set())
            stem = _file_name(f["name"].removesuffix(".pdf"))
            name, n = f"{stem}.pdf", 2
            while name.casefold() in seen:
                name, n = f"{stem} ({n}).pdf", n + 1
            seen.add(name.casefold())
            file_paths[f["id"]] = f"{folder}/Files/{name}"
            items.append(Item(file_paths[f["id"]], f["public_id"], source=study.files.path(f),
                              version=f"{f['size']}:{f['updated_at']}"))
        lecture_paths: dict[int, str] = {}
        for lec in sorted(rows, key=lambda r: (r["recorded_at"], r["id"])):
            folder = folders.get(lec["course_id"], f"{ROOT}/Unfiled")
            when = datetime.fromisoformat(lec["recorded_at"]).astimezone(tz)
            stem = f"{when:%Y-%m-%d} {_file_name(lec['title'] or 'Lecture')}"
            path, n = f"{folder}/{stem}.md", 2
            while path in lecture_paths.values():
                path, n = f"{folder}/{stem} {n}.md", n + 1
            lecture_paths[lec["id"]] = path
        for lec in rows:
            items.append(Item(lecture_paths[lec["id"]], lec["public_id"],
                              self._lecture(lec, courses.get(lec["course_id"]), folders, file_paths)))
        for cid, c in courses.items():
            lectures = [lec for lec in rows if lec["course_id"] == cid]
            files = [f for f in all_files if f["course_id"] == cid]
            if lectures or files:
                items.append(Item(f"{folders[cid]}/{_file_name(c['name'])}.md", f"course:{cid}",
                                  self._course(c, lectures, lecture_paths, files, file_paths)))
        return items

    def _lecture(self, lec: dict, course: dict | None, folders: dict, file_paths: dict) -> str:
        tz = self.study.tz
        when = datetime.fromisoformat(lec["recorded_at"]).astimezone(tz)
        name = course["name"] if course else None
        meta = ["---", f"course: {name or 'unfiled'}", f"date: {when:%Y-%m-%d}", f'time: "{when:%H:%M}"']
        if lec["duration_s"]:
            meta.append(f"duration: {round(lec['duration_s'] / 60)} min")
        if lec["language"]:
            meta.append(f"language: {lec['language']}")
        meta += [f"lecture: {lec['public_id']}", "tags:", "  - lecture"]
        if name:
            meta.append(f"  - {_tag(name)}")
        meta.append("---")
        head = [f"{when:%a %d %b %Y, %H:%M}"]
        if name:
            head.insert(0, _link(f"{folders[course['id']]}/{_file_name(name)}.md", name))
        if lec["duration_s"]:
            m = round(lec["duration_s"] / 60)
            head.append(f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min")
        out = ["\n".join(meta), f"# {lec['title'] or 'Lecture'}", " · ".join(head)]
        slides = self.study.files.files(lecture_id=lec["id"])
        if slides:
            out.append("Slides: " + ", ".join(_link(file_paths[f["id"]], f["name"]) for f in slides
                                              if f["id"] in file_paths))
        out.append(lec["notes"])
        if lec["text"]:
            out.append("> [!note]- What you typed\n" + _quote(lec["text"]))
        if lec["transcript"]:
            out.append("> [!quote]- Transcript\n" + _quote(lec["transcript"]))
        return "\n\n".join(out) + "\n"

    def _course(self, c: dict, lectures: list[dict], lecture_paths: dict, files: list[dict], file_paths: dict) -> str:
        tz = self.study.tz
        out = [f"---\ntags:\n  - course\n  - {_tag(c['name'])}\n---", f"# {c['name']}"]
        if exam := c["next_exam"]:
            out.append(f"Next exam: {exam.start.astimezone(tz):%a %d %b %Y, %H:%M} ({exam.title})")
        if lectures:
            lines = []
            for lec in sorted(lectures, key=lambda r: r["recorded_at"]):
                when = datetime.fromisoformat(lec["recorded_at"]).astimezone(tz)
                lines.append(f"- {_link(lecture_paths[lec['id']], f'{when:%a %d %b}: ' + (lec['title'] or 'Lecture'))}")
            out.append("## Lectures\n" + "\n".join(lines))
        if files:
            sections: dict[str, list[str]] = {}
            for f in files:
                sections.setdefault(f["section"], []).append(
                    f"- {_link(file_paths[f['id']], f['name'])} · {f['pages']} pages")
            out.append("## Files\n" + "\n\n".join((f"### {s}\n" if s else "") + "\n".join(lines)
                                                  for s, lines in sections.items()))
        out.append("*Written by Aide. Edit a page and Aide leaves it as you made it.*")
        return "\n\n".join(out) + "\n"

    # -- writing ---------------------------------------------------------------------

    async def sync(self) -> dict[str, int]:
        """Brings the vault in line with the study store. Returns how many files were written and removed."""
        items = await self.render()
        records = {r["path"]: dict(r) for r in self.conn.execute("SELECT * FROM vault_files")}
        written = removed = 0
        for item in items:
            rec = records.pop(item.path, None)
            if await self._put(item, rec):
                written += 1
        for path, rec in records.items():  # what Aide wrote that's no longer wanted
            disk = self.folder / path
            if disk.exists() and self._unchanged(disk, rec):
                disk.unlink()
                self._prune(disk.parent)
                removed += 1
            self.conn.execute("DELETE FROM vault_files WHERE path = ?", (path,))
        if written or removed:
            log.info("vault: wrote %d, removed %d", written, removed)
        return {"written": written, "removed": removed}

    def _unchanged(self, disk: Path, rec: dict) -> bool:
        if disk.suffix == ".pdf":
            return disk.stat().st_size == int(rec["sha"].split(":")[0])
        return _sha(disk.read_bytes()) == rec["sha"]

    async def _put(self, item: Item, rec: dict | None) -> bool:
        disk = self.folder / item.path
        want = item.version if item.source else _sha(item.text.encode())
        if rec is not None:
            if not disk.exists():
                return False  # the user deleted it: theirs to bring back
            if not self._unchanged(disk, rec):
                return False  # the user edited it
            if rec["sha"] == want:
                return False
        elif disk.exists():
            if item.source is None and _sha(disk.read_bytes()) == want:
                self._record(item, want)  # already there, as Aide would write it
            return False  # someone else's file with that name
        disk.parent.mkdir(parents=True, exist_ok=True)
        tmp = disk.with_name(f".{disk.name}.tmp")
        if item.source:
            if not item.source.exists():
                return False
            await asyncio.to_thread(shutil.copyfile, item.source, tmp)
        else:
            tmp.write_text(item.text)
        os.replace(tmp, disk)
        self._record(item, want)
        return True

    def _record(self, item: Item, sha: str) -> None:
        self.conn.execute("INSERT INTO vault_files (path, ref, sha) VALUES (?, ?, ?) "
                          "ON CONFLICT(path) DO UPDATE SET ref = excluded.ref, sha = excluded.sha",
                          (item.path, item.ref, sha))

    def _prune(self, folder: Path) -> None:
        """Removes folders left empty, up to the vault."""
        while folder != self.folder and folder.is_relative_to(self.folder):
            try:
                folder.rmdir()
            except OSError:
                return
            folder = folder.parent
