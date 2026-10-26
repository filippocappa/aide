"""Routines: jobs an agent runs on a schedule, each posting in its own chat. The contract is docs/API.md, "Routines".

The store keeps them and works out when they're due; `deliver` runs one (through the agent) and sends the alert;
`routine_schedule` is the background job that runs them on time.
"""

import asyncio
import json
import logging
import re
from datetime import date, datetime, time, timedelta, timezone
from typing import TYPE_CHECKING
from zoneinfo import ZoneInfo

from .agents import AGENTS, STARTING_WATCHES, check_agent
from .db import Database, utcnow
from .push import Push

if TYPE_CHECKING:
    from .live import LiveActivities
    from .agent import Agent

log = logging.getLogger(__name__)

TICK = 30  # seconds
CATCH_UP = timedelta(hours=2)  # a run missed by less than this (the server was down) still runs, once
RETRY = timedelta(minutes=10)  # after a failed run
WATCH_CAP = 3  # watch notes a day, all watches together; later scheduled checks that day are skipped
DAY_NAMES = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_TIME = re.compile(r"([01]\d|2[0-3]):[0-5]\d")
EDITABLE = ("title", "prompt", "time", "days", "enabled", "watch")


def check_time(value: str) -> str:
    if not isinstance(value, str) or not _TIME.fullmatch(value.strip()):
        raise ValueError(f"time must be HH:MM (24-hour), not {value!r}")
    return value.strip()


def check_days(days: list[int]) -> list[int]:
    if not isinstance(days, list) or any(not isinstance(d, int) or isinstance(d, bool) or not 1 <= d <= 7
                                         for d in days):
        raise ValueError("days must be ISO weekdays, 1 = Monday … 7 = Sunday ([] for every day)")
    return sorted(set(days))


def _text(value: str, what: str) -> str:
    value = (value or "").strip()
    if not value:
        raise ValueError(f"{what} is empty")
    return value


def days_text(days: list[int]) -> str:
    if not days:
        return "every day"
    if days == [1, 2, 3, 4, 5]:
        return "Mon–Fri"
    return ", ".join(DAY_NAMES[d - 1] for d in days)


class RoutineStore:
    def __init__(self, db: Database, tz: ZoneInfo):
        self.db = db
        self.conn = db.conn
        self.tz = tz

    # -- schedule ----------------------------------------------------------

    def _slots(self, r: dict, start: date, step: int):
        """Scheduled times from `start`, one day at a time forwards (step 1) or backwards (-1), for 8 days."""
        hh, mm = map(int, r["time"].split(":"))
        for i in range(8):
            day = start + timedelta(days=i * step)
            if not r["days"] or day.isoweekday() in r["days"]:
                yield datetime.combine(day, time(hh, mm), self.tz)

    def next_run(self, r: dict, now: datetime | None = None) -> datetime | None:
        if not r["enabled"]:
            return None
        now = (now or utcnow()).astimezone(self.tz)
        return next((s for s in self._slots(r, now.date(), 1) if s > now), None)

    def latest_slot(self, r: dict, now: datetime) -> datetime | None:
        now = now.astimezone(self.tz)
        return next((s for s in self._slots(r, now.date(), -1) if s <= now), None)

    def due(self, now: datetime | None = None) -> list[dict]:
        """Enabled routines with a run owed: the latest slot came after the last run (and after the routine was set
        up or rescheduled), less than CATCH_UP ago."""
        now = now or utcnow()
        out = []
        for r in self.all():
            if not r["enabled"] or (slot := self.latest_slot(r, now)) is None or now - slot >= CATCH_UP:
                continue
            after = max(filter(None, (r["since"], r["last_run"])))
            if slot > datetime.fromisoformat(after):
                out.append(r)
        return out

    # -- storage -----------------------------------------------------------

    def _row(self, row) -> dict:
        r = dict(row)
        r["days"] = json.loads(r["days"])
        r["enabled"] = bool(r["enabled"])
        r["watch"] = bool(r["watch"])
        return r

    _SELECT = "SELECT r.*, c.public_id FROM routines r JOIN conversations c ON c.id = r.conversation_id"

    def get(self, routine_id: int) -> dict | None:
        row = self.conn.execute(self._SELECT + " WHERE r.id = ?", (routine_id,)).fetchone()
        return self._row(row) if row else None

    def find(self, routine_id: int, agent: str | None = None) -> dict:
        """The routine, or KeyError. With `agent`, only one of that agent's (an agent manages its own)."""
        r = self.get(routine_id)
        if r is None or agent is not None and r["agent"] != agent:
            raise KeyError(f"no routine with id {routine_id}")
        return r

    def all(self, agent: str | None = None) -> list[dict]:
        """By agent order, then time."""
        rows = [self._row(r) for r in self.conn.execute(self._SELECT + " ORDER BY r.time, r.id")]
        order = list(AGENTS)
        rows.sort(key=lambda r: order.index(r["agent"]) if r["agent"] in order else len(order))
        return [r for r in rows if agent is None or r["agent"] == agent]

    def create(self, agent: str, title: str, prompt: str, time: str, days: list[int] | None = None,  # noqa: A002
               enabled: bool = True, watch: bool = False) -> dict:
        agent, title, prompt = check_agent(agent), _text(title, "title"), _text(prompt, "prompt")
        time, days = check_time(time), check_days(days or [])
        chat = self.db.new_app_conversation(agent)
        self.db.set_conversation_title(chat["id"], title)
        cur = self.conn.execute(
            "INSERT INTO routines (agent, title, prompt, time, days, enabled, conversation_id, since, watch) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (agent, title, prompt, time, json.dumps(days), int(enabled), chat["id"], utcnow().isoformat(),
             int(watch)))
        return self.get(cur.lastrowid)

    def add_starting_watches(self) -> list[dict]:
        """Secretary's and Coach's first watches, once per database: deleting one doesn't bring it back."""
        if not self.db.once("starting-watches"):
            return []
        return [self.create(agent, **idea) for agent, idea in STARTING_WATCHES]

    def watch_notes_today(self, now: datetime | None = None) -> int:
        """Notes posted by watches since local midnight."""
        midnight = datetime.combine((now or utcnow()).astimezone(self.tz).date(), time(), self.tz)
        return self.conn.execute(
            "SELECT COUNT(*) FROM messages WHERE routine IS NOT NULL AND ts >= ? "
            "AND json_extract(routine, '$.id') IN (SELECT id FROM routines WHERE watch = 1)",
            (midnight.astimezone(timezone.utc).isoformat(),)).fetchone()[0]

    def update(self, routine_id: int, **changes) -> dict:
        r = self.find(routine_id)
        changes = {k: v for k, v in changes.items() if k in EDITABLE and v is not None}
        if "title" in changes:
            changes["title"] = _text(changes["title"], "title")
        if "prompt" in changes:
            changes["prompt"] = _text(changes["prompt"], "prompt")
        if "time" in changes:
            changes["time"] = check_time(changes["time"])
        if "days" in changes:
            changes["days"] = json.dumps(check_days(changes["days"]))
        if "enabled" in changes:
            changes["enabled"] = int(bool(changes["enabled"]))
        if "watch" in changes:
            changes["watch"] = int(bool(changes["watch"]))
        if {"time", "days", "enabled"} & set(changes):  # a new schedule starts now: no catching up on old slots
            changes["since"] = utcnow().isoformat()
        if changes:
            self.conn.execute(f"UPDATE routines SET {', '.join(f'{k} = ?' for k in changes)} WHERE id = ?",
                              (*changes.values(), routine_id))
        if "title" in changes:  # the chat is named after it
            self.db.set_conversation_title(r["conversation_id"], changes["title"])
        return self.get(routine_id)

    def delete(self, routine_id: int) -> bool:
        """The routine only: its chat stays."""
        return self.conn.execute("DELETE FROM routines WHERE id = ?", (routine_id,)).rowcount > 0

    def mark_run(self, routine_id: int, at: datetime | None = None) -> None:
        self.conn.execute("UPDATE routines SET last_run = ? WHERE id = ?",
                          ((at or utcnow()).isoformat(), routine_id))

    # -- shapes ------------------------------------------------------------

    def as_json(self, r: dict) -> dict:
        def local(dt: datetime | None) -> str | None:
            return dt.astimezone(self.tz).replace(microsecond=0).isoformat() if dt else None
        return {"id": r["id"], "agent": r["agent"], "title": r["title"], "prompt": r["prompt"], "time": r["time"],
                "days": r["days"], "enabled": r["enabled"], "watch": r["watch"], "conversation_id": r["public_id"],
                "next_run": local(self.next_run(r)),
                "last_run": local(datetime.fromisoformat(r["last_run"]) if r["last_run"] else None)}

    def line(self, r: dict) -> str:
        """One line for the agents' tools."""
        nxt = self.next_run(r)
        when = f"next {nxt:%a %d %b %H:%M}" if nxt else "off"
        kind = " · watch" if r["watch"] else ""
        return (f"[{r['id']}] {AGENTS[r['agent']].name} · {r['title']}{kind} · {days_text(r['days'])} at {r['time']} "
                f"· {when}")


# -- running -------------------------------------------------------------------


def first_line(text: str) -> str:
    return next((line.strip() for line in text.splitlines() if line.strip()), text.strip())


async def deliver(agent: "Agent", channel: str, routine: dict, push: Push | None) -> str | None:
    """Run a routine now, post the reply in its chat, then push it. Returns the reply,
    or None when a watch found nothing that needs the user (then nothing is posted or sent)."""
    reply, queued = await agent.run_routine(channel, routine)
    if reply is None:
        return None
    title = f"{AGENTS[routine['agent']].name} · {routine['title']}"
    note = f"{queued} action{'s' if queued != 1 else ''} waiting for your OK." if queued else ""
    body = first_line(reply) + (f" ({note})" if note else "")
    sent = False
    if push:
        try:
            sent = await push.send_message(routine["public_id"], title, body, routine=routine["id"])
        except Exception:
            log.exception("routine %s push failed", routine["id"])
    if not sent:
        log.warning("routine %s not pushed; it's still in the app", routine["id"])
    return reply


async def routine_schedule(agent: "Agent", channel: str, push: Push | None,
                           live: "LiveActivities | None" = None) -> None:
    """Run each routine at its time, and once after a short outage (less than CATCH_UP late). Watches are skipped
    once today's notes reach WATCH_CAP. A routine (not a watch) shows as a Live Activity while it runs."""
    store: RoutineStore = agent.routines
    failed: dict[int, datetime] = {}
    while True:
        await asyncio.sleep(TICK)  # first: let startup finish before catching up
        try:
            now = utcnow()
            for r in store.due(now):
                if r["id"] in failed and now - failed[r["id"]] < RETRY:
                    continue
                if r["watch"] and store.watch_notes_today(now) >= WATCH_CAP:
                    store.mark_run(r["id"], now)
                    log.info("watch %s (%s) skipped: %d notes today already", r["id"], r["title"], WATCH_CAP)
                    continue
                key = await live.routine_started(r) if live and not r["watch"] else None
                since = int(now.timestamp())
                reply = None
                try:
                    reply = await deliver(agent, channel, r, push)
                except Exception:
                    log.exception("routine %s (%s) failed", r["id"], r["title"])
                    failed[r["id"]] = now
                    continue
                finally:
                    if key:
                        await live.routine_ended(key, since, reply)
                failed.pop(r["id"], None)
                log.info("routine %s (%s) ran", r["id"], r["title"])
        except Exception:
            log.exception("routine tick failed")
