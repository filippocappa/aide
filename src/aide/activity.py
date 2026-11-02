"""What the agents did, in one feed (docs/API.md, "Activity and approvals").

Each place where an agent acts records a line here: a change it made, an action it queued and how the user answered,
a routine or watch run, Aide asking a specialist, a message posted unasked, objectives proposed, a digest made.
Recording never fails the thing it records.
"""

import logging
import sqlite3
from datetime import datetime, timedelta

from .db import utcnow

log = logging.getLogger(__name__)

KEEP = timedelta(days=90)
DETAIL = 280  # characters of detail kept

# What a tool that changes something did, in the past tense. Others read as their name.
LABELS = {
    "create_event": "Added an event", "edit_event": "Changed an event", "delete_event": "Deleted an event",
    "propose_events": "Proposed events",
    "create_reminder": "Added a reminder", "update_reminder": "Changed a reminder",
    "complete_reminder": "Completed a reminder", "delete_reminder": "Deleted a reminder",
    "send_mail": "Sent a mail", "reply_mail": "Replied to a mail",
    "draft_reply": "Drafted a reply", "discard_draft": "Discarded a draft",
    "add_habit": "Added a habit", "check_habit": "Checked a habit", "delete_habit": "Deleted a habit",
    "fill_habit_days": "Filled in a habit's days",
    "log_meal": "Logged a meal", "update_meal": "Changed a meal", "set_food_goals": "Set food goals",
    "delete_meal": "Deleted a meal",
    "update_notes": "Changed lecture notes", "delete_lecture": "Deleted a lecture",
    "apply_proposal": "Applied notebook changes", "decline_proposal": "Declined notebook changes",
    "edit_topic": "Edited a notebook topic", "start_notebook": "Started a notebook",
    "rewrite_introduction": "Rewrote a notebook introduction", "find_figures": "Looked for figures",
    "write_exercises": "Wrote exercises", "write_mock_exam": "Wrote a mock exam",
    "notes_writer": "Changed who writes the notes",
    "remember": "Remembered something", "forget": "Forgot something",
    "create_routine": "Made a routine", "update_routine": "Changed a routine", "delete_routine": "Deleted a routine",
    "add_objective": "Added an objective", "update_objective": "Changed an objective",
    "accept_objectives": "Accepted objectives", "plan_objectives": "Planned objectives",
    "add_transit_alert": "Set a tram alert", "update_transit_alert": "Changed a tram alert",
    "delete_transit_alert": "Deleted a tram alert", "leave_for": "Planned a trip",
    "lock_now": "Locked the apps", "add_lock_schedule": "Set a Screen Time lock",
    "update_lock": "Changed a Screen Time lock", "end_lock": "Ended a lock early", "delete_lock": "Deleted a lock",
    "cancel_queued": "Cancelled queued actions",
    "start_errand": "Started an errand", "reply_errand": "Answered an errand", "cancel_errand": "Cancelled an errand",
    "errand_go": "Went on with an errand",
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


# -- grouped (the app's feed, since 2026-11-02) ------------------------------------------------------------------

RUN = timedelta(minutes=45)   # lines of one run: the same agent doing the same kind of thing in one chat
PLAN = timedelta(minutes=10)  # one plan's objectives lines, whoever proposed them
ERRAND = "Started an errand"


def grouped(items: list[dict], tz) -> list[dict]:
    """The feed folded for reading: what came together as one row, newest first.

    - A run: lines next to each other with the same agent and kind, in one chat or with the same title, each within
      45 min of the next ("Logged a meal" four times is one row with `count` 4).
    - An errand: "Started an errand" and what the errand posted in that chat after it, until the next one, is one row
      of kind `errand` with the errand's title and its last state.
    - A plan: the `objectives` lines made within 10 min of each other, from any agent, are one row.
    - Quiet checks: a day's `quiet` lines are one row, where the newest of them was.
    A row of more than one line has `count`, `agents` (who, in order of first appearance) and `children` (the lines,
    newest first); a single line is as it was. `items` is newest first, as `recent` gives it.
    """
    oldest_first = list(reversed(items))
    groups: list[list[dict]] = []
    errands: dict[str | None, list[dict]] = {}  # the open errand per chat
    quiet: dict[str, list[dict]] = {}            # the day's quiet checks, by local day
    for item in oldest_first:
        ts = _ts(item)
        if item["kind"] == "quiet":
            day = ts.astimezone(tz).date().isoformat()
            if day not in quiet:
                quiet[day] = []
                groups.append(quiet[day])
            quiet[day].append(item)
            continue
        chat = item["conversation_id"]
        if item["kind"] == "action" and item["title"] == ERRAND:
            errands[chat] = [item]
            groups.append(errands[chat])
            continue
        run = errands.get(chat)
        if run and chat and item["kind"] in ("errand", "message") and ts - _ts(run[-1]) <= RUN:
            run.append(item)
            continue
        last = next((g for g in reversed(groups) if g[-1]["kind"] != "quiet"), None)
        if last is not None and not _is_errand(last) and _joins(last, item):
            last.append(item)
            continue
        groups.append([item])
    rows = [_row(g) for g in groups]
    rows.sort(key=lambda r: r["id"], reverse=True)
    return rows


def _joins(group: list[dict], item: dict) -> bool:
    prev = group[-1]
    gap = _ts(item) - _ts(prev)
    if item["kind"] == "objectives":
        return prev["kind"] == "objectives" and gap <= PLAN
    same_place = prev["conversation_id"] == item["conversation_id"] or _title(prev) == _title(item)
    return (prev["kind"] == item["kind"] and prev["agent"] == item["agent"] and same_place
            and item["kind"] not in ("digest", "errand") and gap <= RUN)


def _title(item: dict) -> str:
    """The title a run is told by: a meal scanned in the app (before 2026-11-02 "Logged Penne, 300 g (scanned in the
    app)") is "Logged a meal" like the ones logged in chat."""
    title = item["title"]
    if item["kind"] == "action" and title.startswith("Logged ") and title.endswith("(scanned in the app)"):
        return "Logged a meal"
    return title


def _row(group: list[dict]) -> dict:
    newest = group[-1]
    if len(group) == 1 and not _is_errand(group):
        return newest
    children = list(reversed(group))
    agents: list[str] = []
    for item in group:
        if item["agent"] not in agents:
            agents.append(item["agent"])
    row = {**newest, "agent": group[0]["agent"], "count": len(group), "agents": agents, "children": children}
    kind = newest["kind"]
    if _is_errand(group):
        states = [i for i in children if i["kind"] == "errand"]
        row.update(kind="errand", title=states[0]["title"] if states else "An errand",
                   detail=states[0]["detail"] if states else group[0]["detail"])
    elif kind == "quiet":
        names = list(dict.fromkeys(i["title"] for i in children))
        row.update(title="1 quiet check" if len(group) == 1 else f"{len(group)} quiet checks",
                   detail="Nothing needed you: " + ", ".join(names) + ".")
    elif kind == "objectives":
        periods = [p for p in ("month", "week", "day") if any(i["title"].endswith(f"for the {p}") for i in group)]
        n = sum(_number(i["title"]) for i in group)
        words = {"day": "today", "week": "the week", "month": "the month"}
        row.update(title=f"Proposed {n} objective{'s' if n != 1 else ''}"
                   + (" for " + _and([words[p] for p in reversed(periods)]) if periods else ""),
                   detail=None)
    else:
        titles = list(dict.fromkeys(_title(i) for i in children))
        row["title"] = titles[0] if len(titles) == 1 else _and(titles[:3]) + (" and more" if len(titles) > 3 else "")
    return row


def _is_errand(group: list[dict]) -> bool:
    return group[0]["kind"] == "action" and group[0]["title"] == ERRAND


def _ts(item: dict) -> datetime:
    return datetime.fromisoformat(item["ts"])


def _number(title: str) -> int:
    words = title.split()
    return int(words[1]) if len(words) > 1 and words[1].isdigit() else 1


def _and(words: list[str]) -> str:
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + " and " + words[-1]
