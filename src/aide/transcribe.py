"""Speech to text for the app's voice chats: the recording goes to an audio model on OpenRouter, which handles
Italian and English (and both in one sentence) without being told which. The contract is docs/API.md, "Voice"."""

import base64
import time

import httpx

from . import usage
from .config import OPENROUTER_BASE_URL, TRANSCRIBE_MODEL

MAX_BYTES = 10 * 1024 * 1024  # about five minutes of 16 kHz mono WAV
FORMATS = {"audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/mpeg": "mp3", "audio/mp3": "mp3",
           "audio/mp4": "m4a", "audio/m4a": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac"}

PROMPT = ("Transcribe this voice message exactly as spoken, in the language it is spoken in. It is usually Italian "
          "or English, sometimes both in one sentence. Write numbers, times and names the way the speaker would "
          "type them, with normal punctuation. Return only the transcript: no quotes, labels or notes. If there "
          "is no speech, return nothing.")


class Transcriber:
    def __init__(self, api_key: str, model: str = TRANSCRIBE_MODEL, http: httpx.AsyncClient | None = None):
        self.api_key = api_key
        self.model = model
        self.http = http or httpx.AsyncClient(timeout=60)

    async def __call__(self, audio: bytes, fmt: str, language: str | None = None) -> str:
        """The transcript, or "" when nothing was said. httpx.HTTPError when the model can't be reached."""
        hint = f" The speaker's phone is set to {language}." if language else ""
        body = {"model": self.model, "temperature": 0, "messages": [{"role": "user", "content": [
            {"type": "text", "text": PROMPT + hint},
            {"type": "input_audio", "input_audio": {"data": base64.b64encode(audio).decode(), "format": fmt}},
        ]}], "usage": {"include": True}}  # the cost comes back with the answer
        started = time.monotonic()
        r = await self.http.post(f"{OPENROUTER_BASE_URL}/v1/chat/completions", json=body,
                                 headers={"Authorization": f"Bearer {self.api_key}"})
        ms = round((time.monotonic() - started) * 1000)
        if r.is_error:
            usage.record("openrouter", self.model, ms=ms, ok=False, purpose="transcribe")
        r.raise_for_status()
        u = r.json().get("usage") or {}
        usage.record("openrouter", self.model, input=u.get("prompt_tokens") or 0, output=u.get("completion_tokens") or 0,
                     cost=u.get("cost"), ms=ms, purpose="transcribe")
        text = (r.json()["choices"][0]["message"].get("content") or "").strip()
        return text.strip('"\u201c\u201d').strip()
