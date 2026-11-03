import asyncio
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from aide.db import Database
from aide.focus import FocusStore, FocusWatcher, focus_tools, natural_end, phase, studied
from aide.locks import LockStore
from aide.objectives import ObjectiveStore

ROME = ZoneInfo("Europe/Rome")
T0 = datetime(2026, 11, 3, 14, 0, tzinfo=timezone.utc)


class Study:
    def __init__(self, conn):
        self.conn = conn

    def chat(self, course_id):
        return f"chat-{course_id}"

    async def courses(self):
        return [dict(r) for r in self.conn.execute("SELECT id, name FROM courses")]

    def course_by_name(self, name):
        row = self.conn.execute("SELECT id, name FROM courses WHERE name = ?", (name,)).fetchone()
        return dict(row) if row else None


class Live:
    enabled = True

    def __init__(self, token=True):
        self.token, self.calls = token, []

    def settings(self):
        return {"focus": True}

    async def start(self, kind, attributes, state, alert, stale=None):
        self.calls.append(("start", kind, attributes, state, alert))
        return self.token

    async def update(self, key, state, alert=None, stale=None):
        self.calls.append(("update", key, state, alert))
        return True

    async def end(self, key, state, dismiss):
        self.calls.append(("end", key, state))
        return True


class Agent:
    def __init__(self):
        self.posts = []

    async def post(self, chat, note, text, attachments=None, record=True):
        self.posts.append((chat, text, attachments))


@pytest.fixture
def env():
    db = Database(":memory:")
    db.conn.executescript("CREATE TABLE IF NOT EXISTS courses (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, "
                          "chat TEXT)")
    course = db.conn.execute("INSERT INTO courses (name) VALUES ('macroeconomics')").lastrowid
    locks = LockStore(db.conn, ROME)
    store = FocusStore(db.conn, ROME, locks, Study(db.conn))
    yield store, locks, course
    db.close()


def test_rounds_are_strict_locks_and_breaks_are_gaps(env):
    store, locks, course = env
    synced = []
    locks.on_change.append(lambda: synced.append(1))
    s = store.start(course, 25, 5, 4, topic="t_islm", topic_title="IS-LM", now=T0)
    assert len(synced) == 1  # one sync push for all four rounds
    rounds = [lk for lk in locks.all(T0) if lk.get("focus") == s["public_id"]]
    assert len(rounds) == 4 and all(lk["strict"] for lk in rounds)
    assert [datetime.fromisoformat(lk["starts_at"]) for lk in rounds] == [T0 + timedelta(minutes=30 * i)
                                                                          for i in range(4)]
    assert natural_end(s) == T0 + timedelta(minutes=115)
    assert locks.as_json(rounds[0])["focus"] == s["public_id"]

    assert phase(s, T0 + timedelta(minutes=10))["kind"] == "focus"
    p = phase(s, T0 + timedelta(minutes=27))
    assert p["kind"] == "break" and p["round"] == 1 and p["ends"] == T0 + timedelta(minutes=30)
    assert phase(s, T0 + timedelta(minutes=31))["round"] == 2
    assert phase(s, T0 + timedelta(minutes=120))["kind"] == "done"
    assert studied(s, T0 + timedelta(minutes=40)) == (1, 35)
    assert studied(s, T0 + timedelta(hours=3)) == (4, 100)

    with pytest.raises(ValueError, match="is on until"):
        store.start(course, now=T0 + timedelta(minutes=5))


def test_rhythm_limits(env):
    store, _, course = env
    with pytest.raises(ValueError, match="15"):
        store.start(course, 10, 5, 2, now=T0)
    with pytest.raises(ValueError, match="rounds"):
        store.start(course, 25, 5, 9, now=T0)
    with pytest.raises(ValueError, match="no course"):
        store.start(999, now=T0)
    one = store.start(course, 50, 10, 1, now=T0)  # "50 minutes on macro"
    assert one["break_min"] == 0 and natural_end(one) == T0 + timedelta(minutes=50)


def test_ending_early(env):
    store, locks, course = env
    s = store.start(course, 25, 5, 4, now=T0)
    in_round = T0 + timedelta(minutes=10)
    with pytest.raises(ValueError, match="emergency pass"):
        store.end(s["public_id"], "bored", now=in_round)
    after = store.end(s["public_id"], use_pass=True, now=in_round)
    assert after["ended"] == "early" and locks.passes(in_round)["left"] == 2
    assert not [lk for lk in locks.all(T0) if lk.get("focus")]  # the rounds still to come went too
    assert studied(after, T0 + timedelta(hours=2)) == (0, 10)

    gentle = store.start(course, 25, 5, 2, strict=False, now=T0 + timedelta(hours=3))
    store.end(gentle["public_id"], "a call", now=T0 + timedelta(hours=3, minutes=5))
    on_break = store.start(course, 25, 5, 2, now=T0 + timedelta(hours=5))
    store.end(on_break["public_id"], now=T0 + timedelta(hours=5, minutes=27))  # a break: nothing asked
    assert locks.passes(T0 + timedelta(hours=6))["left"] == 2


def test_a_round_deleted_elsewhere_ends_it(env):
    store, locks, course = env
    s = store.start(course, 25, 5, 2, strict=False, now=T0)
    first = next(lk for lk in locks.all(T0) if lk.get("focus"))
    locks.unlock(first["id"], "from the locks page", now=T0 + timedelta(minutes=3))
    done = store.finish_due(T0 + timedelta(minutes=5))
    assert [d["ended"] for d in done] == ["early"]
    assert store.current(T0 + timedelta(minutes=5)) is None


def test_watcher_live_activity_and_post(env):
    store, _, course = env
    live, agent = Live(), Agent()
    watch = FocusWatcher(store, live, agent)
    s = store.start(course, 25, 5, 2, topic_title="IS-LM", now=T0)

    async def go():
        await watch.tick(T0 + timedelta(seconds=5))
        await watch.tick(T0 + timedelta(minutes=1))  # same phase: nothing sent
        await watch.tick(T0 + timedelta(minutes=26))
        await watch.tick(T0 + timedelta(minutes=31))
        await watch.tick(T0 + timedelta(minutes=56))
    asyncio.run(go())
    kinds = [c[0] for c in live.calls]
    assert kinds == ["start", "update", "update", "end"]
    start = live.calls[0]
    assert start[1] == "focus" and start[2]["topic"] == "IS-LM" and start[3]["phase"] == "focus"
    assert live.calls[1][2]["phase"] == "break" and live.calls[1][3]["sound"] == "default"
    assert live.calls[2][2]["round"] == 2
    assert live.calls[3][2]["over"]
    chat, text, cards = agent.posts[0]
    assert chat == f"chat-{course}" and "2 rounds" in text and "50 min" in text
    assert cards[0]["open"][0]["url"].startswith(f"aide://study/{course}/quiz?focus={s['public_id']}")

    checked = store.set_check(s["public_id"], 4, 5)
    asyncio.run(watch.checked(checked))
    assert "4 of 5" in agent.posts[-1][1]
    assert "check 4/5" in store.text(T0 + timedelta(hours=1))


def test_no_start_token_is_not_retried(env):
    store, _, course = env
    live = Live(token=False)
    watch = FocusWatcher(store, live)
    store.start(course, 25, 5, 2, now=T0)
    asyncio.run(watch.tick(T0 + timedelta(seconds=5)))
    asyncio.run(watch.tick(T0 + timedelta(minutes=26)))
    assert [c[0] for c in live.calls] == ["start"]


def test_objective_counts_rounds(env):
    store, _, course = env
    objectives = ObjectiveStore(store.conn, ROME)
    today = datetime.now(ROME).date()
    o = objectives.add("professor", "week", today, "4 rounds of macro this week",
                       measure={"type": "focus", "course": course}, target=4)
    assert objectives.as_json(o)["progress"] == 0
    start = datetime.now(timezone.utc) - timedelta(hours=3)
    store.start(course, 25, 5, 2, now=start)
    j = objectives.as_json(o)
    assert j["progress"] == 2 and j["measure"]["label"] == "focus rounds on macroeconomics"


def test_tools(env):
    store, _, course = env
    tools = {t.name: t.handler for t in focus_tools(store, store.study, ROME)}
    text = asyncio.run(tools["start_focus"]("macro", focus_min=50, rounds=1, topic="IS-LM"))
    assert "1 × 50 min" in text and "Macroeconomics" in text
    status = asyncio.run(tools["focus_status"]())
    assert "On now" in status and "IS-LM" in status
    with pytest.raises(ValueError, match="is on until"):
        asyncio.run(tools["start_focus"]("macroeconomics"))


def test_api():
    from fastapi.testclient import TestClient

    from aide.agent import Agent
    from aide.channels.api import create_app
    from aide.reminders import ReminderStore
    from aide.tools import ToolRegistry
    from test_api import AUTH, TOKEN, FakeClient

    db = Database(":memory:")
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    c = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN))
    course = db.conn.execute("INSERT INTO courses (name) VALUES ('macroeconomics')").lastrowid
    assert c.get("/v1/focus", headers=AUTH).json()["current"] is None
    assert c.post("/v1/focus", json={"course_id": course, "focus_min": 5}, headers=AUTH).status_code == 400
    s = c.post("/v1/focus", json={"course_id": course, "rounds": 2, "strict": False, "topic_title": "IS-LM"},
               headers=AUTH).json()
    assert s["phase"]["kind"] == "focus" and s["phase"]["round"] == 1 and s["course"] == "Macroeconomics"
    got = c.get("/v1/focus", headers=AUTH).json()
    assert got["current"]["id"] == s["id"] and got["presets"][0]["name"] == "25/5"
    rounds = [lk for lk in c.get("/v1/locks", headers=AUTH).json()["locks"] if lk["focus"] == s["id"]]
    assert len(rounds) == 2
    assert c.post(f"/v1/focus/{s['id']}/end", json={}, headers=AUTH).status_code == 400  # a round needs a reason
    assert c.post(f"/v1/locks/{rounds[0]['id']}/unlock", json={"reason": "a call"}, headers=AUTH).json() == \
        {"lock": None}
    ended = c.get(f"/v1/focus/{s['id']}", headers=AUTH).json()
    assert ended["ended"] == "early" and ended["reason"] == "a call"
    assert not [lk for lk in c.get("/v1/locks", headers=AUTH).json()["locks"] if lk["focus"]]
    assert c.post(f"/v1/focus/{s['id']}/check", json={"right": 3, "total": 5}, headers=AUTH).json()["check"] == \
        {"right": 3, "total": 5}
    assert c.get("/v1/focus/f_nope", headers=AUTH).status_code == 404
    db.close()
