import sqlite3
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.agents import AGENTS, SPECIALISTS
from aide.channels.api import create_app
from aide.db import Database
from aide.reminders import ReminderStore
from aide.tools import Tool, ToolRegistry
from aide.tools.reminders import reminder_tools

ROME = ZoneInfo("Europe/Rome")
AUTH = {"Authorization": "Bearer t"}


class Block(SimpleNamespace):
    def to_dict(self):
        return dict(vars(self))


class FakeClient:
    """Scripted responses; records each request's system prompt and tool names."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    async def _create(self, **kwargs):
        self.requests.append(kwargs)
        stop_reason, content = self.responses.pop(0)
        return SimpleNamespace(stop_reason=stop_reason, content=content)


def done(text):
    return ("end_turn", [Block(type="text", text=text)])


def calls(*uses):
    return ("tool_use", [Block(type="tool_use", id=f"t{i}", name=n, input=a) for i, (n, a) in enumerate(uses)])


def fake(name):
    async def run() -> str:
        return f"{name} ran"
    return Tool(name, name, {"type": "object", "properties": {}, "required": [], "additionalProperties": False}, run)


# Stand-ins for the real tools, by name, to check who gets what.
OTHERS = [fake(n) for n in ("get_current_time", "health", "list_habits", "list_events", "create_event", "send_mail",
                            "web_search", "fetch_page", "find_places")]


@pytest.fixture
def env():
    db = Database(":memory:")
    store = ReminderStore(db.conn)

    def make(responses=()):
        agent = Agent(FakeClient(responses), db, ToolRegistry([*reminder_tools(store, ROME), *OTHERS]),
                      model="m", tz=ROME)
        return TestClient(create_app(agent, store, None, ROME, "t")), agent, store
    yield make
    db.close()


def tool_names(request):
    return {t["name"] for t in request["tools"]}


def new_chat(client, agent_id):
    return client.post("/v1/conversations", json={"agent": agent_id}, headers=AUTH).json()["id"]


# -- definitions -----------------------------------------------------------------


def test_agents_endpoint_matches_the_contract(env):
    client, _, _ = env()
    agents = client.get("/v1/agents", headers=AUTH).json()["agents"]
    assert [a["id"] for a in agents] == ["aide", "secretary", "professor", "coach", "finance"]
    assert [a["orchestrator"] for a in agents] == [True, False, False, False, False]
    assert agents[3] == {"id": "coach", "name": "Coach", "role": "Sleep, training and habits", "color": "#E0782F",
                         "orchestrator": False, "starters": ["How did I sleep this week?", "Should I train hard today?"]}
    assert all(a["color"].startswith("#") and len(a["color"]) == 7 for a in agents)
    assert client.get("/v1/agents").status_code == 401


def test_each_agent_has_its_own_stable_prompt(env):
    _, agent, _ = env()
    prompts = {a: agent._system(a)[0]["text"] for a in AGENTS}
    assert len(set(prompts.values())) == len(AGENTS)
    assert all(agent._system(a)[0]["text"] == prompts[a] for a in AGENTS)  # byte-stable
    assert "medical claims" in prompts["coach"] and "investment advice" in prompts["finance"]
    assert "check understanding" in prompts["professor"] and "ask_agent" in prompts["aide"]


def test_tool_sets_follow_the_table(env):
    _, agent, _ = env()
    names = {a: {t.name for t in agent.registries[a]} for a in AGENTS}
    assert names["aide"] >= {"health", "create_event", "send_mail", "create_reminder", "ask_agent", "remember"}
    assert names["coach"] == {"health", "list_habits", "list_events", "web_search", "fetch_page",
                              "get_current_time", "remember", "forget", "cancel_queued"}
    assert names["professor"] == names["finance"] == {"web_search", "fetch_page", "get_current_time", "remember",
                                                      "forget", "cancel_queued"}
    assert {"create_event", "send_mail", "create_reminder", "find_places"} <= names["secretary"]
    assert "health" not in names["secretary"]
    assert all("ask_agent" not in names[a] for a in SPECIALISTS)


# -- conversations ---------------------------------------------------------------


def test_conversation_belongs_to_an_agent(env):
    client, agent, _ = env()
    row = client.post("/v1/conversations", json={"agent": "coach"}, headers=AUTH).json()
    assert row["agent"] == "coach" and row["title"] is None
    assert client.post("/v1/conversations", json={}, headers=AUTH).json()["agent"] == "aide"
    r = client.post("/v1/conversations", json={"agent": "butler"}, headers=AUTH)
    assert r.status_code == 400 and "unknown agent" in r.json()["error"]
    listed = {c["id"]: c["agent"] for c in client.get("/v1/conversations", headers=AUTH).json()["conversations"]}
    assert listed[row["id"]] == "coach" and listed["main"] == "aide"
    # A digest chat is Aide's whatever agent is asked for.
    assert agent.new_conversation("Good morning", agent="coach")["agent"] == "aide"


def test_chat_answers_as_the_conversations_agent(env):
    client, agent, _ = env([done("Slept well."), done("Sleep check")])
    cid = new_chat(client, "coach")
    body = client.post("/v1/chat", json={"text": "how did I sleep?", "conversation_id": cid}, headers=AUTH).json()
    assert body["reply"] == "Slept well." and body["consulted"] == []
    request = agent.client.requests[0]
    assert request["system"][0]["text"] == AGENTS["coach"].prompt
    assert "health" in tool_names(request) and "create_event" not in tool_names(request)


def test_older_databases_become_aides_and_shared(tmp_path):
    path = tmp_path / "old.db"
    old = sqlite3.connect(path)
    old.executescript("""
        CREATE TABLE conversations (id INTEGER PRIMARY KEY, channel TEXT NOT NULL, started_at TEXT NOT NULL,
            last_active_at TEXT NOT NULL, model TEXT, public_id TEXT, title TEXT);
        CREATE TABLE messages (id INTEGER PRIMARY KEY, conversation_id INTEGER NOT NULL, channel TEXT NOT NULL,
            role TEXT NOT NULL, content TEXT NOT NULL, ts TEXT NOT NULL, attachments TEXT);
        CREATE TABLE memory (id INTEGER PRIMARY KEY, text TEXT NOT NULL, created_at TEXT NOT NULL);
        INSERT INTO conversations VALUES (1, 'app', 'x', 'x', NULL, 'c_1', 'Old');
        INSERT INTO messages VALUES (1, 1, 'app', 'assistant', '"hi"', 'x', NULL);
        INSERT INTO memory VALUES (1, 'Vegetarian', 'x');
    """)
    old.close()
    db = Database(path)
    assert db.app_conversation("c_1")["agent"] == "aide"
    assert db.memories()[0]["agent"] is None
    assert db.history_with_ts(1)[0][4] == []
    db.close()


# -- memory ----------------------------------------------------------------------


def test_memory_api_takes_and_returns_the_agent(env):
    client, agent, _ = env()
    shared = client.post("/v1/memory", json={"text": "Vegetarian"}, headers=AUTH).json()
    own = client.post("/v1/memory", json={"text": "Marathon in April", "agent": "coach"}, headers=AUTH).json()
    assert shared["agent"] is None and own["agent"] == "coach"
    assert [i["agent"] for i in client.get("/v1/memory", headers=AUTH).json()["items"]] == ["coach", None]
    assert client.post("/v1/memory", json={"text": "x", "agent": "butler"}, headers=AUTH).status_code == 400
    aide = client.post("/v1/memory", json={"text": "Likes tea", "agent": "aide"}, headers=AUTH).json()
    assert aide["agent"] is None  # Aide has no items of its own
    assert agent.db.memory_item(aide["id"])["agent"] is None


def test_each_agent_sees_shared_memory_plus_its_own(env):
    _, agent, _ = env()
    agent.db.add_memory("Vegetarian")
    agent.db.add_memory("Marathon in April", "coach")
    agent.db.add_memory("Saving for a bike", "finance")
    aide = agent._system("aide")[-1]["text"]
    coach = agent._system("coach")[-1]["text"]
    assert "Vegetarian" in aide and "Marathon" not in aide and "bike" not in aide
    assert "(shared) Vegetarian" in coach and "(yours) Marathon in April" in coach and "bike" not in coach


def test_remember_scope(env):
    client, agent, _ = env([
        calls(("remember", {"text": "Trains on Tuesdays", "scope": "own"}),
              ("remember", {"text": "Lives in Milan", "scope": "shared"})), done("Noted."), done("t"),
        calls(("remember", {"text": "Likes tea"})), done("Noted."),
    ])
    cid = new_chat(client, "coach")
    client.post("/v1/chat", json={"text": "I train on Tuesdays, I live in Milan", "conversation_id": cid},
                headers=AUTH)
    client.post("/v1/chat", json={"text": "I like tea"}, headers=AUTH)  # Aide's shared chat
    assert {m["text"]: m["agent"] for m in agent.db.memories()} == {
        "Trains on Tuesdays": "coach", "Lives in Milan": None, "Likes tea": None}
    remember = {a: next(t for t in agent.registries[a] if t.name == "remember").input_schema for a in AGENTS}
    assert "scope" not in remember["aide"]["properties"] and remember["coach"]["required"] == ["text", "scope"]


async def test_specialist_cannot_forget_another_agents_memory(env):
    _, agent, _ = env()
    item = agent.db.add_memory("Saving for a bike", "finance")
    forget = next(t for t in agent.registries["coach"] if t.name == "forget")
    with pytest.raises(KeyError):
        await forget.describe(memory_id=item["id"])


# -- ask_agent -------------------------------------------------------------------


def test_aide_asks_a_specialist(env):
    client, agent, store = env([
        calls(("ask_agent", {"agent": "coach", "request": "Should he train hard today? He asked at 8."})),
        done("Recovery looks fine, go for it."),  # Coach's stateless turn
        done("Coach thinks you're good to go."),
    ])
    agent.db.add_memory("Marathon in April", "coach")
    body = client.post("/v1/chat", json={"text": "should I train hard today?"}, headers=AUTH).json()
    assert body["reply"] == "Coach thinks you're good to go." and body["consulted"] == ["coach"]

    aide_first, coach, aide_second = agent.client.requests
    assert coach["system"][0]["text"] == AGENTS["coach"].prompt and "Marathon" in coach["system"][-1]["text"]
    assert "ask_agent" not in tool_names(coach) and "ask_agent" in tool_names(aide_first)
    assert len(coach["messages"]) == 1 and "[Asked by Aide] Should he train hard" in str(coach["messages"][0])
    result = aide_second["messages"][-1]["content"][0]
    assert result["type"] == "tool_result" and "Coach answered:\nRecovery looks fine" in result["content"]

    history = client.get("/v1/history", headers=AUTH).json()["messages"]
    assert [m["consulted"] for m in history] == [[], ["coach"]]
    # Nothing goes into Coach's own chats.
    assert not [c for c in client.get("/v1/conversations", headers=AUTH).json()["conversations"]
                if c["agent"] == "coach"]


def test_a_specialists_cards_and_queued_actions_join_aides_turn(env):
    client, agent, store = env()
    rem = store.create("Bins", None)
    agent.client.responses = [
        calls(("ask_agent", {"agent": "secretary", "request": "Show the open reminders, delete Bins"})),
        calls(("list_reminders", {}), ("delete_reminder", {"reminder_id": rem.id})),
        done("Listed; deleting Bins is queued."),
        done("Secretary queued deleting Bins."),
    ]
    body = client.post("/v1/chat", json={"text": "clean up my reminders"}, headers=AUTH).json()
    assert body["consulted"] == ["secretary"]
    assert [r["id"] for r in body["attachments"][0]["reminders"]] == [rem.id]
    assert len(body["pending"]) == 1 and "Bins" in body["pending"][0]["summary"]
    assert store.get(rem.id) is not None  # not yet
    client.post("/v1/confirm", json={}, headers=AUTH)
    assert store.get(rem.id).deleted


def test_at_most_three_asks_per_turn(env):
    ask = ("ask_agent", {"agent": "finance", "request": "?"})
    client, agent, _ = env([calls(ask, ask, ask, ask), done("a"), done("b"), done("c"), done("Done.")])
    body = client.post("/v1/chat", json={"text": "money?"}, headers=AUTH).json()
    assert body["consulted"] == ["finance"] * 3
    results = agent.client.requests[-1]["messages"][-1]["content"]
    assert [r["is_error"] for r in results] == [False, False, False, True]
    assert "already asked 3 times" in results[3]["content"]


def test_a_specialist_cannot_ask_others(env):
    client, agent, _ = env([
        calls(("ask_agent", {"agent": "coach", "request": "?"})),
        calls(("ask_agent", {"agent": "finance", "request": "?"})),  # Coach tries to ask
        done("I'll answer myself."),
        done("Coach says so."),
    ])
    body = client.post("/v1/chat", json={"text": "hi"}, headers=AUTH).json()
    assert body["consulted"] == ["coach"]
    coach_result = agent.client.requests[2]["messages"][-1]["content"][0]
    assert coach_result["is_error"] and "unknown tool" in coach_result["content"]
