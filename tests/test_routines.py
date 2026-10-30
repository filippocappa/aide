import asyncio
import sqlite3
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.agents import AGENTS
from aide.channels.api import create_app
from aide.db import Database, utcnow
from aide.reminders import ReminderStore
from aide.routines import deliver
from aide.tools import ToolRegistry
from aide.tools.reminders import reminder_tools
from test_agents import AUTH, OTHERS, ROME, FakeClient, calls, done


class FakePush:
    def __init__(self, works=True):
        self.works = works
        self.sent = []
        self.routines = []  # the routine each push named

    async def send_message(self, conversation_id, title, body, routine=None):
        self.sent.append((conversation_id, title, body))
        self.routines.append(routine)
        return self.works


@pytest.fixture
def env():
    db = Database(":memory:")
    store = ReminderStore(db.conn)

    def make(responses=(), push_works=True):
        agent = Agent(FakeClient(responses), db, ToolRegistry([*reminder_tools(store, ROME), *OTHERS]),
                      model="m", tz=ROME, delegate=False)
        push = FakePush(push_works)
        client = TestClient(create_app(agent, store, None, ROME, "t", push=push))
        return client, agent, store, push
    yield make
    db.close()


RECAP = {"agent": "coach", "title": "Weekly recap", "prompt": "Recap my week.", "time": "18:00", "days": [7]}


def conversations(client):
    return {c["id"]: c for c in client.get("/v1/conversations", headers=AUTH).json()["conversations"]}


# -- the API ---------------------------------------------------------------------


def test_creating_a_routine_creates_its_chat(env):
    client, *_ = env()
    r = client.post("/v1/routines", json=RECAP, headers=AUTH).json()
    assert {k: r[k] for k in RECAP} == RECAP and r["enabled"] is True and r["last_run"] is None
    assert datetime.fromisoformat(r["next_run"]).isoweekday() == 7 and r["next_run"][11:16] == "18:00"
    chat = conversations(client)[r["conversation_id"]]
    assert chat["agent"] == "coach" and chat["title"] == "Weekly recap" and chat["routine"] == r["id"]
    assert conversations(client)["main"]["routine"] is None
    assert client.post("/v1/conversations", json={}, headers=AUTH).json()["routine"] is None
    every_day = client.post("/v1/routines", json={**RECAP, "days": []}, headers=AUTH).json()
    assert every_day["days"] == []


@pytest.mark.parametrize("bad", [{"agent": "butler"}, {"time": "25:00"}, {"time": "6pm"}, {"prompt": "  "},
                                 {"days": [0]}, {"days": [8]}])
def test_bad_routines_are_400(env, bad):
    client, *_ = env()
    r = client.post("/v1/routines", json={**RECAP, **bad}, headers=AUTH)
    assert r.status_code == 400 and r.json()["error"]
    assert client.get("/v1/routines", headers=AUTH).json()["routines"] == []


def test_list_is_by_agent_then_time_and_filters(env):
    client, *_ = env()
    for agent, time in (("coach", "18:00"), ("secretary", "09:00"), ("aide", "20:00"), ("coach", "07:30")):
        client.post("/v1/routines", json={**RECAP, "agent": agent, "time": time}, headers=AUTH)
    listed = client.get("/v1/routines", headers=AUTH).json()["routines"]
    assert [(r["agent"], r["time"]) for r in listed] == [("aide", "20:00"), ("secretary", "09:00"),
                                                       ("coach", "07:30"), ("coach", "18:00")]
    assert [r["time"] for r in client.get("/v1/routines?agent=coach", headers=AUTH).json()["routines"]] == [
        "07:30", "18:00"]
    assert client.get("/v1/routines?agent=butler", headers=AUTH).status_code == 400


def test_patch_and_delete(env):
    client, *_ = env()
    r = client.post("/v1/routines", json=RECAP, headers=AUTH).json()
    off = client.patch(f"/v1/routines/{r['id']}", json={"enabled": False, "title": "Sunday recap"},
                       headers=AUTH).json()
    assert off["enabled"] is False and off["next_run"] is None and off["prompt"] == "Recap my week."
    assert conversations(client)[r["conversation_id"]]["title"] == "Sunday recap"  # the chat follows the name
    on = client.patch(f"/v1/routines/{r['id']}", json={"enabled": True, "time": "07:05", "days": [3, 1, 1]},
                      headers=AUTH).json()
    assert on["time"] == "07:05" and on["days"] == [1, 3] and on["next_run"][11:16] == "07:05"
    assert client.patch(f"/v1/routines/{r['id']}", json={"time": "7"}, headers=AUTH).status_code == 400
    assert client.patch("/v1/routines/99", json={}, headers=AUTH).status_code == 404

    assert client.delete(f"/v1/routines/{r['id']}", headers=AUTH).json() == {"ok": True}
    assert client.get("/v1/routines", headers=AUTH).json()["routines"] == []
    assert conversations(client)[r["conversation_id"]]["routine"] is None  # the chat stays
    assert client.delete(f"/v1/routines/{r['id']}", headers=AUTH).status_code == 404


def test_deleting_the_chat_deletes_the_routine(env):
    client, *_ = env()
    r = client.post("/v1/routines", json=RECAP, headers=AUTH).json()
    client.delete(f"/v1/conversations/{r['conversation_id']}", headers=AUTH)
    assert client.get("/v1/routines", headers=AUTH).json()["routines"] == []


# -- when it runs ----------------------------------------------------------------


def test_next_run_follows_days_and_local_time(env):
    _, agent, *_ = env()
    store = agent.routines
    r = store.create(**RECAP)
    monday = datetime(2026, 10, 19, 12, 0, tzinfo=ROME)
    assert store.next_run(r, monday) == datetime(2026, 10, 25, 18, 0, tzinfo=ROME)  # after the clocks go back
    sunday_late = datetime(2026, 10, 25, 18, 0, tzinfo=ROME)
    assert store.next_run(r, sunday_late) == datetime(2026, 11, 1, 18, 0, tzinfo=ROME)
    daily = store.create(**{**RECAP, "days": [], "time": "07:00"})
    assert store.next_run(daily, monday) == datetime(2026, 10, 20, 7, 0, tzinfo=ROME)
    weekdays = store.create(**{**RECAP, "days": [1, 2, 3, 4, 5], "time": "09:00"})
    friday = datetime(2026, 10, 23, 10, 0, tzinfo=ROME)
    assert store.next_run(weekdays, friday) == datetime(2026, 10, 26, 9, 0, tzinfo=ROME)


def test_due_runs_once_and_catches_up_less_than_two_hours_late(env):
    _, agent, *_ = env()
    store = agent.routines
    r = store.create(**{**RECAP, "days": []})
    slot = datetime(2026, 10, 20, 18, 0, tzinfo=ROME)
    store.conn.execute("UPDATE routines SET since = ? WHERE id = ?", ((slot - timedelta(days=1)).isoformat(), r["id"]))
    assert store.due(slot - timedelta(minutes=1)) == []  # yesterday's slot came before it was set up
    assert [d["id"] for d in store.due(slot)] == [r["id"]]
    assert [d["id"] for d in store.due(slot + timedelta(hours=1, minutes=59))] == [r["id"]]  # back from an outage
    assert store.due(slot + timedelta(hours=2)) == []  # too late: skipped
    store.mark_run(r["id"], slot + timedelta(seconds=20))
    assert store.due(slot + timedelta(minutes=1)) == []  # ran already
    store.update(r["id"], enabled=False)
    assert store.due(slot + timedelta(days=1)) == []


def test_a_new_or_rescheduled_routine_does_not_run_for_a_slot_already_past(env):
    _, agent, *_ = env()
    store = agent.routines
    now = utcnow()
    r = store.create(**{**RECAP, "days": [], "time": f"{(now - timedelta(minutes=5)).astimezone(ROME):%H:%M}"})
    assert store.due(now) == []
    store.conn.execute("UPDATE routines SET since = ? WHERE id = ?", ((now - timedelta(hours=1)).isoformat(), r["id"]))
    assert store.due(now)  # had it existed earlier, it would be owed
    store.update(r["id"], days=[])  # touching the schedule starts it afresh
    assert store.due(now) == []


# -- a run -----------------------------------------------------------------------


def test_a_run_posts_in_the_chat_and_pushes(env):
    client, agent, _, push = env([done("Good week: 4 of 5 sessions.\nMore sleep next week."),
                                       done("Better than last week.")])
    r = client.post("/v1/routines", json=RECAP, headers=AUTH).json()
    body = client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH).json()
    assert body["conversation_id"] == r["conversation_id"] and body["routine"]["last_run"]

    request = agent.client.requests[0]
    assert request["system"][0]["text"] == AGENTS["coach"].prompt and "health" in {t["name"] for t in request["tools"]}
    assert "Recap my week." in str(request["messages"])
    history = client.get("/v1/history", params={"conversation_id": r["conversation_id"]}, headers=AUTH).json()
    assert [(m["role"], m.get("routine")) for m in history["messages"]] == [
        ("assistant", {"id": r["id"], "title": "Weekly recap"})]  # the prompt stays hidden
    assert push.sent == [(r["conversation_id"], "Coach · Weekly recap", "Good week: 4 of 5 sessions.")]
    assert push.routines == [r["id"]]  # the app opens Today on the note
    assert conversations(client)[r["conversation_id"]]["preview"].startswith("Good week")

    client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH)  # the next run sees the chat so far
    assert "Good week: 4 of 5" in str(agent.client.requests[1]["messages"])
    # A reply in the routine chat is an ordinary message, without `routine`.
    agent.client.responses = [done("Sure.")]
    client.post("/v1/chat", json={"text": "thanks", "conversation_id": r["conversation_id"]}, headers=AUTH)
    last = client.get("/v1/history", params={"conversation_id": r["conversation_id"]}, headers=AUTH).json()
    assert [m.get("routine", {}).get("id") for m in last["messages"]] == [r["id"], r["id"], None, None]


class FakePlan:
    """The engine with background work on the Claude plan: run() makes the scripted calls through Aide's own tools,
    then answers (or fails)."""

    def __init__(self, script=(), reply="From the plan.", fail: Exception | None = None):
        self.script, self.reply, self.fail = list(script), reply, fail
        self.runs: list[dict] = []
        self.results: list = []

    def plan_for_background(self) -> bool:
        return True

    async def run(self, system, prompt, tools, call, fast=True, max_turns=12, effort=None):
        self.runs.append({"system": system, "prompt": prompt, "tools": [t.name for t in tools], "fast": fast})
        for name, args in self.script:
            self.results.append(await call(name, args))
        if self.fail:
            raise self.fail
        return self.reply


def test_a_routine_runs_on_the_claude_plan_when_chosen(env):
    client, agent, store, push = env()
    rem = store.create("Old errand", None)
    agent.engine = FakePlan([("list_reminders", {}), ("delete_reminder", {"reminder_id": rem.id})],
                            "Cleared one old errand.")
    r = client.post("/v1/routines", json={**RECAP, "agent": "secretary", "title": "Tidy up"}, headers=AUTH).json()
    client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH)
    run = agent.engine.runs[0]
    assert run["system"].startswith(AGENTS["secretary"].prompt) and "delete_reminder" in run["tools"]
    assert "Recap my week." in run["prompt"] and agent.client.requests == []
    assert "Old errand" in agent.engine.results[0][0]
    assert push.sent[0][1:] == ("Secretary · Tidy up", "Cleared one old errand. (1 action waiting for your OK.)")
    assert not store.get(rem.id).deleted  # queued in Aide's code, as on OpenRouter
    stored = agent.db.history(agent.db.app_conversation(r["conversation_id"])["id"])
    assert [m["role"] for m in stored] == ["user", "assistant"] and "tool_use" not in str(stored)

    agent.engine.script = []
    client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH)  # the next run reads the chat so far
    assert "[Earlier in this chat" in agent.engine.runs[1]["prompt"]
    assert "You: Cleared one old errand." in agent.engine.runs[1]["prompt"]


def test_a_watch_on_the_plan_still_cannot_change_anything(env):
    client, agent, store, push = env()
    rem = store.create("Old errand", None)
    agent.engine = FakePlan([("delete_reminder", {"reminder_id": rem.id})], "One old errand you could drop.")
    r = client.post("/v1/routines", json=WATCH, headers=AUTH).json()
    client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH)
    out, err = agent.engine.results[0]
    assert err and "Not during a check" in out
    assert agent.db.pending_actions("main", timedelta(minutes=30)) == []


async def test_when_the_plan_fails_before_any_tool_the_routine_runs_on_openrouter(env):
    _, agent, _, push = env([done("From OpenRouter.")])
    agent.engine = FakePlan(fail=RuntimeError("Claude Code: no login"))
    r = agent.routines.create(**RECAP)
    assert await deliver(agent, "main", r, push) == "From OpenRouter."
    agent.engine = FakePlan([("list_reminders", {})], fail=RuntimeError("Claude Code: gone"))
    with pytest.raises(RuntimeError):  # a tool ran already: not run twice
        await deliver(agent, "main", r, push)


def test_a_disabled_routine_still_runs_on_request(env):
    client, *_ = env([done("Done.")])
    r = client.post("/v1/routines", json={**RECAP, "enabled": False}, headers=AUTH).json()
    assert client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH).status_code == 200
    assert client.post("/v1/routines/99/run", json={}, headers=AUTH).status_code == 404


def test_queued_actions_wait_and_the_push_says_so(env):
    client, agent, store, push = env()
    rem = store.create("Old errand", None)
    agent.client.responses = [calls(("delete_reminder", {"reminder_id": rem.id})), done("Cleared one old errand.")]
    r = client.post("/v1/routines", json={**RECAP, "agent": "secretary", "title": "Tidy up"}, headers=AUTH).json()
    client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH)
    assert push.sent[0][1:] == ("Secretary · Tidy up", "Cleared one old errand. (1 action waiting for your OK.)")
    assert not store.get(rem.id).deleted
    client.post("/v1/confirm", json={}, headers=AUTH)
    assert store.get(rem.id).deleted


async def test_a_routine_whose_push_fails_stays_in_its_chat(env):
    _, agent, _, push = env([done("Recap.\nDetails.")], push_works=False)
    r = agent.routines.create(**RECAP)
    assert await deliver(agent, "main", r, push) == "Recap.\nDetails."
    assert len(push.sent) == 1 and agent.routines.get(r["id"])["last_run"]


# -- by chat ---------------------------------------------------------------------


def test_an_agent_makes_its_own_routines_by_chat(env):
    client, agent, *_ = env()
    cid = client.post("/v1/conversations", json={"agent": "coach"}, headers=AUTH).json()["id"]
    agent.client.responses = [
        calls(("create_routine", {"title": "Weekly recap", "prompt": "Recap my week.", "time": "18:00", "days": [7]})),
        done("Set: Sundays at 18:00."), done("Recap"),
    ]
    client.post("/v1/chat", json={"text": "every Sunday at 18 recap my week", "conversation_id": cid}, headers=AUTH)
    [r] = client.get("/v1/routines", headers=AUTH).json()["routines"]
    assert r["agent"] == "coach" and r["days"] == [7] and r["conversation_id"] != cid
    create = next(t for t in agent.registries["coach"] if t.name == "create_routine")
    assert "agent" not in create.input_schema["properties"]
    result = agent.client.requests[1]["messages"][-1]["content"][0]
    assert "Weekly recap" in result["content"] and "Sun at 18:00" in result["content"]


async def test_aide_manages_anyones_routines_the_others_only_their_own(env):
    _, agent, *_ = env()
    tools = {a: {t.name: t for t in agent.registries[a]} for a in ("aide", "coach")}
    out = await tools["aide"]["create_routine"].handler(title="Mail sweep", prompt="Sweep.", time="09:00",
                                                      days=[1, 2, 3, 4, 5], agent="secretary")
    assert "Secretary · Mail sweep · Mon–Fri at 09:00" in out
    mine = agent.routines.create(**RECAP)
    assert "Mail sweep" in await tools["aide"]["list_routines"].handler()
    listed = await tools["coach"]["list_routines"].handler()
    assert "Weekly recap" in listed and "Mail sweep" not in listed
    sweep = agent.routines.all("secretary")[0]["id"]
    with pytest.raises(KeyError):
        await tools["coach"]["update_routine"].handler(routine_id=sweep, enabled=False)
    with pytest.raises(KeyError):
        await tools["coach"]["delete_routine"].describe(routine_id=sweep)
    out = await tools["coach"]["update_routine"].handler(routine_id=mine["id"], time="19:30")
    assert "at 19:30" in out
    await tools["aide"]["update_routine"].handler(routine_id=sweep, enabled=False)
    assert "off" in await tools["aide"]["list_routines"].handler()


def test_deleting_by_chat_is_queued(env):
    client, agent, *_ = env()
    r = agent.routines.create(**RECAP)
    agent.client.responses = [calls(("delete_routine", {"routine_id": r["id"]})), done("Queued.")]
    body = client.post("/v1/chat", json={"text": "drop the weekly recap"}, headers=AUTH).json()
    assert "Delete the routine 'Weekly recap' (Coach)" in body["pending"][0]["summary"]
    assert agent.routines.get(r["id"])
    client.post("/v1/confirm", json={}, headers=AUTH)
    assert agent.routines.get(r["id"]) is None and agent.db.app_conversation(r["public_id"])  # the chat stays


def test_prompts_explain_routines(env):
    _, agent, *_ = env()
    assert all("[Scheduled routine" in agent._system(a)[0]["text"] for a in AGENTS)
    assert "for any of the specialists" in agent._system("aide")[0]["text"]
    assert "for any of the specialists" not in agent._system("coach")[0]["text"]


# -- watches ---------------------------------------------------------------------

WATCH = {"agent": "secretary", "title": "Mail that needs you", "prompt": "Check my mail.", "time": "11:00",
         "days": [1, 2, 3, 4, 5], "watch": True}


def test_a_watch_that_finds_nothing_posts_and_sends_nothing(env):
    client, agent, _, push = env([done("NOTHING.")])
    r = client.post("/v1/routines", json=WATCH, headers=AUTH).json()
    assert r["watch"] is True
    body = client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH).json()
    assert body["spoke"] is False and body["routine"]["last_run"]
    assert "a watch" in str(agent.client.requests[0]["messages"])
    history = client.get("/v1/history", params={"conversation_id": r["conversation_id"]}, headers=AUTH).json()
    assert history["messages"] == [] and agent.db.history(agent.db.app_conversation(r["conversation_id"])["id"]) == []
    assert push.sent == []


def test_a_watch_that_finds_something_posts_and_pushes(env):
    client, agent, _, push = env([done("Marco asked about Friday.\nDraft: Friday works, see you at 10.")])
    r = client.post("/v1/routines", json=WATCH, headers=AUTH).json()
    body = client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH).json()
    assert body["spoke"] is True
    history = client.get("/v1/history", params={"conversation_id": r["conversation_id"]}, headers=AUTH).json()
    assert [m["text"][:5] for m in history["messages"]] == ["Marco"]  # the check's prompt stays hidden
    assert push.sent == [(r["conversation_id"], "Secretary · Mail that needs you", "Marco asked about Friday.")]


def test_nothing_can_be_changed_during_a_watch(env):
    client, agent, store, push = env()
    rem = store.create("Old errand", None)
    agent.client.responses = [
        calls(("delete_reminder", {"reminder_id": rem.id}), ("create_reminder", {"title": "New one"}),
              ("list_reminders", {})),
        done("One old errand you could drop."),
    ]
    r = client.post("/v1/routines", json=WATCH, headers=AUTH).json()
    client.post(f"/v1/routines/{r['id']}/run", json={}, headers=AUTH)
    results = agent.client.requests[1]["messages"][-1]["content"]
    assert [x["is_error"] for x in results] == [True, True, False]
    assert "Not during a check" in results[0]["content"]
    assert agent.db.pending_actions("main", timedelta(minutes=30)) == []
    assert [x.title for x in store.open()] == ["Old errand"]
    assert push.sent[0][2] == "One old errand you could drop."  # no "waiting for your OK"
    # An ordinary chat turn afterwards can change things again.
    agent.client.responses = [calls(("create_reminder", {"title": "Call Marco"})), done("Added.")]
    client.post("/v1/chat", json={"text": "remind me to call Marco"}, headers=AUTH)
    assert "Call Marco" in [x.title for x in store.open()]


def test_watches_stop_after_three_notes_a_day(env):
    client, agent, *_ = env()
    watches = [agent.routines.create(**{**WATCH, "title": f"Watch {i}", "days": []}) for i in range(4)]
    agent.client.responses = [done(f"Note {i}.") for i in range(3)]
    now = utcnow()
    for w in watches[:3]:
        agent.db.conn.execute("UPDATE routines SET since = ? WHERE id = ?",
                              ((now - timedelta(days=2)).isoformat(), w["id"]))
    assert agent.routines.watch_notes_today(now) == 0
    for w in watches[:3]:
        client.post(f"/v1/routines/{w['id']}/run", json={}, headers=AUTH)
    assert agent.routines.watch_notes_today(now) == 3
    agent.routines.create(**RECAP)  # an ordinary routine's posts don't count
    assert agent.routines.watch_notes_today(now) == 3


async def test_the_scheduler_skips_watches_over_the_cap(env, monkeypatch):
    import aide.routines as routines
    _, agent, _, push = env([done("Note.")])
    w = agent.routines.create(**{**WATCH, "days": []})
    monkeypatch.setattr(routines.RoutineStore, "watch_notes_today", lambda self, now=None: routines.WATCH_CAP)
    monkeypatch.setattr(routines.RoutineStore, "due", lambda self, now=None: [self.get(w["id"])])
    monkeypatch.setattr(routines, "TICK", 0)
    calls_before = len(agent.client.requests)
    task = asyncio.create_task(routines.routine_schedule(agent, "main", push))
    await asyncio.sleep(0.05)
    task.cancel()
    assert len(agent.client.requests) == calls_before and push.sent == []
    assert agent.routines.get(w["id"])["last_run"]


def test_the_starting_watches_are_set_up_once(env):
    client, agent, *_ = env()
    added = agent.routines.add_starting_watches()
    assert [(r["agent"], r["title"], r["watch"]) for r in added] == [
        ("secretary", "Mail that needs you", True), ("secretary", "Tomorrow", True),
        ("coach", "Recovery check", True), ("coach", "Habits tonight", True), ("coach", "Weigh-in", True)]
    client.delete(f"/v1/routines/{added[0]['id']}", headers=AUTH)
    assert agent.routines.add_starting_watches() == []
    assert len(client.get("/v1/routines", headers=AUTH).json()["routines"]) == 4
    ideas = {a["id"]: a["routine_ideas"] for a in client.get("/v1/agents", headers=AUTH).json()["agents"]}
    assert [i["title"] for i in ideas["secretary"] if i["watch"]] == ["Mail that needs you", "Tomorrow"]
    assert not any(i["watch"] for i in ideas["finance"])


def test_watch_round_trips_and_old_routines_are_not_watches(env):
    client, *_ = env()
    r = client.post("/v1/routines", json=RECAP, headers=AUTH).json()
    assert r["watch"] is False
    assert client.patch(f"/v1/routines/{r['id']}", json={"watch": True}, headers=AUTH).json()["watch"] is True


async def test_an_agent_sets_up_a_watch_by_chat(env):
    _, agent, *_ = env()
    tools = {t.name: t for t in agent.registries["coach"]}
    out = await tools["create_routine"].handler(title="Sleep watch", prompt="Check my sleep.", time="09:30",
                                                days=[], watch=True)
    assert "Sleep watch · watch · every day at 09:30" in out
    assert all("NOTHING" in agent._system(a)[0]["text"] for a in AGENTS)


def test_routines_carry_a_line_for_the_app(env):
    client, agent, *_ = env()
    added = agent.routines.add_starting_watches()
    assert added[0]["summary"].startswith("Reads your unread mail")
    # One made from an idea before summaries existed gets its line; one of the user's own stays without.
    agent.routines.conn.execute("UPDATE routines SET summary = NULL")
    mine = client.post("/v1/routines", json=dict(RECAP, title="My thing"), headers=AUTH).json()
    assert mine["summary"] is None
    agent.routines.add_starting_watches()
    got = {r["title"]: r["summary"] for r in client.get("/v1/routines", headers=AUTH).json()["routines"]}
    assert got["Tomorrow"].startswith("Looks over tomorrow") and got["My thing"] is None
    r = client.patch(f"/v1/routines/{mine['id']}", json={"summary": " Does my thing. "}, headers=AUTH).json()
    assert r["summary"] == "Does my thing."
    ideas = {a["id"]: a["routine_ideas"] for a in client.get("/v1/agents", headers=AUTH).json()["agents"]}
    assert all(i["summary"] for i in ideas["coach"])


async def test_an_agent_gives_its_routine_a_line(env):
    _, agent, *_ = env()
    tools = {t.name: t for t in agent.registries["coach"]}
    assert "summary" in tools["create_routine"].input_schema["required"]
    await tools["create_routine"].handler(title="Sleep watch", prompt="Check my sleep.", time="09:30", days=[],
                                          watch=True, summary="Checks your sleep.")
    assert agent.routines.all("coach")[-1]["summary"] == "Checks your sleep."


def test_an_older_database_gets_the_watch_column(tmp_path):
    path = tmp_path / "old.db"
    Database(path).close()
    old = sqlite3.connect(path)
    old.executescript("ALTER TABLE routines DROP COLUMN watch;")
    old.close()
    db = Database(path)
    assert "watch" in {r["name"] for r in db.conn.execute("PRAGMA table_info(routines)")}


# -- older databases -------------------------------------------------------------


def test_older_team_messages_survive_the_rebuild(tmp_path):
    path = tmp_path / "old.db"
    Database(path).close()
    old = sqlite3.connect(path)
    old.executescript("""
        DROP TABLE team_messages;
        CREATE TABLE team_messages (id INTEGER PRIMARY KEY, conversation_id INTEGER NOT NULL REFERENCES conversations(id),
            message_id INTEGER NOT NULL REFERENCES messages(id), sender TEXT NOT NULL, recipient TEXT NOT NULL,
            text TEXT NOT NULL, ts TEXT NOT NULL);
        INSERT INTO conversations (id, channel, started_at, last_active_at) VALUES (1, 'main', 'x', 'x');
        INSERT INTO messages (id, conversation_id, channel, role, content, ts) VALUES (1, 1, 'main', 'assistant', '"hi"', 'x');
        INSERT INTO team_messages VALUES (1, 1, 1, 'aide', 'coach', 'Gym?', '2026-10-19T10:00:00+00:00');
    """)
    old.close()
    db = Database(path)
    db.add_team_message({"from": "user", "to": "team", "text": "hi all", "ts": "2026-10-19T11:00:00+00:00"})
    assert [(t["text"], t["conversation_id"]) for t in db.team_messages(10)] == [("Gym?", "main"), ("hi all", None)]
    assert db.history_with_ts(1)[0][6] is None
    db.close()
