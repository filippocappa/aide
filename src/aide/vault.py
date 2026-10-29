"""The Obsidian vault on this server: Aide writes the study notes and files into it as markdown and PDFs, and
webdav.py serves it, so Obsidian on the phone and the Mac syncs it (the Remotely Save plugin, over Tailscale).

Everything Aide writes is under Aide/ in the vault, one folder per course:
- with a notebook (notebook.py): "00 Introduction.md", a page per topic ("01 The IS-LM model.md"), Cards/ with
  the topic's flashcards for the Spaced Repetition plugin, and Images/ with the slides the topics show as figures;
- otherwise an index page named after the course;
- and in every course, Sources/ with a page per lecture, and Files/ with the PDFs.

Aide only changes what it wrote: a file the user edited (its hash isn't the one Aide wrote) or deleted is theirs
from then on, and Aide leaves it alone. Two exceptions. A topic page is shared: the user's edits are read back into
the notebook (pull), Aide's later changes build on them and are written over the page. A cards file is only ever
added to, a line per new card, since the plugin writes its review data into it. Renamed or deleted lectures and
topics move or remove their page, when it's unedited.
"""

import asyncio
import hashlib
import json
import logging
import os
import re
import shutil
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from .material import page_image
from .notebook import FIGURE, date_line, figures, max_points, mock_paper, mock_title
from .study import StudyStore

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS vault_files (
    path TEXT PRIMARY KEY,  -- relative to the vault
    ref  TEXT NOT NULL,  -- what it shows: a lecture, file or course id; intro:, topic:, cards:, figure:, formulas:, exercises:, mock:
    sha  TEXT NOT NULL  -- of what Aide wrote (a PDF: its version, size and time; an image: its size and version)
);
"""

ROOT = "Aide"
INTERVAL = 60  # seconds between syncs when nothing kicks one
_BAD = re.compile(r'[\\/:*?"<>|#^\[\]]+')  # not in file names, or they break Obsidian's links
_WIKILINK = re.compile(r"\[\[([^\]|#]+)(#[^\]|]*)?(?:\|([^\]]*))?\]\]")
_EMBED = re.compile(r"!\[\[([^\]|]+\.jpg)(?:\|[^\]]*)?\]\](?:[ \t]*\n\*([^*\n]*)\*)?")
FIGURE_SIDE = 1400  # pixels: a slide drawn for a page, sharp on a laptop


@dataclass
class Item:
    path: str
    ref: str
    text: str | None = None  # markdown, or
    source: Path | None = None  # a PDF to copy
    version: str = ""  # the PDF's
    cards: list[str] = field(default_factory=list)  # a cards file: its card lines, added to what's there
    page: tuple[Path, int] | None = None  # an image: this page of this PDF, drawn


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


def _links_out(body: str, paths: dict[str, str]) -> str:
    """[[Topic title]] in a topic's body as a link Obsidian resolves: [[Aide/course/03 Topic title|Topic title]]."""
    def sub(m: re.Match) -> str:
        path = paths.get(m.group(1).strip().casefold())
        if path is None:
            return m.group(0)
        return f"[[{path.removesuffix('.md')}{m.group(2) or ''}|{m.group(3) or m.group(1).strip()}]]"
    return _WIKILINK.sub(sub, body)


def _links_in(body: str, titles: dict[str, str]) -> str:
    """The reverse, for a page read back: a link to a topic's page (by path or name) becomes [[Topic title]]."""
    def sub(m: re.Match) -> str:
        title = titles.get(m.group(1).strip().casefold())
        if title is None:
            return m.group(0)
        label = m.group(3)
        return f"[[{title}{m.group(2) or ''}" + (f"|{label}]]" if label and label != title else "]]")
    return _WIKILINK.sub(sub, body)


def _figures_out(body: str, images: dict[tuple[str, int], str]) -> str:
    """![caption](figure:f_…/12) as the drawn page embedded, its caption in italics under it."""
    def sub(m: re.Match) -> str:
        path = images.get((m.group(2), int(m.group(3))))
        if path is None:
            return m.group(0)
        return f"![[{path}]]" + (f"\n*{m.group(1)}*" if m.group(1) else "")
    return FIGURE.sub(sub, body)


def _figures_in(body: str, figures: dict[str, str]) -> str:
    """The reverse: an embedded figure (by path or file name) and the caption under it, as ![caption](figure:…)."""
    def sub(m: re.Match) -> str:
        ref = figures.get(m.group(1).strip().casefold())
        return m.group(0) if ref is None else f"![{(m.group(2) or '').strip()}]({ref})"
    return _EMBED.sub(sub, body)


def topic_body(page: str, titles: dict[str, str], figures: dict[str, str] | None = None) -> str:
    """A topic page's body: without its frontmatter and its "# " title."""
    if page.startswith("---\n") and (end := page.find("\n---", 4)) >= 0:
        page = page[end + 4:]
    page = page.lstrip("\n")
    if page.startswith("# "):
        page = page.partition("\n")[2]
    return _links_in(_figures_in(page.strip(), figures or {}), titles)


def _question(line: str) -> str | None:
    return line.split("::", 1)[0].strip().casefold() if "::" in line else None


class Vault:
    def __init__(self, folder: Path, study: StudyStore, notebook=None):
        self.folder = folder
        self.study = study
        self.notebook = notebook  # NotebookStore, or None: no notebook pages
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

    # -- the notebook's pages ------------------------------------------------------------

    def _folder(self, course: dict) -> str:
        return f"{ROOT}/{_file_name(course['name'])}"

    def _topic_paths(self, course: dict) -> dict[int, str]:
        """The written topics' pages, numbered in order: {topic row id: path}."""
        if self.notebook is None:
            return {}
        written = [t for t in self.notebook.topics(course["id"]) if t["body"]]
        return {t["id"]: f"{self._folder(course)}/{n:02d} {_file_name(t['title'])}.md" for n, t in enumerate(written, 1)}

    def _titles(self) -> dict[str, str]:
        """Every topic page's path and name (casefolded, no .md) → the topic's title: for reading links back."""
        out = {}
        if self.notebook is None:
            return out
        for row in self.conn.execute("SELECT DISTINCT course_id FROM topics").fetchall():
            if course := self.study.course(row[0]):
                titles = {t["id"]: t["title"] for t in self.notebook.topics(course["id"])}
                for tid, path in self._topic_paths(course).items():
                    stem = path.removesuffix(".md")
                    out[stem.casefold()] = out[stem.rsplit("/", 1)[1].casefold()] = titles[tid]
        return out

    def pull(self) -> int:
        """Topic pages the user changed, read back into the notebook. How many."""
        if self.notebook is None:
            return 0
        changed, titles = 0, None
        figures = {}  # an embedded image's path and file name → figure:f_…/12
        for rec in self.conn.execute("SELECT path, ref FROM vault_files WHERE ref LIKE 'figure:%'"):
            figures[rec["path"].casefold()] = figures[rec["path"].rsplit("/", 1)[-1].casefold()] = rec["ref"]
        for rec in self.conn.execute("SELECT * FROM vault_files WHERE ref LIKE 'topic:%'").fetchall():
            disk = self.folder / rec["path"]
            if not disk.exists():
                continue
            data = disk.read_bytes()
            if _sha(data) == rec["sha"] or (topic := self.notebook.topic(rec["ref"][6:])) is None:
                continue
            titles = titles if titles is not None else self._titles()
            body = topic_body(data.decode(errors="replace"), titles, figures)
            if not body:
                continue  # emptied: left as the user made it, like any edited page
            if body != topic["body"]:
                self.notebook.set_body(topic["id"], body, by_user=True)
                changed += 1
            self.conn.execute("UPDATE vault_files SET sha = ? WHERE path = ?", (_sha(data), rec["path"]))
        if changed:
            log.info("vault: read back %d edited topic page(s)", changed)
        return changed

    # -- what the vault should hold ----------------------------------------------------

    async def render(self) -> list[Item]:
        study, tz = self.study, self.study.tz
        # Folders come from the stored courses, so a calendar that's briefly unreachable moves nothing; the
        # calendar only adds the next exam.
        live = {c["id"]: c for c in await study.courses()}
        rows = [lec for lec in study.lectures(limit=100_000) if lec["notes"]]
        all_files = study.files.files()
        noted = set()
        if self.notebook is not None:
            noted = {r[0] for r in self.conn.execute("SELECT course_id FROM course_intros UNION "
                                                     "SELECT course_id FROM topics WHERE body != ''")}
        courses = {}
        for cid in sorted(({r["course_id"] for r in (*rows, *all_files)} | noted) - {None}):
            if stored := study.course(cid):
                courses[cid] = {"next_exam": None, **stored, **live.get(cid, {})}
        folders = {cid: self._folder(c) for cid, c in courses.items()}
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
        # The notebook: topic pages and their cards, and which lectures each topic was built from.
        topic_paths: dict[int, str] = {}
        expanded: dict[str, list[str]] = {}  # lecture public id → links to the topics it went into
        practice: dict[int, list[str]] = {}  # course id → its formula sheet and exercises, for the Introduction
        for cid in noted & courses.keys():
            course = courses[cid]
            paths = self._topic_paths(course)
            topic_paths |= paths
            topics = [t for t in self.notebook.topics(cid) if t["id"] in paths]
            by_title = {t["title"].casefold(): paths[t["id"]] for t in topics}
            images: dict[tuple[str, int], str] = {}
            for t in topics:
                for _, fid, n in figures(t["body"]):
                    f = study.files.get(fid)
                    if f is None or (fid, n) in images:
                        continue
                    images[(fid, n)] = f"{folders[cid]}/Images/{_file_name(f['name'].removesuffix('.pdf'))} p{n}.jpg"
                    items.append(Item(images[(fid, n)], f"figure:{fid}/{n}", page=(study.files.path(f), n),
                                      version=f"{f['size']}:{f['updated_at']}"))
            sets = {e["topic_id"]: e for e in self.notebook.exercise_sets(cid) if e["topic_id"] in paths}
            exercise_paths = {tid: f"{folders[cid]}/Exercises/{paths[tid].rsplit('/', 1)[1]}" for tid in sets}
            for t in topics:
                items.append(Item(paths[t["id"]], f"topic:{t['public_id']}",
                                  self._topic(t, course, by_title, images, exercise_paths.get(t["id"]))))
                if cards := json.loads(t["cards"]):
                    items.append(Item(f"{folders[cid]}/Cards/{_file_name(t['title'])}.md", f"cards:{t['public_id']}",
                                      self._cards_head(t, course, paths[t["id"]]),
                                      cards=[f"{q}::{a}" for q, a in cards]))
                for s in json.loads(t["sources"]):
                    if "lecture" in s:
                        expanded.setdefault(s["lecture"], []).append(_link(paths[t["id"]], t["title"]))
            if sheet := self.notebook.formulas(cid):
                practice.setdefault(cid, []).append(_link(f"{folders[cid]}/Formulas.md", "Formulas"))
                items.append(Item(f"{folders[cid]}/Formulas.md", f"formulas:{cid}",
                                  self._formulas(course, _figures_out(_links_out(sheet, by_title), images))))
            for tid, e in sets.items():
                items.append(Item(exercise_paths[tid], f"exercises:{e['public_id']}",
                                  self._exercises(e, course, paths[tid], _links_out(e["body"], by_title))))
            if sets:
                practice.setdefault(cid, []).append("Exercises: " + ", ".join(
                    _link(exercise_paths[e["topic_id"]], e["topic_title"]) for e in sets.values()))
            if mocks := self.notebook.mocks(cid):
                # The course's own papers apart from the ones Aide wrote.
                mock_paths = {m["id"]: f"{folders[cid]}/Past exams/{_file_name(mock_title(m))}.md" if m["source"]
                              else f"{folders[cid]}/Mock exams/Mock exam {m['number']}.md" for m in mocks}
                for m in mocks:
                    items.append(Item(mock_paths[m["id"]], f"mock:{m['public_id']}",
                                      self._mock(m, course, _links_out(m["body"], by_title))))
                for label, kind in (("Past exams", True), ("Mock exams", False)):
                    if some := [m for m in mocks if bool(m["source"]) == kind]:
                        practice.setdefault(cid, []).append(f"{label}: " + ", ".join(
                            _link(mock_paths[m["id"]], mock_title(m)) for m in some))
        lecture_paths: dict[int, str] = {}
        for lec in sorted(rows, key=lambda r: (r["recorded_at"], r["id"])):
            folder = folders.get(lec["course_id"], f"{ROOT}/Unfiled")
            when = datetime.fromisoformat(lec["recorded_at"]).astimezone(tz)
            stem = f"{when:%Y-%m-%d} {_file_name(lec['title'] or 'Lecture')}"
            path, n = f"{folder}/Sources/{stem}.md", 2
            while path in lecture_paths.values():
                path, n = f"{folder}/Sources/{stem} {n}.md", n + 1
            lecture_paths[lec["id"]] = path
        for lec in rows:
            course = courses.get(lec["course_id"])
            index = (f"{folders[course['id']]}/00 Introduction.md" if course["id"] in noted else
                     f"{folders[course['id']]}/{_file_name(course['name'])}.md") if course else None
            items.append(Item(lecture_paths[lec["id"]], lec["public_id"],
                              self._lecture(lec, course, index, file_paths, expanded.get(lec["public_id"], []))))
        for cid, c in courses.items():
            lectures = [lec for lec in rows if lec["course_id"] == cid]
            files = [f for f in all_files if f["course_id"] == cid]
            if cid in noted:
                items.append(Item(f"{folders[cid]}/00 Introduction.md", f"intro:{cid}",
                                  self._introduction(c, topic_paths, lectures, lecture_paths, files, file_paths,
                                                     practice.get(cid, []))))
            elif lectures or files:
                items.append(Item(f"{folders[cid]}/{_file_name(c['name'])}.md", f"course:{cid}",
                                  self._course(c, lectures, lecture_paths, files, file_paths)))
        return items

    def _lecture(self, lec: dict, course: dict | None, index: str | None, file_paths: dict,
                 expanded: list[str]) -> str:
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
        if name and index:
            head.insert(0, _link(index, name))
        if lec["duration_s"]:
            m = round(lec["duration_s"] / 60)
            head.append(f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min")
        out = ["\n".join(meta), f"# {lec['title'] or 'Lecture'}", " · ".join(head)]
        slides = self.study.files.files(lecture_id=lec["id"])
        if slides:
            out.append("Slides: " + ", ".join(_link(file_paths[f["id"]], f["name"]) for f in slides
                                              if f["id"] in file_paths))
        if expanded:
            out.append("Expanded: " + ", ".join(expanded))
        out.append(lec["notes"])
        if lec["text"]:
            out.append("> [!note]- What you typed\n" + _quote(lec["text"]))
        if lec["transcript"]:
            out.append("> [!quote]- Transcript\n" + _quote(lec["transcript"]))
        return "\n\n".join(out) + "\n"

    def _topic(self, t: dict, course: dict, by_title: dict[str, str], images: dict,
               exercises: str | None = None) -> str:
        folder = self._folder(course)
        meta = ["---", f'course: "{_link(f"{folder}/00 Introduction.md", course["name"])}"',
                f'cards: "{_link(f"{folder}/Cards/{_file_name(t["title"])}.md", "Cards")}"' if json.loads(t["cards"])
                else None, f'exercises: "{_link(exercises, "Exercises")}"' if exercises else None,
                f"topic: {t['public_id']}", "tags:", "  - topic", f"  - {_tag(course['name'])}", "---"]
        body = _figures_out(_links_out(t["body"], by_title), images)
        return "\n".join(m for m in meta if m) + f"\n\n# {t['title']}\n\n{body}\n"

    def _cards_head(self, t: dict, course: dict, page: str) -> str:
        return f"#flashcards/{_tag(course['name'])}\n\nCards for {_link(page, t['title'])}. Aide adds new ones at the end.\n\n"

    def _formulas(self, course: dict, sheet: str) -> str:
        folder = self._folder(course)
        return (f'---\ncourse: "{_link(f"{folder}/00 Introduction.md", course["name"])}"\ntags:\n  - formulas\n'
                f"  - {_tag(course['name'])}\n---\n\n# Formulas: {course['name']}\n\n{sheet}\n\n"
                "*Gathered by Aide from the topics' Formulas, and kept in step with them. Edit a topic's to change "
                "it here; edit this page and Aide leaves it as you made it.*\n")

    def _exercises(self, e: dict, course: dict, page: str, body: str) -> str:
        folder = self._folder(course)
        return (f'---\ncourse: "{_link(f"{folder}/00 Introduction.md", course["name"])}"\n'
                f'topic: "{_link(page, e["topic_title"])}"\ntags:\n  - exercises\n  - {_tag(course["name"])}\n---\n\n'
                f"# Exercises: {e['topic_title']}\n\nFor {_link(page, e['topic_title'])}. Try each before opening its "
                f"solution.\n\n{body}\n\n*The course's own exercises, from its exercise sheets and past exams, solved "
                "by Aide (following the course's solutions where it has them). Edit this page and Aide leaves it as "
                "you made it.*\n")

    def _mock(self, m: dict, course: dict, body: str) -> str:
        """The paper as it would be printed, then its answers: a mock taken on paper, the answers looked at after."""
        folder = self._folder(course)
        paper, answers = mock_paper(body)
        s = m["scoring"]
        mcq = any(q["type"] == "mcq" for q in m["questions"])
        rules = [f"{m['minutes']} minutes" if m["minutes"] else None,
                 f"{max_points(m['questions'], s):g} points",
                 (f"multiple choice: right {s['right']:g}, wrong {s['wrong']:g}, blank {s['blank']:g}" if mcq else None)]
        source = self.notebook.files.get(m["source"]) if m["source"] else None
        made = (f"*The course's own paper, copied from {source['name'] if source else 'its files'}; the answers are "
                "Aide's where the paper had none." if m["source"] else "*Written by Aide like the real exam.")
        return (f'---\ncourse: "{_link(f"{folder}/00 Introduction.md", course["name"])}"\ntags:\n'
                f"  - {'past-exam' if m['source'] else 'mock-exam'}\n"
                f"  - {_tag(course['name'])}\n---\n\n# {mock_title(m)}: {course['name']}\n\n"
                f"{' · '.join(r for r in rules if r)}\n\n{paper}\n\n---\n\n## Answers\n\n{answers}\n\n"
                f"{made} Take it in the app, timed and marked, or here on paper. Edit this page and Aide leaves it as "
                "you made it.*\n")

    def _introduction(self, c: dict, topic_paths: dict, lectures: list[dict], lecture_paths: dict,
                      files: list[dict], file_paths: dict, practice: list[str] = ()) -> str:
        tz = self.study.tz
        intro = self.notebook.intro(c["id"])
        out = [f"---\ntags:\n  - course\n  - {_tag(c['name'])}\n---", f"# {c['name']}"]
        if exam := c["next_exam"]:
            out.append(f"Next exam: {exam.start.astimezone(tz):%a %d %b %Y, %H:%M} ({exam.title})")
        if intro:
            out.append(intro["body"])
        if dates := self.notebook.dates(c["id"]):
            out.append("## Dates\n" + "\n".join(f"- {date_line(d)}" for d in dates))
        topics = self.notebook.topics(c["id"])
        if topics:
            lines = []
            for n, t in enumerate(topics, 1):
                name = _link(topic_paths[t["id"]], t["title"]) if t["id"] in topic_paths else f"{t['title']} (not written yet)"
                lines.append(f"{n}. {name}" + (f": {t['summary']}" if t["summary"] else ""))
            out.append("## Topics\n" + "\n".join(lines))
        if practice:
            out.append("## Practice\n" + "\n".join(f"- {link}" for link in practice))
        if lectures:
            lines = []
            for lec in sorted(lectures, key=lambda r: r["recorded_at"]):
                when = datetime.fromisoformat(lec["recorded_at"]).astimezone(tz)
                lines.append(f"- {_link(lecture_paths[lec['id']], f'{when:%a %d %b}: ' + (lec['title'] or 'Lecture'))}")
            out.append("## Lectures\n" + "\n".join(lines))
        if files:
            out.append("## Files\n" + self._file_list(files, file_paths))
        out.append("*Written by Aide. Edit a topic page and Aide builds on your version; edit this page and Aide "
                   "leaves it as you made it.*")
        return "\n\n".join(out) + "\n"

    @staticmethod
    def _file_list(files: list[dict], file_paths: dict) -> str:
        sections: dict[str, list[str]] = {}
        for f in files:
            sections.setdefault(f["section"], []).append(f"- {_link(file_paths[f['id']], f['name'])} · {f['pages']} pages")
        return "\n\n".join((f"### {s}\n" if s else "") + "\n".join(lines) for s, lines in sections.items())

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
            out.append("## Files\n" + self._file_list(files, file_paths))
        out.append("*Written by Aide. Edit a page and Aide leaves it as you made it.*")
        return "\n\n".join(out) + "\n"

    # -- writing ---------------------------------------------------------------------

    async def sync(self) -> dict[str, int]:
        """Brings the vault in line with the study store, after reading back the user's topic edits. Returns how
        many files were written and removed."""
        self.pull()
        items = await self.render()
        records = {r["path"]: dict(r) for r in self.conn.execute("SELECT * FROM vault_files")}
        written = removed = 0
        for item in items:
            rec = records.pop(item.path, None)
            put = self._put_cards if item.cards else self._put_page if item.page else self._put
            if await put(item, rec):
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
        if disk.suffix in (".pdf", ".jpg"):
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

    async def _put_page(self, item: Item, rec: dict | None) -> bool:
        """A slide drawn as an image for a figure. Recorded as its size and the PDF's version: drawn again when the
        PDF changes, left alone when the user replaced it."""
        disk = self.folder / item.path
        if rec is not None:
            if not disk.exists() or not self._unchanged(disk, rec):
                return False
            if rec["sha"].split(":", 1)[1] == item.version:
                return False
        elif disk.exists():
            return False  # someone else's file with that name
        if not item.page[0].exists():
            return False
        try:
            data = await page_image(*item.page, FIGURE_SIDE)
        except Exception as e:
            log.warning("vault: couldn't draw %s: %s", item.path, e)
            return False
        disk.parent.mkdir(parents=True, exist_ok=True)
        tmp = disk.with_name(f".{disk.name}.tmp")
        tmp.write_bytes(data)
        os.replace(tmp, disk)
        self._record(item, f"{len(data)}:{item.version}")
        return True

    async def _put_cards(self, item: Item, rec: dict | None) -> bool:
        """A cards file: written whole the first time; after that only new cards are added at the end, so the
        plugin's review data on the others stays."""
        disk = self.folder / item.path
        if not disk.exists():
            if rec is not None:
                return False  # the user deleted it
            text = item.text + "\n".join(item.cards) + "\n"
        else:
            text = disk.read_text(errors="replace")
            if rec is None and not text.startswith(item.text.split("\n", 1)[0]):
                return False  # someone else's file with that name
            have = {q for line in text.splitlines() if (q := _question(line))}
            new = [c for c in item.cards if _question(c) not in have]
            if not new:
                if rec is None:
                    self._record(item, _sha(text.encode()))
                return False
            text = text + ("" if text.endswith("\n") else "\n") + "\n".join(new) + "\n"
        disk.parent.mkdir(parents=True, exist_ok=True)
        tmp = disk.with_name(f".{disk.name}.tmp")
        tmp.write_text(text)
        os.replace(tmp, disk)
        self._record(item, _sha(text.encode()))
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
