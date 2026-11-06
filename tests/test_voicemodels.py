"""The call voice's client for the Chatterbox service, and Kokoro standing in when it's not there."""

import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from aide.voicemodels import Speaker, VoiceModels


class FakeVoice(BaseHTTPRequestHandler):
    """The service's endpoints: odd-sized chunks of 'audio' for /speak, or a failure."""
    protocol_version = "HTTP/1.1"
    loaded = False
    fail = False
    asked: list = []

    def log_message(self, *args):
        pass

    def _json(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._json({"loaded": FakeVoice.loaded})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        FakeVoice.asked.append((self.path, body))
        if self.path == "/load":
            FakeVoice.loaded = True
            return self._json({})
        if self.path == "/release":
            FakeVoice.loaded = False
            return self._json({})
        if FakeVoice.fail:
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for piece in (b"\x01\x02\x03", b"\x04\x05", b"\x06"):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece))
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")


@pytest.fixture
def service():
    FakeVoice.loaded, FakeVoice.fail, FakeVoice.asked = False, False, []
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeVoice)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


async def collect(gen) -> bytes:
    return b"".join([pcm async for pcm in gen])


def models(url: str) -> VoiceModels:
    voice = VoiceModels(speaker_url=url)

    async def kokoro(text, lang):
        yield b"KK"
    voice._kokoro = kokoro
    return voice


async def test_it_loads_the_service_and_streams_whole_samples(service):
    speaker = Speaker(service)
    assert await speaker.check() and FakeVoice.loaded
    pieces = [pcm async for pcm in speaker.speak("Ciao", "it")]
    assert all(len(p) % 2 == 0 for p in pieces) and b"".join(pieces) == b"\x01\x02\x03\x04\x05\x06"
    assert FakeVoice.asked[-1] == ("/speak", {"text": "Ciao", "lang": "it"})


async def test_kokoro_speaks_while_the_service_is_down_or_failing(service):
    voice = models("http://127.0.0.1:9")  # nothing there
    assert not await voice.speaker.check()
    assert await collect(voice.speak("Hello", "en")) == b"KK"

    voice = models(service)
    await voice.speaker.check()
    FakeVoice.fail = True
    assert await collect(voice.speak("Hello", "en")) == b"KK"
    assert not voice.speaker.up  # until the next call checks again
    FakeVoice.fail = False
    assert await voice.speaker.check()
    assert await collect(voice.speak("Hello", "en")) == b"\x01\x02\x03\x04\x05\x06"


async def test_lending_the_gpu_lets_the_service_go_too(service):
    voice = models(service)
    await voice.speaker.check()
    voice._warming = None

    async def lend():
        async with voice.lend():
            assert not FakeVoice.loaded and not voice.speaker.up
    voice.warm = lambda: asyncio.sleep(0)
    await lend()
