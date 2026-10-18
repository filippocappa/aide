"""SQLite storage. WAL mode, all timestamps stored as UTC ISO-8601 strings."""

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS conversations (
    id             INTEGER PRIMARY KEY,
    channel        TEXT NOT NULL,
    started_at     TEXT NOT NULL,
    last_active_at TEXT NOT NULL
);

-- content is the JSON the API expects: a string, or a list of content blocks
-- stored exactly as returned, so thinking and tool_use blocks replay unchanged.
CREATE TABLE IF NOT EXISTS messages (
    id              INTEGER PRIMARY KEY,
    conversation_id INTEGER NOT NULL REFERENCES conversations(id),
    channel         TEXT NOT NULL,
    role            TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    content         TEXT NOT NULL,
    ts              TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id, id);

CREATE TABLE IF NOT EXISTS audit_log (
    id     INTEGER PRIMARY KEY,
    ts     TEXT NOT NULL,
    tool   TEXT NOT NULL,
    args   TEXT NOT NULL,
    result TEXT NOT NULL,
    error  INTEGER NOT NULL DEFAULT 0
);
"""


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Database:
    def __init__(self, path: Path | str):
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path, isolation_level=None)  # explicit transactions only
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self.conn.executescript(SCHEMA)

    def close(self) -> None:
        self.conn.close()

    # -- conversations -----------------------------------------------------

    def current_conversation(self, channel: str, idle: timedelta) -> int:
        """Return the active conversation for a channel, starting a new one after `idle` of silence."""
        now = utcnow()
        row = self.conn.execute(
            "SELECT id, last_active_at FROM conversations WHERE channel = ? ORDER BY id DESC LIMIT 1",
            (channel,),
        ).fetchone()
        if row and now - datetime.fromisoformat(row["last_active_at"]) < idle:
            return row["id"]
        return self.new_conversation(channel)

    def new_conversation(self, channel: str) -> int:
        now = utcnow().isoformat()
        cur = self.conn.execute(
            "INSERT INTO conversations (channel, started_at, last_active_at) VALUES (?, ?, ?)",
            (channel, now, now),
        )
        return cur.lastrowid

    def history(self, conversation_id: int) -> list[dict]:
        rows = self.conn.execute(
            "SELECT role, content FROM messages WHERE conversation_id = ? ORDER BY id",
            (conversation_id,),
        ).fetchall()
        return [{"role": r["role"], "content": json.loads(r["content"])} for r in rows]

    def append_turn(self, conversation_id: int, channel: str, messages: list[dict]) -> None:
        """Store a whole turn atomically, so history never ends on an unanswered tool_use."""
        now = utcnow().isoformat()
        with self.conn:
            self.conn.execute("BEGIN")
            self.conn.executemany(
                "INSERT INTO messages (conversation_id, channel, role, content, ts) VALUES (?, ?, ?, ?, ?)",
                [(conversation_id, channel, m["role"], json.dumps(m["content"]), now) for m in messages],
            )
            self.conn.execute(
                "UPDATE conversations SET last_active_at = ? WHERE id = ?", (now, conversation_id)
            )

    # -- audit -------------------------------------------------------------

    def audit(self, tool: str, args: dict, result: str, error: bool = False) -> None:
        self.conn.execute(
            "INSERT INTO audit_log (ts, tool, args, result, error) VALUES (?, ?, ?, ?, ?)",
            (utcnow().isoformat(), tool, json.dumps(args), result, int(error)),
        )
