import asyncio
import json
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from aide import engine as engine_module
from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.engine import Engine, course_var
from aide.photos import PhotoStore
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from test_api import AUTH, TOKEN, FakeCalendar, done
from test_food import RecordingClient
from test_study import ROME

# Claude Code as the server runs it: one stream-json message in, events out. What it does comes from files next to
# it: `mode` (ok or limit) and `reset` (when the limit resets, epoch seconds); each call is kept in `calls`.
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
here = pathlib.Path(__file__).parent
message = json.loads(sys.stdin.readline())
args = sys.argv[1:]
mode = (here / "mode").read_text().strip() if (here / "mode").exists() else "ok"
with (here / "calls").open("a") as f:
    f.write(json.dumps({"args": args, "key": os.environ.get("ANTHROPIC_API_KEY"),
                        "max": os.environ.get("CLAUDE_CODE_MAX_OUTPUT_TOKENS"), "cwd": os.getcwd(),
                        "content": message["message"]["content"]}) + "\n")
model = args[args.index("--model") + 1]
print(json.dumps({"type": "system", "subtype": "init", "model": model}))
if mode == "limit":
    reset = int((here / "reset").read_text())
    print(json.dumps({"type": "rate_limit_event", "rate_limit_info": {
        "status": "rejected", "resetsAt": reset, "rateLimitType": "five_hour",
        "unifiedWindows": {"five_hour": {"utilization": 1.0, "resetsAt": reset}}}}))
    print(json.dumps({"type": "result", "subtype": "success", "is_error": True,
                      "result": "You've hit your limit"}))
else:
    print(json.dumps({"type": "rate_limit_event", "rate_limit_info": {
        "status": "allowed", "resetsAt": 1792660800, "rateLimitType": "five_hour",
        "unifiedWindows": {"five_hour": {"utilization": 0.25, "resetsAt": 1792660800},
                           "seven_day": {"utilization": 0.5, "resetsAt": 1792753200}}}}))
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": f"ok from {model}"}))
'''


@pytest.fixture
def plan(tmp_path, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-not-for-the-plan")
    monkeypatch.setattr(engine_module, "RESET_SLACK", 0)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    claude = bin_dir / "claude"
    claude.write_text(FAKE_CLAUDE)
    claude.chmod(0o755)
    db = Database(":memory:")
    client = RecordingClient([])
    engine = Engine(db.conn, client, "m", "smart", claude=str(claude), workdir=tmp_path / "work")

    def calls() -> list[dict]:
        path = bin_dir / "calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def limit(seconds: float) -> datetime:
        reset = int(datetime.now(timezone.utc).timestamp() + seconds)
        (bin_dir / "reset").write_text(str(reset))
        (bin_dir / "mode").write_text("limit")
        return datetime.fromtimestamp(reset, timezone.utc)

    yield engine, client, calls, limit, (lambda: (bin_dir / "mode").write_text("ok")), db
    db.close()


async def until(check, seconds: float = 5) -> None:
    for _ in range(int(seconds / 0.02)):
        if check():
            return
        await asyncio.sleep(0.02)
    raise AssertionError("timed out")


TEXT = [{"type": "text", "text": "hello"}]


async def test_openrouter_until_the_plan_is_chosen(plan):
    engine, client, calls, *_ = plan
    client.responses.append(done("from OpenRouter"))
    assert engine.engine == "openrouter"
    assert await engine.ask("Be brief.", TEXT, 500) == "from OpenRouter"
    assert client.requests[0]["model"] == "smart" and calls() == []


async def test_the_plan_writes_with_sonnet_and_haiku_and_its_usage_is_kept(plan):
    engine, client, calls, *_ = plan
    engine.set_engine("claude")
    assert await engine.ask("Be brief.", TEXT, 500, fast=True) == "ok from haiku"
    assert await engine.ask("Write.", TEXT, 16000) == "ok from sonnet"
    first = calls()[0]
    args = first["args"]
    assert args[args.index("--system-prompt") + 1] == "Be brief." and args[args.index("--tools") + 1] == ""
    assert "--no-session-persistence" in args and "--bare" not in args  # --bare would skip the plan's login
    assert first["key"] is None and first["max"] == "500"  # never an API key: it would bill the key, not the plan
    assert first["content"] == TEXT and first["cwd"].endswith("work")
    assert engine.usage == {"five_hour": {"used": 0.25, "resets_at": "2026-10-22T09:20:00Z"},
                            "seven_day": {"used": 0.5, "resets_at": "2026-10-23T11:00:00Z"}}
    assert client.requests == []


async def test_at_the_limit_a_job_waits_for_the_user_then_finishes_on_openrouter(plan):
    engine, client, calls, limit, _, _ = plan
    engine.set_engine("claude")
    resets = limit(3600)
    asked = []

    async def on_pause(paused):
        asked.append(paused)
    engine.on_pause = on_pause
    client.responses += [done("one from OpenRouter"), done("two from OpenRouter"), done("three")]
    course_var.set(5)
    first = asyncio.create_task(engine.ask("Write.", TEXT, 1000))
    await until(lambda: asked)
    second = asyncio.create_task(engine.ask("Write.", TEXT, 1000))  # a topic written alongside waits too
    await asyncio.sleep(0.2)
    assert len(asked) == 1 and not first.done() and not second.done()
    assert asked[0]["course"] == 5 and asked[0]["window"] == "five_hour"
    assert asked[0]["resets_at"] == resets.isoformat().replace("+00:00", "Z")
    assert engine.status()["paused"] == asked[0] and engine.usage["five_hour"]["used"] == 1.0
    assert client.requests == []  # nothing spent before the user says so

    engine.decide("openrouter")
    assert {await first, await second} == {"one from OpenRouter", "two from OpenRouter"}
    assert engine.status()["paused"] is None and engine.status()["openrouter_until"] is not None
    tried = len(calls())
    assert await engine.ask("Write.", TEXT, 1000) == "three"  # until the reset, the plan isn't tried
    assert len(calls()) == tried
    with pytest.raises(LookupError):
        engine.decide("wait")


async def test_waiting_tries_the_plan_again_after_the_reset(plan):
    engine, client, calls, limit, unlimit, _ = plan
    engine.set_engine("claude")
    limit(1)
    asked = []

    async def on_pause(paused):
        asked.append(paused)
    engine.on_pause = on_pause
    task = asyncio.create_task(engine.ask("Write.", TEXT, 1000))
    await until(lambda: asked)
    engine.decide("wait")
    unlimit()
    assert await asyncio.wait_for(task, 10) == "ok from sonnet"
    assert client.requests == [] and len(asked) == 1


def test_the_writer_endpoints(plan):
    engine, client, _, _, _, db = plan
    agent = Agent(client, db, ToolRegistry([]), model="m", smart_model="smart", tz=ROME,
                  photos=PhotoStore(engine.workdir / "photos"), delegate=False)
    api = TestClient(create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, engine=engine))
    status = api.get("/v1/writer", headers=AUTH).json()
    assert status == {"engine": "openrouter", "available": True, "usage": None, "paused": None,
                      "openrouter_until": None}
    assert api.put("/v1/writer", json={"engine": "claude"}, headers=AUTH).json()["engine"] == "claude"
    assert api.put("/v1/writer", json={"engine": "gpt"}, headers=AUTH).status_code == 400
    assert api.post("/v1/writer/decide", json={"use": "wait"}, headers=AUTH).status_code == 409
    engine.claude = None
    assert api.put("/v1/writer", json={"engine": "claude"}, headers=AUTH).status_code == 409
