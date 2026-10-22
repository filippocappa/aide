import asyncio

import pytest
from fastapi.testclient import TestClient

from aide import activity
from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.reminders import reminder_tools
from test_agents import AUTH, OTHERS, ROME, FakeClient, calls, done


@pytest.fixture
def env():
    db = Database(":memory:")
    store = ReminderStore(db.conn)

    def make(responses=(), delegate=False):
        agent = Agent(FakeClient(responses), db, ToolRegistry([*reminder_tools(store, ROME), *OTHERS]),
                      model="m", tz=ROME, delegate=delegate)
        return TestClient(create_app(agent, store, None, ROME, "t")), agent, store
    yield make
    db.close()


def feed(client, **params):
    return client.get("/v1/activity", params=params, headers=AUTH).json()


def test_a_change_an_agent_makes_is_in_the_feed(env):
    client, *_ = env([calls(("create_reminder", {"title": "Bins"})), done("Added.")])
    cid = client.post("/v1/conversations", json={}, headers=AUTH).json()["id"]
    client.post("/v1/chat", json={"text": "remind me of the bins", "conversation_id": cid}, headers=AUTH)
    [item] = feed(client)["items"]
    assert item["agent"] == "aide" and item["kind"] == "action" and item["title"] == "Added a reminder"
    assert "Bins" in item["detail"] and item["conversation_id"] == cid and item["ts"].endswith(("+01:00", "+02:00"))


def test_reads_are_not_in_the_feed(env):
    client, *_ = env([calls(("list_reminders", {})), done("None.")])
    client.post("/v1/chat", json={"text": "what's due?"}, headers=AUTH)
    assert feed(client)["items"] == []


def test_queued_actions_are_approvals_and_can_be_confirmed_one_at_a_time(env):
    client, agent, store = env()
    bins, milk = store.create("Bins"), store.create("Milk")
    client, *_ = env([calls(("delete_reminder", {"reminder_id": bins.id}), ("delete_reminder", {"reminder_id": milk.id})),
                      done("Queued both.")])
    client.post("/v1/chat", json={"text": "delete bins and milk"}, headers=AUTH)
    waiting = client.get("/v1/approvals", headers=AUTH).json()
    assert waiting["waiting"] == 2 and [a["summary"] for a in waiting["actions"]] == \
        ["Delete reminder 'Bins'", "Delete reminder 'Milk'"]
    first = waiting["actions"][0]
    assert first["agent"] == "aide" and first["conversation_id"] == "main" and first["expires_at"] > first["created_at"]

    r = client.post("/v1/confirm", json={"ids": [first["id"]]}, headers=AUTH).json()
    assert r["result"] == "✓ Deleted reminder: Bins" and [p["summary"] for p in r["pending"]] == ["Delete reminder 'Milk'"]
    r = client.post("/v1/cancel", json={"ids": [waiting["actions"][1]["id"]]}, headers=AUTH).json()
    assert r["pending"] == [] and not store.get(milk.id).deleted
    assert client.get("/v1/approvals", headers=AUTH).json()["waiting"] == 0
    kinds = [(i["kind"], i["title"]) for i in feed(client)["items"]]
    assert kinds == [("cancelled", "Delete reminder 'Milk'"), ("confirmed", "Delete reminder 'Bins'"),
                     ("queued", "Delete reminder 'Milk'"), ("queued", "Delete reminder 'Bins'")]


def test_confirm_without_ids_still_runs_everything(env):
    client, agent, store = env()
    bins = store.create("Bins")
    client, *_ = env([calls(("delete_reminder", {"reminder_id": bins.id})), done("Queued.")])
    client.post("/v1/chat", json={"text": "delete bins"}, headers=AUTH)
    assert client.post("/v1/confirm", json={}, headers=AUTH).json()["pending"] == []
    assert client.post("/v1/confirm", headers=AUTH).json()["result"] == "Nothing is waiting for confirmation."


def test_asks_and_the_specialists_changes_are_theirs(env):
    client, *_ = env([calls(("ask_agent", {"agent": "secretary", "request": "Add bins for Monday"})),
                      calls(("create_reminder", {"title": "Bins"})), done("Added bins."), done("Secretary added it.")],
                     delegate=True)
    client.post("/v1/chat", json={"text": "bins on monday"}, headers=AUTH)
    items = feed(client)["items"]
    assert [(i["agent"], i["kind"], i["title"]) for i in items] == [
        ("secretary", "action", "Added a reminder"), ("aide", "ask", "Asked Secretary")]
    assert items[1]["detail"] == "Add bins for Monday"
    assert [i["kind"] for i in feed(client, agent="secretary")["items"]] == ["action"]


def test_routine_and_watch_runs_are_in_the_feed(env):
    client, *_ = env([done("NOTHING"), done("Marco asked about Friday.\nDraft: …"), done("Good week.")])
    watch = client.post("/v1/routines", json={"agent": "secretary", "title": "Mail", "prompt": "Check.",
                                               "time": "11:00", "watch": True}, headers=AUTH).json()
    recap = client.post("/v1/routines", json={"agent": "coach", "title": "Recap", "prompt": "Recap.",
                                               "time": "18:00", "days": [7]}, headers=AUTH).json()
    for r in (watch, watch, recap):
        client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH)
    items = feed(client)["items"]
    assert [(i["agent"], i["kind"], i["title"], i["detail"]) for i in items] == [
        ("coach", "routine", "Recap", "Good week."),
        ("secretary", "watch", "Mail", "Marco asked about Friday."),
        ("secretary", "quiet", "Mail", "Checked: nothing needed you.")]
    assert items[0]["conversation_id"] == recap["conversation_id"]


def test_upcoming_routines_are_the_next_five_enabled(env):
    client, *_ = env()
    for t in ("09:00", "10:00", "11:00", "12:00", "13:00", "14:00"):
        client.post("/v1/routines", json={"agent": "coach", "title": t, "prompt": "p", "time": t}, headers=AUTH)
    client.post("/v1/routines", json={"agent": "coach", "title": "off", "prompt": "p", "time": "08:00",
                                      "enabled": False}, headers=AUTH)
    upcoming = client.get("/v1/approvals", headers=AUTH).json()["upcoming"]
    assert len(upcoming) == 5 and "off" not in [r["title"] for r in upcoming]
    assert [r["next_run"] for r in upcoming] == sorted(r["next_run"] for r in upcoming)


def test_posts_are_messages_from_the_chats_agent(env):
    client, agent, _ = env()
    cid = client.post("/v1/conversations", json={"agent": "professor"}, headers=AUTH).json()["id"]
    asyncio.run(agent.post(cid, "[Lecture notes ready]", "Your notes on IS-LM are ready."))
    [item] = feed(client)["items"]
    assert (item["agent"], item["kind"], item["detail"], item["conversation_id"]) == \
        ("professor", "message", "Your notes on IS-LM are ready.", cid)


def test_the_feed_pages_and_filters(env):
    client, agent, _ = env()
    for n in range(5):
        activity.record(agent.db.conn, "coach" if n % 2 else "secretary", "action", f"Thing {n}")
    page = feed(client, limit=2)
    assert [i["title"] for i in page["items"]] == ["Thing 4", "Thing 3"] and page["next"]
    rest = feed(client, limit=10, before=page["next"])
    assert [i["title"] for i in rest["items"]] == ["Thing 2", "Thing 1", "Thing 0"] and rest["next"] is None
    assert [i["title"] for i in feed(client, agent="coach")["items"]] == ["Thing 3", "Thing 1"]
    assert client.get("/v1/activity", params={"agent": "butler"}, headers=AUTH).status_code == 400


def test_old_lines_are_dropped_and_long_ones_cut(env):
    _, agent, _ = env()
    conn = agent.db.conn
    conn.execute("INSERT INTO activity (ts, agent, kind, title) VALUES ('2020-01-01T00:00:00+00:00', 'aide', 'x', 'old')")
    activity.record(conn, "aide", "action", "new", "\n\n" + "a" * 1000 + "\nsecond line")
    rows = conn.execute("SELECT title, detail FROM activity").fetchall()
    assert [r["title"] for r in rows] == ["new"] and len(rows[0]["detail"]) == activity.DETAIL

