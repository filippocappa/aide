from datetime import timedelta
from types import SimpleNamespace

import pytest

from aide.agent import Agent
from aide.db import Database
from aide.tools import Tool, ToolRegistry


class Block(SimpleNamespace):
    def to_dict(self):
        return dict(vars(self))


def text(t):
    return Block(type="text", text=t)


def tool_use(id, name, input):
    return Block(type="tool_use", id=id, name=name, input=input)


class FakeClient:
    """Stands in for AsyncAnthropic: returns scripted responses and records requests."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    async def _create(self, **kwargs):
        self.requests.append(kwargs)
        stop_reason, content = self.responses.pop(0)
        return SimpleNamespace(stop_reason=stop_reason, content=content)


async def echo(word: str) -> str:
    return word.upper()


async def boom() -> str:
    raise RuntimeError("calendar down")


TOOLS = ToolRegistry([
    Tool("echo", "Echo", {"type": "object", "properties": {"word": {"type": "string"}},
                          "required": ["word"], "additionalProperties": False}, echo),
    Tool("boom", "Fails", {"type": "object", "properties": {}, "required": [],
                           "additionalProperties": False}, boom),
])


@pytest.fixture
def db():
    d = Database(":memory:")
    yield d
    d.close()


def make_agent(db, responses):
    client = FakeClient(responses)
    return Agent(client, db, TOOLS, model="test-model"), client


async def test_plain_reply_is_stored(db):
    agent, _ = make_agent(db, [("end_turn", [text("hi there")])])
    assert await agent.reply("discord", "hello") == "hi there"
    conv = db.current_conversation("discord", timedelta(hours=1))
    assert db.history(conv) == [
        {"role": "user", "content": "hello"},
        {"role": "assistant", "content": [{"type": "text", "text": "hi there"}]},
    ]


async def test_tool_loop_runs_tools_and_returns_results_together(db):
    agent, client = make_agent(db, [
        ("tool_use", [tool_use("t1", "echo", {"word": "a"}), tool_use("t2", "boom", {})]),
        ("end_turn", [text("done")]),
    ])
    assert await agent.reply("discord", "go") == "done"

    results = client.requests[1]["messages"][-1]
    assert results["role"] == "user"
    assert results["content"] == [
        {"type": "tool_result", "tool_use_id": "t1", "content": "A", "is_error": False},
        {"type": "tool_result", "tool_use_id": "t2", "content": "Error: calendar down", "is_error": True},
    ]
    audit = db.conn.execute("SELECT tool, error FROM audit_log ORDER BY id").fetchall()
    assert [tuple(r) for r in audit] == [("echo", 0), ("boom", 1)]


async def test_history_is_replayed_on_next_turn(db):
    agent, client = make_agent(db, [("end_turn", [text("one")]), ("end_turn", [text("two")])])
    await agent.reply("discord", "first")
    await agent.reply("discord", "second")
    roles = [m["role"] for m in client.requests[1]["messages"]]
    assert roles == ["user", "assistant", "user"]


async def test_failed_turn_leaves_history_untouched(db):
    agent, _ = make_agent(db, [("tool_use", [tool_use("t1", "echo", {"word": "a"})])])
    with pytest.raises(IndexError):  # scripted client runs out mid-loop, like an API failure
        await agent.reply("discord", "go")
    conv = db.current_conversation("discord", timedelta(hours=1))
    assert db.history(conv) == []


async def test_cut_off_tool_use_gets_a_result(db):
    agent, _ = make_agent(db, [("max_tokens", [text("partial"), tool_use("t1", "echo", {"word": "a"})])])
    assert "cut off" in await agent.reply("discord", "go")
    conv = db.current_conversation("discord", timedelta(hours=1))
    last = db.history(conv)[-1]
    assert last["content"][0]["tool_use_id"] == "t1"


async def test_reset_starts_fresh_conversation(db):
    agent, client = make_agent(db, [("end_turn", [text("one")]), ("end_turn", [text("two")])])
    await agent.reply("discord", "first")
    agent.reset("discord")
    await agent.reply("discord", "second")
    assert len(client.requests[1]["messages"]) == 1


async def test_request_is_cache_friendly(db):
    agent, client = make_agent(db, [("end_turn", [text("x")]), ("end_turn", [text("y")])])
    await agent.reply("discord", "a")
    await agent.reply("discord", "b")
    first, second = client.requests
    assert first["system"] == second["system"]
    assert first["tools"] == second["tools"]
    assert first["cache_control"] == {"type": "ephemeral"}
