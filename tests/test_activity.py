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
    activity.record(agent.db.conn, "coach", "watch", "Recovery check", "Low HRV.")
    activity.record(agent.db.conn, "coach", "routine", "Weekly recap", "Good week.")
    activity.record(agent.db.conn, "aide", "digest", "Morning digest")
    assert [i["title"] for i in feed(client, kind="routine,watch")["items"]] == ["Weekly recap", "Recovery check"]
    assert [i["title"] for i in feed(client, kind="watch", agent="coach")["items"]] == ["Recovery check"]
    assert client.get("/v1/activity", params={"agent": "butler"}, headers=AUTH).status_code == 400


def test_old_lines_are_dropped_and_long_ones_cut(env):
    _, agent, _ = env()
    conn = agent.db.conn
    conn.execute("INSERT INTO activity (ts, agent, kind, title) VALUES ('2020-01-01T00:00:00+00:00', 'aide', 'x', 'old')")
    activity.record(conn, "aide", "action", "new", "\n\n" + "a" * 1000 + "\nsecond line")
    rows = conn.execute("SELECT title, detail FROM activity").fetchall()
    assert [r["title"] for r in rows] == ["new"] and len(rows[0]["detail"]) == activity.DETAIL



def line(i, minute, agent, kind, title, detail=None, chat=None, day=2):
    return {"id": i, "ts": f"2026-11-0{day}T{minute // 60:02d}:{minute % 60:02d}:00+00:00", "agent": agent,
            "kind": kind, "title": title, "detail": detail, "conversation_id": chat}


def fold(*lines):
    return activity.grouped(sorted(lines, key=lambda x: x["id"], reverse=True), ROME)


def test_a_run_of_the_same_thing_in_one_chat_is_one_row():
    rows = fold(line(1, 600, "coach", "action", "Logged a meal", "eggs", "c1"),
                line(2, 610, "coach", "action", "Logged a meal", "toast", "c1"),
                line(3, 640, "coach", "action", "Changed a meal", "toast, 2 slices", "c1"),
                line(4, 800, "coach", "action", "Logged a meal", "pasta", "c1"))  # 2 h later: its own row
    assert [r["id"] for r in rows] == [4, 3]
    run = rows[1]
    assert run["count"] == 3 and run["agents"] == ["coach"] and run["title"] == "Changed a meal and Logged a meal"
    assert [c["id"] for c in run["children"]] == [3, 2, 1] and run["detail"] == "toast, 2 slices"
    assert "count" not in rows[0] and "children" not in rows[0]


def test_another_agent_or_chat_breaks_a_run():
    rows = fold(line(1, 600, "coach", "action", "Logged a meal", chat="c1"),
                line(2, 601, "coach", "action", "Changed a meal", chat="c2"),
                line(3, 602, "aide", "action", "Changed a meal", chat="c2"))
    assert [r.get("count", 1) for r in rows] == [1, 1, 1]


def test_meals_scanned_in_the_app_join_the_ones_logged_in_chat():
    rows = fold(line(1, 600, "coach", "action", "Logged HiPro Mango, 300 g (scanned in the app)"),
                line(2, 601, "coach", "action", "Logged a meal", "eggs", "c1"),
                line(3, 602, "coach", "action", "Logged a meal", "Penne, 300 g, scanned in the app"))
    [run] = rows
    assert run["count"] == 3 and run["title"] == "Logged a meal"


def test_an_errand_is_one_row_with_its_last_state():
    rows = fold(line(1, 600, "aide", "ask", "Asked Professor", chat="c1"),
                line(2, 601, "aide", "action", "Started an errand", "Errand #17 started", "c1"),
                line(3, 602, "aide", "errand", "Grade check", "Needs you: log in", "c1"),
                line(4, 602, "aide", "message", "Uni chat", "I need you on unito.it", "c1"),
                line(5, 610, "aide", "errand", "Grade check", "Cancelled", "c1"),
                line(6, 611, "aide", "ask", "Asked Professor", chat="c1"))
    assert [r["id"] for r in rows] == [6, 5, 1]
    errand = rows[1]
    assert errand["kind"] == "errand" and errand["title"] == "Grade check" and errand["detail"] == "Cancelled"
    assert errand["count"] == 4 and [c["id"] for c in errand["children"]] == [5, 4, 3, 2]


def test_a_plan_is_one_row_whoever_proposed():
    rows = fold(line(1, 600, "secretary", "objectives", "Proposed 1 objective for the month"),
                line(2, 600, "coach", "objectives", "Proposed 2 objectives for the month"),
                line(3, 601, "professor", "objectives", "Proposed 3 objectives for the week"),
                line(4, 601, "professor", "objectives", "Proposed 1 objective for the day"))
    [plan] = rows
    assert plan["kind"] == "objectives" and plan["count"] == 4 and plan["agents"] == ["secretary", "coach", "professor"]
    assert plan["title"] == "Proposed 7 objectives for today, the week and the month"


def test_a_days_quiet_checks_are_one_row_where_the_newest_was():
    rows = fold(line(1, 480, "coach", "quiet", "Recovery check", "Checked: nothing needed you.", "w1"),
                line(2, 580, "coach", "action", "Logged a meal", chat="c1"),
                line(3, 600, "secretary", "quiet", "Mail that needs you", "Checked: nothing needed you.", "w2"),
                line(4, 605, "coach", "action", "Logged a meal", chat="c1"),
                line(0, 1050, "coach", "quiet", "Recovery check", day=1))
    assert [r["id"] for r in rows] == [4, 3, 0]
    quiet = rows[1]
    assert quiet["title"] == "2 quiet checks" and quiet["agents"] == ["coach", "secretary"]
    assert quiet["detail"] == "Nothing needed you: Mail that needs you, Recovery check."
    assert rows[0]["count"] == 2  # the meals around a quiet check still make a run
    assert "count" not in rows[2]  # another day's lone check is as it was


def test_the_grouped_feed_pages_on_the_lines(env):
    client, agent, _ = env()
    for n in range(4):
        activity.record(agent.db.conn, "coach", "action", "Logged a meal", f"meal {n}", "c1")
    activity.record(agent.db.conn, "secretary", "quiet", "Tomorrow", "Checked: nothing needed you.", "w1")
    page = feed(client, grouped="true", limit=3)
    assert page["next"]  # the 3 newest lines: the check and two meals
    quiet, meals = page["items"]
    assert quiet["title"] == "Tomorrow" and "children" not in quiet  # a lone check is as it was
    assert meals["children"][0]["ts"].endswith(("+01:00", "+02:00"))
    assert meals["count"] == 2 and [c["detail"] for c in meals["children"]] == ["meal 3", "meal 2"]
    rest = feed(client, grouped="true", before=page["next"])
    assert rest["items"][0]["count"] == 2 and rest["next"] is None
    assert len(feed(client)["items"]) == 5  # without grouped, the lines as they were
