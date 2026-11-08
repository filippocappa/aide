"""Who answers a message for Aide (#59): one small call to the fast model before any agent runs.

Aide always delegates, so a message to it mostly costs an Aide round that only calls `ask_agent`, the specialist's
turn, and an Aide round that passes the answer on. The router picks the specialist first, and when it's sure enough
(THRESHOLD) that specialist answers the user directly. Anything else, Aide answers as before.

Two kinds of model: TypeSafe's Jev (`typesafe/…`, the default with an OpenRouter key), a decision model that returns a
choice with a probability per agent in ~0.2 s through OpenRouter's decisions endpoint; or a chat model (Haiku) asked
for JSON through the Anthropic SDK, ~0.9 s, whose `p` is its own guess.

It fails open: a timeout (BUDGET), an HTTP error or an answer that doesn't check out is no pick, never a failed turn.
Each call leaves a row in `routes` (no message text): what it picked, how sure, how long, and whether it was used,
so the threshold can be checked against real traffic. Its cost is in the usage ledger under `purpose` "route".
"""

import asyncio
import json
import logging
import re
import sqlite3
import time
from dataclasses import dataclass
from datetime import timedelta

import httpx

from . import usage
from .agents import AGENTS, ORCHESTRATOR, SPECIALISTS
from .db import utcnow

log = logging.getLogger(__name__)

BUDGET = 1.5  # seconds the router may take; past it Aide answers
THRESHOLD = 0.6  # how sure it must be of a specialist
KEEP = timedelta(days=90)
CONTEXT = 6  # earlier messages it reads
DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"  # decision models (alpha: the shape may change)

# Aide's own work, besides anything that needs more than one specialist.
GENERAL = ("chat, opinions, general knowledge, web search, finding a place or a product, booking, buying or ordering "
           "something on a website, memory, routines, settings")

# What each one does, for the router only (the agents' own prompts are long). An agent added to agents.py without a
# line here is never picked: Aide still reaches it through ask_agent.
SCOPES = {
    "secretary": "calendar and events, reminders and to-dos, mail (reading, drafting replies), trams and buses "
                 "(GTT), leaving for an event, weather, travel times",
    "professor": "university study: courses, lectures and their notes, notebooks, quizzes and flashcards, practice "
                 "and mock exams, exam dates and sign-ups (Esse3), study plans and review sessions (it puts them in the "
                 "calendar itself), focus sessions, course files, explaining course material",
    "coach": "sleep, bedtime and recovery, workouts and training, food and meals (logging, calories, targets), "
             "weight, habits and streaks, Apple Health numbers, Screen Time locks and app limits",
    "finance": "money: payments and spending, categories and budget, subscriptions, bank accounts and balances, "
               "purchases",
}

PROMPT = """You route a message the user sent to their personal assistant, Aide, which leads a team of specialists. \
Pick who should answer it.

The specialists:
{agents}

Pick "aide" when the message needs more than one specialist, when it's general ({general}), or when you can't tell. \
A short follow-up ("and tomorrow?", "yes", "the second one") goes to whoever the conversation was with.

Reply with JSON only, no other text: {{"agent": "<one of: {ids}>", "p": <0 to 1, how sure you are>}}"""


@dataclass(frozen=True)
class Pick:
    agent: str
    p: float


class Router:
    def __init__(self, client, model: str, conn: sqlite3.Connection, budget: float = BUDGET,
                 threshold: float = THRESHOLD, key: str | None = None, http: httpx.AsyncClient | None = None):
        self.client = client  # the Anthropic SDK through OpenRouter, as the agents use (chat models)
        self.model = model
        self.key = key  # the OpenRouter key, for a decision model
        self.http = http
        self.conn = conn
        self.budget = budget
        self.threshold = threshold
        self.agents = tuple(a for a in SPECIALISTS if a in SCOPES)
        self.system = PROMPT.format(
            agents="\n".join(f"- {a}: {AGENTS[a].name}, {SCOPES[a]}" for a in self.agents),
            ids=", ".join((ORCHESTRATOR, *self.agents)), general=GENERAL)
        criteria = {a: f"{AGENTS[a].name}: the message is about {SCOPES[a]}." for a in self.agents}
        criteria[ORCHESTRATOR] = (f"Aide: the message needs more than one specialist, or is general ({GENERAL}), or "
                                  "it's unclear.")
        self.question = {"agent": {
            "type": "choice", "criteria": criteria,
            "instructions": "The user sent the new message to their personal assistant, Aide, which leads a team of "
                            "specialists. Who should answer it? A short follow-up (\"and tomorrow?\", \"yes\", \"the "
                            "second one\") goes to whoever the conversation was with."}}
        conn.execute("""CREATE TABLE IF NOT EXISTS routes (
            id INTEGER PRIMARY KEY, at TEXT NOT NULL, place TEXT NOT NULL, agent TEXT, p REAL, ms INTEGER NOT NULL,
            used INTEGER NOT NULL DEFAULT 0, error TEXT)""")
        conn.execute("DELETE FROM routes WHERE at < ?", ((utcnow() - KEEP).isoformat(),))
        conn.commit()

    async def pick(self, text: str, context: list[str], photos: int = 0, place: str = "chat") -> Pick | None:
        """The specialist to answer `text`, or None for Aide (unsure, Aide's own work, or the router failed).
        `context`: the conversation's last messages as "User: …" / "Aide: …" lines, oldest first. `place`: "chat"
        (Aide's chat) or "team" (the Team chat), for the log."""
        started = time.monotonic()
        found: Pick | None = None
        error = None
        try:
            async with asyncio.timeout(self.budget):
                found = await self._ask(text, context, photos)
        except TimeoutError:
            error = "timeout"
        except Exception as e:  # an HTTP error, a refusal: Aide answers
            error = type(e).__name__
            log.warning("router failed: %s", e)
        ms = round((time.monotonic() - started) * 1000)
        used = found is not None and found.agent != ORCHESTRATOR and found.p >= self.threshold
        if found is None and error is None:
            error = "bad answer"
        try:
            self.conn.execute("INSERT INTO routes (at, place, agent, p, ms, used, error) VALUES (?, ?, ?, ?, ?, ?, ?)",
                              (utcnow().isoformat(), place, found.agent if found else None,
                               found.p if found else None, ms, int(used), error))
            self.conn.commit()
        except sqlite3.Error:
            log.exception("router: could not log the pick")
        log.info("route (%s): %s in %d ms%s", place,
                 f"{found.agent} {found.p:.2f}" if found else "none", ms, f" ({error})" if error else "")
        return found if used else None

    @property
    def decides(self) -> bool:
        """A decision model (Jev), not a chat model."""
        return self.model.startswith("typesafe/")

    async def _ask(self, text: str, context: list[str], photos: int) -> Pick | None:
        if self.decides:
            return await self._decide(text, context, photos)
        lines = "\n".join(context[-CONTEXT:]) or "(none)"
        sent = f" [and {photos} photo{'s' if photos != 1 else ''}]" if photos else ""
        message = f"The conversation so far:\n{lines}\n\nThe new message:\n{text.strip()[:2000] or '(no text)'}{sent}"
        with usage.labels(purpose="route"):
            response = await self.client.beta.messages.create(
                model=self.model, max_tokens=120, system=self.system, thinking={"type": "disabled"},
                messages=[{"role": "user", "content": message}])
        answer = "".join(b.text for b in response.content if b.type == "text")
        return self.parse(answer)

    async def _decide(self, text: str, context: list[str], photos: int) -> Pick | None:
        """A decision model's choice: the agent it picks and the probability it gives that agent."""
        message = text.strip()[:2000] or "(no text)"
        if photos:
            message += f" [and {photos} photo{'s' if photos != 1 else ''}]"
        body = {"model": self.model, "questions": self.question,
                "state": {"conversation_so_far": context[-CONTEXT:] or "(none)", "new_message": message}}
        if self.http is None:
            self.http = httpx.AsyncClient(timeout=self.budget + 1)
        started = time.monotonic()
        response = await self.http.post(DECISIONS_URL, json=body, headers={"Authorization": f"Bearer {self.key}"})
        response.raise_for_status()
        data = response.json()
        spent = data.get("usage") or {}
        usage.record("openrouter", self.model, input=spent.get("input_tokens") or 0,
                     output=spent.get("output_tokens") or 0, cost=spent.get("cost"),
                     ms=round((time.monotonic() - started) * 1000), purpose="route")
        answer = (data.get("answers") or {}).get("agent") or {}
        agent = str(answer.get("choice") or "").strip().lower()
        try:
            p = float((answer.get("probabilities") or {})[agent])
        except (KeyError, TypeError, ValueError):
            return None
        if agent not in (ORCHESTRATOR, *self.agents) or not 0 <= p <= 1:
            return None
        return Pick(agent, p)

    def parse(self, answer: str) -> Pick | None:
        """The pick in the model's answer, or None when it doesn't check out (not JSON, an agent not offered, no
        probability between 0 and 1). A model that thinks out loud first can run out of tokens before the closing
        brace: the JSON is then closed for it."""
        m = re.search(r"\{.*?(\}|$)", answer, re.S)
        if not m:
            return None
        found = m.group(0) if m.group(1) else m.group(0).rstrip() + "}"
        try:
            data = json.loads(found)
            agent, p = str(data["agent"]).strip().lower(), float(data["p"])
        except (ValueError, KeyError, TypeError):
            return None
        if agent not in (ORCHESTRATOR, *self.agents) or not 0 <= p <= 1:
            return None
        return Pick(agent, p)
