"""Course dates that aren't exams or mid-terms (a sign-up opening, a sign-up or hand-in deadline) as reminders.

The course page shows only exams and mid-terms; the rest of what Professor and Esse3 read is something to do on a
day, so it becomes a reminder (the reminders store, synced to Apple Reminders, which notifies on the day). One
reminder per date, kept in step as the dates change: moved when the date moves, deleted when the date is gone or
something says it's done (`you` set: signed up already, registration accepted). A reminder the user ticked or
deleted is left alone, and a date that has passed lets go of its reminder. Only dates from today on get one.
"""

import logging
from datetime import date, datetime, time
from zoneinfo import ZoneInfo

log = logging.getLogger(__name__)

KINDS = ("deadline", "other")
AT = time(9, 0)  # when a reminder goes off on its day, unless the date says an earlier time

SCHEMA = """
CREATE TABLE IF NOT EXISTS date_reminders (
    course_id   INTEGER NOT NULL,
    date_id     TEXT NOT NULL,
    reminder_id TEXT NOT NULL,
    PRIMARY KEY (course_id, date_id)
);
"""


class DateReminders:
    def __init__(self, notebook, reminders, tz: ZoneInfo, today=None):
        self.notebook = notebook
        self.reminders = reminders
        self.tz = tz
        self.conn = notebook.conn
        self.conn.executescript(SCHEMA)
        self._today = today or (lambda: datetime.now(tz).date())

    def changed(self, course_id: int, what: str) -> None:
        """NotebookStore's change listener."""
        if what == "the course's dates":
            self.sync(course_id)

    def sync_all(self) -> None:
        ids = {r[0] for r in self.conn.execute(
            "SELECT course_id FROM official_dates UNION SELECT course_id FROM course_dates "
            "UNION SELECT course_id FROM course_date_edits UNION SELECT course_id FROM date_reminders")}
        for course_id in sorted(ids):
            try:
                self.sync(course_id)
            except Exception:
                log.exception("date reminders: course %s", course_id)

    def sync(self, course_id: int) -> None:
        today = self._today()
        items = {d["id"]: d for d in self.notebook.dates(course_id)}
        want = {i: d for i, d in items.items()
                if d["kind"] in KINDS and d["date"] >= today.isoformat() and not d.get("you")}
        have = {r["date_id"]: r["reminder_id"] for r in self.conn.execute(
            "SELECT date_id, reminder_id FROM date_reminders WHERE course_id = ?", (course_id,))}
        name = self._name(course_id)
        for date_id, d in want.items():
            title, due, notes = self._reminder(d, name)
            rem = self.reminders.get(have[date_id]) if date_id in have else None
            if date_id not in have:
                rem = self.reminders.create(title, due, notes)
                self.conn.execute("INSERT INTO date_reminders (course_id, date_id, reminder_id) VALUES (?, ?, ?)",
                                  (course_id, date_id, rem.id))
            elif rem is not None and not rem.deleted and not rem.completed and \
                    (rem.title, rem.due_at, rem.notes) != (title, due, notes):
                self.reminders.update(rem.id, title=title, due_at=due, notes=notes)
        for date_id, reminder_id in have.items():
            if date_id in want:
                continue
            d = items.get(date_id)
            if d is None or d["date"] >= today.isoformat():  # gone, done, or no longer a reminder's kind
                rem = self.reminders.get(reminder_id)
                if rem is not None and not rem.deleted and not rem.completed:
                    self.reminders.delete(reminder_id)
            self.conn.execute("DELETE FROM date_reminders WHERE course_id = ? AND date_id = ?", (course_id, date_id))

    def _name(self, course_id: int) -> str:
        course = self.notebook.study.course(course_id)
        name = course["name"] if course else "Course"
        return name[:1].upper() + name[1:]

    def _reminder(self, d: dict, name: str) -> tuple[str, datetime, str]:
        what = d["what"][:1].lower() + d["what"][1:] if d["what"][1:2].islower() else d["what"]
        at = AT
        if d.get("time"):
            hh, mm = map(int, d["time"].split(":"))
            at = min(AT, time(hh, mm)) if d["kind"] == "deadline" else time(hh, mm)
        due = datetime.combine(date.fromisoformat(d["date"]), at, self.tz)
        notes = " ".join(x for x in (d.get("details"), f"From {d['source']}." if d.get("source") else "") if x)
        return f"{name}: {what}", due, notes
