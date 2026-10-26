"""Who does the model work: OpenRouter (pay per token) or the user's Claude plan, through Claude Code on this
machine (`claude -p`, logged in with the user's account; no API key, so it counts against the plan's limits).
Two switches, set apart in the app:

- Notes (`engine`): the heavy study jobs through `Engine.ask`: lecture notes, the notebook (Introduction, outline,
  triage, topic pages, merges, answer checks) and the slide scan. With the plan, Sonnet writes and Haiku does the
  quick reads, as on OpenRouter. When the plan's limit is reached, the job waits and the user is asked (in the
  course's chat, and with buttons in the app): wait for the reset, or finish on OpenRouter until then. Nothing is
  spent on OpenRouter without that.
- Background (`background`): the work nobody waits on: routines and watches (`Engine.run`, a tool loop through the
  Claude Agent SDK, with Aide's own tools run in this process), digest greetings, mail drafts, chat titles and the
  objectives planner (`Engine.ask(background=True)`). At the plan's limit these go to OpenRouter without asking.

Chat stays on OpenRouter: it streams through Aide's own tool loop.
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
from typing import TYPE_CHECKING, Awaitable, Callable

if TYPE_CHECKING:
    from .tools import Tool

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
        self._limited_until: datetime | None = None  # the plan said no; background work skips it until then

    # -- the setting --------------------------------------------------------------------------

    @property
    def engine(self) -> str:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'writer'").fetchone()
        engine = json.loads(row[0]).get("engine") if row else None
        return engine if engine in ENGINES else DEFAULT

    def set_engine(self, engine: str) -> None:
        self._set("writer", engine)
        if engine == "openrouter" and self.paused:
            self.decide("openrouter")  # switching over answers a pending question too

    @property
    def background(self) -> str:
        """Who does the background work (routines, watches, digests, drafts, titles, objectives)."""
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'background'").fetchone()
        engine = json.loads(row[0]).get("engine") if row else None
        return engine if engine in ENGINES else DEFAULT

    def set_background(self, engine: str) -> None:
        self._set("background", engine)

    def _set(self, key: str, engine: str) -> None:
        if engine not in ENGINES:
            raise ValueError(f"engine must be one of {', '.join(ENGINES)}")
        self.conn.execute("INSERT INTO settings (key, value) VALUES (?, ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, json.dumps({"engine": engine})))
        self.conn.commit()

    def plan_for_background(self) -> bool:
        """Background work goes to the plan now: chosen, installed, and not at the limit (nor paused on it)."""
        if self._limited_until and _now() >= self._limited_until:
            self._limited_until = None
        return (self.background == "claude" and self.available and self._limited_until is None
                and self.paused is None and not (self._wait_until and _now() < self._wait_until)
                and not self._on_openrouter())

    @property
    def available(self) -> bool:
        return self.claude is not None

    @property
    def usage(self) -> dict | None:
        """The plan's windows as Claude Code last reported them: {"five_hour": {"used": 0.2, "resets_at": "…"}}."""
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'plan_usage'").fetchone()
        return json.loads(row[0]) if row else None

    def status(self) -> dict:
        return {"engine": self.engine, "background": self.background, "available": self.available,
                "usage": self.usage,
                "paused": self.paused and {**self.paused, "since": _iso(self.paused["since"]),
                                           "resets_at": _iso(self.paused["resets_at"])},
                "openrouter_until": _iso(self._openrouter_until) if self._on_openrouter() else None}

    # -- asking ---------------------------------------------------------------------------------

    async def ask(self, system: str, content: list[dict], max_tokens: int, fast: bool = False,
                  wait: bool = True, background: bool = False, effort: str | None = None) -> str:
        """One model call, with the engine the user chose for notes; while the plan's limit is reached, it waits for
        the user's answer (or the reset). `wait` False: a call that can't wait goes to OpenRouter at the limit
        instead, without asking. `background`: with the background engine, never waiting. `effort` is OpenRouter's
        (Claude Code thinks on its own)."""
        tier = "fast" if fast else "smart"
        if background:
            if self.plan_for_background():
                try:
                    return await self._claude(system, content, max_tokens, tier)
                except PlanLimit as e:
                    self._limited(e)
            return await self._openrouter(system, content, max_tokens, tier, effort)
        while self.engine == "claude" and self.claude and not self._on_openrouter():
            if self.paused or (self._wait_until and _now() < self._wait_until):
                if not wait:
                    break
                await self._hold()
                continue
            try:
                return await self._claude(system, content, max_tokens, tier)
            except PlanLimit as e:
                self._limited(e)
                if not wait:
                    break
                await self._pause(e)
        return await self._openrouter(system, content, max_tokens, tier)

    async def run(self, system: str, prompt: str, tools: "list[Tool]",
                  call: Callable[[str, dict], Awaitable[tuple[str, bool]]], fast: bool = True, max_turns: int = 12,
                  effort: str | None = None) -> str:
        """A tool loop on the plan: Claude Code through the Claude Agent SDK, with `tools` served in this process
        (an in-process MCP server) and each call run by `call(name, args)` -> (text, is_error), so the queue for
        confirmation and a watch's read-only rule stay in Aide's code. Claude Code's own tools are off. Returns the
        final text; PlanLimit at the limit (and later calls skip the plan until the reset)."""
        from claude_agent_sdk import (AssistantMessage, ClaudeAgentOptions, RateLimitEvent, ResultMessage,
                                      create_sdk_mcp_server, query, tool)

        def wrap(t: "Tool"):
            async def handler(args: dict) -> dict:
                out, err = await call(t.name, args)
                return {"content": [{"type": "text", "text": str(out)}], "is_error": err}
            return tool(t.name, t.description, t.input_schema)(handler)

        self.workdir.mkdir(parents=True, exist_ok=True)
        options = ClaudeAgentOptions(
            system_prompt=system, model=CLAUDE_MODELS["fast" if fast else "smart"], tools=[],
            mcp_servers={"aide": create_sdk_mcp_server("aide", tools=[wrap(t) for t in tools])},
            allowed_tools=[f"mcp__aide__{t.name}" for t in tools], strict_mcp_config=True, setting_sources=[],
            permission_mode="dontAsk", max_turns=max_turns, cwd=self.workdir, cli_path=self.claude,
            effort=effort if effort in ("low", "medium", "high") else None,
            # The plan, never a key: the SDK can only override the environment, and an empty key counts as none.
            env={**{k: "" for k in os.environ if k.startswith("ANTHROPIC_")},
                 "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1"},
            stderr=lambda line: log.debug("claude: %s", line))

        async def prompt_stream():  # in-process tools need the streaming input mode
            yield {"type": "user", "message": {"role": "user", "content": prompt}}

        async def loop() -> str:
            texts: list[str] = []
            result, limit = None, None
            try:
                async for m in query(prompt=prompt_stream(), options=options):
                    if isinstance(m, RateLimitEvent):
                        limit = m.rate_limit_info.raw or {}
                        self._save_usage(limit)
                    elif isinstance(m, AssistantMessage):
                        if text := "".join(getattr(b, "text", "") for b in m.content).strip():
                            texts.append(text)
                    elif isinstance(m, ResultMessage):
                        result = m
            except Exception as e:  # the CLI exits non-zero at the limit
                if limit and limit.get("status") == "rejected":
                    raise PlanLimit(_resets(limit, ""), limit.get("rateLimitType"), str(e)) from e
                raise RuntimeError(f"Claude Code: {str(e)[:200]}") from e
            text = (result.result if result else None) or ""
            if limit and limit.get("status") == "rejected" or \
                    result and result.is_error and _PLAN_LIMIT.search(text):
                raise PlanLimit(_resets(limit, text), (limit or {}).get("rateLimitType"), text or "limit reached")
            if result is None or result.is_error:
                if result is not None and result.subtype == "error_max_turns" and texts:
                    return texts[-1]
                raise RuntimeError(f"Claude Code: {(text or getattr(result, 'subtype', None) or 'no result')[:200]}")
            return (text or (texts[-1] if texts else "")).strip() or "(no reply)"

        try:
            return await asyncio.wait_for(loop(), TIMEOUT)
        except asyncio.TimeoutError:
            raise RuntimeError("Claude Code took too long") from None
        except PlanLimit as e:
            self._limited(e)
            raise

    def _limited(self, e: PlanLimit) -> None:
        log.warning("Claude plan limit: %s", e)
        self._limited_until = e.resets_at or _now() + UNKNOWN_RESET

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

    async def _openrouter(self, system: str, content: list[dict], max_tokens: int, tier: str,
                          effort: str | None = None) -> str:
        response = await self.client.beta.messages.create(
            model=self.models[tier], max_tokens=max_tokens, system=system,
            messages=[{"role": "user", "content": content}],
            **({"output_config": {"effort": effort}} if effort else {}))
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
        except asyncio.CancelledError:
            proc.kill()
            raise
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


async def ask_text(engine: "Engine | None", client, model: str, system: str, text: str, max_tokens: int,
                   effort: str = "low") -> str:
    """A small background call (a greeting, a title, drafts): through the engine, on the plan when the user chose it
    for background work; straight to `client` when there's no engine (tests)."""
    if engine is not None:
        return await engine.ask(system, [{"type": "text", "text": text}], max_tokens,
                                fast=model != engine.models["smart"], background=True, effort=effort)
    response = await client.beta.messages.create(
        model=model, max_tokens=max_tokens, system=system, messages=[{"role": "user", "content": text}],
        output_config={"effort": effort})
    return "".join(b.text for b in response.content if b.type == "text").strip()
