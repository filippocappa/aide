import asyncio
import base64
import json

import httpx
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.transcribe import Transcriber
from test_api import AUTH, ROME, TOKEN, FakeCalendar, FakeClient


def make(handler=None):
    db = Database(":memory:")
    agent = Agent(FakeClient(()), db, ToolRegistry([]), model="m", tz=ROME)
    transcriber = None
    if handler:
        transcriber = Transcriber("key", "audio-model", httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    return TestClient(create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN,
                                 transcriber=transcriber))


def reply(text):
    return httpx.Response(200, json={"choices": [{"message": {"role": "assistant", "content": text}}]})


def test_sends_the_audio_to_the_model_and_returns_the_text():
    seen = []
    def handler(request):
        seen.append(request)
        return reply(' "Domani alle 9 ho il dentista, remind me the day before." ')
    client = make(handler)
    r = client.post("/v1/transcribe?language=it-IT", content=b"RIFF-audio",
                    headers={**AUTH, "Content-Type": "audio/wav"})
    assert r.status_code == 200
    assert r.json() == {"text": "Domani alle 9 ho il dentista, remind me the day before."}
    body = json.loads(seen[0].content)
    assert seen[0].url.path == "/api/v1/chat/completions"
    assert seen[0].headers["authorization"] == "Bearer key"
    assert body["model"] == "audio-model"
    text, audio = body["messages"][0]["content"]
    assert "it-IT" in text["text"]
    assert audio == {"type": "input_audio", "input_audio": {"data": base64.b64encode(b"RIFF-audio").decode(),
                                                            "format": "wav"}}


def test_silence_is_an_empty_transcript():
    client = make(lambda request: reply(""))
    r = client.post("/v1/transcribe", content=b"x", headers={**AUTH, "Content-Type": "audio/mp4"})
    assert r.json() == {"text": ""}


def test_bad_requests():
    client = make(lambda request: reply("hi"))
    assert client.post("/v1/transcribe", content=b"x", headers={"Content-Type": "audio/wav"}).status_code == 401
    assert client.post("/v1/transcribe", content=b"x", headers={**AUTH, "Content-Type": "text/plain"}).status_code == 415
    assert client.post("/v1/transcribe", content=b"", headers={**AUTH, "Content-Type": "audio/wav"}).status_code == 400
    big = b"0" * (10 * 1024 * 1024 + 1)
    assert client.post("/v1/transcribe", content=big, headers={**AUTH, "Content-Type": "audio/wav"}).status_code == 413


def test_off_without_a_key_and_upstream_errors_are_502():
    r = make().post("/v1/transcribe", content=b"x", headers={**AUTH, "Content-Type": "audio/wav"})
    assert r.status_code == 503
    r = make(lambda request: httpx.Response(500)).post(
        "/v1/transcribe", content=b"x", headers={**AUTH, "Content-Type": "audio/wav"})
    assert r.status_code == 502 and r.json() == {"error": "couldn't transcribe that, try again"}
