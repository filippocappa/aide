import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from aide import host
from aide.agent import Agent
from aide.db import Database
from aide.livecall import LiveCalls
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.reminders import reminder_tools
from test_api import ROME, FakeClient

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(autouse=True)
def state(tmp_path, monkeypatch):
    monkeypatch.setattr(host, "STATE_DIR", tmp_path)
    monkeypatch.setattr(host, "CLAIMS", tmp_path / "claims")
    monkeypatch.setattr(host, "STATE", tmp_path / "aide.json")
    monkeypatch.setattr(host, "dev_processes", lambda: [])
    monkeypatch.setattr(host, "_watcher", None)
    return tmp_path


def test_claims_hold_while_their_process_runs():
    cid = host.claim("emulator", "roenlabs", mb=4000)
    assert [(c["id"], c["what"], c["who"], c["mb"]) for c in host.claims()] == [(cid, "emulator", "roenlabs", 4000)]
    host.release(cid)
    assert host.claims() == []
    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    host.claim("gradle", "roenlabs", pid=dead.pid)
    assert host.claims() == []  # its process is gone: swept
    assert list(host.CLAIMS.glob("*.json")) == []


def test_describe():
    assert host.describe([{"who": "roenlabs", "what": "Android emulator"}]) == "Roen's Android emulator"
    assert host.describe([{"who": "roenlabs", "what": "Android emulator"}, {"who": "roenlabs", "what": "Metro"},
                          {"who": "fzts", "what": "Expo"}]) == "Roen's Android emulator and Metro and fzts's Expo"
    assert host.describe([{"who": "?", "what": "Gradle"}]) == "Gradle"


def test_watcher_steps_back_and_comes_back(monkeypatch):
    events = []
    seen = []
    monkeypatch.setattr(host, "dev_processes", lambda: seen)

    async def step_back(why):
        events.append(("back", why))

    async def come_back():
        events.append(("again",))

    async def main():
        w = host.HostWatcher(step_back, come_back, quiet=10)
        await w.tick(now=0)
        assert host.holder() is None and w.since is None
        cid = host.claim("emulator", "roenlabs")
        await w.tick(now=1)
        await asyncio.sleep(0)
        assert events == [("back", "Roen's emulator")]
        assert host.holder() == "Roen's emulator"
        await w.tick(now=2)
        state = host.read_state()
        assert state["stepped_back"] and state["ready"] == [cid]  # host-claim may go ahead
        waiting = asyncio.create_task(host.until_free())  # a transcription
        seen.append({"what": "Metro", "who": "roenlabs"})
        host.release(cid)
        await w.tick(now=20)  # a scan: Metro still runs
        assert w.held == "Roen's Metro" and not waiting.done()
        seen.clear()
        await w.tick(now=30)
        await w.tick(now=35)  # quiet for 5 s: not yet
        assert events == [("back", "Roen's emulator")] and not waiting.done()
        assert host.holder() == "Roen's Metro"  # the quiet while still says what it was
        await w.tick(now=41)
        await asyncio.wait_for(waiting, 1)
        assert events[-1] == ("again",)
        assert host.holder() is None and host.read_state()["since"] is None
    asyncio.run(main())


def test_watcher_says_what_it_finishes_first():
    release = asyncio.Event()

    async def step_back(why):
        await release.wait()

    async def main():
        w = host.HostWatcher(step_back, finishing=lambda: "a live call")
        cid = host.claim("emulator", "roenlabs")
        await w.tick(now=0)
        await asyncio.sleep(0)
        await w.tick(now=1)
        state = host.read_state()
        assert state["finishing"] == "a live call" and state["ready"] == [] and not state["stepped_back"]
        release.set()
        for _ in range(3):
            await asyncio.sleep(0)
        await w.tick(now=2)
        assert host.read_state()["ready"] == [cid] and host.read_state()["finishing"] is None
    asyncio.run(main())


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    from aide import livecall
    monkeypatch.setattr(livecall, "HOLD_POLL", 0.01)


def calls_for(switched: list, synced: list | None = None) -> LiveCalls:
    db = Database(":memory:")
    agent = Agent(FakeClient([]), db, ToolRegistry(reminder_tools(ReminderStore(db.conn), ROME)), model="m",
                  delegate=False, tz=ROME)

    async def connect(text):
        raise AssertionError("no calls while held")

    async def switch(on):
        switched.append(on)
    connect.engine, connect.switch = "local", switch
    calls = LiveCalls(agent, db.conn, connect)
    if synced is not None:
        calls.on_change.append(lambda: synced.append(calls.as_json()))
    return calls


def test_live_calls_step_back_after_the_call_and_come_back():
    switched, synced = [], []
    calls = calls_for(switched, synced)

    async def main():
        calls.active["c_1"] = object()  # a call going
        stepping = asyncio.create_task(calls.step_back("Roen's Android emulator"))
        await asyncio.sleep(0.01)
        assert calls.on is False and calls.finishing() == "a live call"  # no new calls, the one going goes on
        assert calls.as_json() == {"live": False, "enabled": True, "engine": "local", "loading": False,
                                   "held_by": "Roen's Android emulator"}
        assert switched == []
        del calls.active["c_1"]
        await asyncio.wait_for(stepping, 5)
        assert switched == [False]
        await calls.set_enabled(True)  # turned on in the app meanwhile: still held, nothing loaded
        await calls._switching
        assert switched == [False]
        await calls.come_back()
        await calls._switching
        await asyncio.sleep(0)
        assert switched == [False, True] and calls.on and "held_by" not in calls.as_json()
        assert synced[-1]["live"] is True
    asyncio.run(main())


def test_live_calls_off_stay_off():
    switched = []
    calls = calls_for(switched)

    async def main():
        await calls.set_enabled(False)
        await calls._switching
        await calls.step_back("Roen's Expo")
        await calls.come_back()
        assert switched == [False]  # turned off by the user: not loaded again
    asyncio.run(main())


def test_settle_while_held_loads_nothing():
    switched = []
    calls = calls_for(switched)
    calls.held = "Roen's Android emulator"
    asyncio.run(calls.settle())
    assert switched == [False]


def test_host_claim_waits_for_aide(state):
    env = {**os.environ, "AIDE_HOST_STATE": str(state)}
    script = str(ROOT / "deploy/host-claim")
    # Aide isn't running: it goes ahead.
    out = subprocess.run([sys.executable, script, "emulator", "--", sys.executable, "-c",
                          "import sys; sys.exit(3)"], env=env, capture_output=True, text=True, timeout=20)
    assert out.returncode == 3 and "isn't running" in out.stderr
    assert list((state / "claims").glob("*.json")) == []  # released at the end

    # Aide answers the claim while the command waits.
    (state / "aide.json").write_text(json.dumps({"at": host.iso(), "ready": [], "stepped_back": False}))
    code = ("import json, os, time, pathlib\n"
            f"d = pathlib.Path({str(state)!r})\n"
            "while True:\n"
            "    cs = list((d / 'claims').glob('*.json'))\n"
            "    if cs: break\n"
            "    time.sleep(0.05)\n"
            "cid = json.loads(cs[0].read_text())['id']\n"
            "now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())\n"
            "(d / 'aide.json').write_text(json.dumps({'at': now, 'ready': [cid], 'stepped_back': True}))\n")
    aide = subprocess.Popen([sys.executable, "-c", code])
    out = subprocess.run([sys.executable, script, "--mb", "4000", "emulator", "--", sys.executable, "-c",
                          "print('started')"], env=env, capture_output=True, text=True, timeout=20)
    aide.wait(5)
    assert out.returncode == 0 and out.stdout.strip() == "started"
    assert "stepped back for the emulator" in out.stderr
    listed = subprocess.run([sys.executable, script, "--list"], env=env, capture_output=True, text=True, timeout=10)
    assert "No claims." in listed.stdout


def test_aide_status_reads_the_claims(state, monkeypatch):
    import importlib.util
    spec = importlib.util.spec_from_file_location("aide_status", ROOT / "deploy/aide-status.py")
    status = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(status)
    host.claim("emulator", "roenlabs")
    (state / "aide.json").write_text(json.dumps({"at": host.iso(), "since": "2026-11-25T18:00:00Z",
                                                 "held_by": [{"who": "roenlabs", "what": "emulator"}],
                                                 "stepped_back": True}))
    assert status.stepped_back({"state": "active"}) == {"by": "Roen's emulator", "since": "2026-11-25T18:00:00Z",
                                                        "ready": True}
    assert status.stepped_back({"state": "inactive"}) is None
    assert [c["who"] for c in host.claims()] == ["roenlabs"]
