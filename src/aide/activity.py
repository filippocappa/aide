"""What the agents did, in one feed (docs/API.md, "Activity and approvals").

Each place where an agent acts records a line here: a change it made, an action it queued and how the user answered,
a routine or watch run, Aide asking a specialist, a message posted unasked, objectives proposed, a digest made.
Recording never fails the thing it records.
"""

import logging
import sqlite3
from datetime import timedelta

from .db import utcnow

log = logging.getLogger(__name__)

KEEP = timedelta(days=90)
DETAIL = 280  # characters of detail kept

# What a tool that changes something did, in the past tense. Others read as their name.
LABELS = {
    "create_event": "Added an event", "edit_event": "Changed an event", "delete_event": "Deleted an event",
    "create_reminder": "Added a reminder", "update_reminder": "Changed a reminder",
    "complete_reminder": "Completed a reminder", "delete_reminder": "Deleted a reminder",
    "send_mail": "Sent a mail", "reply_mail": "Replied to a mail",
    "draft_reply": "Drafted a reply", "discard_draft": "Discarded a draft",
    "add_habit": "Added a habit", "check_habit": "Checked a habit", "delete_habit": "Deleted a habit",
    "log_meal": "Logged a meal", "update_meal": "Changed a meal", "set_food_goals": "Set food goals",
    "delete_meal": "Deleted a meal",
    "update_notes": "Changed lecture notes", "delete_lecture": "Deleted a lecture",
    "apply_proposal": "Applied notebook changes", "decline_proposal": "Declined notebook changes",
    "edit_topic": "Edited a notebook topic", "start_notebook": "Started a notebook",
    "rewrite_introduction": "Rewrote a notebook introduction", "find_figures": "Looked for figures",
    "notes_writer": "Changed who writes the notes",
    "remember": "Remembered something", "forget": "Forgot something",
    "create_routine": "Made a routine", "update_routine": "Changed a routine", "delete_routine": "Deleted a routine",
    "add_objective": "Added an objective", "update_objective": "Changed an objective",
    "accept_objectives": "Accepted objectives", "plan_objectives": "Planned objectives",
    "add_transit_alert": "Set a tram alert", "update_transit_alert": "Changed a tram alert",
    "delete_transit_alert": "Deleted a tram alert",
    "cancel_queued": "Cancelled queued actions",
}

DIGESTS = {"daily": "Morning digest", "wake": "Wake-up briefing", "evening": "Evening digest",
            "weekly": "Weekly digest", "monthly": "Monthly digest"}


def label(tool: str) -> str:
    return LABELS.get(tool) or tool.replace("_", " ").capitalize()


def first_line(text: str | None) -> str | None:
    if not text:
        return None
    line = next((line.strip() for line in str(text).splitlines() if line.strip()), "")
    return (line if len(line) <= DETAIL else line[:DETAIL - 1].rstrip() + "…") or None


def record(conn: sqlite3.Connection, agent: str, kind: str, title: str, detail: str | None = None,
           conversation: str | None = None) -> None:
    """One line of the feed. `conversation` is the chat it happened in (a public id, "main", or "team")."""
    try:
        now = utcnow()
        conn.execute("INSERT INTO activity (ts, agent, kind, title, detail, conversation) VALUES (?, ?, ?, ?, ?, ?)",
                     (now.isoformat(), agent, kind, title, first_line(detail), conversation))
        conn.execute("DELETE FROM activity WHERE ts < ?", ((now - KEEP).isoformat(),))
    except Exception:
        log.exception("activity not recorded: %s %s", kind, title)


def recent(conn: sqlite3.Connection, agent: str | None = None, before: int | None = None,
           limit: int = 100, kinds: list[str] | None = None) -> list[dict]:
    """Newest first, all agents or one, older than the line `before`, of any kind or only `kinds`."""
    sql, params = "SELECT * FROM activity WHERE 1", []
    if agent is not None:
        sql += " AND agent = ?"
        params.append(agent)
    if kinds:
        sql += f" AND kind IN ({', '.join('?' * len(kinds))})"
        params += kinds
    if before is not None:
        sql += " AND id < ?"
        params.append(before)
    rows = conn.execute(sql + " ORDER BY id DESC LIMIT ?", (*params, limit)).fetchall()
    return [{"id": r["id"], "ts": r["ts"], "agent": r["agent"], "kind": r["kind"], "title": r["title"],
             "detail": r["detail"], "conversation_id": r["conversation"]} for r in rows]
