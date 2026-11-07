"""The router (#59): a message to Aide goes straight to the specialist when it's clear whose it is."""

import asyncio

import pytest

from aide.agents import AGENTS
from aide.router import Pick, Router

from test_agents import AUTH, FakeClient, calls, done, env, new_chat, tool_names  # noqa: F401 (env: a fixture)


def says(text):
    """What the router's model answers."""
    return done(text)


def routed(agent, responses, picks):
    agent.router = Router(FakeClient([says(p) for p in picks]), "fast", agent.db.conn)
    return agent.router


def test_a_clear_message_goes_straight_to_the_specialist(env):
    client, agent, _ = env([done("Seven hours, a bit short of your usual.")])  # Coach's turn, no Aide round
    router = routed(agent, [], ['{"agent": "coach", "p": 0.93}'])
    body = client.post("/v1/chat", json={"text": "how did I sleep?"}, headers=AUTH).json()
    assert body["reply"] == "Seven hours, a bit short of your usual."
    assert body["routed"] == {"agent": "coach", "p": 0.93} and body["consulted"] == ["coach"] and body["team"] == []

    (coach,) = agent.client.requests
    assert coach["system"][0]["text"] == AGENTS["coach"].prompt and "ask_agent" in tool_names(coach)
    asked = str(coach["messages"][0])
    assert "In Aide's chat" in asked and "how did I sleep?" in asked
    # The router saw the message and was asked for JSON, with no thinking.
    (pick,) = router.client.requests
    assert "how did I sleep?" in pick["messages"][0]["content"] and pick["thinking"] == {"type": "disabled"}

    history = client.get("/v1/history", headers=AUTH).json()["messages"]
    assert [m.get("routed") for m in history] == [None, {"agent": "coach", "p": 0.93}]
    assert history[-1]["text"] == "Seven hours, a bit short of your usual."
    row = agent.db.conn.execute("SELECT place, agent, p, used, error FROM routes").fetchone()
    assert tuple(row) == ("chat", "coach", 0.93, 1, None)


def test_aides_next_turn_reads_the_hand_off_as_an_ask(env):
    client, agent, _ = env([done("Seven hours."), done("You're welcome!")])
    routed(agent, [], ['{"agent": "coach", "p": 0.9}', '{"agent": "aide", "p": 0.8}'])
    client.post("/v1/chat", json={"text": "how did I sleep?"}, headers=AUTH)
    client.post("/v1/chat", json={"text": "thanks"}, headers=AUTH)
    aide = agent.client.requests[-1]
    assert aide["system"][0]["text"] == AGENTS["aide"].prompt
    use, result, answer = aide["messages"][1:4]
    assert use["content"][0]["name"] == "ask_agent" and use["content"][0]["input"]["agent"] == "coach"
    assert result["content"][0]["tool_use_id"] == use["content"][0]["id"]
    assert "Coach answered:\nSeven hours." in result["content"][0]["content"]
    assert answer["content"][0]["text"] == "Seven hours."


def test_a_follow_up_hands_the_specialist_the_chat_so_far(env):
    client, agent, _ = env([done("Seven hours."), done("Six and a half.")])
    routed(agent, [], ['{"agent": "coach", "p": 0.9}', '{"agent": "coach", "p": 0.85}'])
    client.post("/v1/chat", json={"text": "how did I sleep?"}, headers=AUTH)
    client.post("/v1/chat", json={"text": "and the night before?"}, headers=AUTH)
    asked = str(agent.client.requests[-1]["messages"][0])
    assert "User: how did I sleep?" in asked and "Coach: Seven hours." in asked
    assert "Coach: Seven hours." in agent.router.client.requests[-1]["messages"][0]["content"]


@pytest.mark.parametrize("answer", ['{"agent": "aide", "p": 0.95}', '{"agent": "coach", "p": 0.4}',
                                    'Coach, I think', '{"agent": "bob", "p": 0.9}', '{"agent": "coach", "p": 7}'])
def test_unsure_or_bad_answers_leave_it_to_aide(env, answer):
    client, agent, _ = env([done("Hi there!")])
    routed(agent, [], [answer])
    body = client.post("/v1/chat", json={"text": "hey"}, headers=AUTH).json()
    assert body["reply"] == "Hi there!" and "routed" not in body
    assert agent.client.requests[0]["system"][0]["text"] == AGENTS["aide"].prompt


def test_a_slow_or_failing_router_leaves_it_to_aide(env):
    client, agent, _ = env([done("Hi there!"), done("Hello again.")])
    router = Router(FakeClient([]), "fast", agent.db.conn, budget=0.05)

    async def slow(**kwargs):
        await asyncio.sleep(1)
    router.client.beta.messages.create = slow
    agent.router = router
    assert client.post("/v1/chat", json={"text": "hey"}, headers=AUTH).json()["reply"] == "Hi there!"

    async def broken(**kwargs):
        raise RuntimeError("402")
    router.client.beta.messages.create = broken
    assert client.post("/v1/chat", json={"text": "hey"}, headers=AUTH).json()["reply"] == "Hello again."
    errors = [r[0] for r in agent.db.conn.execute("SELECT error FROM routes ORDER BY id")]
    assert errors == ["timeout", "RuntimeError"]


def test_only_aides_typed_turns_are_routed(env):
    client, agent, _ = env([done("Your sleep was fine.")])
    routed(agent, [], [])  # any call would fail: no answers scripted
    chat = new_chat(client, "coach")
    body = client.post("/v1/chat", json={"text": "how did I sleep?", "conversation_id": chat}, headers=AUTH).json()
    assert body["reply"] == "Your sleep was fine." and "routed" not in body
    assert agent.router.client.requests == []


def test_the_routed_specialist_may_ask_a_teammate(env):
    client, agent, _ = env([
        calls(("ask_agent", {"agent": "secretary", "request": "Put a run in tomorrow at 7"})),
        done("Added."),  # Secretary
        done("A run is in for 7 tomorrow."),  # Coach again
    ])
    routed(agent, [], ['{"agent": "coach", "p": 0.8}'])
    body = client.post("/v1/chat", json={"text": "plan me a run tomorrow morning"}, headers=AUTH).json()
    assert body["reply"] == "A run is in for 7 tomorrow." and body["routed"]["agent"] == "coach"
    assert body["consulted"] == ["coach", "secretary"]
    assert [(t["from"], t["to"]) for t in body["team"]] == [("coach", "secretary"), ("secretary", "coach")]


def test_the_team_chat_routes_when_nobody_is_mentioned(env):
    client, agent, _ = env([done("Pasta with chicken.")])
    routed(agent, [], ['{"agent": "coach", "p": 0.88}'])
    body = client.post("/v1/team", json={"text": "what should I eat tonight?"}, headers=AUTH).json()
    assert [(m["from"], m.get("routed")) for m in body["messages"]] == [
        ("user", None), ("coach", {"agent": "coach", "p": 0.88})]
    assert agent.client.requests[0]["system"][0]["text"] == AGENTS["coach"].prompt
    team = client.get("/v1/team", headers=AUTH).json()["messages"]
    assert team[-1]["routed"] == {"agent": "coach", "p": 0.88}
    # A mention still decides, with no router call.
    client2_responses = [done("Here.")]
    agent.client.responses += client2_responses
    client.post("/v1/team", json={"text": "@secretary anything today?"}, headers=AUTH)
    assert len(agent.router.client.requests) == 1


def test_parse():
    router = Router.__new__(Router)
    router.agents = ("secretary", "coach")
    assert router.parse('Sure: {"agent": "Coach", "p": 0.7}') == Pick("coach", 0.7)
    assert router.parse('```json\n{"agent": "aide", "p": 1}\n```') == Pick("aide", 1.0)
    assert router.parse('{"agent": "finance", "p": 0.9}') is None
    assert router.parse('{"agent": "coach"}') is None
