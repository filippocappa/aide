"""SQLite storage. WAL mode, all timestamps stored as UTC ISO-8601 strings."""

import json
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS conversations (
    id             INTEGER PRIMARY KEY,
    channel        TEXT NOT NULL,
    started_at     TEXT NOT NULL,
    last_active_at TEXT NOT NULL,
    model          TEXT,  -- NULL means the default model
    public_id      TEXT,  -- app chats only ("c_…"); NULL for the shared conversation
    title          TEXT
);

-- content is the JSON the API expects: a string, or a list of content blocks
-- stored exactly as returned, so thinking and tool_use blocks replay unchanged.
CREATE TABLE IF NOT EXISTS messages (
    id              INTEGER PRIMARY KEY,
    conversation_id INTEGER NOT NULL REFERENCES conversations(id),
    channel         TEXT NOT NULL,
    role            TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    content         TEXT NOT NULL,
    ts              TEXT NOT NULL,
    attachments     TEXT  -- JSON list shown as cards under a reply (docs/API.md); NULL for none
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
    conversation TEXT,  -- public id of the app chat that queued it; NULL means the shared conversation
    created_at TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'pending'  -- pending, done, failed, cancelled, expired, replaced
);

-- Short facts the model sees in every conversation.
CREATE TABLE IF NOT EXISTS memory (
    id         INTEGER PRIMARY KEY,
    text       TEXT NOT NULL,
    created_at TEXT NOT NULL
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
        if "public_id" not in columns:  # databases created before the app had many chats
            self.conn.execute("ALTER TABLE conversations ADD COLUMN public_id TEXT")
            self.conn.execute("ALTER TABLE conversations ADD COLUMN title TEXT")
        self.conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS conversations_public ON conversations(public_id)")
        columns = {r["name"] for r in self.conn.execute("PRAGMA table_info(messages)")}
        if "attachments" not in columns:  # databases created before replies had cards
            self.conn.execute("ALTER TABLE messages ADD COLUMN attachments TEXT")
        columns = {r["name"] for r in self.conn.execute("PRAGMA table_info(pending_actions)")}
        if "target" not in columns:  # databases created before actions could be replaced
            self.conn.execute("ALTER TABLE pending_actions ADD COLUMN target TEXT")
            self.conn.execute("UPDATE pending_actions SET target = json_extract(args, '$.event_id')")
        if "conversation" not in columns:
            self.conn.execute("ALTER TABLE pending_actions ADD COLUMN conversation TEXT")
        # Discord and the app now share one conversation, keyed "main" instead of "discord".
        for table in ("conversations", "messages", "pending_actions"):
            self.conn.execute(f"UPDATE {table} SET channel = 'main' WHERE channel = 'discord'")

    def close(self) -> None:
        self.conn.close()

    # -- conversations -----------------------------------------------------

    def current_conversation(self, channel: str, idle: timedelta) -> int:
        """Return the active conversation for a channel, starting a new one after `idle` of silence."""
        now = utcnow()
        row = self.latest_conversation(channel)
        if row and now - datetime.fromisoformat(row["last_active_at"]) < idle:
            return row["id"]
        return self.new_conversation(channel)

    def latest_conversation(self, channel: str) -> sqlite3.Row | None:
        return self.conn.execute(
            "SELECT id, last_active_at FROM conversations WHERE channel = ? ORDER BY id DESC LIMIT 1",
            (channel,),
        ).fetchone()

    def new_conversation(self, channel: str) -> int:
        now = utcnow().isoformat()
        cur = self.conn.execute(
            "INSERT INTO conversations (channel, started_at, last_active_at) VALUES (?, ?, ?)",
            (channel, now, now),
        )
        return cur.lastrowid

    def new_app_conversation(self) -> sqlite3.Row:
        """An app chat: never rotates on idle, lives until deleted."""
        now = utcnow().isoformat()
        public_id = "c_" + secrets.token_hex(6)
        self.conn.execute(
            "INSERT INTO conversations (channel, started_at, last_active_at, public_id) VALUES ('app', ?, ?, ?)",
            (now, now, public_id),
        )
        return self.app_conversation(public_id)

    def app_conversation(self, public_id: str) -> sqlite3.Row | None:
        return self.conn.execute(
            "SELECT id, public_id, title, last_active_at FROM conversations WHERE public_id = ?", (public_id,)
        ).fetchone()

    def app_conversations(self) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT id, public_id, title, last_active_at FROM conversations "
            "WHERE public_id IS NOT NULL ORDER BY last_active_at DESC"
        ).fetchall()

    def delete_app_conversation(self, public_id: str) -> bool:
        with self.conn:
            self.conn.execute("BEGIN")
            row = self.app_conversation(public_id)
            if row is None:
                return False
            self.conn.execute("DELETE FROM messages WHERE conversation_id = ?", (row["id"],))
            self.conn.execute("DELETE FROM conversations WHERE id = ?", (row["id"],))
        return True

    def set_conversation_title(self, conversation_id: int, title: str) -> None:
        self.conn.execute("UPDATE conversations SET title = ? WHERE id = ?", (title, conversation_id))

    def conversation_model(self, conversation_id: int) -> str | None:
        row = self.conn.execute("SELECT model FROM conversations WHERE id = ?", (conversation_id,)).fetchone()
        return row["model"]

    def set_conversation_model(self, conversation_id: int, model: str) -> None:
        self.conn.execute("UPDATE conversations SET model = ? WHERE id = ?", (model, conversation_id))

    def history_with_ts(self, conversation_id: int) -> list[tuple[str, object, str, list]]:
        """(role, content, ts, attachments) per message, oldest first."""
        rows = self.conn.execute(
            "SELECT role, content, ts, attachments FROM messages WHERE conversation_id = ? ORDER BY id",
            (conversation_id,),
        ).fetchall()
        return [(r["role"], json.loads(r["content"]), r["ts"], json.loads(r["attachments"] or "[]")) for r in rows]

    def history(self, conversation_id: int) -> list[dict]:
        rows = self.conn.execute(
            "SELECT role, content FROM messages WHERE conversation_id = ? ORDER BY id",
            (conversation_id,),
        ).fetchall()
        return [{"role": r["role"], "content": json.loads(r["content"])} for r in rows]

    def append_turn(self, conversation_id: int, channel: str, messages: list[dict],
                    attachments: list[dict] | None = None) -> None:
        """Store a whole turn atomically, so history never ends on an unanswered tool_use.

        `attachments` go with the turn's last message (the final reply).
        """
        now = utcnow().isoformat()
        last = len(messages) - 1
        with self.conn:
            self.conn.execute("BEGIN")
            self.conn.executemany(
                "INSERT INTO messages (conversation_id, channel, role, content, ts, attachments) VALUES (?, ?, ?, ?, ?, ?)",
                [(conversation_id, channel, m["role"], json.dumps(m["content"]), now,
                  json.dumps(attachments) if attachments and i == last else None) for i, m in enumerate(messages)],
            )
            self.conn.execute(
                "UPDATE conversations SET last_active_at = ? WHERE id = ?", (now, conversation_id)
            )

    # -- pending actions -----------------------------------------------------

    def add_pending(self, channel: str, tool: str, args: dict, summary: str, target: str | None = None,
                    conversation: str | None = None) -> tuple[int, int]:
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
                "INSERT INTO pending_actions (channel, tool, args, summary, target, conversation, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (channel, tool, json.dumps(args), summary, target, conversation, utcnow().isoformat()),
            )
        return cur.lastrowid, replaced

    def pending_actions(self, channel: str, ttl: timedelta) -> list[dict]:
        cutoff = (utcnow() - ttl).isoformat()
        self.conn.execute(
            "UPDATE pending_actions SET status = 'expired' WHERE status = 'pending' AND created_at < ?",
            (cutoff,),
        )
        rows = self.conn.execute(
            "SELECT id, tool, args, summary, conversation FROM pending_actions "
            "WHERE channel = ? AND status = 'pending' ORDER BY id",
            (channel,),
        ).fetchall()
        return [{"id": r["id"], "tool": r["tool"], "args": json.loads(r["args"]), "summary": r["summary"],
                 "conversation": r["conversation"]} for r in rows]

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

    # -- memory ------------------------------------------------------------

    def add_memory(self, text: str) -> sqlite3.Row:
        cur = self.conn.execute(
            "INSERT INTO memory (text, created_at) VALUES (?, ?)", (text, utcnow().isoformat())
        )
        return self.memory_item(cur.lastrowid)

    def memory_item(self, memory_id: int) -> sqlite3.Row | None:
        return self.conn.execute("SELECT id, text, created_at FROM memory WHERE id = ?", (memory_id,)).fetchone()

    def memories(self) -> list[sqlite3.Row]:
        """Newest first."""
        return self.conn.execute("SELECT id, text, created_at FROM memory ORDER BY id DESC").fetchall()

    def delete_memory(self, memory_id: int) -> bool:
        return self.conn.execute("DELETE FROM memory WHERE id = ?", (memory_id,)).rowcount > 0

    def set_memory_text(self, memory_id: int, text: str) -> None:
        self.conn.execute("UPDATE memory SET text = ? WHERE id = ?", (text, memory_id))

    def memories_being_forgotten(self) -> set[int]:
        """Ids of memories with a queued, not yet confirmed `forget`."""
        rows = self.conn.execute(
            "SELECT json_extract(args, '$.memory_id') AS id FROM pending_actions "
            "WHERE tool = 'forget' AND status = 'pending'"
        ).fetchall()
        return {r["id"] for r in rows}

    # -- audit -------------------------------------------------------------

    def audit(self, tool: str, args: dict, result: str, error: bool = False) -> None:
        self.conn.execute(
            "INSERT INTO audit_log (ts, tool, args, result, error) VALUES (?, ?, ?, ?, ?)",
            (utcnow().isoformat(), tool, json.dumps(args), result, int(error)),
        )
