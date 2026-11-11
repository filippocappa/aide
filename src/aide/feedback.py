"""👍/👎 on a reply: the whole turn kept as it ran, for a developer to look at. The contract is docs/API.md, "Chat",
"Rating a reply".

A rating saves the turn the reply belongs to (from the user's message to the next one: the tool calls, their results
cut short, the reply), with the chat's agent, model and the router's pick, so a bad answer can be read later as it
happened, not as the history shows it. Nothing here goes to a model. Read them on the server with

    uv run python -m aide.feedback            # the ones not looked at yet, newest last
    uv run python -m aide.feedback --all      # every one
    uv run python -m aide.feedback --done 3 4 # mark them looked at
"""

import json
import sqlite3
import sys
from datetime import datetime, timezone

RATINGS = ("up", "down")
CUT = 4000  # characters of a tool result kept
NOTE = 2000  # characters of the user's note

SCHEMA = """
CREATE TABLE IF NOT EXISTS feedback (
    id          INTEGER PRIMARY KEY,
    message_id  INTEGER NOT NULL UNIQUE,  -- messages.id of the rated reply
    conversation_id INTEGER NOT NULL,
    rating      TEXT NOT NULL,            -- up | down
    note        TEXT,                     -- what was wrong (or right), in the user's words
    turn        TEXT NOT NULL,            -- JSON: the turn as it ran
    created_at  TEXT NOT NULL,            -- UTC
    reviewed_at TEXT                      -- UTC, once a developer has looked at it
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _cut(block: object) -> object:
    """A message's content with pictures dropped and long tool results cut, to keep the row readable."""
    if isinstance(block, list):
        return [_cut(b) for b in block]
    if not isinstance(block, dict):
        return block
    if block.get("type") == "image":
        return {"type": "image"}
    if block.get("type") == "document":
        return {"type": "document"}
    out = {k: _cut(v) if isinstance(v, (list, dict)) else v for k, v in block.items()}
    if block.get("type") == "tool_result" and isinstance(out.get("content"), str) and len(out["content"]) > CUT:
        out["content"] = out["content"][:CUT] + f"… [{len(block['content']) - CUT} more characters]"
    if block.get("type") == "text" and isinstance(out.get("text"), str) and len(out["text"]) > CUT * 2:
        out["text"] = out["text"][:CUT * 2] + "…"
    return out


class FeedbackStore:
    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn
        conn.executescript(SCHEMA)

    def ratings(self, conversation_id: int) -> dict[int, str]:
        """{message id: rating} for a chat, for its history."""
        return {r["message_id"]: r["rating"] for r in self.conn.execute(
            "SELECT message_id, rating FROM feedback WHERE conversation_id = ?", (conversation_id,))}

    def rate(self, conversation_id: int, message_id: int, rating: str | None, note: str | None = None) -> dict | None:
        """Rate a reply (`rating` None takes the rating back). The turn is saved the first time; a note added later
        replaces the one before. A ValueError for a message that isn't a reply in that chat."""
        row = self.conn.execute("SELECT id, role FROM messages WHERE id = ? AND conversation_id = ?",
                                (message_id, conversation_id)).fetchone()
        if row is None or row["role"] != "assistant":
            raise ValueError("no such reply in this chat")
        if rating is None:
            self.conn.execute("DELETE FROM feedback WHERE message_id = ?", (message_id,))
            return None
        if rating not in RATINGS:
            raise ValueError(f"rating is one of {', '.join(RATINGS)}")
        note = (note or "").strip()[:NOTE] or None
        old = self.conn.execute("SELECT * FROM feedback WHERE message_id = ?", (message_id,)).fetchone()
        if old:
            self.conn.execute("UPDATE feedback SET rating = ?, note = COALESCE(?, note), reviewed_at = NULL "
                              "WHERE id = ?", (rating, note, old["id"]))
        else:
            self.conn.execute("INSERT INTO feedback (message_id, conversation_id, rating, note, turn, created_at) "
                              "VALUES (?, ?, ?, ?, ?, ?)",
                              (message_id, conversation_id, rating, note,
                               json.dumps(self.turn(conversation_id, message_id)), _now()))
        return self.get(message_id)

    def get(self, message_id: int) -> dict | None:
        row = self.conn.execute("SELECT * FROM feedback WHERE message_id = ?", (message_id,)).fetchone()
        return {**dict(row), "turn": json.loads(row["turn"])} if row else None

    def turn(self, conversation_id: int, message_id: int) -> dict:
        """The turn `message_id` is in: from the user's message before it to the one after (not included), with the
        chat's agent, model and title."""
        rows = self.conn.execute("SELECT id, role, content, ts, routed, attachments FROM messages "
                                 "WHERE conversation_id = ? ORDER BY id", (conversation_id,)).fetchall()
        said = lambda r: r["role"] == "user" and isinstance(json.loads(r["content"]), str)  # noqa: E731
        at = next(i for i, r in enumerate(rows) if r["id"] == message_id)
        start = next((i for i in range(at, -1, -1) if said(rows[i])), 0)
        end = next((i for i in range(at + 1, len(rows)) if said(rows[i])), len(rows))
        chat = self.conn.execute("SELECT * FROM conversations WHERE id = ?", (conversation_id,)).fetchone()
        team = self.conn.execute("SELECT sender, recipient, text, ts FROM team_messages WHERE conversation_id = ? "
                                 "AND message_id BETWEEN ? AND ? ORDER BY id",
                                 (conversation_id, rows[start]["id"], rows[end - 1]["id"])).fetchall()
        keys = chat.keys() if chat else []
        return {
            "chat": {k: chat[k] for k in ("public_id", "agent", "title", "model") if k in keys} if chat else {},
            "messages": [{"id": r["id"], "role": r["role"], "ts": r["ts"], "content": _cut(json.loads(r["content"])),
                          **({"routed": json.loads(r["routed"])} if r["routed"] else {}),
                          **({"cards": [a.get("type") for a in json.loads(r["attachments"])]}
                             if r["attachments"] and r["attachments"] != "[]" else {})}
                         for r in rows[start:end]],
            "team": [dict(t) for t in team],
        }

    def all(self, unreviewed: bool = True) -> list[dict]:
        rows = self.conn.execute("SELECT message_id FROM feedback " + ("WHERE reviewed_at IS NULL " if unreviewed
                                                                         else "") + "ORDER BY id").fetchall()
        return [self.get(r["message_id"]) for r in rows]

    def reviewed(self, ids: list[int]) -> None:
        self.conn.executemany("UPDATE feedback SET reviewed_at = ? WHERE id = ?", [(_now(), i) for i in ids])


def render(f: dict) -> str:
    """One rated turn as plain text, for reading in a terminal."""
    chat = f["turn"]["chat"]
    lines = [f"#{f['id']}  {'👍' if f['rating'] == 'up' else '👎'}  {f['created_at'][:16]}Z  "
             f"{chat.get('agent', '?')} · {chat.get('title') or chat.get('public_id')} · model {chat.get('model') or 'usual'}"]
    if f["note"]:
        lines.append(f"  note: {f['note']}")
    for m in f["turn"]["messages"]:
        mark = " ◀ rated" if m["id"] == f["message_id"] else ""
        content = m["content"]
        if isinstance(content, str):
            lines.append(f"  [{m['role']}]{mark} {content}")
            continue
        for b in content:
            kind = b.get("type")
            if kind == "text":
                lines.append(f"  [{m['role']}]{mark} {b['text']}")
            elif kind == "tool_use":
                lines.append(f"  [tool] {b['name']}({json.dumps(b.get('input'), ensure_ascii=False)[:600]})")
            elif kind == "tool_result":
                c = b.get("content")
                text = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
                lines.append(f"  [result] {text[:1200]}")
            elif kind in ("thinking", "redacted_thinking"):
                continue
            else:
                lines.append(f"  [{kind}]")
        if m.get("routed"):
            lines.append(f"  [routed] {m['routed']}")
        if m.get("cards"):
            lines.append(f"  [cards] {', '.join(m['cards'])}")
    for t in f["turn"]["team"]:
        lines.append(f"  [team {t['sender']}→{t['recipient']}] {t['text'][:600]}")
    return "\n".join(lines)


def main(argv: list[str]) -> None:
    from .config import load_settings
    conn = sqlite3.connect(load_settings().db_path)
    conn.row_factory = sqlite3.Row
    store = FeedbackStore(conn)
    if argv[:1] == ["--done"]:
        store.reviewed([int(a) for a in argv[1:]])
        conn.commit()
        print(f"marked {len(argv) - 1} as looked at")
        return
    found = store.all(unreviewed="--all" not in argv)
    print("\n\n".join(render(f) for f in found) if found else "nothing new")


if __name__ == "__main__":
    main(sys.argv[1:])
