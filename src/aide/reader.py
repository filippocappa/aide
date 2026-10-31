"""The photo reader: a vision model on OpenRouter writes what a turn's photos show for an agent that reads photos
(Coach), which then works from those lines on the everyday model (Agent._describe). Gemini Flash was picked on
17 of the user's meal photos (2026-10-31, #29): as close to what was logged as GPT-6 Luna and closer than Sonnet,
in 2-4 s, for about $0.0015 a read; Sonnet's long notes also ran out before a label's nutrition table."""

import base64
import time

import httpx

from . import usage
from .config import OPENROUTER_BASE_URL, PHOTO_READ_MODEL


class PhotoReader:
    def __init__(self, api_key: str, model: str = PHOTO_READ_MODEL, http: httpx.AsyncClient | None = None):
        self.api_key = api_key
        self.model = model
        self.http = http

    async def __call__(self, system: str, images: list[tuple[bytes, str]], text: str, max_tokens: int) -> str:
        """What the model saw, or "". httpx.HTTPError (or KeyError on an odd answer) when it can't be had."""
        body = {"model": self.model, "max_tokens": max_tokens, "reasoning": {"effort": "low"},
                "usage": {"include": True},  # the cost comes back with the answer
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": [
                    *({"type": "image_url", "image_url": {"url": f"data:{kind};base64,{base64.b64encode(data).decode()}"}}
                      for data, kind in images),
                    {"type": "text", "text": text}]}]}
        started = time.monotonic()
        try:
            # A client of its own per read unless one was given: the app's requests can run on different loops.
            async with httpx.AsyncClient(timeout=60) if self.http is None else _Borrowed(self.http) as http:
                r = await http.post(f"{OPENROUTER_BASE_URL}/v1/chat/completions", json=body,
                                    headers={"Authorization": f"Bearer {self.api_key}"})
            r.raise_for_status()
            answer = r.json()
            message = answer["choices"][0]["message"]
        except Exception:
            usage.record("openrouter", self.model, ms=round((time.monotonic() - started) * 1000), ok=False)
            raise
        u = answer.get("usage") or {}
        usage.record("openrouter", self.model, input=u.get("prompt_tokens") or 0,
                     output=u.get("completion_tokens") or 0, cost=u.get("cost"),
                     ms=round((time.monotonic() - started) * 1000))
        return (message.get("content") or "").strip()


class _Borrowed:
    """A given client as a context manager that leaves it open."""

    def __init__(self, http: httpx.AsyncClient):
        self.http = http

    async def __aenter__(self) -> httpx.AsyncClient:
        return self.http

    async def __aexit__(self, *exc) -> None:
        pass
