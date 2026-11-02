"""Professor's check_moodle: Moodle is synced every 4 hours (moodle.py), so a grade, a notice or slides put up since
aren't in the course files yet. This syncs now and says what came: the new or changed files, and the new lines on
a course page (where announcements are)."""

import asyncio
from datetime import datetime

from ..db import utcnow
from ..moodle import MoodleSync
from . import Tool

WAIT = 120  # seconds a check waits for the sync
NEW_TEXT = 3000  # characters of a course page's new lines


def moodle_tools(moodle: MoodleSync) -> list[Tool]:
    def pages() -> dict[int, tuple[int | None, str]]:
        return {r[0]: (r[1], r[2]) for r in
                moodle.conn.execute("SELECT moodle_id, course_id, text FROM moodle_courses")}

    async def check_moodle() -> str:
        if not moodle.site:
            return "Moodle isn't set up on this server."
        if not moodle.token:
            return "Moodle isn't connected: the user logs in from the app (Settings → Moodle)."
        started = utcnow().isoformat()
        before = pages()
        try:
            result = await asyncio.wait_for(moodle.sync(), WAIT)
        except asyncio.TimeoutError:
            return "Moodle is slow to answer; the check goes on in the background. Look at the files again in a minute."
        if "error" in result:
            return (f"Moodle couldn't be checked: {result['error']}. If the login expired, the user logs in again "
                    "in the app (Settings → Moodle).")
        out = []
        files = [f for f in moodle.files.files() if f["source"] == "moodle" and f["updated_at"] >= started]
        for f in sorted(files, key=lambda f: f["added_at"]):
            course = (moodle.study.course(f["course_id"]) or {}).get("name", "unfiled")
            kind = "new" if f["added_at"] >= started else "changed"
            put_up = (f" · put up {datetime.fromtimestamp(f['source_time'], moodle.study.tz):%a %d %b %H:%M}"
                      if f["source_time"] else "")
            out.append(f"[{f['public_id']}] {f['name']} ({course}, {kind}{put_up}) · {f['pages']} pages")
        notices = []
        for moodle_id, (course_id, text) in pages().items():
            old = before.get(moodle_id, (None, ""))[1]
            if course_id is None or text == old:
                continue
            seen = set(old.splitlines())
            lines = "\n".join(line for line in text.splitlines() if line.strip() and line not in seen)
            if lines:
                course = (moodle.study.course(course_id) or {}).get("name", "a course")
                notices.append(f"New on the {course} page:\n{lines[:NEW_TEXT]}")
        if not out and not notices:
            return "Checked Moodle just now: nothing new since the last check. What's there is in the course files."
        head = (f"Checked Moodle just now. {len(out)} new or changed file(s), read them with read_file:\n"
                + "\n".join(out)) if out else "Checked Moodle just now: no new files."
        return "\n\n".join([head, *notices])

    return [Tool("check_moodle", "Check Moodle now for what was put up since the last sync (every 4 hours): new or "
                 "changed course files, and new lines on a course page, where notices go. Use it before answering "
                 "about anything that may have just come out on Moodle (grades or results, a notice, new slides), or "
                 "when the user says something is there.", {"type": "object", "properties": {}, "required": [],
                                                            "additionalProperties": False}, check_moodle,
                 step=lambda _: "Checking Moodle")]
