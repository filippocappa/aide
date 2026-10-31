import sqlite3
from types import SimpleNamespace

import pytest

from aide import usage
from aide.agent import _window


@pytest.fixture
def conn(monkeypatch):
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    monkeypatch.setattr(usage, "_conn", None)
    usage.setup(c)
    yield c
    c.close()


def test_price_follows_the_rate_cards():
    assert usage.price("anthropic/claude-haiku-5.5", 10_000, 0, 0, 1_000) == pytest.approx(0.0015)
    assert usage.price("anthropic/claude-sonnet-5.5", 0, 50_000, 10_000, 0) == pytest.approx(0.01 + 0.025)
    assert usage.price("anthropic/claude-haiku-5.5", 120_000, 0, 0, 0) == pytest.approx(0.06)  # the long card
    assert usage.price("google/gemini-3.5-flash-lite", 1000, 0, 0, 0) is None


def test_a_call_is_recorded_with_its_labels_or_its_caller(conn):
    with usage.labels(purpose="chat", agent="coach", conversation="c_1"):
        with usage.labels(purpose="ask"):
            usage.record("openrouter", "anthropic/claude-haiku-5.5", input=1000, output=100)
    usage.record("tavily", "search")
    rows = [dict(r) for r in conn.execute("SELECT * FROM usage ORDER BY id")]
    assert {k: rows[0][k] for k in ("purpose", "agent", "conversation", "input", "output")} == \
        {"purpose": "ask", "agent": "coach", "conversation": "c_1", "input": 1000, "output": 100}
    assert rows[0]["cost"] == pytest.approx(0.00015)
    assert rows[1]["purpose"] == "test_usage.test_a_call_is_recorded_with_its_labels_or_its_caller" or \
        rows[1]["purpose"] == "unknown"  # tests aren't an aide module


async def test_watch_records_every_create(conn):
    async def create(**kwargs):
        if kwargs.get("fail"):
            raise RuntimeError("no")
        u = SimpleNamespace(input_tokens=200, output_tokens=50, cache_read_input_tokens=1000,
                            cache_creation_input_tokens=0, cost=0.002)
        return SimpleNamespace(usage=u, model="anthropic/claude-sonnet-5.5")
    client = SimpleNamespace(beta=SimpleNamespace(messages=SimpleNamespace(create=create)))
    usage.watch(client)
    with usage.labels(purpose="notes"):
        await client.beta.messages.create(model="anthropic/claude-sonnet-5.5")
        with pytest.raises(RuntimeError):
            await client.beta.messages.create(model="anthropic/claude-sonnet-5.5", fail=True)
    s = usage.summary(7)
    assert s["total"]["calls"] == 2 and s["total"]["failed"] == 1
    assert s["total"]["cost"] == pytest.approx(0.002)  # OpenRouter's own figure wins
    assert s["purposes"][0]["key"] == "openrouter:notes" and s["total"]["cache_read"] == 1000


def test_claude_code_runs_count_apart(conn):
    usage.from_claude_code({"usage": {"input_tokens": 5, "output_tokens": 9, "cache_read_input_tokens": 300},
                            "total_cost_usd": 0.04}, "sonnet")
    s = usage.summary(1)
    assert s["total"]["calls"] == 0  # not money spent
    assert s["engines"] == [{"key": "plan", "calls": 1, "input": 5, "cache_read": 300, "cache_write": 0,
                             "output": 9, "failed": 0, "cost": 0.04}]


def turn(i, tools=False):
    msgs = [{"role": "user", "content": f"q{i}"}]
    if tools:
        msgs += [{"role": "assistant", "content": [{"type": "tool_use", "id": f"t{i}", "name": "x", "input": {}}]},
                 {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"t{i}", "content": "r"}]}]
    return msgs + [{"role": "assistant", "content": f"a{i}"}]


def test_the_window_moves_in_steps_at_turn_starts():
    turns = [turn(i, tools=i % 2 == 0) for i in range(12)]
    flat = lambda ts: [m for t in ts for m in t]  # noqa: E731
    assert _window(flat(turns[:5]), 10, 5) == flat(turns[:5])  # fewer than keep: all of it
    cut = _window(flat(turns), 5, 5)  # 12 turns: 5 left out, 7 read, from a turn's start
    assert "5 earlier turns" in cut[0]["content"] and cut[1:] == flat(turns[5:])
    assert _window(flat(turns[:10]), 5, 5)[1:] == flat(turns[5:10])  # 10 turns: the same cut, so the cache holds
    assert "10 earlier turns" in _window(flat(turns + [turn(12), turn(13), turn(14)]), 5, 5)[0]["content"]
