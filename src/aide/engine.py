"""Who writes the study notes: OpenRouter (pay per token) or the user's Claude plan, through Claude Code on this
machine (`claude -p`, logged in with the user's account; no API key, so it counts against the plan's limits).

Chat stays on OpenRouter: it needs Aide's own tool loop. The heavy jobs go through `Engine.ask`: lecture notes, the
notebook (Introduction, outline, triage, topic pages, merges, answer checks) and the slide scan. With the plan,
Sonnet writes and Haiku does the quick reads, as on OpenRouter.

When the plan's limit is reached, the job waits and the user is asked (in the course's chat, and with buttons in
the app): wait for the reset, or finish on OpenRouter until then. Nothing is spent on OpenRouter without that.
"""

import asyncio
import json
import logging
import os
import re
import shutil
from contextvars import ContextVar
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Awaitable, Callable

log = logging.getLogger(__name__)

ENGINES = ("openrouter", "claude")
DEFAULT = "openrouter"
CLAUDE_MODELS = {"smart": "sonnet", "fast": "haiku"}
TIMEOUT = 20 * 60  # seconds for one call: a long topic page on Sonnet takes a few minutes
UNKNOWN_RESET = timedelta(minutes=30)  # how long to wait before trying again when the reset time isn't known
RESET_SLACK = 30  # seconds after the reset before trying the plan again

# The course a job is for, so a pause is asked about in that course's chat. Set by the workers.
course_var: ContextVar[int | None] = ContextVar("course", default=None)


class PlanLimit(Exception):
    def __init__(self, resets_at: datetime | None, window: str | None, message: str):
        super().__init__(message)
        self.resets_at = resets_at
        self.window = window


class Engine:
    def __init__(self, conn, client, fast_model: str, smart_model: str, claude: str | None = None,
                 workdir: Path | None = None):
        self.conn = conn
        conn.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        self.client = client  # OpenRouter, through the Anthropic SDK
        self.models = {"fast": fast_model, "smart": smart_model}
        self.claude = claude or shutil.which("claude") or _found(Path.home() / ".local/bin/claude")
        self.workdir = workdir or Path("data/claude")  # one folder: Claude Code keeps a project per folder
        self.on_pause: Callable[[dict], Awaitable[None]] | None = None  # asks the user; set by the app
        self.paused: dict | None = None  # {"since", "resets_at", "window", "course"} while waiting for an answer
        self._answered = asyncio.Event()
        self._openrouter_until: datetime | None = None  # the user said: finish on OpenRouter until the reset
        self._wait_until: datetime | None = None  # the user said: wait for the reset

    # -- the setting --------------------------------------------------------------------------

    @property
    def engine(self) -> str:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'writer'").fetchone()
        engine = json.loads(row[0]).get("engine") if row else None
        return engine if engine in ENGINES else DEFAULT

    def set_engine(self, engine: str) -> None:
        if engine not in ENGINES:
            raise ValueError(f"engine must be one of {', '.join(ENGINES)}")
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('writer', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps({"engine": engine}),))
        self.conn.commit()
        if engine == "openrouter" and self.paused:
            self.decide("openrouter")  # switching over answers a pending question too

    @property
    def available(self) -> bool:
        return self.claude is not None

    @property
    def usage(self) -> dict | None:
        """The plan's windows as Claude Code last reported them: {"five_hour": {"used": 0.2, "resets_at": "…"}}."""
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'plan_usage'").fetchone()
        return json.loads(row[0]) if row else None

    def status(self) -> dict:
        return {"engine": self.engine, "available": self.available, "usage": self.usage,
                "paused": self.paused and {**self.paused, "since": _iso(self.paused["since"]),
                                           "resets_at": _iso(self.paused["resets_at"])},
                "openrouter_until": _iso(self._openrouter_until) if self._on_openrouter() else None}

    # -- asking ---------------------------------------------------------------------------------

    async def ask(self, system: str, content: list[dict], max_tokens: int, fast: bool = False) -> str:
        """One model call, with the engine the user chose; while the plan's limit is reached, it waits for the
        user's answer (or the reset)."""
        tier = "fast" if fast else "smart"
        while self.engine == "claude" and self.claude and not self._on_openrouter():
            if self.paused or (self._wait_until and _now() < self._wait_until):
                await self._hold()
                continue
            try:
                return await self._claude(system, content, max_tokens, tier)
            except PlanLimit as e:
                log.warning("Claude plan limit: %s", e)
                await self._pause(e)
        return await self._openrouter(system, content, max_tokens, tier)

    def decide(self, use: str) -> None:
        """The user's answer to a pause: "wait" for the reset, or "openrouter" until then."""
        if use not in ("wait", "openrouter"):
            raise ValueError("use must be wait or openrouter")
        if self.paused is None:
            raise LookupError("nothing is waiting")
        until = self.paused["resets_at"] or _now() + UNKNOWN_RESET
        if use == "openrouter":
            self._openrouter_until = until
        else:
            self._wait_until = until
        self.paused = None
        self._answered.set()

    async def _pause(self, e: PlanLimit) -> None:
        if self.paused is not None or (self._wait_until and _now() < self._wait_until):
            return  # already asked
        self._answered = asyncio.Event()
        self.paused = {"since": _now(), "resets_at": e.resets_at, "window": e.window, "course": course_var.get()}
        if self.on_pause is not None:
            try:
                await self.on_pause(self.status()["paused"])
            except Exception:
                log.exception("couldn't ask about the plan limit")

    async def _hold(self) -> None:
        """Until the user answers or the reset comes, whichever is first."""
        until = self._wait_until if self.paused is None else (self.paused["resets_at"] or _now() + UNKNOWN_RESET)
        seconds = max(0.1, (until - _now()).total_seconds() + RESET_SLACK) if until else UNKNOWN_RESET.total_seconds()
        try:
            await asyncio.wait_for(self._answered.wait(), timeout=seconds) if self.paused else \
                await asyncio.sleep(seconds)
        except asyncio.TimeoutError:
            pass
        if self.paused and until and _now() >= until:
            self.paused = None  # no answer, and the window reset: try the plan again
        if self._wait_until and _now() >= self._wait_until:
            self._wait_until = None

    def _on_openrouter(self) -> bool:
        if self._openrouter_until and _now() >= self._openrouter_until:
            self._openrouter_until = None
        return self._openrouter_until is not None

    async def _openrouter(self, system: str, content: list[dict], max_tokens: int, tier: str) -> str:
        response = await self.client.beta.messages.create(
            model=self.models[tier], max_tokens=max_tokens, system=system,
            messages=[{"role": "user", "content": content}])
        text = "".join(b.text for b in response.content if b.type == "text").strip()
        if not text:
            raise RuntimeError("the model's answer came back empty")
        return text

    async def _claude(self, system: str, content: list[dict], max_tokens: int, tier: str) -> str:
        self.workdir.mkdir(parents=True, exist_ok=True)
        env = {k: v for k, v in os.environ.items() if not k.startswith("ANTHROPIC_")}  # the plan, never a key
        env |= {"CLAUDE_CODE_MAX_OUTPUT_TOKENS": str(max_tokens), "MAX_THINKING_TOKENS": "0",
                "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1"}
        message = json.dumps({"type": "user", "message": {"role": "user", "content": content}})
        proc = await asyncio.create_subprocess_exec(
            self.claude, "-p", "--model", CLAUDE_MODELS[tier], "--input-format", "stream-json",
            "--output-format", "stream-json", "--verbose", "--system-prompt", system, "--tools", "",
            "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands",
            "--setting-sources", "project",
            cwd=self.workdir, env=env, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, limit=16 * 1024 * 1024)
        try:
            out, err = await asyncio.wait_for(proc.communicate(message.encode() + b"\n"), TIMEOUT)
        except asyncio.TimeoutError:
            proc.kill()
            raise RuntimeError("Claude Code took too long") from None
        result, limit = None, None
        for line in out.decode(errors="replace").splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") == "rate_limit_event":
                limit = event.get("rate_limit_info") or {}
                self._save_usage(limit)
            elif event.get("type") == "result":
                result = event
        text = (result or {}).get("result") or ""
        if limit and limit.get("status") == "rejected" or \
                result and result.get("is_error") and _PLAN_LIMIT.search(text):
            raise PlanLimit(_resets(limit, text), (limit or {}).get("rateLimitType"), text or "limit reached")
        if result is None or result.get("is_error"):
            why = text or err.decode(errors="replace").strip()[-300:] or f"exit {proc.returncode}"
            raise RuntimeError(f"Claude Code: {why[:200]}")
        if not text.strip():
            raise RuntimeError("the model's answer came back empty")
        return text.strip()

    def _save_usage(self, info: dict) -> None:
        windows = {name: {"used": w.get("utilization"), "resets_at": _iso(_epoch(w.get("resetsAt")))}
                   for name, w in (info.get("unifiedWindows") or {}).items() if isinstance(w, dict)}
        if not windows:
            return
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('plan_usage', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps(windows),))
        self.conn.commit()


_PLAN_LIMIT = re.compile(r"(usage|rate|session|weekly|5-hour|five.hour) limit|limit (reached|resets)|hit your limit",
                         re.I)


def _found(path: Path) -> str | None:
    return str(path) if path.exists() else None


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _epoch(value) -> datetime | None:
    try:
        return datetime.fromtimestamp(int(value), timezone.utc)
    except (TypeError, ValueError, OverflowError):
        return None


def _iso(when: datetime | None) -> str | None:
    return when.replace(microsecond=0).isoformat().replace("+00:00", "Z") if when else None


def _resets(info: dict | None, text: str) -> datetime | None:
    """When the limit resets: from the rate limit event, else the "…|1730000000" Claude Code puts in its message."""
    if info and (when := _epoch(info.get("resetsAt"))):
        return when
    m = re.search(r"\|(\d{9,11})\b", text)
    return _epoch(m.group(1)) if m else None
