"""Study tools, for Professor: courses, lectures and their notes. Reading and changing notes run immediately;
deleting a lecture waits for the user's !yes."""

from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from ..study import StudyStore
from . import Tool

TRANSCRIPT_CHARS = 60_000  # read_lecture's transcript, at most


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def study_tools(store: StudyStore, tz: ZoneInfo, audio_dir: Path | None = None) -> list[Tool]:
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

    async def list_courses() -> str:
        courses = await store.courses()
        if not courses:
            return "No courses yet: they come from the study calendar, and none were found."
        lines = []
        for c in courses:
            parts = [c["name"], f"{c['lectures']} lecture(s)"]
            if exam := c["next_exam"]:
                parts.append(f"next exam {exam.start.astimezone(tz):%a %d %b %Y %H:%M} ({exam.title})")
            lines.append(" · ".join(parts))
        if n := store.unfiled():
            lines.append(f"{n} unfiled lecture(s)")
        return "\n".join(lines)

    async def list_lectures(course: str | None = None) -> str:
        lectures = store.lectures(await course_id(course), limit=50)
        return "\n".join(line(lec) for lec in lectures) if lectures else "No lectures yet."

    async def read_lecture(lecture_id: str, transcript: bool = False) -> str:
        lecture = store.find(lecture_id)
        out = [line(lecture).split("\n")[0]]
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
        found = store.search(query, await course_id(course))
        if not found:
            return f"Nothing in the notes or transcripts matches {query!r}."
        return "\n".join(f"{line(lec).split(chr(10))[0]}\n    {lec['snippet']}" for lec in found)

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

    lid = {"lecture_id": {"type": "string", "description": "The id in brackets, l_…"}}
    course = {"course": {"type": "string", "description": "A course name from list_courses; omit for all"}}
    return [
        Tool("list_courses", "List the user's courses (from their timetable calendar), with how many lectures each "
             "has and the next exam.", _obj({}, []), list_courses),
        Tool("list_lectures", "List lectures, newest first, each with its id in brackets and the first line of its "
             "notes.", _obj(course, []), list_lectures),
        Tool("read_lecture", "Read a lecture's notes, and with transcript true its transcript too (time marks like "
             "[12:30]).", _obj({**lid, "transcript": {"type": "boolean"}}, ["lecture_id"]), read_lecture),
        Tool("search_study", "Search every lecture's notes and transcript for words (all must appear), best "
             "matches first, each with a snippet.",
             _obj({"query": {"type": "string"}, **course}, ["query"]), search_study),
        Tool("update_notes", "Replace a lecture's notes with a new full version (markdown, same sections), to add "
             "or fix something the user asked for. Keep everything else as it was. Runs immediately; the previous "
             "version is kept.", _obj({**lid, "notes": {"type": "string"}}, ["lecture_id", "notes"]), update_notes),
        Tool("delete_lecture", "Delete a lecture with its notes and recording. Needs the user's confirmation: it is "
             "queued, and runs only when the user replies !yes.", _obj(lid, ["lecture_id"]), delete_lecture,
             confirm=True, describe=describe_delete, target_arg="lecture_id"),
    ]
