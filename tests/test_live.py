import asyncio
import json
import time
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from aide import live as live_mod
from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.live import LiveActivities
from aide.push import Push
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.transit import AlertStore, AlertWatcher, Boards, Location, Transit, Walks
from test_api import AUTH, ROME, TOKEN, FakeClient, done
from test_push import APNs, key  # noqa: F401: the key fixture
from test_transit import DAY, FakeLive, FakePush, at, live_feed, timetable  # noqa: F401: the timetable fixture

START = "c3" * 32
ACTIVITY = "d4" * 32


@pytest.fixture
def env(key):  # noqa: F811
    db = Database(":memory:")
    apns = APNs()
    push = Push(db.conn, key[0], "KEY123", "TEAM456", "com.filippocappa.aide", httpx.MockTransport(apns.handle))
    yield db, push, LiveActivities(db.conn, push), apns
    db.close()


def aps(apns: APNs) -> list[dict]:
    return [p["aps"] for p in apns.payloads()]


async def settle() -> None:
    while live_mod._running:
        await asyncio.gather(*list(live_mod._running))


# -- tokens and the sender ----------------------------------------------------------------


def test_tokens(env):
    db, _, live, _ = env
    live.set_start_token("tram", START, "sandbox")
    live.set_start_token("tram", "e5" * 32, "production")  # replaces
    assert (live.start_token("tram")["token"], live.start_token("tram")["environment"]) == ("e5" * 32, "production")
    live.register("agent:main", ACTIVITY, "sandbox")
    assert live.token("agent:main")["token"] == ACTIVITY
    live.remove("agent:main")
    live.remove_start_token("tram")
    assert live.token("agent:main") is None and live.start_token("tram") is None
    with pytest.raises(ValueError):
        live.set_start_token("bus", START, "sandbox")
    with pytest.raises(ValueError):
        live.register("agent:main", "zz", "sandbox")
    with pytest.raises(ValueError):
        live.register("agent:main", ACTIVITY, "staging")
    # Activity tokens go after 12 hours, start tokens stay.
    live.set_start_token("agent", START, "sandbox")
    live.register("agent:old", ACTIVITY, "sandbox")
    db.conn.execute("UPDATE live_tokens SET created_at = ?",
                    ((datetime.now(timezone.utc) - timedelta(hours=13)).isoformat(),))
    assert live.token("agent:old") is None and live.start_token("agent")


async def test_headers_timestamps_and_a_token_apns_refuses(env):
    _, _, live, apns = env
    live.register("agent:main", ACTIVITY, "sandbox")
    state = {"status": "working", "detail": "", "text": "", "since": 1}
    assert await live.update("agent:main", state)
    assert await live.update("agent:main", state, alert={"title": "Aide", "body": "Hi"})
    first, second = apns.requests
    assert str(first.url) == f"https://api.sandbox.push.apple.com/3/device/{ACTIVITY}"
    assert (first.headers["apns-topic"], first.headers["apns-push-type"], first.headers["apns-priority"]) == (
        "com.filippocappa.aide.push-type.liveactivity", "liveactivity", "5")
    assert second.headers["apns-priority"] == "10"
    one, two = aps(apns)
    assert one == {"timestamp": one["timestamp"], "event": "update", "content-state": state}
    assert two["timestamp"] > one["timestamp"]  # each newer than the last, even within a second
    apns.replies[ACTIVITY] = (410, "Unregistered")
    assert not await live.update("agent:main", state)
    assert live.token("agent:main") is None
    assert not await live.update("agent:main", state) and len(apns.requests) == 3  # no token: nothing sent


async def test_nothing_is_sent_without_a_key():
    db = Database(":memory:")
    live = LiveActivities(db.conn, Push(db.conn))
    live.set_start_token("tram", START, "sandbox")
    assert not await live.start("tram", {"key": "tram:1"}, {}, {"title": "t", "body": "b"})


# -- tram ---------------------------------------------------------------------------------------


async def test_a_tram_alert_starts_follows_and_ends_its_live_activity(env, timetable):  # noqa: F811
    db, push, live, apns = env
    fake = FakePush()
    location = Location(db.conn, fake)
    alerts = AlertStore(db.conn, ROME, timetable)
    a = alerts.create("1", "4", now=at(7, 50).astimezone(timezone.utc))
    feed = FakeLive(live_feed(("T1", [(2, 120)]), ("T5", None)))
    watcher = AlertWatcher(alerts, Transit(timetable, feed), location, Walks(), fake, live)
    location.save(45.0650, 7.6756, 10, at(7, 59))
    live.set_start_token("tram", START, "sandbox")

    await watcher.tick(at(8, 0, 20))
    assert fake.alerts == []  # the Live Activity instead of the plain push
    [start] = aps(apns)
    key = f"tram:{a['id']}:T1:20261022"
    tram = int(at(8, 7).timestamp())
    walk = start["content-state"]["walk"]
    assert 200 < walk < 400
    assert start == {
        "timestamp": start["timestamp"], "event": "start", "attributes-type": "TramActivityAttributes",
        "attributes": {"key": key, "line": "4", "vehicle": "Tram", "stop": "Porta Nuova", "code": "252",
                       "towards": "Falchera", "alert": a["id"]},
        "content-state": {"at": tram, "leave": tram - walk - 120, "walk": walk, "live": True, "delay": 120,
                          "next": int(at(8, 15).timestamp()), "gone": False, "stops": 0,
                          "near": "Vittorio Emanuele II Cap", "starts": None, "feed_down": False, "at_stop": False,
                          "riding": False, "to": None},
        "stale-date": tram + 120,
        "alert": {"title": "Tram 4 in 7 min: leave now", "body": start["alert"]["body"], "sound": "default"}}
    assert apns.requests[0].headers["apns-priority"] == "10"
    assert str(apns.requests[0].url).endswith(START)

    await watcher.tick(at(8, 1))  # nothing moved
    feed.data = live_feed(("T1", [(2, 240)]))
    await watcher.tick(at(8, 1, 30))  # moved, but the app hasn't sent the activity's token yet
    assert len(apns.requests) == 1
    live.register(key, ACTIVITY, "sandbox")
    await watcher.tick(at(8, 2))
    update = aps(apns)[1]
    assert update["event"] == "update" and update["content-state"]["at"] == tram + 120
    assert update["content-state"]["delay"] == 240 and update["stale-date"] == tram + 240
    assert apns.requests[1].headers["apns-priority"] == "5"

    await watcher.tick(at(8, 9, 40))  # 08:09 was its time: it has left
    end = aps(apns)[2]
    assert end["event"] == "end" and end["content-state"]["gone"] is True
    assert end["dismissal-date"] == int(at(8, 11, 40).timestamp())
    assert watcher.following == {} and live.token(key) is None


STOP_252 = (45.06254, 7.67561)
FALCHERA = (45.1200, 7.7100)


async def test_near_the_stop_it_follows_the_earlier_tram_then_the_ride_to_where_you_get_off(env, timetable):  # noqa: F811
    db, push, live, apns = env
    fake = FakePush()
    location = Location(db.conn, fake)
    alerts = AlertStore(db.conn, ROME, timetable)
    a = alerts.create("1", "4", "08:15", now=at(7, 40).astimezone(timezone.utc), to_stop="4")
    watcher = AlertWatcher(alerts, Transit(timetable, FakeLive()), location, Walks(), fake, live)
    live.set_start_token("tram", START, "sandbox")
    location.save(45.0716, 7.6756, 10, at(7, 50))  # about 1 km north: a 17 min walk
    await watcher.tick(at(7, 53))
    [start] = aps(apns)
    key = start["attributes"]["key"]
    assert key.endswith(":T2:20261022") and start["content-state"]["at"] == int(at(8, 15).timestamp())
    live.register(key, ACTIVITY, "sandbox")

    location.save(*STOP_252, 15, at(8, 2))  # left early: already at the stop, and the 08:05 is coming
    await watcher.tick(at(8, 2, 30))
    switch = aps(apns)[1]
    assert switch["content-state"]["at"] == int(at(8, 5).timestamp()) and switch["content-state"]["at_stop"] is True
    assert switch["alert"]["title"] == "Tram 4 in 2 min" and "You're at the stop." in switch["alert"]["body"]
    assert watcher.following[key]["trip"] == "T1"

    location.save(*STOP_252, 15, at(8, 5, 20))
    await watcher.tick(at(8, 5, 30))  # it's here, and so is the phone: on it or not, a fix will say
    assert len(apns.requests) == 2 and key in watcher.following

    location.save(FALCHERA[0] - 0.002, FALCHERA[1], 20, at(8, 7))  # along its line, away from the stop: on board
    await watcher.tick(at(8, 7, 10))
    ride = aps(apns)[2]
    assert ride["content-state"] | {} == {
        "at": int(at(8, 30).timestamp()), "leave": None, "walk": None, "live": False, "delay": None, "next": None,
        "gone": False, "stops": 0, "near": "Falchera", "starts": None, "feed_down": False, "at_stop": False,
        "riding": True, "to": "Falchera"}
    assert ride["alert"]["title"] == "Falchera is next"
    await watcher.tick(at(8, 20))
    assert len(apns.requests) == 3  # nothing new, and the heads-up only once

    await watcher.tick(at(8, 31, 10))  # there
    end = aps(apns)[3]
    assert end["event"] == "end" and end["content-state"]["gone"] is True and end["content-state"]["riding"] is True
    assert end["content-state"]["to"] == "Falchera" and watcher.following == {}


async def test_still_at_the_stop_once_it_has_gone_it_follows_the_next(env, timetable):  # noqa: F811
    db, push, live, apns = env
    fake = FakePush()
    location = Location(db.conn, fake)
    alerts = AlertStore(db.conn, ROME, timetable)
    alerts.create("1", "4", now=at(8, 0).astimezone(timezone.utc))
    watcher = AlertWatcher(alerts, Transit(timetable, FakeLive()), location, Walks(), fake, live)
    live.set_start_token("tram", START, "sandbox")
    location.save(*STOP_252, 15, at(8, 3))
    await watcher.tick(at(8, 3, 30))
    [start] = aps(apns)
    key = start["attributes"]["key"]
    live.register(key, ACTIVITY, "sandbox")
    location.save(*STOP_252, 15, at(8, 6, 30))
    await watcher.tick(at(8, 6, 40))  # the 08:05 went without them
    switch = aps(apns)[1]
    assert switch["event"] == "update" and switch["content-state"]["at"] == int(at(8, 7).timestamp())
    assert switch["alert"]["title"].startswith("Tram 4 now") and watcher.following[key]["trip"] == "T5"

    location.save(45.0716, 7.6756, 15, at(8, 9))  # walked off, nowhere along its line
    await watcher.tick(at(8, 9, 10))
    assert aps(apns)[2]["event"] == "end" and watcher.following == {}


async def test_without_a_start_token_the_plain_push_goes(env, timetable):  # noqa: F811
    db, _, live, apns = env
    fake = FakePush()
    location = Location(db.conn, fake)
    alerts = AlertStore(db.conn, ROME, timetable)
    alerts.create("1", "4", "08:10", [4], minutes=10)
    watcher = AlertWatcher(alerts, Transit(timetable, FakeLive()), location, Walks(), fake, live)
    await watcher.tick(at(7, 56))
    assert [t for _, t, _ in fake.alerts] == ["Tram 4 in 9 min"] and apns.requests == []


# -- agents ---------------------------------------------------------------------------------------


@pytest.fixture
def quick(monkeypatch):
    monkeypatch.setattr(live_mod, "SETTLE", 0)
    monkeypatch.setattr(live_mod, "THROTTLE", 0)


async def test_an_agent_turn_asks_writes_and_finishes(env, quick):
    _, _, live, apns = env
    live.register("agent:c1", ACTIVITY, "sandbox")
    turn = live.turn("c1", "aide")
    turn.team({"from": "aide", "to": "coach", "text": "How did I sleep?"})
    await settle()
    turn.team({"from": "coach", "to": "aide", "text": "Well."})  # an answer isn't an ask
    turn.text("He", True)
    turn.text("llo")
    await settle()
    turn.finished("You slept well.\n\nMore below.")
    await settle()
    asking, writing, finished, end = aps(apns)
    assert asking["content-state"] == {"status": "asking", "detail": "Asking Coach", "text": "",
                                       "since": turn.since}
    assert writing["content-state"]["status"] == "writing"
    assert finished["content-state"] == {"status": "done", "detail": "", "text": "You slept well.",
                                         "since": turn.since}
    assert finished["alert"] == {"title": "Aide", "body": "You slept well.", "sound": "default"}
    assert end["event"] == "end" and end["dismissal-date"] >= int(time.time()) + 29 * 60
    assert live.token("agent:c1") is None


async def test_updates_are_throttled_to_the_latest(env, quick, monkeypatch):
    _, _, live, apns = env
    monkeypatch.setattr(live_mod, "THROTTLE", 0.2)
    live.register("agent:c1", ACTIVITY, "sandbox")
    turn = live.turn("c1", "aide")
    turn.team({"from": "aide", "to": "coach", "text": "?"})
    await asyncio.sleep(0)  # the first goes out at once
    turn.team({"from": "aide", "to": "professor", "text": "?"})
    turn.team({"from": "aide", "to": "finance", "text": "?"})
    await settle()
    assert [p["content-state"]["detail"] for p in aps(apns)] == ["Asking Coach", "Asking Finance"]


async def test_the_app_ended_it_so_nothing_more_goes(env, quick):
    _, _, live, apns = env
    turn = live.turn("c1", "aide")
    turn.finished("Done.")
    turn.failed()
    await settle()
    assert apns.requests == []


async def test_a_failed_turn_ends_without_an_alert(env, quick):
    _, _, live, apns = env
    live.register("agent:team", ACTIVITY, "sandbox")
    live.turn("team").failed()
    await settle()
    [end] = aps(apns)
    assert end["event"] == "end" and end["content-state"]["status"] == "failed" and "alert" not in end


def test_chat_and_team_chat_push_to_the_registered_key(env, quick):
    db, push, live, apns = env
    agent = Agent(FakeClient([done("Here's your day."), done("All good from me.")]), db, ToolRegistry([]),
                  model="m", delegate=False, tz=ROME)
    app = create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN, push=push, live=live)
    with TestClient(app) as c:
        assert c.post("/v1/live/activities", json={"key": "agent:main", "token": ACTIVITY,
                                                    "environment": "sandbox"}, headers=AUTH).json() == {"ok": True}
        assert c.post("/v1/chat", json={"text": "my day?"}, headers=AUTH).status_code == 200
        wait_for(apns, 2)
        assert [p["event"] for p in aps(apns)] == ["update", "end"]
        assert aps(apns)[0]["alert"]["body"] == "Here's your day."
        c.post("/v1/live/activities", json={"key": "agent:team", "token": ACTIVITY, "environment": "sandbox"},
               headers=AUTH)
        assert c.post("/v1/team", json={"text": "@coach status?"}, headers=AUTH).status_code == 200
        wait_for(apns, 4)
        assert aps(apns)[2]["alert"] == {"title": "Coach", "body": "All good from me.", "sound": "default"}
        # With the app open, it deletes the key first: nothing goes.
        c.post("/v1/live/activities", json={"key": "agent:main", "token": ACTIVITY, "environment": "sandbox"},
               headers=AUTH)
        assert c.delete("/v1/live/activities/agent:main", headers=AUTH).json() == {"ok": True}
        assert live.token("agent:main") is None


def wait_for(apns: APNs, count: int) -> None:
    deadline = time.monotonic() + 3
    while len(apns.requests) < count and time.monotonic() < deadline:
        time.sleep(0.02)
    assert len(apns.requests) == count


def test_token_endpoints(env):
    db, push, live, _ = env
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    c = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN, push=push, live=live))
    body = {"kind": "tram", "token": START.upper(), "environment": "production"}
    assert c.post("/v1/live/tokens", json=body, headers=AUTH).json() == {"ok": True}
    assert live.start_token("tram")["token"] == START
    assert c.post("/v1/live/tokens", json={**body, "kind": "bus"}, headers=AUTH).status_code == 400
    assert c.delete("/v1/live/tokens/tram", headers=AUTH).json() == {"ok": True}
    assert c.delete("/v1/live/tokens/bus", headers=AUTH).status_code == 404
    assert live.start_token("tram") is None
    assert c.post("/v1/live/activities", json={"key": "", "token": ACTIVITY, "environment": "sandbox"},
                  headers=AUTH).status_code == 400


async def test_a_routine_starts_quietly_and_ends_at_once(env):
    _, _, live, apns = env
    routine = {"id": 4, "agent": "coach", "title": "Weekly plan", "public_id": "r-77"}
    assert await live.routine_started(routine) is None  # no start token: nothing
    live.set_start_token("agent", START, "sandbox")
    key = await live.routine_started(routine)
    assert key == "agent:r-77"
    [start] = aps(apns)
    assert start["attributes"] == {"key": key, "agent": "coach", "name": "Coach", "color": start["attributes"]["color"],
                                   "conversation": "r-77", "title": "Weekly plan"}
    assert start["alert"] == {"title": "Coach · Weekly plan", "body": "Working on it"}  # no sound
    assert start["content-state"]["status"] == "working"
    live.register(key, ACTIVITY, "sandbox")
    await live.routine_ended(key, start["content-state"]["since"], "Three runs this week.\nDetails…")
    end = aps(apns)[1]
    assert end["event"] == "end" and end["content-state"]["text"] == "Three runs this week."
    assert end["dismissal-date"] <= int(time.time())


# -- widgets -------------------------------------------------------------------------------------


def test_completing_a_reminder_from_the_widget(env):
    db, *_ = env
    store = ReminderStore(db.conn)
    synced = []
    store.on_change.append(lambda: synced.append(1))
    rem = store.create("Bins")
    synced.clear()
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    c = TestClient(create_app(agent, store, None, ROME, TOKEN))
    r = c.post(f"/v1/reminders/{rem.id}/complete", json={"completed": True}, headers=AUTH).json()
    assert r["id"] == rem.id and r["completed"] is True
    assert store.get(rem.id).completed and store.get(rem.id).modified_at >= rem.modified_at and synced == [1]
    assert c.post(f"/v1/reminders/{rem.id}/complete", json={"completed": False}, headers=AUTH).json()["completed"] is False
    assert c.post("/v1/reminders/nope/complete", json={}, headers=AUTH).status_code == 404


def test_nearby_boards(env, timetable, monkeypatch):  # noqa: F811
    db, *_ = env
    location = Location(db.conn, FakePush())
    boards = Boards(Transit(timetable, FakeLive()), location, Walks())
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    c = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN, location=location, boards=boards))
    monkeypatch.setattr("aide.transit.utcnow", lambda: at(8, 0).astimezone(timezone.utc))
    assert c.get("/v1/transit/nearby", headers=AUTH).json() == {"boards": [], "fix_at": None}
    location.save(45.0625, 7.6758, 10, at(7, 59))  # beside 252, 150 m from 253 across the road
    got = c.get("/v1/transit/nearby", headers=AUTH).json()
    assert got["fix_at"] == "2026-10-22T07:59:00+02:00"
    assert [b["stop"]["code"] for b in got["boards"]] == ["252", "253"]
    assert got["boards"][0]["walk"] is not None
    monkeypatch.setattr("aide.transit.utcnow", lambda: at(10, 30).astimezone(timezone.utc))
    assert c.get("/v1/transit/nearby", headers=AUTH).json() == {"boards": [], "fix_at": "2026-10-22T07:59:00+02:00"}
    off = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN))
    assert off.get("/v1/transit/nearby", headers=AUTH).status_code == 404
