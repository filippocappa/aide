"""OpenAI's GPT-Live as a live call's voice (livecall.LiveVoice), over its primary WebSocket with client
delegation: it listens and speaks; our agents answer what it hands over.

The protocol (developers.openai.com, "GPT-Live", read 2026-11-06): connect to wss://api.openai.com/v1/live/sessions
with the API key, send `session.start` with the model, voice, audio format and instructions, wait for
`session.started`. Then audio goes both ways as base64 PCM16 (`session.input_audio.append`,
`session.output_audio.delta`); the words come as pieces (`session.input_transcript.delta`,
`session.output_transcript.delta`); `session.delegation.created` hands a request over (an id, no words), answered
with `session.commentary.append` (said aloud) and kept company with `session.thinking.append` (silent). Appends take
at most 500 tokens each. `session.closed` ends it."""

import asyncio
import base64
import json
import logging
import secrets
from typing import AsyncIterator

from websockets.asyncio.client import ClientConnection, connect

from .livecall import Audio, Closed, Delegation, Event, Heard, Said

log = logging.getLogger(__name__)

URL = "wss://api.openai.com/v1/live/sessions"
MODEL = "gpt-live-1"
VOICE = "marin"
RATE = 24000


class LiveError(Exception):
    pass


class GptLive:
    rate = RATE
    provider, price_minute = "openai", 0.05  # gpt-live-1, billed by the second (2026-11)

    def __init__(self, ws: ClientConnection):
        self.ws = ws
        self.model = MODEL
        self.seconds = 0.0
        self.session: str | None = None
        self._send_lock = asyncio.Lock()

    @classmethod
    async def open(cls, key: str, instructions: str, model: str = MODEL, voice: str = VOICE) -> "GptLive":
        ws = await connect(URL, additional_headers={"Authorization": f"Bearer {key}"}, max_size=None,
                           open_timeout=10)
        live = cls(ws)
        live.model = model
        try:
            await live._send({"type": "session.start", "session": {
                "model": model, "instructions": instructions,
                "audio": {"format": {"type": "audio/pcm", "rate": RATE}, "output": {"voice": voice}},
                "delegation": {"type": "client"},
            }})
            async with asyncio.timeout(10):
                while True:
                    event = json.loads(await ws.recv())
                    if event["type"] == "session.started":
                        live.session = event.get("session", {}).get("id")
                        log.info("GPT-Live session %s started", live.session)
                        return live
                    if event["type"] == "error":
                        raise LiveError(event.get("error", {}).get("message") or "GPT-Live refused the session")
        except BaseException:
            await ws.close()
            raise

    async def _send(self, event: dict) -> None:
        event.setdefault("event_id", f"evt_{secrets.token_hex(8)}")
        async with self._send_lock:
            await self.ws.send(json.dumps(event))

    async def send_audio(self, pcm: bytes) -> None:
        if len(pcm) % 2:
            pcm = pcm[:-1]
        if pcm:
            await self._send({"type": "session.input_audio.append", "audio": base64.b64encode(pcm).decode()})

    async def think(self, text: str, delegation: str | None = None) -> None:
        await self._send({"type": "session.thinking.append", "delegation_id": delegation, "content": text})

    async def answer(self, delegation: str, pieces: list[str]) -> None:
        for piece in pieces:
            await self._send({"type": "session.commentary.append", "delegation_id": delegation, "content": piece})

    async def say(self, text: str) -> None:
        await self._send({"type": "session.instructions.append", "delegation_id": None,
                          "content": f"Say this to the user now, briefly, in your own words: {text}"})

    async def events(self) -> AsyncIterator[Event]:
        async for message in self.ws:
            if isinstance(message, bytes):
                continue
            event = json.loads(message)
            match event.get("type"):
                case "session.output_audio.delta":
                    yield Audio(base64.b64decode(event["delta"]))
                case "session.input_transcript.delta":
                    yield Heard(event.get("delta") or "")
                case "session.output_transcript.delta":
                    yield Said(event.get("delta") or "")
                case "session.delegation.created":
                    yield Delegation(event["delegation"]["id"])
                case "session.usage.updated":
                    self.seconds = float((event.get("usage") or {}).get("seconds") or self.seconds)
                case "session.closed":
                    self.seconds = float((event.get("usage") or {}).get("seconds") or self.seconds)
                    yield Closed(event.get("reason") or "closed")
                    return
                case "error":
                    error = event.get("error") or {}
                    log.warning("GPT-Live error %s: %s", error.get("code"), error.get("message"))
                case "info":
                    log.info("GPT-Live: %s", event.get("message"))

    async def close(self) -> None:
        try:
            await self._send({"type": "session.close"})
            async with asyncio.timeout(5):
                async for message in self.ws:  # let it drain to session.closed
                    if isinstance(message, str) and '"session.closed"' in message:
                        event = json.loads(message)
                        self.seconds = float((event.get("usage") or {}).get("seconds") or self.seconds)
                        break
        except Exception:
            pass
        finally:
            await self.ws.close()
