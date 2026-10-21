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
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create, stream=self._stream))

    async def _create(self, **kwargs):
        self.requests.append(kwargs)
        stop_reason, content = self.responses.pop(0)
        return SimpleNamespace(stop_reason=stop_reason, content=content)

    def _stream(self, **kwargs):
        return FakeStream(self._create(**kwargs))


class FakeStream:
    """messages.stream(): each text block as a block start, then its words one by one."""

    def __init__(self, response):
        self.pending = response

    async def __aenter__(self):
        self.response = await self.pending
        return self

    async def __aexit__(self, *exc):
        return False

    async def __aiter__(self):
        for block in self.response.content:
            yield SimpleNamespace(type="content_block_start", content_block=SimpleNamespace(type=block.type))
            if block.type == "text":
                for i, word in enumerate(block.text.split(" ")):
                    yield SimpleNamespace(type="text", text=word if i == 0 else " " + word)

    async def get_final_message(self):
        return self.response


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
    coach = {k: v for k, v in agents[3].items() if k not in ("prompt", "tools", "connectors")}
    assert {**coach, "routine_ideas": coach["routine_ideas"][:1]} == {
        "id": "coach", "name": "Coach", "role": "Sleep, training, food and habits", "color": "#23A26D",
        "orchestrator": False, "starters": ["How did I sleep this week?", "Should I train hard today?",
                                            "What have I eaten today?"],
        "routine_ideas": [{"title": "Weekly recap", "prompt": AGENTS["coach"].routine_ideas[0]["prompt"],
                           "time": "18:00", "days": [7], "watch": False}]}
    assert [(i["title"], i["time"], i["days"], i["watch"]) for a in agents for i in a["routine_ideas"]] == [
        ("Plan my week", "20:00", [7], False), ("Mail sweep", "09:00", [1, 2, 3, 4, 5], False),
        ("Mail that needs you", "11:00", [1, 2, 3, 4, 5], True), ("Tomorrow", "18:30", [1, 2, 3, 4, 7], True),
        ("Review what I studied", "17:00", [7], False), ("Weekly recap", "18:00", [7], False),
        ("Recovery check", "09:00", [], True), ("Habits tonight", "20:30", [], True),
        ("Week's spending", "19:00", [7], False)]
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
    routines = {"list_routines", "create_routine", "update_routine", "delete_routine"}
    assert names["coach"] == {"health", "list_habits", "list_events", "web_search", "fetch_page",
                              "get_current_time", "remember", "forget", "cancel_queued", *routines}
    assert names["professor"] == names["finance"] == {"web_search", "fetch_page", "get_current_time", "remember",
                                                      "forget", "cancel_queued", *routines}
    assert all(routines <= names[a] for a in AGENTS)
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


def test_specialists_see_shared_memory_plus_their_own_and_aide_sees_all(env):
    _, agent, _ = env()
    agent.db.add_memory("Vegetarian")
    agent.db.add_memory("Marathon in April", "coach")
    agent.db.add_memory("Saving for a bike", "finance")
    aide = agent._system("aide")[-1]["text"]
    coach = agent._system("coach")[-1]["text"]
    assert "] Vegetarian" in aide and "(Coach's) Marathon in April" in aide and "(Finance's) Saving for a bike" in aide
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
    aide_forget = next(t for t in agent.registries["aide"] if t.name == "forget")
    assert await aide_forget.describe(memory_id=item["id"]) == "Forget 'Saving for a bike'"


async def test_aide_doesnt_save_what_a_specialist_already_knows(env):
    _, agent, _ = env()
    agent.db.add_memory("Business law is in Novoli", "secretary")
    remember = next(t for t in agent.registries["aide"] if t.name == "remember")
    assert (await remember.handler(text="Business law is in Novoli")).startswith("Already saved")


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


# -- team talk -------------------------------------------------------------------


def ask(agent_id, request):
    return calls(("ask_agent", {"agent": agent_id, "request": request}))


def team_lines(team):
    return [(t["from"], t["to"], t["text"]) for t in team]


def test_team_messages_are_in_chat_history_and_the_team_chat(env):
    client, agent, _ = env([ask("coach", "Gym tonight? Slept 6h."), done("Easy session is fine."),
                            done("Coach says go easy."), done("Gym chat"),
                            ask("finance", "Budget for a bike?"), done("Save 50 a month."), done("Finance says 50.")])
    cid = new_chat(client, "aide")
    body = client.post("/v1/chat", json={"text": "gym tonight?", "conversation_id": cid}, headers=AUTH).json()
    expected = [("aide", "coach", "Gym tonight? Slept 6h."), ("coach", "aide", "Easy session is fine.")]
    assert team_lines(body["team"]) == expected and body["consulted"] == ["coach"]
    assert all(t["ts"].endswith(("+01:00", "+02:00")) for t in body["team"])
    client.post("/v1/chat", json={"text": "bike budget?"}, headers=AUTH)  # the shared conversation

    history = client.get("/v1/history", params={"conversation_id": cid}, headers=AUTH).json()["messages"]
    assert [team_lines(m["team"]) for m in history] == [[], expected]

    team = client.get("/v1/team", headers=AUTH).json()["messages"]
    assert [(t["from"], t["conversation_id"]) for t in team] == [("aide", cid), ("coach", cid),
                                                                ("aide", "main"), ("finance", "main")]
    assert [t["text"] for t in client.get("/v1/team?limit=2", headers=AUTH).json()["messages"]] == [
        "Budget for a bike?", "Save 50 a month."]  # the latest, oldest first

    client.delete(f"/v1/conversations/{cid}", headers=AUTH)
    assert [t["conversation_id"] for t in client.get("/v1/team", headers=AUTH).json()["messages"]] == ["main"] * 2


def test_plain_replies_have_an_empty_team(env):
    client, _, _ = env([done("hi")])
    assert client.post("/v1/chat", json={"text": "hi"}, headers=AUTH).json()["team"] == []
    assert [m["team"] for m in client.get("/v1/history", headers=AUTH).json()["messages"]] == [[], []]


async def test_team_messages_are_announced_as_they_happen(env):
    _, agent, _ = env([ask("coach", "Gym?"), done("Go easy."), done("Coach says go easy.")])
    seen, at_request = [], []
    create = agent.client._create

    async def spy(**kwargs):
        at_request.append(len(seen))
        return await create(**kwargs)
    agent.client.beta.messages.create = spy
    turn = await agent.respond("main", "gym?", on_team=seen.append)
    assert at_request == [0, 1, 2]  # the ask is out before Coach starts, the answer before Aide's reply
    assert seen == turn.team and team_lines(seen) == [("aide", "coach", "Gym?"), ("coach", "aide", "Go easy.")]


def events(response):
    """(event, data) pairs, checking the wire format: one event line, one data line, a blank line."""
    import json
    blocks = response.text.split("\n\n")
    assert blocks[-1] == ""
    out = []
    for block in blocks[:-1]:
        event, data = block.split("\n")
        assert event.startswith("event: ") and data.startswith("data: ")
        out.append((event.removeprefix("event: "), json.loads(data.removeprefix("data: "))))
    return out


def test_streamed_chat_sends_team_then_the_reply(env):
    client, agent, store = env()
    rem = store.create("Bins", None)
    agent.client.responses = [ask("secretary", "Delete Bins\nplease"),
                              calls(("delete_reminder", {"reminder_id": rem.id})), done("Queued it.\nDone."),
                              done("Secretary queued it.")]
    r = client.post("/v1/chat", json={"text": "delete bins", "stream": True}, headers=AUTH)
    assert r.headers["content-type"].startswith("text/event-stream")
    got = events(r)
    assert [e for e, _ in got] == ["team", "team", "text", "text", "text", "reply"]
    assert got[0][1]["text"] == "Delete Bins\nplease" and got[1][1]["from"] == "secretary"
    # Only Aide's own reply is streamed, not Secretary's answer, and it starts a fresh draft after the ask.
    assert [d for _, d in got[2:5]] == [{"delta": "Secretary", "restart": True}, {"delta": " queued", "restart": False},
                                        {"delta": " it.", "restart": False}]
    reply = got[5][1]
    assert reply["reply"] == "Secretary queued it." and reply["team"] == [got[0][1], got[1][1]]
    assert len(reply["pending"]) == 1  # the usual queue: nothing deleted until !yes
    assert store.get(rem.id) and not store.get(rem.id).deleted


def test_streamed_chat_without_asks_is_just_the_reply(env):
    client, _, _ = env([done("hi")])
    got = events(client.post("/v1/chat", json={"text": "hi", "stream": True}, headers=AUTH))
    assert got[0] == ("text", {"delta": "hi", "restart": False})
    assert [e for e, _ in got] == ["text", "reply"] and got[1][1]["team"] == []


def test_streamed_text_starts_over_after_tools(env):
    """Text before a tool call is a draft: the round after the tools replaces it, and the reply is only that."""
    client, agent, _ = env([("tool_use", [Block(type="text", text="Let me check."),
                                          Block(type="tool_use", id="t0", name="list_events", input={})]),
                            ("end_turn", [Block(type="text", text="Free"), Block(type="text", text="all day.")])])
    got = events(client.post("/v1/chat", json={"text": "busy?", "stream": True}, headers=AUTH))
    texts = [d for e, d in got if e == "text"]
    assert [d["restart"] for d in texts] == [False, False, False, True, False, False, False]
    assert "".join(d["delta"] for d in texts[3:]) == "Free\n\nall day."
    assert got[-1][1]["reply"] == "Free\n\nall day."


def test_streamed_chat_errors(env):
    client, _, _ = env([])  # no scripted response: the turn fails after the stream starts
    got = events(client.post("/v1/chat", json={"text": "hi", "stream": True}, headers=AUTH))
    assert got == [("error", {"error": "Something went wrong on the server. It's in the logs."})]
    assert client.post("/v1/chat", json={"text": "hi", "stream": True, "conversation_id": "c_nope"},
                       headers=AUTH).status_code == 404  # before the stream: plain HTTP error
    assert client.post("/v1/chat", json={"text": " ", "stream": True}, headers=AUTH).status_code == 400


# -- writing in the Team chat ----------------------------------------------------


def team_rows(messages):
    return [(m["from"], m["to"], m["text"], m["conversation_id"]) for m in messages]


def test_without_a_mention_aide_answers_in_the_team_chat(env):
    client, agent, _ = env([ask("coach", "Gym?"), done("Go easy."), done("Done."),
                            done("Coach says go easy tonight.")])
    client.post("/v1/chat", json={"text": "gym?"}, headers=AUTH)  # earlier team talk, from Aide's chat
    body = client.post("/v1/team", json={"text": "what should I eat tonight?"}, headers=AUTH).json()
    assert team_rows(body["messages"]) == [("user", "team", "what should I eat tonight?", None),
                                           ("aide", "team", "Coach says go easy tonight.", None)]
    assert body["pending"] == [] and body["messages"][0]["ts"].endswith(("+01:00", "+02:00"))
    request = agent.client.requests[-1]
    assert request["system"][0]["text"] == AGENTS["aide"].prompt and "ask_agent" in tool_names(request)
    context = request["messages"][0]["content"][0]["text"]
    assert "[Team chat] You are Aide" in context and "Aide → Coach: Gym?" in context
    assert context.index("Coach → Aide: Go easy.") < context.index("User → Everyone: what should I eat tonight?")
    team = client.get("/v1/team", headers=AUTH).json()["messages"]
    assert team_rows(team)[-2:] == team_rows(body["messages"])
    assert [t["conversation_id"] for t in team[:2]] == ["main", "main"]


def test_a_follow_up_goes_to_whoever_answered(env):
    """#16: no mention, and the last message was answered by Secretary not long ago: Secretary answers again."""
    client, agent, _ = env([done("Milk and eggs?"), done("Found them in Reminders."), done("Hi!")])
    client.post("/v1/team", json={"text": "@secretary what do I need at the supermarket?"}, headers=AUTH)
    body = client.post("/v1/team", json={"text": "it's in the reminders"}, headers=AUTH).json()
    assert [m["from"] for m in body["messages"]] == ["user", "secretary"]
    assert agent.client.requests[-1]["system"][0]["text"] == AGENTS["secretary"].prompt
    # @aide always goes back to Aide.
    body = client.post("/v1/team", json={"text": "@aide thanks"}, headers=AUTH).json()
    assert [m["from"] for m in body["messages"]] == ["user", "aide"]


def test_an_old_conversation_goes_back_to_aide(env):
    client, agent, _ = env([done("Milk."), done("Morning!")])
    client.post("/v1/team", json={"text": "@secretary shopping list?"}, headers=AUTH)
    agent.db.conn.execute("UPDATE team_messages SET ts = '2026-01-01T08:00:00+00:00'")
    body = client.post("/v1/team", json={"text": "good morning"}, headers=AUTH).json()
    assert [m["from"] for m in body["messages"]] == ["user", "aide"]


def test_mentions_pick_who_answers_in_order(env):
    client, agent, _ = env([done("Sleep is fine."), done("Budget allows it.")])
    body = client.post("/v1/team", json={"text": "@Finance @coach can I do a ski trip? mail me at a@b.com"},
                       headers=AUTH).json()
    assert [m["from"] for m in body["messages"]] == ["user", "finance", "coach"]
    finance, coach = agent.client.requests
    assert finance["system"][0]["text"] == AGENTS["finance"].prompt and coach["system"][0]["text"] == AGENTS["coach"].prompt
    assert "Finance → Everyone: Sleep is fine." in coach["messages"][0]["content"][0]["text"]  # sees what was said
    assert all("ask_agent" not in tool_names(r) for r in agent.client.requests)


def test_at_most_three_mentions():
    from aide.agents import mentions
    assert mentions("@coach @finance @secretary @professor @coach hi") == ["coach", "finance", "secretary"]
    assert mentions("@COACH and @Coach") == ["coach"] and mentions("a@b.com") == [] and mentions("no one") == []


def test_team_chat_errors(env):
    client, agent, _ = env()
    r = client.post("/v1/team", json={"text": "@bob hi"}, headers=AUTH)
    assert r.status_code == 400 and r.json() == {"error": "No agent called @bob."}
    assert client.post("/v1/team", json={"text": "  "}, headers=AUTH).status_code == 400
    assert client.post("/v1/team", json={"text": "@bob", "stream": True}, headers=AUTH).status_code == 400
    assert client.post("/v1/team", json={"text": "hi"}).status_code == 401
    assert client.get("/v1/team", headers=AUTH).json()["messages"] == []  # nothing stored for a refused message


def test_actions_queued_in_the_team_chat_join_the_queue(env):
    client, agent, store = env()
    rem = store.create("Bins", None)
    agent.client.responses = [calls(("delete_reminder", {"reminder_id": rem.id})), done("Queued deleting Bins.")]
    body = client.post("/v1/team", json={"text": "@secretary delete bins"}, headers=AUTH).json()
    assert len(body["pending"]) == 1 and not store.get(rem.id).deleted
    client.post("/v1/confirm", json={}, headers=AUTH)
    assert store.get(rem.id).deleted
    assert client.get("/v1/history", headers=AUTH).json()["messages"] == []  # no note lands in the shared chat


def test_streamed_team_chat(env):
    client, _, _ = env([ask("coach", "Recovery?"), done("HRV is up."), done("Coach says you're recovered.")])
    got = events(client.post("/v1/team", json={"text": "how am I doing?", "stream": True}, headers=AUTH))
    assert [(e, d.get("agent") or d.get("from")) for e, d in got[:-1]] == [
        ("team", "user"), ("working", "aide"), ("team", "aide"), ("working", "coach"), ("team", "coach"),
        ("team", "aide")]
    event, body = got[-1]
    assert event == "done" and body["messages"] == [d for e, d in got if e == "team"] and body["pending"] == []
    assert [(m["from"], m["to"]) for m in body["messages"]] == [
        ("user", "team"), ("aide", "coach"), ("coach", "aide"), ("aide", "team")]


def test_streamed_team_chat_errors(env):
    client, _, _ = env([])
    got = events(client.post("/v1/team", json={"text": "hi", "stream": True}, headers=AUTH))
    assert [e for e, _ in got] == ["team", "working", "error"]


def test_agents_show_their_prompt_and_connectors(env):
    client, agent, _ = env()
    agents = {a["id"]: a for a in client.get("/v1/agents", headers=AUTH).json()["agents"]}
    assert agents["coach"]["prompt"] == AGENTS["coach"].prompt
    assert set(agents["coach"]["tools"]) == {t.name for t in agent.registries["coach"]}
    coach = {c["id"]: c for c in agents["coach"]["connectors"]}
    assert list(coach) == ["calendar", "health", "habits", "web", "memory", "routines"]
    assert coach["calendar"] == {"id": "calendar", "name": "iCloud Calendar", "read_only": True, "tools": ["list_events"]}
    assert coach["health"]["read_only"] and not coach["memory"]["read_only"]
    assert "team" in {c["id"] for c in agents["aide"]["connectors"]}
    assert "team" not in {c["id"] for c in agents["professor"]["connectors"]}


def test_connectors_mark_what_can_only_read():
    from aide.agents import connectors
    assert connectors(["search_mail", "read_mail"]) == [
        {"id": "mail", "name": "Gmail", "read_only": True, "tools": ["search_mail", "read_mail"]}]
    assert connectors(["send_mail"])[0]["read_only"] is False
    assert connectors(["get_current_time", "cancel_queued"]) == []
