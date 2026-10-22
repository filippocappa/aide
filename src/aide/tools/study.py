"""Study tools, for Professor: courses, lectures and their notes, the course files (slides, handouts), and the
course notebooks (notebook.py). Reading and changing notes run immediately; deleting a lecture waits for the user's
!yes. A notebook is read the way code is searched: its outline first, then one section, never the whole of it."""

import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from ..engine import Engine
from ..notebook import NotebookStore, date_line, sections
from ..study import StudyStore
from . import Tool

TRANSCRIPT_CHARS = 60_000  # read_lecture's transcript, at most
FILE_CHARS = 40_000  # read_file's text, at most
TOPIC_CHARS = 8_000  # read_topic gives a longer page as its opening and a list of sections


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def study_tools(store: StudyStore, tz: ZoneInfo, audio_dir: Path | None = None,
                notebook: NotebookStore | None = None, engine: Engine | None = None) -> list[Tool]:
    def when(lecture: dict) -> str:
        return f"{datetime.fromisoformat(lecture['recorded_at']).astimezone(tz):%a %d %b %Y %H:%M}"

    def course_name(lecture: dict) -> str:
        course = store.course(lecture["course_id"]) if lecture["course_id"] else None
        return course["name"] if course else "unfiled"

    def line(lecture: dict) -> str:
        out = f"[{lecture['public_id']}] {when(lecture)} · {course_name(lecture)} · {lecture['title'] or '(no title)'}"
        if lecture["status"] != "ready":
            out += f" · {lecture['status']}" + (f" ({lecture['error']})" if lecture["error"] else "")
        elif first := next((ln for ln in lecture["notes"].splitlines() if ln.strip()), None):
            out += f"\n    {first.strip()}"
        return out

    async def course_id(name: str | None) -> int | None:
        if not name:
            return None
        await store.courses()
        course = store.course_by_name(name)
        if course is None:
            raise ValueError(f"no course called {name!r}; list_courses has their names")
        return course["id"]

    def file_line(f: dict) -> str:
        where = f["section"] or ("slides of a lecture" if f["lecture_id"] else "course material")
        return f"[{f['public_id']}] {f['name']} · {f['pages']} pages · {where}" + (" · a scan" if f["scanned"] else "")

    async def list_courses() -> str:
        courses = await store.courses()
        if not courses:
            return "No courses yet: they come from the study calendar, and none were found."
        lines = []
        today = datetime.now(tz).date()
        for c in courses:
            parts = [c["name"], f"{c['lectures']} lecture(s)", f"{store.files.count(c['id'])} file(s)"]
            if exam := c["next_exam"]:
                parts.append(f"next exam {exam.start.astimezone(tz):%a %d %b %Y %H:%M} ({exam.title})")
            if notebook and (intro := notebook.intro(c["id"])) and intro["exam"]:
                parts.append(f"the exam: {intro['exam']}")
            lines.append(" · ".join(parts))
            if notebook:  # read from the course's page and files
                lines += [f"    {date_line(d, today)}" for d in notebook.dates(c["id"], since=today)]
        if n := store.unfiled():
            lines.append(f"{n} unfiled lecture(s)")
        return "\n".join(lines)

    async def list_lectures(course: str | None = None) -> str:
        lectures = store.lectures(await course_id(course), limit=50)
        return "\n".join(line(lec) for lec in lectures) if lectures else "No lectures yet."

    async def read_lecture(lecture_id: str, transcript: bool = False) -> str:
        lecture = store.find(lecture_id)
        out = [line(lecture).split("\n")[0]]
        if slides := store.files.files(lecture_id=lecture["id"]):
            out.append("Slides: " + "; ".join(file_line(f) for f in slides))
        if lecture["text"]:
            out.append(f"What the user typed with it:\n{lecture['text']}")
        out.append(f"Notes:\n{lecture['notes']}" if lecture["notes"] else "No notes yet.")
        if transcript:
            text = lecture["transcript"] or "(no recording)"
            if len(text) > TRANSCRIPT_CHARS:
                text = text[:TRANSCRIPT_CHARS] + "\n(transcript cut here; search_study finds later passages)"
            out.append(f"Transcript:\n{text}")
        return "\n\n".join(out)

    async def search_study(query: str, course: str | None = None) -> str:
        cid = await course_id(course)
        topics = notebook.search(query, cid) if notebook else []
        lectures, pages = store.search(query, cid), store.files.search(query, cid)
        if not topics and not lectures and not pages:
            return f"Nothing in the notebooks, notes, transcripts or course files matches {query!r}."
        out = [f"[{t['public_id']}] {t['title']} › {t['heading'] or '(opening)'}\n    {t['snippet']}" for t in topics]
        out += [f"{line(lec).split(chr(10))[0]}\n    {lec['snippet']}" for lec in lectures]
        out += [f"[{p['public_id']}] {p['name']}, p. {p['page']}\n    {p['snippet']}" for p in pages]
        return "\n".join(out)

    async def list_files(course: str | None = None) -> str:
        files = store.files.files(await course_id(course))
        if not files:
            return "No files yet: the user adds them in the Study tab, or they come from Moodle."
        by_course: dict[int | None, list[str]] = {}
        for f in files:
            by_course.setdefault(f["course_id"], []).append(file_line(f))
        return "\n\n".join(f"{(store.course(c) or {}).get('name', 'unfiled')}:\n" + "\n".join(lines)
                           for c, lines in by_course.items())

    async def read_file(file_id: str, first_page: int = 1, last_page: int | None = None) -> str:
        f = store.files.find(file_id)
        if f["scanned"] and not store.files.read_pages(f):
            return f"{file_line(f)}\nIt's a scan whose pages haven't been read yet, so it can't be read here."
        text = store.files.text(f, max(1, first_page), last_page)
        if len(text) > FILE_CHARS:
            text = text[:FILE_CHARS] + "\n(cut here: read the next pages on their own)"
        return f"{file_line(f)}\n\n{text or '(no text on those pages)'}"

    async def update_notes(lecture_id: str, notes: str) -> str:
        lecture = store.update(lecture_id, notes=notes)
        return f"Updated the notes of {line(lecture).split(chr(10))[0]}. The previous version is kept."

    async def delete_lecture(lecture_id: str) -> str:
        lecture = store.delete(lecture_id)
        if lecture is None:
            raise KeyError(f"no lecture {lecture_id}")
        if lecture["audio"] and audio_dir is not None:
            (audio_dir / lecture["audio"]).unlink(missing_ok=True)
        return f"Deleted lecture: {lecture['title'] or when(lecture)}"

    async def describe_delete(lecture_id: str) -> str:
        lecture = store.find(lecture_id)
        return f"Delete the {course_name(lecture)} lecture '{lecture['title'] or '(no title)'}' ({when(lecture)}), " \
               "with its notes and recording"

    async def course_row(name: str) -> dict:
        return store.course(await course_id(name))

    async def notebook_outline(course: str) -> str:
        c = await course_row(course)
        if not notebook.started(c["id"]):
            return f"{c['name']} has no notebook yet. start_notebook sets one up: it proposes the topics first."
        out = [f"The {c['name']} notebook."]
        if (intro := notebook.intro(c["id"])) and intro["exam"]:
            out.append(f"Exam: {intro['exam']}")
        out.append(notebook.outline(c["id"]) or "No topics yet.")
        if waiting := notebook.proposals(c["id"]):
            out.append("Waiting for the user's answer: " + "; ".join(
                f"{p['public_id']} ({p['kind']}, {len(p['items'])} items)" for p in waiting))
        if notebook.busy(c["id"]):
            out.append("Being written right now, in the background.")
        return "\n\n".join(out)

    async def read_topic(topic: str, section: str | None = None) -> str:
        t = notebook.find_topic(topic)
        head = f"[{t['public_id']}] {t['title']}"
        if not t["body"]:
            return f"{head} isn't written yet."
        heads = [h for h, _ in sections(t["body"]) if h]
        if section:
            text = notebook.section(t, section)
            if text is None:
                return f"{head} has no section {section!r}. Its sections: {'; '.join(heads)}"
            return f"{head}\n\n{text}"
        if len(t["body"]) <= TOPIC_CHARS:
            return f"{head}\nFrom: {'; '.join(notebook.source_names(json.loads(t['sources'])))}\n\n{t['body']}"
        opening = next((text for h, text in sections(t["body"]) if not h), "")
        return (f"{head}\n\n{opening}\n\nThe page is long ({len(t['body']):,} characters): read a section by its "
                f"heading. Sections: {'; '.join(heads)}")

    def proposal_text(p: dict) -> str:
        name = (store.course(p["course_id"]) or {}).get("name", "?")
        lines = [f"{p['public_id']} · {name} · {p['kind']} · {p['status']}"]
        for n, it in enumerate(p["items"], 1):
            verb = "expand" if it.get("topic") else "new topic" if p["kind"] == "update" else "topic"
            lines.append(f"  {n}. {verb} {it['title']}: {it.get('add') or it.get('summary') or ''}")
        return "\n".join(lines)

    async def proposals(course: str | None = None) -> str:
        waiting = notebook.proposals(await course_id(course))
        return "\n\n".join(proposal_text(p) for p in waiting) if waiting else "No proposals are waiting."

    async def apply_proposal(proposal: str, items: list[int] | None = None, note: str | None = None) -> str:
        p = notebook.apply(proposal, items, note)
        name = store.course(p["course_id"])["name"]
        return (f"Under way, in the background: {len(p['chosen']['items'])} topic(s) of the {name} notebook. It "
                f"takes a few minutes; the result is posted in the {name} chat, with a notification. Tell the user.")

    async def decline_proposal(proposal: str) -> str:
        notebook.decline(proposal)
        return "Declined: nothing was changed."

    async def edit_topic(topic: str, section: str, text: str) -> str:
        t = notebook.replace_section(notebook.find_topic(topic), section, text)
        return f"Changed the section {section!r} of {t['title']}. The previous version is kept."

    async def start_notebook(course: str) -> str:
        c = await course_row(course)
        notebook.start(c["id"])
        return (f"Started: the {c['name']} Introduction is being written from the course page, then the topics are "
                f"planned from the material and proposed in the {c['name']} chat for the user's OK (a few minutes). "
                "Nothing goes into the notes before that.")

    async def rewrite_introduction(course: str) -> str:
        c = await course_row(course)
        if not notebook.started(c["id"]):
            return f"{c['name']} has no notebook yet. start_notebook sets one up, Introduction included."
        notebook.enqueue(c["id"], "intro")
        return (f"Under way: the {c['name']} Introduction is written again from the course page and what the course "
                "files say about the exam (a minute or two). The topics stay as they are. It's posted in the course chat.")

    async def find_figures(course: str) -> str:
        c = await course_row(course)
        if not notebook.topics(c["id"]):
            return f"The {c['name']} notebook has no topics yet."
        notebook.enqueue(c["id"], "figures", again=True)
        return (f"Under way: each {c['name']} topic's slides get one look (once; new ones later), then figures go into "
                "the topics that miss good ones. Nothing is rewritten. The result comes in the course chat.")

    async def notes_writer(engine_choice: str | None = None, limit_answer: str | None = None) -> str:
        if engine is None:
            return "Notes are written through OpenRouter; there's no other choice on this server."
        out = []
        if limit_answer:
            try:
                engine.decide(limit_answer)
                out.append("Finishing on OpenRouter until the plan resets." if limit_answer == "openrouter"
                           else "Waiting for the plan to reset; the job carries on by itself then.")
            except LookupError:
                out.append("Nothing was waiting on the plan's limit.")
        if engine_choice:
            if engine_choice == "claude" and not engine.available:
                return "Claude Code isn't installed on the server, so the plan can't be used."
            engine.set_engine(engine_choice)
            out.append("From now on notes are written with " +
                       ("the user's Claude plan (Claude Code)." if engine_choice == "claude" else "OpenRouter (paid)."))
        s = engine.status()
        out.append("Writer: " + ("the Claude plan" if s["engine"] == "claude" else "OpenRouter") + ".")
        for name, w in (s["usage"] or {}).items():
            if w.get("used") is not None:
                out.append(f"Plan {name.replace('_', '-')} window: {round(w['used'] * 100)}% used.")
        if s["paused"]:
            out.append("A job is paused on the plan's limit, waiting for the user: wait, or OpenRouter.")
        return " ".join(out)

    lid = {"lecture_id": {"type": "string", "description": "The id in brackets, l_…"}}
    course = {"course": {"type": "string", "description": "A course name from list_courses; omit for all"}}
    one_course = {"course": {"type": "string", "description": "A course name from list_courses"}}
    tid = {"topic": {"type": "string", "description": "The topic's id in brackets, t_…, or its title"}}
    pid = {"proposal": {"type": "string", "description": "The proposal's id, p_…"}}
    notebook_tools = [
        Tool("notebook", "A course notebook's outline: the exam in a line, then each topic with its id, title, "
             "summary, subtopics and how many questions and cards it has, and proposals waiting for the user. No "
             "text: start here, then read_topic what you need.", _obj(one_course, ["course"]), notebook_outline),
        Tool("read_topic", "Read a notebook topic: one section by its heading (Explanation, Key terms, Formulas, "
             "Worked examples, Exam-style questions, or a subtopic), or the whole page when it's short.",
             _obj({**tid, "section": {"type": "string"}}, ["topic"]), read_topic),
        Tool("proposals", "The notebook proposals waiting for the user's answer: what Aide would write or add, item "
             "by item, numbered.", _obj(course, []), proposals),
        Tool("apply_proposal", "The user agreed to a proposal: write it, all of it or the items they chose (by "
             "number), with what they asked for besides as note (\"stress the graphs\", \"merge 3 and 4\"). Runs "
             "in the background.", _obj({**pid, "items": {"type": "array", "items": {"type": "integer"}},
                                         "note": {"type": "string"}}, ["proposal"]), apply_proposal),
        Tool("decline_proposal", "The user doesn't want a proposal: drop it.", _obj(pid, ["proposal"]),
             decline_proposal),
        Tool("edit_topic", "Replace one section of a topic page with new text (its heading is kept; a new section "
             "when there's none by that name), for a change the user asked for. Runs immediately; the previous "
             "version is kept.", _obj({**tid, "section": {"type": "string"}, "text": {"type": "string"}},
                                      ["topic", "section", "text"]), edit_topic),
        Tool("start_notebook", "Set up a course's notebook: an Introduction (the exam, how to prepare) written now, "
             "and the topics proposed to the user, from all the course's material. Runs in the background.",
             _obj(one_course, ["course"]), start_notebook),
        Tool("rewrite_introduction", "Write a course notebook's Introduction (the exam, how to prepare, textbook, "
             "instructors) again, from the course page and the course files, when it's wrong or out of date (a new "
             "exam notice). The topics aren't touched. Runs in the background.",
             _obj(one_course, ["course"]), rewrite_introduction),
        Tool("find_figures", "Look at the slides of a course's topics once and add figures (graphs, diagrams) to the "
             "topics that miss good ones, when the user wants more pictures in the notes. Runs in the background; "
             "nothing is rewritten.", _obj(one_course, ["course"]), find_figures),
        Tool("notes_writer", "Who writes the study notes: the user's Claude plan (Claude Code on the server, no extra "
             "cost) or OpenRouter (paid). Without arguments it says which, and how much of the plan is used. "
             "engine_choice switches it when the user asks; limit_answer is their answer when a job is paused on "
             "the plan's limit: wait for the reset, or finish on OpenRouter.",
             _obj({"engine_choice": {"type": "string", "enum": ["claude", "openrouter"]},
                   "limit_answer": {"type": "string", "enum": ["wait", "openrouter"]}}, []), notes_writer),
    ] if notebook else []
    return [
        Tool("list_courses", "List the user's courses (from their timetable calendar), with how many lectures each "
             "has, the next exam, how the exam works, and what's coming from the course's page and files (exams, "
             "mid-terms, sign-up deadlines).", _obj({}, []), list_courses),
        Tool("list_lectures", "List lectures, newest first, each with its id in brackets and the first line of its "
             "notes.", _obj(course, []), list_lectures),
        Tool("read_lecture", "Read a lecture's notes, and with transcript true its transcript too (time marks like "
             "[12:30]).", _obj({**lid, "transcript": {"type": "boolean"}}, ["lecture_id"]), read_lecture),
        Tool("search_study", "Search every lecture's notes and transcript, and the course files page by page, for "
             "words (all must appear), best matches first, each with a snippet.",
             _obj({"query": {"type": "string"}, **course}, ["query"]), search_study),
        Tool("list_files", "List the course files (slides, handouts, the professor's notes: PDFs from the user or "
             "Moodle), each with its id in brackets.", _obj(course, []), list_files),
        Tool("read_file", "Read a file's text, page by page (each starts with [p. N]); for a long one, a range of "
             "pages.", _obj({"file_id": {"type": "string", "description": "The id in brackets, f_…"},
                             "first_page": {"type": "integer"}, "last_page": {"type": "integer"}}, ["file_id"]),
             read_file),
        Tool("update_notes", "Replace a lecture's notes with a new full version (markdown, same sections), to add "
             "or fix something the user asked for. Keep everything else as it was. Runs immediately; the previous "
             "version is kept.", _obj({**lid, "notes": {"type": "string"}}, ["lecture_id", "notes"]), update_notes),
        Tool("delete_lecture", "Delete a lecture with its notes and recording. Needs the user's confirmation: it is "
             "queued, and runs only when the user replies !yes.", _obj(lid, ["lecture_id"]), delete_lecture,
             confirm=True, describe=describe_delete, target_arg="lecture_id"),
        *notebook_tools,
    ]
