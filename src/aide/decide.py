"""Decision models: TypeSafe's Jev (`typesafe/jev-1.13`) through OpenRouter's decisions endpoint.

A decision model doesn't write: given a state (any JSON) and a choice question (each option with a line saying when
it's the one), it returns the option it picks and a probability for each, in ~0.2 s for a fraction of a cent. Used by
the router (who answers a message, router.py) and by the marker of written study answers (quiz.mark).

The endpoint is alpha (`/api/alpha/decisions`): its shape may change. Callers treat any failure as no decision and
go on without one. Each call is in the usage ledger, under the caller's purpose.
"""

import logging
import time
from dataclasses import dataclass

import httpx

from . import usage

log = logging.getLogger(__name__)

URL = "https://openrouter.ai/api/alpha/decisions"
MODEL = "typesafe/jev-1.13"


@dataclass(frozen=True)
class Decision:
    choice: str  # one of the criteria's keys
    p: float  # the probability it gives that choice


class Decider:
    def __init__(self, key: str, model: str = MODEL, http: httpx.AsyncClient | None = None, timeout: float = 5.0):
        self.key = key  # the OpenRouter key
        self.model = model
        self.http = http
        self.timeout = timeout

    async def choose(self, criteria: dict[str, str], instructions: str, state: dict, name: str = "answer",
                     purpose: str | None = None) -> Decision | None:
        """The option picked from `criteria` ({option: when it's the one}) for `state`, or None when the answer
        doesn't check out (a refusal, an option not offered, no probability). HTTP errors are raised."""
        body = {"model": self.model, "state": state,
                "questions": {name: {"type": "choice", "criteria": criteria, "instructions": instructions}}}
        if self.http is None:
            self.http = httpx.AsyncClient(timeout=self.timeout)
        started = time.monotonic()
        response = await self.http.post(URL, json=body, headers={"Authorization": f"Bearer {self.key}"})
        response.raise_for_status()
        data = response.json()
        spent = data.get("usage") or {}
        usage.record("openrouter", self.model, input=spent.get("input_tokens") or 0,
                     output=spent.get("output_tokens") or 0, cost=spent.get("cost"),
                     ms=round((time.monotonic() - started) * 1000), purpose=purpose)
        answer = (data.get("answers") or {}).get(name) or {}
        said = str(answer.get("choice") or "").strip()
        choice = said if said in criteria else next((c for c in criteria if c.lower() == said.lower()), None)
        try:
            p = float((answer.get("probabilities") or {})[said])
        except (KeyError, TypeError, ValueError):
            return None
        if choice is None or not 0 <= p <= 1:
            return None
        return Decision(choice, p)
