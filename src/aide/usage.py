"""What every model call and paid API call cost (docs/API.md, "Usage").

One row per call: OpenRouter (chat turns, asks, routines, notes, titles, digests, transcription…), the Claude plan
through Claude Code (not billed per token, so its cost is what Claude Code says it would have been), Whisper on the
GPU, Tavily and Google Maps. Each row says what it was for (`purpose`), which agent and chat, the tokens (input,
cache reads and writes, output) and the cost in dollars: OpenRouter's own figure when it sends one, else worked out
from PRICES.

Callers label their calls with `labels(purpose=…, agent=…, conversation=…)`; an unlabelled call is named after the
first Aide function up the stack ("videos.brief"). Recording never fails the call it records.
"""

import contextlib
import logging
import sqlite3
import sys
import time
from contextvars import ContextVar
from datetime import timedelta

from .db import utcnow

log = logging.getLogger(__name__)

KEEP = timedelta(days=180)
LONG_PROMPT = 100_000  # Haiku 5.5's dearer rate card starts above this many prompt tokens

# Dollars per million tokens: (input, output), and Haiku's above LONG_PROMPT. Cache reads are 0.1× input,
# writes 1.25× (the 5-minute cache). Matched on the model name, so "anthropic/claude-haiku-5.5" finds "haiku-5".
PRICES = {
    "haiku-5": ((0.10, 0.50), (0.50, 2.50)),
    "sonnet-5": ((2.0, 10.0), None),
}

_labels: ContextVar[dict] = ContextVar("usage_labels", default={})
_conn: sqlite3.Connection | None = None
_SKIP = ("aide.usage", "aide.engine")  # wrappers, not the work a call was for


def setup(conn: sqlite3.Connection) -> None:
    """Make the table and record into it from now on."""
    global _conn
    conn.execute("""CREATE TABLE IF NOT EXISTS usage (
        id INTEGER PRIMARY KEY, at TEXT NOT NULL, engine TEXT NOT NULL, model TEXT, purpose TEXT NOT NULL,
        agent TEXT, conversation TEXT, input INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cost REAL, ms INTEGER,
        ok INTEGER NOT NULL DEFAULT 1)""")
    conn.execute("CREATE INDEX IF NOT EXISTS usage_at ON usage (at)")
    conn.execute("DELETE FROM usage WHERE at < ?", ((utcnow() - KEEP).isoformat(),))
    conn.commit()
    _conn = conn


@contextlib.contextmanager
def labels(**kw):
    """Label the calls made inside: purpose, agent, conversation. Inner labels add to outer ones."""
    token = _labels.set({**_labels.get(), **{k: v for k, v in kw.items() if v is not None}})
    try:
        yield
    finally:
        _labels.reset(token)


def label(**kw) -> None:
    """Like labels, for the rest of the current task (a background job's whole run)."""
    _labels.set({**_labels.get(), **{k: v for k, v in kw.items() if v is not None}})


def price(model: str | None, input: int, cache_read: int, cache_write: int, output: int) -> float | None:
    """Dollars for a call on OpenRouter, from PRICES; None for a model not listed there."""
    card = next((c for key, c in PRICES.items() if model and key in model.replace(".", "-")), None)
    if card is None:
        return None
    (i, o), long = card
    if long and input + cache_read + cache_write > LONG_PROMPT:
        i, o = long
    return (input * i + cache_read * i * 0.1 + cache_write * i * 1.25 + output * o) / 1e6


def record(engine: str, model: str | None = None, *, input: int = 0, cache_read: int = 0, cache_write: int = 0,
           output: int = 0, cost: float | None = None, ms: int | None = None, ok: bool = True,
           purpose: str | None = None, agent: str | None = None, conversation: str | None = None) -> None:
    if _conn is None:
        return
    try:
        tags = _labels.get()
        if cost is None and engine == "openrouter":
            cost = price(model, input, cache_read, cache_write, output)
        _conn.execute(
            "INSERT INTO usage (at, engine, model, purpose, agent, conversation, input, cache_read, cache_write, "
            "output, cost, ms, ok) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (utcnow().isoformat(), engine, model, purpose or tags.get("purpose") or _caller(),
             agent or tags.get("agent"), conversation or tags.get("conversation"), input, cache_read, cache_write,
             output, cost, ms, int(ok)))
        _conn.commit()
    except Exception:
        log.exception("couldn't record usage")


def from_response(response, engine: str = "openrouter", started: float | None = None, **kw) -> None:
    """Record an Anthropic-format response (OpenRouter's, through the SDK)."""
    model = kw.pop("model", None) or getattr(response, "model", None)
    u = getattr(response, "usage", None)
    if u is None:
        return record(engine, model, ms=_ms(started), **kw)
    cost = getattr(u, "cost", None)  # OpenRouter's own figure, when it sends one
    record(engine, model, input=getattr(u, "input_tokens", 0) or 0,
           cache_read=getattr(u, "cache_read_input_tokens", 0) or 0,
           cache_write=getattr(u, "cache_creation_input_tokens", 0) or 0, output=getattr(u, "output_tokens", 0) or 0,
           cost=cost if isinstance(cost, (int, float)) else None, ms=_ms(started), **kw)


def from_claude_code(result: dict | None, model: str, started: float | None = None) -> None:
    """Record a Claude Code run's result (`claude -p`'s result event, or the Agent SDK's ResultMessage as a dict).
    The plan isn't billed per token: the cost is what Claude Code reckons the run would have cost."""
    u = (result or {}).get("usage") or {}
    record("plan", model, input=u.get("input_tokens") or 0, cache_read=u.get("cache_read_input_tokens") or 0,
           cache_write=u.get("cache_creation_input_tokens") or 0, output=u.get("output_tokens") or 0,
           cost=(result or {}).get("total_cost_usd"), ms=_ms(started), ok=bool(result) and not result.get("is_error"))


def watch(client) -> None:
    """Record every `client.beta.messages.create` (streams are recorded where they're read: Agent._stream)."""
    messages = client.beta.messages
    create = messages.create

    async def recorded(*args, **kwargs):
        started = time.monotonic()
        try:
            response = await create(*args, **kwargs)
        except Exception:
            record("openrouter", kwargs.get("model"), ms=_ms(started), ok=False)
            raise
        from_response(response, started=started, model=kwargs.get("model"))
        return response

    messages.create = recorded


def summary(days: int = 7) -> dict:
    """The last `days` days: the money spent on OpenRouter, then totals by engine, purpose ("engine:purpose"),
    model, agent, chat and day (UTC), and the latest 100 calls."""
    if _conn is None:
        return {"days": days, "total": _empty(), "engines": [], "purposes": [], "models": [], "agents": [],
                "conversations": [], "by_day": [], "recent": []}
    since = (utcnow() - timedelta(days=days)).isoformat()
    sums = ("COUNT(*) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read, SUM(cache_write) AS cache_write, "
            "SUM(output) AS output, SUM(COALESCE(cost, 0)) AS cost, SUM(1 - ok) AS failed")

    def by(column: str) -> list[dict]:
        return [_row(r) for r in _conn.execute(
            f"SELECT {column} AS key, {sums} FROM usage WHERE at >= ? GROUP BY {column} ORDER BY cost DESC, calls DESC",
            (since,))]

    total = _row(_conn.execute(f"SELECT NULL AS key, {sums} FROM usage WHERE at >= ? AND engine = 'openrouter'",
                               (since,)).fetchone())
    recent = [dict(r) | {"ok": bool(r["ok"])} for r in _conn.execute(
        "SELECT at, engine, model, purpose, agent, conversation, input, cache_read, cache_write, output, cost, ms, ok "
        "FROM usage WHERE at >= ? ORDER BY id DESC LIMIT 100", (since,))]
    return {"days": days, "total": total, "engines": by("engine"), "purposes": by("engine || ':' || purpose"),
            "models": by("model"), "agents": by("agent"), "conversations": by("conversation"),
            "by_day": by("substr(at, 1, 10)"), "recent": recent}


def _row(r) -> dict:
    d = dict(r)
    return {**{k: d[k] or 0 for k in ("calls", "input", "cache_read", "cache_write", "output", "failed")},
            "key": d["key"], "cost": round(d["cost"] or 0, 6)}


def _empty() -> dict:
    return {"key": None, "calls": 0, "input": 0, "cache_read": 0, "cache_write": 0, "output": 0, "cost": 0,
            "failed": 0}


def _ms(started: float | None) -> int | None:
    return round((time.monotonic() - started) * 1000) if started is not None else None


def _caller() -> str:
    """The first Aide function up the stack that isn't a wrapper: what the call was for."""
    frame = sys._getframe(2)
    while frame is not None:
        module = frame.f_globals.get("__name__", "")
        if module.startswith("aide") and not module.startswith(_SKIP):
            return f"{module.removeprefix('aide.')}.{frame.f_code.co_name}"
        frame = frame.f_back
    return "unknown"
