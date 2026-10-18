"""Reminders: the server's master list, kept in sync with Apple Reminders by the iOS app.

Sync rules are in docs/API.md. Every write bumps a global `seq`, and a sync cursor is
simply the highest seq the app has seen.
"""

import sqlite3
import uuid
from dataclasses import dataclass, replace
from datetime import datetime, timezone

SCHEMA = """
CREATE TABLE IF NOT EXISTS reminders (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    notes       TEXT NOT NULL DEFAULT '',
    due_at      TEXT,                       -- UTC ISO-8601, or NULL
    completed   INTEGER NOT NULL DEFAULT 0,
    apple_id    TEXT UNIQUE,                -- set once the reminder is on the phone
    modified_at TEXT NOT NULL,              -- last content change, either side (UTC)
    deleted     INTEGER NOT NULL DEFAULT 0, -- tombstone
    notified    INTEGER NOT NULL DEFAULT 0, -- Discord fallback already sent
    seq         INTEGER NOT NULL            -- server change counter, for sync cursors
);
CREATE INDEX IF NOT EXISTS reminders_seq ON reminders(seq);
CREATE INDEX IF NOT EXISTS reminders_due ON reminders(due_at) WHERE completed = 0 AND deleted = 0;
"""


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def parse_time(value: str | None) -> datetime | None:
    if value is None:
        return None
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError(f"time without a UTC offset: {value!r}")
    return dt.astimezone(timezone.utc)


def _utc(dt: datetime | None) -> str | None:
    return dt.astimezone(timezone.utc).isoformat() if dt else None


@dataclass(frozen=True)
class Reminder:
    id: str
    title: str
    notes: str
    due_at: datetime | None
    completed: bool
    apple_id: str | None
    modified_at: datetime
    deleted: bool = False


class ReminderStore:
    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn
        self.conn.executescript(SCHEMA)
        # Times are compared as strings, so they must all be UTC. Rows written before _save normalised them:
        for r in self.conn.execute("SELECT id, due_at, modified_at FROM reminders WHERE due_at NOT LIKE '%+00:00' "
                                   "OR modified_at NOT LIKE '%+00:00'").fetchall():
            self.conn.execute("UPDATE reminders SET due_at = ?, modified_at = ? WHERE id = ?",
                              (_utc(parse_time(r["due_at"])), _utc(parse_time(r["modified_at"])), r["id"]))

    # -- reading -----------------------------------------------------------

    @staticmethod
    def _row(r) -> Reminder:
        return Reminder(
            id=r["id"], title=r["title"], notes=r["notes"],
            due_at=parse_time(r["due_at"]), completed=bool(r["completed"]),
            apple_id=r["apple_id"], modified_at=parse_time(r["modified_at"]), deleted=bool(r["deleted"]),
        )

    def get(self, reminder_id: str) -> Reminder | None:
        r = self.conn.execute("SELECT * FROM reminders WHERE id = ?", (reminder_id,)).fetchone()
        return self._row(r) if r else None

    def by_apple_id(self, apple_id: str) -> Reminder | None:
        r = self.conn.execute("SELECT * FROM reminders WHERE apple_id = ?", (apple_id,)).fetchone()
        return self._row(r) if r else None

    def open(self) -> list[Reminder]:
        """Not completed, not deleted; ordered by due time, undated last."""
        rows = self.conn.execute(
            "SELECT * FROM reminders WHERE completed = 0 AND deleted = 0 "
            "ORDER BY due_at IS NULL, due_at, title"
        ).fetchall()
        return [self._row(r) for r in rows]

    def due_before(self, end: datetime) -> list[Reminder]:
        """Open reminders due before `end` (overdue included)."""
        rows = self.conn.execute(
            "SELECT * FROM reminders WHERE completed = 0 AND deleted = 0 AND due_at < ? ORDER BY due_at",
            (end.astimezone(timezone.utc).isoformat(),),
        ).fetchall()
        return [self._row(r) for r in rows]

    def changed_since(self, cursor: int) -> list[Reminder]:
        rows = self.conn.execute("SELECT * FROM reminders WHERE seq > ? ORDER BY seq", (cursor,)).fetchall()
        return [self._row(r) for r in rows]

    def cursor(self) -> int:
        return self.conn.execute("SELECT COALESCE(MAX(seq), 0) FROM reminders").fetchone()[0]

    # -- writing -----------------------------------------------------------

    def _save(self, rem: Reminder) -> Reminder:
        """Insert or replace, bumping seq. Clears the Discord-sent flag if the due time moved."""
        old = self.get(rem.id)
        renotify = old is None or old.due_at != rem.due_at
        self.conn.execute(
            """INSERT INTO reminders (id, title, notes, due_at, completed, apple_id, modified_at, deleted, notified, seq)
               VALUES (:id, :title, :notes, :due_at, :completed, :apple_id, :modified_at, :deleted, 0,
                       (SELECT COALESCE(MAX(seq), 0) + 1 FROM reminders))
               ON CONFLICT(id) DO UPDATE SET
                 title = excluded.title, notes = excluded.notes, due_at = excluded.due_at,
                 completed = excluded.completed, apple_id = excluded.apple_id,
                 modified_at = excluded.modified_at, deleted = excluded.deleted,
                 notified = CASE WHEN :renotify THEN 0 ELSE notified END, seq = excluded.seq""",
            {
                "id": rem.id, "title": rem.title, "notes": rem.notes,
                "due_at": _utc(rem.due_at),
                "completed": int(rem.completed), "apple_id": rem.apple_id,
                "modified_at": _utc(rem.modified_at), "deleted": int(rem.deleted),
                "renotify": int(renotify),
            },
        )
        return rem

    def create(self, title: str, due_at: datetime | None = None, notes: str = "") -> Reminder:
        rem = Reminder(str(uuid.uuid4()), title, notes, due_at, False, None, utcnow())
        with self.conn:
            self.conn.execute("BEGIN")
            return self._save(rem)

    def update(self, reminder_id: str, **changes) -> Reminder:
        with self.conn:
            self.conn.execute("BEGIN")
            rem = self.get(reminder_id)
            if rem is None or rem.deleted:
                raise KeyError(f"no reminder with id {reminder_id}")
            return self._save(replace(rem, **changes, modified_at=utcnow()))

    def delete(self, reminder_id: str) -> Reminder:
        return self.update(reminder_id, deleted=True)

    # -- sync --------------------------------------------------------------

    def sync(self, cursor: int | None, changes: list[dict]) -> tuple[int, list[Reminder]]:
        """Apply the phone's changes, then return (new cursor, reminders the phone must apply)."""
        start = cursor or 0
        touched: dict[str, Reminder] = {}
        with self.conn:
            self.conn.execute("BEGIN")
            for change in changes:
                final = self._apply(change)
                touched[final.id] = final
            out = {r.id: r for r in self.changed_since(start)}
            out.update({rid: self.get(rid) for rid in touched})
            return self.cursor(), list(out.values())

    def _apply(self, c: dict) -> Reminder:
        incoming = Reminder(
            id=c.get("id") or "",
            title=c["title"],
            notes=c.get("notes") or "",
            due_at=parse_time(c.get("due_at")),
            completed=bool(c.get("completed")),
            apple_id=c.get("apple_id"),
            modified_at=parse_time(c["modified_at"]),
            deleted=bool(c.get("deleted")),
        )
        current = self.get(incoming.id) if incoming.id else None
        if current is None and incoming.apple_id:
            current = self.by_apple_id(incoming.apple_id)  # a retry of a sync whose reply was lost
        if current is None:
            return self._save(replace(incoming, id=incoming.id or str(uuid.uuid4())))

        apple_id = incoming.apple_id or current.apple_id  # the phone owns apple_id
        if current.deleted or incoming.deleted:  # deletion beats edits
            winner = replace(current if current.deleted else incoming, deleted=True)
        elif incoming.modified_at > current.modified_at:
            winner = incoming
        else:
            winner = current
        final = replace(winner, id=current.id, apple_id=apple_id)
        return self._save(final) if final != current else current

    # -- Discord fallback --------------------------------------------------

    def unsynced_due(self, now: datetime) -> list[Reminder]:
        """Due, open, never reached the phone, and not yet sent to Discord."""
        rows = self.conn.execute(
            "SELECT * FROM reminders WHERE completed = 0 AND deleted = 0 AND notified = 0 "
            "AND apple_id IS NULL AND due_at <= ? ORDER BY due_at",
            (now.astimezone(timezone.utc).isoformat(),),
        ).fetchall()
        return [self._row(r) for r in rows]

    def mark_notified(self, reminder_id: str) -> None:
        self.conn.execute("UPDATE reminders SET notified = 1 WHERE id = ?", (reminder_id,))
