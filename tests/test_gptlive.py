import asyncio
import base64
import json

import pytest
from websockets.asyncio.server import serve

from aide import gptlive
from aide.gptlive import GptLive, LiveError
from aide.livecall import Audio, Closed, Delegation, Heard, Said


async def fake_openai(handler):
    """A local stand-in for GPT-Live's WebSocket; returns (server, url)."""
    server = await serve(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    return server, f"ws://127.0.0.1:{port}"


async def test_the_adapter_speaks_gpt_lives_protocol(monkeypatch):
    got = []

    async def handler(ws):
        got.append(ws.request.headers["Authorization"])
        start = json.loads(await ws.recv())
        got.append(start)
        await ws.send(json.dumps({"type": "session.started", "session": {"id": "sess_1"}}))
        for _ in range(4):
            got.append(json.loads(await ws.recv()))
        for event in ({"type": "session.input_transcript.delta", "delta": "what's on", "start_ms": 0, "end_ms": 400},
                      {"type": "session.delegation.created", "offset_ms": 900,
                       "delegation": {"id": "item_1", "type": "client", "target": "client"}},
                      {"type": "session.output_audio.delta", "delta": base64.b64encode(b"\1\2").decode()},
                      {"type": "session.output_transcript.delta", "delta": "On it"},
                      {"type": "session.usage.updated", "usage": {"seconds": 3}},
                      {"type": "session.closed", "reason": "remote_hangup", "usage": {"seconds": 4}}):
            await ws.send(json.dumps(event))

    server, url = await fake_openai(handler)
    monkeypatch.setattr(gptlive, "URL", url)
    async with server:
        live = await GptLive.open("sk-test", "Be Aide.", "gpt-live-1", "marin")
        assert live.session == "sess_1"
        await live.send_audio(b"\1\2\3")  # odd: the last byte is dropped
        await live.think("Progress: checking.", "item_1")
        await live.answer("item_1", ["Nothing tomorrow."])
        await live.say("Bye")
        events = [e async for e in live.events()]
    assert got[0] == "Bearer sk-test"
    assert got[1]["type"] == "session.start" and got[1]["session"] == {
        "model": "gpt-live-1", "instructions": "Be Aide.",
        "audio": {"format": {"type": "audio/pcm", "rate": 24000}, "output": {"voice": "marin"}},
        "delegation": {"type": "client"}}
    assert [(e["type"], e.get("delegation_id")) for e in got[2:]] == [
        ("session.input_audio.append", None), ("session.thinking.append", "item_1"),
        ("session.commentary.append", "item_1"), ("session.instructions.append", None)]
    assert base64.b64decode(got[2]["audio"]) == b"\1\2" and got[4]["content"] == "Nothing tomorrow."
    assert all(e["event_id"].startswith("evt_") for e in got[1:])
    assert events == [Heard("what's on"), Delegation("item_1"), Audio(b"\1\2"), Said("On it"),
                      Closed("remote_hangup")]
    assert live.seconds == 4


async def test_a_refused_session_is_an_error(monkeypatch):
    async def handler(ws):
        await ws.recv()
        await ws.send(json.dumps({"type": "error", "error": {"code": "invalid_model", "message": "No such model"}}))
        await asyncio.sleep(1)

    server, url = await fake_openai(handler)
    monkeypatch.setattr(gptlive, "URL", url)
    async with server:
        with pytest.raises(LiveError, match="No such model"):
            await GptLive.open("sk-test", "Be Aide.")
