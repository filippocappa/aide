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
    last_active_at TEXT NOT NULL,
    model          TEXT  -- NULL means the default model
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

-- Tool calls that wait for the user's !yes before running.
CREATE TABLE IF NOT EXISTS pending_actions (
    id         INTEGER PRIMARY KEY,
    channel    TEXT NOT NULL,
    tool       TEXT NOT NULL,
    args       TEXT NOT NULL,
    summary    TEXT NOT NULL,
    target     TEXT,  -- what the action changes; a newer action on the same target replaces it
    created_at TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'pending'  -- pending, done, failed, cancelled, expired, replaced
);

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
        # Explicit transactions only. All access happens on the event loop thread, one call at a time;
        # check_same_thread=False lets test clients (which run the app on another thread) share it.
        self.conn = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self.conn.executescript(SCHEMA)
        self._migrate()

    def _migrate(self) -> None:
        columns = {r["name"] for r in self.conn.execute("PRAGMA table_info(conversations)")}
        if "model" not in columns:  # databases created before !think existed
            self.conn.execute("ALTER TABLE conversations ADD COLUMN model TEXT")
        columns = {r["name"] for r in self.conn.execute("PRAGMA table_info(pending_actions)")}
        if "target" not in columns:  # databases created before actions could be replaced
            self.conn.execute("ALTER TABLE pending_actions ADD COLUMN target TEXT")
            self.conn.execute("UPDATE pending_actions SET target = json_extract(args, '$.event_id')")
        # Discord and the app now share one conversation, keyed "main" instead of "discord".
        for table in ("conversations", "messages", "pending_actions"):
            self.conn.execute(f"UPDATE {table} SET channel = 'main' WHERE channel = 'discord'")

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

    def conversation_model(self, conversation_id: int) -> str | None:
        row = self.conn.execute("SELECT model FROM conversations WHERE id = ?", (conversation_id,)).fetchone()
        return row["model"]

    def set_conversation_model(self, conversation_id: int, model: str) -> None:
        self.conn.execute("UPDATE conversations SET model = ? WHERE id = ?", (model, conversation_id))

    def history_with_ts(self, conversation_id: int) -> list[tuple[str, object, str]]:
        rows = self.conn.execute(
            "SELECT role, content, ts FROM messages WHERE conversation_id = ? ORDER BY id",
            (conversation_id,),
        ).fetchall()
        return [(r["role"], json.loads(r["content"]), r["ts"]) for r in rows]

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

    # -- pending actions -----------------------------------------------------

    def add_pending(self, channel: str, tool: str, args: dict, summary: str, target: str | None = None) -> tuple[int, int]:
        """Queue an action. Returns (new id, number of older actions on the same target it replaced)."""
        with self.conn:
            self.conn.execute("BEGIN")
            replaced = 0
            if target is not None:
                replaced = self.conn.execute(
                    "UPDATE pending_actions SET status = 'replaced' "
                    "WHERE channel = ? AND target = ? AND status = 'pending'",
                    (channel, target),
                ).rowcount
            cur = self.conn.execute(
                "INSERT INTO pending_actions (channel, tool, args, summary, target, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (channel, tool, json.dumps(args), summary, target, utcnow().isoformat()),
            )
        return cur.lastrowid, replaced

    def pending_actions(self, channel: str, ttl: timedelta) -> list[dict]:
        cutoff = (utcnow() - ttl).isoformat()
        self.conn.execute(
            "UPDATE pending_actions SET status = 'expired' WHERE status = 'pending' AND created_at < ?",
            (cutoff,),
        )
        rows = self.conn.execute(
            "SELECT id, tool, args, summary FROM pending_actions "
            "WHERE channel = ? AND status = 'pending' ORDER BY id",
            (channel,),
        ).fetchall()
        return [{"id": r["id"], "tool": r["tool"], "args": json.loads(r["args"]), "summary": r["summary"]} for r in rows]

    def set_pending_status(self, action_id: int, status: str) -> None:
        self.conn.execute("UPDATE pending_actions SET status = ? WHERE id = ?", (status, action_id))

    def cancel_pending(self, channel: str, ids: list[int] | None = None) -> int:
        """Cancel all pending actions for a channel, or only those with the given ids."""
        sql = "UPDATE pending_actions SET status = 'cancelled' WHERE channel = ? AND status = 'pending'"
        params: list = [channel]
        if ids is not None:
            sql += f" AND id IN ({', '.join('?' * len(ids))})" if ids else " AND 0"
            params += ids
        return self.conn.execute(sql, params).rowcount

    # -- audit -------------------------------------------------------------

    def audit(self, tool: str, args: dict, result: str, error: bool = False) -> None:
        self.conn.execute(
            "INSERT INTO audit_log (ts, tool, args, result, error) VALUES (?, ?, ?, ?, ?)",
            (utcnow().isoformat(), tool, json.dumps(args), result, int(error)),
        )
