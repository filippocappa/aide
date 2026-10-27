"""Live Activities (docs/API.md, "Live Activities"): the tokens the app hands over, and the pushes that start,
update and end them. Three kinds: `tram` (a tram alert's countdown, kept by transit.AlertWatcher), `agent` (an
agent at work: a chat turn the app started, a scheduled routine or a notes job the server starts) and `event` (the
next calendar event's countdown, kept by upcoming.EventWatcher).

Push-to-start tokens are kept per kind until the app deletes one or APNs refuses it. An activity's update token is
kept under the key in its attributes, for TOKEN_AGE at most. A start asks iOS for that token (`input-push-token`):
without it iOS hands the app one only now and then, and the activity stays as it started.
"""

import asyncio
import json
import logging
import sqlite3
import time
from datetime import datetime, timedelta, timezone
from typing import Callable

from .agents import AGENTS, ORCHESTRATOR
from .push import HOSTS, Push, check_token
from .routines import first_line

log = logging.getLogger(__name__)

KINDS = {"tram": "TramActivityAttributes", "agent": "AgentActivityAttributes", "event": "EventActivityAttributes"}
TOKEN_AGE = timedelta(hours=12)
THROTTLE = 2.0  # seconds between an agent activity's updates
SETTLE = 3.0  # seconds after a turn before its last update: the app, if open, ends the activity itself first
DONE_FOR = timedelta(minutes=30)  # a finished turn's activity stays this long on the Lock Screen
TEXT_MAX = 140
ENDED_FOR = timedelta(hours=1)  # an end that went out before the token came is sent when it comes, this long
_running: set[asyncio.Task] = set()  # the background pushes, held until they're done

SCHEMA = """
CREATE TABLE IF NOT EXISTS live_tokens (
    key         TEXT PRIMARY KEY,  -- 'start:<kind>' for a push-to-start token, else the activity's key
    token       TEXT NOT NULL,     -- hex
    environment TEXT NOT NULL,     -- sandbox or production
    created_at  TEXT NOT NULL      -- UTC
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""
SETTINGS = {"events": True}


def unix(dt: datetime) -> int:
    return int(dt.timestamp())


def clip(text: str, limit: int = TEXT_MAX) -> str:
    line = first_line(text)
    return line if len(line) <= limit else line[:limit - 1].rstrip() + "…"


class LiveActivities:
    def __init__(self, conn: sqlite3.Connection, push: Push | None):
        self.conn, self.push = conn, push
        self.conn.executescript(SCHEMA)
        self._stamps: dict[str, int] = {}  # key -> last timestamp sent: each push must be newer than the last
        # key -> (end state, dismissal, when): ended before the app handed over the token (a short job the server
        # started); the end goes out when the token comes, so the activity doesn't stay on "working".
        self._ended: dict[str, tuple[dict, datetime, datetime]] = {}
        self._dismissed: set[str] = set()  # keys of activities the user swiped away

    @property
    def enabled(self) -> bool:
        return bool(getattr(self.push, "enabled", False)) and hasattr(self.push, "send_live")

    # -- the settings ----------------------------------------------------------

    def settings(self) -> dict:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'live'").fetchone()
        return {**SETTINGS, **(json.loads(row["value"]) if row else {})}

    def update_settings(self, **changes) -> dict:
        value = {**self.settings(), **{k: v for k, v in changes.items() if k in SETTINGS and v is not None}}
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('live', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps(value),))
        return self.settings()

    # -- tokens --------------------------------------------------------------

    def _put(self, key: str, token: str, environment: str) -> None:
        if environment not in HOSTS:
            raise ValueError("environment must be sandbox or production")
        self.conn.execute("INSERT INTO live_tokens (key, token, environment, created_at) VALUES (?, ?, ?, ?) "
                          "ON CONFLICT(key) DO UPDATE SET token = excluded.token, environment = excluded.environment, "
                          "created_at = excluded.created_at",
                          (key, check_token(token), environment, datetime.now(timezone.utc).isoformat()))

    def set_start_token(self, kind: str, token: str, environment: str) -> None:
        if kind not in KINDS:
            raise ValueError(f"kind must be one of {', '.join(KINDS)}")
        self._put(f"start:{kind}", token, environment)

    def remove_start_token(self, kind: str) -> None:
        self.conn.execute("DELETE FROM live_tokens WHERE key = ?", (f"start:{kind}",))

    def start_token(self, kind: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM live_tokens WHERE key = ?", (f"start:{kind}",)).fetchone()
        return dict(row) if row else None

    def register(self, key: str, token: str, environment: str) -> None:
        if not key or key.startswith("start:"):
            raise ValueError("key must be the activity's key")
        self._put(key, token, environment)
        self._dismissed.discard(key)

    def remove(self, key: str) -> None:
        self.conn.execute("DELETE FROM live_tokens WHERE key = ?", (key,))

    def dismiss(self, key: str) -> None:
        """The app says the user swiped the activity away: no more pushes for it."""
        self.remove(key)
        self._dismissed.add(key)

    def dismissed(self, key: str) -> bool:
        return key in self._dismissed

    def token(self, key: str) -> dict | None:
        cutoff = (datetime.now(timezone.utc) - TOKEN_AGE).isoformat()
        self.conn.execute("DELETE FROM live_tokens WHERE key NOT LIKE 'start:%' AND created_at < ?", (cutoff,))
        row = self.conn.execute("SELECT * FROM live_tokens WHERE key = ?", (key,)).fetchone()
        return dict(row) if row else None

    # -- pushes --------------------------------------------------------------

    def _stamp(self, key: str) -> int:
        now = max(int(time.time()), self._stamps.get(key, 0) + 1)
        self._stamps[key] = now
        return now

    async def _send(self, key: str, row: dict, aps: dict, priority: int) -> bool:
        status, reason = await self.push.send_live(row["token"], row["environment"],
                                                   {"aps": {"timestamp": self._stamp(key), **aps}}, priority)
        if status == 200:
            return True
        if Push.gone(status, reason):
            log.info("APNs says Live Activity token %s… is gone (%s): removing it", row["token"][:8],
                     reason or status)
            self.conn.execute("DELETE FROM live_tokens WHERE key = ?", (row["key"],))
        elif status:
            log.warning("APNs refused a Live Activity push for %s: %s %s", key, status, reason)
        return False

    async def start(self, kind: str, attributes: dict, state: dict, alert: dict,
                    stale: datetime | None = None) -> bool:
        """Push-to-start. False when there's no start token for the kind (or push is off): nothing went out."""
        row = self.start_token(kind)
        if not (self.enabled and row):
            return False
        aps = {"event": "start", "attributes-type": KINDS[kind], "attributes": attributes,
               "content-state": state, "alert": alert, "input-push-token": 1}
        if stale:
            aps["stale-date"] = unix(stale)
        return await self._send(attributes["key"], row, aps, 10)

    async def update(self, key: str, state: dict, alert: dict | None = None, stale: datetime | None = None) -> bool:
        """False when the app hasn't handed over the activity's token (or it's gone)."""
        row = self.token(key)
        if not (self.enabled and row):
            return False
        aps = {"event": "update", "content-state": state}
        if alert:
            aps["alert"] = alert
        if stale:
            aps["stale-date"] = unix(stale)
        return await self._send(key, row, aps, 10 if alert else 5)

    async def end(self, key: str, state: dict, dismiss: datetime) -> bool:
        """The last push; the key is forgotten either way. Without a token yet, it's sent when the token comes."""
        row = self.token(key)
        sent = False
        if self.enabled and row:
            sent = await self._send(key, row, {"event": "end", "content-state": state,
                                               "dismissal-date": unix(dismiss)}, 10)
        elif self.enabled:
            now = datetime.now(timezone.utc)
            self._ended = {k: v for k, v in self._ended.items() if now - v[2] < ENDED_FOR}
            self._ended[key] = (state, dismiss, now)
        self.remove(key)
        self._stamps.pop(key, None)
        return sent

    async def registered(self, key: str) -> None:
        """The app handed over an activity's token: one that has ended meanwhile is ended now."""
        ended = self._ended.pop(key, None)
        if ended and datetime.now(timezone.utc) - ended[2] < ENDED_FOR:
            state, dismiss, _ = ended
            await self.end(key, state, max(dismiss, datetime.now(timezone.utc)))

    # -- agents ----------------------------------------------------------------

    def turn(self, conversation: str, agent: str | None = None) -> "AgentTurn":
        return AgentTurn(self, f"agent:{conversation}", agent)

    async def routine_started(self, routine: dict) -> str | None:
        """A scheduled routine's activity, push-started. Returns its key, or None if it didn't start."""
        a = AGENTS[routine["agent"]]
        key = f"agent:{routine['public_id']}"
        attributes = {"key": key, "agent": a.id, "name": a.name, "color": a.color,
                      "conversation": routine["public_id"], "title": routine["title"]}
        state = {"status": "working", "detail": "", "text": "", "since": int(time.time())}
        try:
            ok = await self.start("agent", attributes, state,
                                  {"title": f"{a.name} · {routine['title']}", "body": "Working on it"},
                                  stale=datetime.now(timezone.utc) + timedelta(minutes=10))
        except Exception:
            log.exception("routine %s: Live Activity didn't start", routine["id"])
            return None
        return key if ok else None

    def notes(self, key: str, conversation: str, title: str, total: int | None = None) -> "NotesRun":
        return NotesRun(self, key, conversation, title, total)

    def errand(self, errand_id: int, conversation: str, title: str) -> "ErrandRun":
        return ErrandRun(self, f"errand:{errand_id}", conversation, title, None)

    async def routine_ended(self, key: str, since: int, reply: str | None) -> None:
        state = {"status": "done", "detail": "", "text": clip(reply) if reply else "", "since": since}
        try:
            await self.end(key, state, datetime.now(timezone.utc))
        except Exception:
            log.exception("%s: Live Activity didn't end", key)


class AgentTurn:
    """One chat or Team chat turn's activity, under the key the app registered: an update for each ask and when the
    reply starts (at most one per THROTTLE), then the reply's first line with an alert, and the end. Callbacks are
    plain functions (the turn's emit hooks); the pushes go out in background tasks, so the turn never waits."""

    def __init__(self, live: LiveActivities, key: str, agent: str | None):
        self.live, self.key, self.agent = live, key, agent
        self.since = int(time.time())
        self._state: dict | None = None  # the latest wanted, not yet sent
        self._last = 0.0
        self._writing = False
        self._task: asyncio.Task | None = None

    def _state_of(self, status: str, detail: str = "", text: str = "") -> dict:
        return {"status": status, "detail": detail, "text": text, "since": self.since}

    def _spawn(self, coro) -> asyncio.Task:
        task = asyncio.get_running_loop().create_task(coro)
        _running.add(task)
        task.add_done_callback(_running.discard)
        return task

    def _want(self, state: dict) -> None:
        if not self.live.enabled:
            return
        self._state = state
        if self._task is None or self._task.done():
            self._task = self._spawn(self._flush())

    async def _flush(self) -> None:
        while self._state is not None:
            wait = self._last + THROTTLE - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            state, self._state = self._state, None
            self._last = time.monotonic()
            try:
                await self.live.update(self.key, state)
            except Exception:
                log.exception("%s: Live Activity update failed", self.key)

    def team(self, message: dict) -> None:
        """A team message of the turn: Aide asking someone is `asking`."""
        if message.get("from") == ORCHESTRATOR and message.get("to") in AGENTS:
            self._want(self._state_of("asking", f"Asking {AGENTS[message['to']].name}"))

    def working(self, agent: str) -> None:
        """Team chat: an agent starts on its answer."""
        if self.agent is None:
            self.agent = agent
        if agent != self.agent:
            self._want(self._state_of("asking", f"Asking {AGENTS[agent].name}"))

    def text(self, delta: str = "", restart: bool = False) -> None:
        if not self._writing:
            self._writing = True
            self._want(self._state_of("writing"))

    def finished(self, reply: str, agent: str | None = None) -> None:
        if self.live.enabled:
            self._spawn(self._finish(reply, agent or self.agent))

    def failed(self) -> None:
        if self.live.enabled:
            self._spawn(self._fail())

    async def _settle(self) -> bool:
        if self._task and not self._task.done():
            await self._task
        await asyncio.sleep(SETTLE)
        return self.live.token(self.key) is not None

    async def _finish(self, reply: str, agent: str | None) -> None:
        try:
            if not await self._settle():
                return  # the app ended it itself, or never had one
            done = self._state_of("done", text=clip(reply))
            name = AGENTS.get(agent or ORCHESTRATOR, AGENTS[ORCHESTRATOR]).name
            await self.live.update(self.key, done, alert={"title": name, "body": done["text"], "sound": "default"})
            await self.live.end(self.key, done, datetime.now(timezone.utc) + DONE_FOR)
        except Exception:
            log.exception("%s: Live Activity didn't finish", self.key)

    async def _fail(self) -> None:
        try:
            if await self._settle():
                await self.live.end(self.key, self._state_of("failed", "Something went wrong"),
                                    datetime.now(timezone.utc) + DONE_FOR)
        except Exception:
            log.exception("%s: Live Activity didn't end", self.key)


class NotesRun(AgentTurn):
    """A notes job's activity (Professor writing a lecture's notes, or a notebook's topics), push-started under its
    own key, so it never meets a chat turn's: the step and the topics done so far, at most one update per THROTTLE,
    then the end with the result, dismissed at once (the `message` or `lecture` push that follows is the
    notification). Like AgentTurn, the calls return at once and the pushes go out in the background."""

    AGENT = "professor"

    def __init__(self, live: LiveActivities, key: str, conversation: str, title: str, total: int | None):
        super().__init__(live, key, self.AGENT)
        self.conversation, self.title, self.total = conversation, title, total
        self.done, self.detail = 0, ""
        self._started: asyncio.Task | None = None

    def _state_of(self, status: str, detail: str = "", text: str = "") -> dict:
        return {"status": status, "detail": detail, "text": text, "since": self.since,
                "done": self.done if self.total else None, "total": self.total}

    def start(self, detail: str) -> None:
        if not self.live.enabled:
            return
        self.detail = detail
        a = AGENTS[self.AGENT]
        attributes = {"key": self.key, "agent": a.id, "name": a.name, "color": a.color,
                      "conversation": self.conversation, "title": self.title}
        alert = {"title": f"{a.name} · {self.title}", "body": detail}
        self._started = self._spawn(self.live.start("agent", attributes, self._state_of("writing", detail), alert,
                                                    stale=datetime.now(timezone.utc) + timedelta(minutes=30)))

    def step(self, detail: str) -> None:
        if detail and detail != self.detail:
            self.detail = detail
            self._want(self._state_of("writing", detail))

    def progress(self) -> None:
        self.done += 1
        self._want(self._state_of("writing", self.detail))

    def finished(self, result: str, agent: str | None = None) -> None:
        if self.live.enabled and self._started:
            self._spawn(self._close(self._state_of("done", text=clip(result))))

    def failed(self, error: str = "") -> None:
        if self.live.enabled and self._started:
            self._spawn(self._close(self._state_of("failed", clip(error) or "Something went wrong")))

    async def _close(self, state: dict) -> None:
        try:
            await self._started
            if self._task and not self._task.done():
                await self._task
            await self.live.end(self.key, state, datetime.now(timezone.utc))
        except Exception:
            log.exception("%s: Live Activity didn't end", self.key)


class ErrandRun(NotesRun):
    """A browser errand's activity: Aide `browsing` with the step it's on, `needs_you` (with an alert) when it waits
    for the user (a login, a choice, a Confirm), then done or failed. Push-started once, kept across the errand's
    phases."""

    AGENT = "aide"

    def __init__(self, live: LiveActivities, key: str, conversation: str, title: str, total: int | None):
        super().__init__(live, key, conversation, title, total)
        self.errand = int(key.split(":")[1])

    def _state_of(self, status: str, detail: str = "", text: str = "") -> dict:
        status = "browsing" if status == "writing" else status
        return {**super()._state_of(status, detail, text), "errand": self.errand}

    def start(self, detail: str) -> None:
        if self._started is None:
            super().start(detail)
        else:
            self.browsing(detail)

    def browsing(self, detail: str) -> None:
        self.detail = detail
        self._want(self._state_of("browsing", detail))

    def step(self, detail: str) -> None:
        if detail and detail != self.detail:
            self.browsing(detail)

    def needs_you(self, detail: str) -> None:
        if not (self.live.enabled and self._started):
            return
        self.detail = detail

        async def send() -> None:
            try:
                await self._started
                await self.live.update(self.key, self._state_of("needs_you", clip(detail)),
                                       alert={"title": f"Aide · {self.title}", "body": clip(detail),
                                              "sound": "default"})
            except Exception:
                log.exception("%s: Live Activity update failed", self.key)
        self._spawn(send())


def hooks(*callbacks: Callable | None) -> Callable:
    """Several callbacks as one, skipping the missing ones."""
    present = [c for c in callbacks if c is not None]

    def call(*args):
        for c in present:
            c(*args)
    return call
