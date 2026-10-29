import re
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.icloud import CalEvent
from aide.reminders import ReminderStore
from aide.shapes import reminder_json
from aide.tools import ToolRegistry
from aide.tools.reminders import reminder_tools

ROME = ZoneInfo("Europe/Rome")
TOKEN = "secret-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class Block(SimpleNamespace):
    def to_dict(self):
        return dict(vars(self))


class FakeClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    async def _create(self, **kwargs):
        stop_reason, content = self.responses.pop(0)
        return SimpleNamespace(stop_reason=stop_reason, content=content)


class FakeCalendar:
    def __init__(self, events):
        self._events = events

    def events(self, start, end):
        return self._events


def done(text):
    return ("end_turn", [Block(type="text", text=text)])


def call(name, **input):
    return ("tool_use", [Block(type="tool_use", id="t1", name=name, input=input)])


@pytest.fixture
def env():
    db = Database(":memory:")
    store = ReminderStore(db.conn)
    def make(responses=(), events=()):
        agent = Agent(FakeClient(responses), db, ToolRegistry(reminder_tools(store, ROME)), model="m", delegate=False, tz=ROME)
        app = create_app(agent, store, FakeCalendar(list(events)), ROME, TOKEN)
        return TestClient(app), agent, store
    yield make
    db.close()


def test_health_needs_no_token(env):
    client, _, _ = env()
    assert client.get("/v1/health").json() == {"ok": True, "version": "0.2.0"}


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}, {"Authorization": TOKEN}])
def test_bad_token_is_rejected(env, headers):
    client, _, _ = env()
    r = client.post("/v1/chat", json={"text": "hi"}, headers=headers)
    assert r.status_code == 401 and r.json() == {"error": "missing or wrong token"}


def test_chat_returns_reply_and_pending(env):
    client, agent, store = env([call("create_reminder", title="Bins"), done("ok")])
    r = client.post("/v1/chat", json={"text": "remind me bins"}, headers=AUTH)
    rem = store.open()[0]
    assert r.json() == {"reply": "ok", "pending": [], "conversation_id": "main",
                        "attachments": [{"type": "reminders", "reminders": [reminder_json(rem, ROME)]}],
                        "consulted": [], "team": []}

    client2, _, _ = env([call("delete_reminder", reminder_id=rem.id), done("queued")])
    body = client2.post("/v1/chat", json={"text": "delete it"}, headers=AUTH).json()
    assert body["pending"][0]["summary"] == "Delete reminder 'Bins'"

    r = client2.post("/v1/confirm", json={}, headers=AUTH).json()
    assert r == {"result": "✓ Deleted reminder: Bins", "pending": []}
    assert store.open() == []


def test_history_shows_only_visible_text(env):
    client, _, _ = env([call("create_reminder", title="Bins"), done("Added it.")])
    client.post("/v1/chat", json={"text": "remind me bins"}, headers=AUTH)
    msgs = client.get("/v1/history", headers=AUTH).json()["messages"]
    assert [(m["role"], m["text"]) for m in msgs] == [("user", "remind me bins"), ("assistant", "Added it.")]


def test_today_lists_events_and_due_reminders(env):
    ev = CalEvent("e1", "Home", "Dentist", datetime(2026, 10, 20, 15, tzinfo=ROME), datetime(2026, 10, 20, 16, tzinfo=ROME))
    client, _, store = env(events=[ev])
    store.create("Overdue", datetime(2026, 10, 19, 9, tzinfo=ROME))
    store.create("Today", datetime(2026, 10, 20, 17, tzinfo=ROME))
    store.create("Tomorrow", datetime(2026, 10, 21, 9, tzinfo=ROME))
    store.create("Someday")
    body = client.get("/v1/today?date=2026-10-20", headers=AUTH).json()
    assert body["events"][0] == {"id": "e1", "title": "Dentist", "calendar": "Home",
                                 "start": "2026-10-20T15:00:00+02:00", "end": "2026-10-20T16:00:00+02:00",
                                 "all_day": False, "location": "", "notes": "", "recurring": False}
    assert [r["title"] for r in body["reminders"]] == ["Overdue", "Today"]
    assert body["reminders"][1]["due_at"] == "2026-10-20T17:00:00+02:00"


def test_the_first_chat_is_the_default(env):
    client, agent, _ = env([done("hi")])
    client.post("/v1/chat", json={"text": "hello"}, headers=AUTH)
    assert [m["text"] for m in agent.visible_history(CONVERSATION)] == ["hello", "hi"]


# -- conversations -------------------------------------------------------------


def test_conversations_list_includes_the_shared_one(env):
    client, _, _ = env([done("hi there")])
    client.post("/v1/chat", json={"text": "hello"}, headers=AUTH)
    rows = client.get("/v1/conversations", headers=AUTH).json()["conversations"]
    assert [(r["id"], r["title"], r["preview"]) for r in rows] == [("main", "First chat", "hi there")]
    assert rows[0]["updated_at"].endswith(("+01:00", "+02:00"))


def test_app_conversation_is_separate_and_gets_a_title(env):
    client, agent, _ = env([done("shared reply"), done("Friday 10:00 it is."), done("Dentist on Friday")])
    client.post("/v1/chat", json={"text": "in the first chat"}, headers=AUTH)
    new = client.post("/v1/conversations", json={}, headers=AUTH).json()
    assert new["id"].startswith("c_") and new["title"] is None and new["preview"] is None
    body = client.post("/v1/chat", json={"text": "dentist friday 10", "conversation_id": new["id"]},
                       headers=AUTH).json()
    assert body["reply"] == "Friday 10:00 it is." and body["conversation_id"] == new["id"]

    app_msgs = client.get(f"/v1/history?conversation_id={new['id']}", headers=AUTH).json()["messages"]
    assert [m["text"] for m in app_msgs] == ["dentist friday 10", "Friday 10:00 it is."]
    shared = client.get("/v1/history", headers=AUTH).json()["messages"]
    assert [m["text"] for m in shared] == ["in the first chat", "shared reply"]

    rows = client.get("/v1/conversations", headers=AUTH).json()["conversations"]
    assert [(r["id"], r["title"]) for r in rows] == [(new["id"], "Dentist on Friday"), ("main", "First chat")]


def test_title_falls_back_to_the_first_message(env):
    client, _, _ = env([done("ok")])  # no scripted title response: the title call fails
    cid = client.post("/v1/conversations", json={}, headers=AUTH).json()["id"]
    client.post("/v1/chat", json={"text": "plan a weekend trip to the lakes with friends", "conversation_id": cid},
                headers=AUTH)
    rows = client.get("/v1/conversations", headers=AUTH).json()["conversations"]
    row = next(r for r in rows if r["id"] == cid)
    assert row["title"] == "plan a weekend trip to the lakes with…"


def test_think_per_conversation(env):
    client, agent, _ = env()
    cid = client.post("/v1/conversations", json={}, headers=AUTH).json()["id"]
    assert client.post("/v1/think", json={"conversation_id": cid}, headers=AUTH).json() == {"ok": True}
    assert agent.db.conversation_model(agent.db.app_conversation(cid)["id"]) == agent.smart_model
    assert agent.db.conversation_model(agent.db.current_conversation(CONVERSATION, agent.idle)) is None
    assert client.post("/v1/think", headers=AUTH).json() == {"ok": True}  # old clients send no body


def test_delete_conversation(env):
    client, _, _ = env([done("ok")])
    cid = client.post("/v1/conversations", json={}, headers=AUTH).json()["id"]
    client.post("/v1/chat", json={"text": "hi", "conversation_id": cid}, headers=AUTH)
    assert client.delete(f"/v1/conversations/{cid}", headers=AUTH).json() == {"ok": True}
    assert [r["id"] for r in client.get("/v1/conversations", headers=AUTH).json()["conversations"]] == ["main"]
    assert client.get(f"/v1/history?conversation_id={cid}", headers=AUTH).status_code == 404
    r = client.post("/v1/chat", json={"text": "hi", "conversation_id": cid}, headers=AUTH)
    assert r.status_code == 404 and "error" in r.json()
    assert client.delete(f"/v1/conversations/{cid}", headers=AUTH).status_code == 404


def test_shared_conversation_cannot_be_deleted(env):
    client, _, _ = env()
    r = client.delete("/v1/conversations/main", headers=AUTH)
    assert r.status_code == 400 and "error" in r.json()


def test_queue_is_global_and_results_go_to_the_chat_that_queued(env):
    client, agent, store = env()
    rem = store.create("Bins")
    client, agent, _ = env([call("delete_reminder", reminder_id=rem.id), done("queued"), done("Delete bins")])
    cid = client.post("/v1/conversations", json={}, headers=AUTH).json()["id"]
    body = client.post("/v1/chat", json={"text": "delete bins", "conversation_id": cid}, headers=AUTH).json()
    assert [p["summary"] for p in body["pending"]] == ["Delete reminder 'Bins'"]
    assert agent.pending(CONVERSATION) == ["Delete reminder 'Bins'"]  # the first chat sees it too

    assert client.post("/v1/confirm", json={}, headers=AUTH).json()["result"] == "✓ Deleted reminder: Bins"
    app_conv = agent.db.app_conversation(cid)["id"]
    assert "Deleted reminder: Bins" in agent.db.history(app_conv)[-1]["content"]
    assert agent.visible_history(CONVERSATION) == []  # nothing noted in the shared chat


# -- memory --------------------------------------------------------------------


def test_memory_crud(env):
    client, _, _ = env()
    assert client.get("/v1/memory", headers=AUTH).json() == {"items": []}
    a = client.post("/v1/memory", json={"text": "Vegetarian"}, headers=AUTH).json()
    b = client.post("/v1/memory", json={"text": "Sister is Giulia"}, headers=AUTH).json()
    assert a["text"] == "Vegetarian" and isinstance(a["id"], int) and a["created_at"].endswith(("+01:00", "+02:00"))
    items = client.get("/v1/memory", headers=AUTH).json()["items"]
    assert [i["text"] for i in items] == ["Sister is Giulia", "Vegetarian"]  # newest first
    assert client.delete(f"/v1/memory/{a['id']}", headers=AUTH).json() == {"ok": True}
    assert client.delete(f"/v1/memory/{a['id']}", headers=AUTH).status_code == 404
    assert [i["id"] for i in client.get("/v1/memory", headers=AUTH).json()["items"]] == [b["id"]]
    assert client.post("/v1/memory", json={"text": "  "}, headers=AUTH).status_code == 400


def test_memory_is_in_every_conversations_system_context(env):
    client, agent, _ = env([done("a"), done("b"), done("title")])
    requests = []
    create = agent.client.beta.messages.create

    async def spy(**kwargs):
        requests.append(kwargs)
        return await create(**kwargs)
    agent.client.beta.messages.create = spy

    client.post("/v1/memory", json={"text": "Vegetarian"}, headers=AUTH)
    client.post("/v1/chat", json={"text": "hi"}, headers=AUTH)
    cid = client.post("/v1/conversations", json={}, headers=AUTH).json()["id"]
    client.post("/v1/chat", json={"text": "hi", "conversation_id": cid}, headers=AUTH)
    for req in requests[:2]:
        assert "Vegetarian" in req["system"][-1]["text"]


def test_model_remembers_immediately_but_forgetting_is_queued(env):
    client, agent, _ = env([call("remember", text="Likes window seats"), done("Noted.")])
    client.post("/v1/chat", json={"text": "I always want a window seat"}, headers=AUTH)
    item = client.get("/v1/memory", headers=AUTH).json()["items"][0]
    assert item["text"] == "Likes window seats"

    client, agent, _ = env([call("forget", memory_id=item["id"]), done("Queued.")])
    body = client.post("/v1/chat", json={"text": "forget the seat thing"}, headers=AUTH).json()
    assert body["pending"][0]["summary"] == "Forget 'Likes window seats'"
    assert len(client.get("/v1/memory", headers=AUTH).json()["items"]) == 1  # not yet
    client.post("/v1/confirm", json={}, headers=AUTH)
    assert client.get("/v1/memory", headers=AUTH).json()["items"] == []


# -- sync ----------------------------------------------------------------------


def iso(dt):
    return dt.isoformat().replace("+00:00", "Z")


def test_first_sync_sends_server_reminders(env):
    client, _, store = env()
    store.create("Call mum", datetime(2026, 10, 20, 17, tzinfo=ROME))
    body = client.post("/v1/reminders/sync", json={"cursor": None, "changes": []}, headers=AUTH).json()
    assert body["cursor"] == "1"
    assert [r["title"] for r in body["reminders"]] == ["Call mum"]
    assert body["reminders"][0]["apple_id"] is None


def test_phone_created_reminder_gets_an_id_and_retry_is_idempotent(env):
    client, _, store = env()
    change = {"id": None, "apple_id": "apple-1", "title": "Buy milk", "modified_at": "2026-10-18T11:26:10Z"}
    first = client.post("/v1/reminders/sync", json={"changes": [change]}, headers=AUTH).json()
    rid = first["reminders"][0]["id"]
    assert rid and first["reminders"][0]["apple_id"] == "apple-1"
    again = client.post("/v1/reminders/sync", json={"changes": [change]}, headers=AUTH).json()
    assert again["reminders"][0]["id"] == rid and len(store.open()) == 1


def test_phone_attaches_apple_id_then_server_stays_quiet(env):
    client, _, store = env()
    rem = store.create("Call mum", datetime.now(timezone.utc) - timedelta(minutes=1))
    assert [r.id for r in store.unsynced_due(datetime.now(timezone.utc))] == [rem.id]
    change = {"id": rem.id, "apple_id": "apple-9", "title": "Call mum", "due_at": iso(rem.due_at),
              "modified_at": iso(datetime.now(timezone.utc))}
    client.post("/v1/reminders/sync", json={"cursor": "1", "changes": [change]}, headers=AUTH)
    assert store.get(rem.id).apple_id == "apple-9"
    assert store.unsynced_due(datetime.now(timezone.utc)) == []  # Apple alerts now, not Discord


def test_reminders_carry_their_list(env):
    client, _, store = env()
    lists = {"lists": ["Reminders", "Groceries"], "default_list": "Reminders"}
    change = {"id": None, "apple_id": "apple-1", "title": "Milk", "list": "Groceries", "modified_at": "2026-10-18T11:26:10Z"}
    body = client.post("/v1/reminders/sync", json={**lists, "changes": [change]}, headers=AUTH).json()
    rid = body["reminders"][0]["id"]
    assert body["reminders"][0]["list"] == "Groceries"
    assert store.lists() == ["Reminders", "Groceries"] and store.default_list() == "Reminders"
    # An app from before lists sends no "list": the reminder stays where it is.
    old = {"id": rid, "apple_id": "apple-1", "title": "Oat milk", "modified_at": "2026-10-18T11:30:00Z"}
    client.post("/v1/reminders/sync", json={"changes": [old]}, headers=AUTH)
    assert store.get(rid).list == "Groceries" and store.get(rid).title == "Oat milk"
    assert store.lists() == ["Reminders", "Groceries"]  # and doesn't wipe the lists


def test_a_reminder_from_before_lists_learns_its_list(env):
    client, _, store = env()
    rem = store.create("Call mum")  # list unknown, and the phone's copy isn't newer
    stale = {"id": rem.id, "apple_id": "apple-2", "title": "Call mum", "list": "Reminders",
             "modified_at": iso(rem.modified_at - timedelta(minutes=1))}
    client.post("/v1/reminders/sync", json={"changes": [stale]}, headers=AUTH)
    assert store.get(rem.id).list == "Reminders"


async def test_agents_use_lists(env):
    _, agent, store = env()
    store.set_lists(["Reminders", "Groceries"], "Reminders")
    tools = agent.registries["aide"]
    out, err = await agent._execute("create_reminder", {"title": "Eggs", "list": "groceries"}, tools)
    assert not err and "· Groceries" in out
    out, err = await agent._execute("create_reminder", {"title": "Call mum"}, tools)
    assert not err and "· Groceries" not in out and "Reminders" not in out.split("\n")[0]
    out, _ = await agent._execute("list_reminders", {"list": "Groceries"}, tools)
    assert out.startswith("Lists: Reminders (default), Groceries") and "Eggs" in out and "Call mum" not in out
    out, _ = await agent._execute("list_reminders", {"list": "Reminders"}, tools)  # the default list has the list-less
    assert "Call mum" in out and "Eggs" not in out
    out, err = await agent._execute("create_reminder", {"title": "x", "list": "Work"}, tools)
    assert err and "The lists are: Reminders, Groceries" in out
    eggs = next(r for r in store.open() if r.title == "Eggs")
    out, err = await agent._execute("update_reminder", {"reminder_id": eggs.id, "list": "Reminders"}, tools)
    assert not err and store.get(eggs.id).list == "Reminders"


def test_newer_edit_wins_and_older_edit_loses(env):
    client, _, store = env()
    rem = store.create("Old title")
    newer = {"id": rem.id, "title": "Phone title", "modified_at": iso(rem.modified_at + timedelta(minutes=1))}
    body = client.post("/v1/reminders/sync", json={"changes": [newer]}, headers=AUTH).json()
    assert body["reminders"][0]["title"] == "Phone title"
    older = {"id": rem.id, "title": "Stale title", "modified_at": iso(rem.modified_at - timedelta(minutes=1))}
    body = client.post("/v1/reminders/sync", json={"changes": [older]}, headers=AUTH).json()
    assert body["reminders"][0]["title"] == "Phone title"  # final form sent back so the phone corrects itself


def test_deletion_beats_a_newer_edit(env):
    client, _, store = env()
    rem = store.create("x")
    store.delete(rem.id)
    edit = {"id": rem.id, "title": "edited later", "modified_at": iso(datetime.now(timezone.utc) + timedelta(hours=1))}
    body = client.post("/v1/reminders/sync", json={"changes": [edit]}, headers=AUTH).json()
    assert body["reminders"][0]["deleted"] is True


def test_cursor_only_returns_newer_changes(env):
    client, _, store = env()
    store.create("a")
    cursor = client.post("/v1/reminders/sync", json={}, headers=AUTH).json()["cursor"]
    store.create("b")
    body = client.post("/v1/reminders/sync", json={"cursor": cursor}, headers=AUTH).json()
    assert [r["title"] for r in body["reminders"]] == ["b"]


def test_bad_cursor_and_naive_time_are_400(env):
    client, _, _ = env()
    assert client.post("/v1/reminders/sync", json={"cursor": "abc"}, headers=AUTH).status_code == 400
    naive = {"id": None, "title": "x", "modified_at": "2026-10-18T11:00:00"}
    r = client.post("/v1/reminders/sync", json={"changes": [naive]}, headers=AUTH)
    assert r.status_code == 400 and "offset" in r.json()["error"]


# -- memory duplicates ---------------------------------------------------------


async def _remember(db, *texts):
    from aide.tools.memory import memory_tools
    remember = next(t for t in memory_tools(db) if t.name == "remember").handler
    return [await remember(t) for t in texts]


async def test_remember_skips_duplicates_and_rewordings():
    db = Database(":memory:")
    out = await _remember(db, "Name is Filippo", "My name is Filippo", "User's name is filippo.", "Vegetarian",
                          "Is vegetarian")
    assert [o.split(":")[0] for o in out] == ["Remembered", "Already saved, nothing added", "Already saved, nothing added",
                                              "Remembered", "Already saved, nothing added"]
    assert [m["text"] for m in db.memories()] == ["Vegetarian", "Name is Filippo"]


async def test_remember_merges_extra_detail_but_not_a_negation():
    db = Database(":memory:")
    out = await _remember(db, "Dentist is Dr Rossi", "Dentist is Dr Rossi in Milan", "Likes cats", "Likes cats not")
    assert out[1].startswith("Already saved; updated")
    assert [m["text"] for m in db.memories()] == ["Likes cats not", "Likes cats", "Dentist is Dr Rossi in Milan"]


async def test_near_duplicate_is_refused_until_the_old_one_is_being_forgotten():
    db = Database(":memory:")
    await _remember(db, "Dentist is Dr Rossi")
    (out,) = await _remember(db, "Dentist is Dr Russo")
    assert out.startswith("Not saved") and "forget" in out
    db.add_pending("main", "forget", {"memory_id": 1}, "Forget 'Dentist is Dr Rossi'", "1")
    (out,) = await _remember(db, "Dentist is Dr Russo")
    assert out.startswith("Remembered")


def test_memory_block_tells_the_model_to_check_first(env):
    _, agent, _ = env()
    agent.db.add_memory("Vegetarian")
    block = agent._system()[-1]["text"]
    assert "Before calling remember, check this list" in block and "[1] Vegetarian" in block


def test_local_due_times_are_stored_as_utc_so_due_checks_work():
    db = Database(":memory:")
    store = ReminderStore(db.conn)
    rem = store.create("x", datetime(2026, 10, 19, 23, 30, tzinfo=ROME))  # 21:30 UTC
    assert db.conn.execute("SELECT due_at FROM reminders").fetchone()[0] == "2026-10-19T21:30:00+00:00"
    assert [r.id for r in store.due_before(datetime(2026, 10, 20, tzinfo=ROME))] == [rem.id]
    assert [r.id for r in store.unsynced_due(datetime(2026, 10, 19, 21, 31, tzinfo=timezone.utc))] == [rem.id]


# -- attachments ---------------------------------------------------------------


def calls(*uses):
    return ("tool_use", [Block(type="tool_use", id=f"t{i}", name=n, input=a) for i, (n, a) in enumerate(uses)])


def test_listing_reminders_attaches_them_and_history_keeps_them_up_to_date(env):
    client, agent, store = env()
    a, b = store.create("Bins", datetime(2026, 10, 20, 9, tzinfo=ROME)), store.create("Call mum")
    client, agent, _ = env([call("list_reminders"), done("Two open reminders.")])
    body = client.post("/v1/chat", json={"text": "what are my reminders?"}, headers=AUTH).json()
    (att,) = body["attachments"]
    assert att["type"] == "reminders" and [r["id"] for r in att["reminders"]] == [a.id, b.id]
    assert set(att["reminders"][0]) == {"id", "title", "notes", "due_at", "completed", "apple_id", "modified_at",
                                        "deleted", "list"}  # the same Reminder object as /v1/reminders/sync
    store.update(a.id, completed=True)  # ticked in the app afterwards
    user, reply = client.get("/v1/history", headers=AUTH).json()["messages"]
    assert user["attachments"] == []
    assert reply["text"] == "Two open reminders." and reply["attachments"][0]["reminders"][0]["completed"] is True


def test_created_and_changed_reminders_merge_into_one_attachment(env):
    client, agent, store = env()
    rem = store.create("Bins")
    client, _, _ = env([calls(("create_reminder", {"title": "Milk"}), ("complete_reminder", {"reminder_id": rem.id})),
                        call("list_reminders"), done("Done.")])
    body = client.post("/v1/chat", json={"text": "add milk, bins are done"}, headers=AUTH).json()
    (att,) = body["attachments"]
    titles = [(r["title"], r["completed"]) for r in att["reminders"]]
    assert sorted(titles) == [("Bins", True), ("Milk", False)]  # Milk listed again later: shown once


def test_no_tools_means_no_attachments(env):
    client, _, _ = env([done("hi")])
    assert client.post("/v1/chat", json={"text": "hello"}, headers=AUTH).json()["attachments"] == []
    assert all(m["attachments"] == [] for m in client.get("/v1/history", headers=AUTH).json()["messages"])


def test_listing_events_attaches_event_objects():
    from aide.tools.calendar import calendar_tools
    db = Database(":memory:")
    ev = CalEvent("e1", "Home", "Dentist", datetime(2026, 10, 20, 15, tzinfo=ROME), datetime(2026, 10, 20, 16, tzinfo=ROME))

    class Cal(FakeCalendar):
        def calendars(self):
            return ["Home"]
    tools = ToolRegistry(calendar_tools(Cal([ev]), ROME))
    agent = Agent(FakeClient([call("list_events", start_date="2026-10-20", end_date="2026-10-20"), done("One.")]),
                  db, tools, model="m", delegate=False, tz=ROME)
    app = create_app(agent, ReminderStore(db.conn), Cal([ev]), ROME, TOKEN)
    body = TestClient(app).post("/v1/chat", json={"text": "tuesday?"}, headers=AUTH).json()
    assert body["attachments"] == [{"type": "events", "events": [{
        "id": "e1", "title": "Dentist", "calendar": "Home", "start": "2026-10-20T15:00:00+02:00",
        "end": "2026-10-20T16:00:00+02:00", "all_day": False, "location": "", "notes": "", "recurring": False}]}]


def test_system_prompt_says_the_app_shows_cards(env):
    _, agent, _ = env()
    assert "as cards" in agent._system()[0]["text"]


def test_a_spoken_message_is_stamped_by_voice(env):
    client, agent, _ = env([done("a"), done("b")])
    requests = []
    create = agent.client.beta.messages.create

    async def spy(**kwargs):
        requests.append(kwargs)
        return await create(**kwargs)
    agent.client.beta.messages.create = spy

    client.post("/v1/chat", json={"text": "typed"}, headers=AUTH)
    client.post("/v1/chat", json={"text": "spoken", "voice": True}, headers=AUTH)
    typed, spoken = (str(r["messages"][-1]["content"]) for r in requests)
    assert "by voice" not in typed and re.search(r"\d\d:\d\d, by voice\] spoken", spoken)
