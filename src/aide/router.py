"""Who answers a message for Aide (#59): one small call to the fast model before any agent runs.

Aide always delegates, so a message to it mostly costs an Aide round that only calls `ask_agent`, the specialist's
turn, and an Aide round that passes the answer on. The router picks the specialist first, and when it's sure enough
(THRESHOLD) that specialist answers the user directly. Anything else, Aide answers as before.

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

from . import usage
from .agents import AGENTS, ORCHESTRATOR, SPECIALISTS
from .db import utcnow

log = logging.getLogger(__name__)

BUDGET = 1.5  # seconds the router may take; past it Aide answers
THRESHOLD = 0.6  # how sure it must be of a specialist
KEEP = timedelta(days=90)
CONTEXT = 6  # earlier messages it reads

# What each one does, for the router only (the agents' own prompts are long). An agent added to agents.py without a
# line here is never picked: Aide still reaches it through ask_agent.
SCOPES = {
    "secretary": "calendar and events, reminders and to-dos, mail (reading, drafting replies), trams and buses "
                 "(GTT), leaving for an event, weather, places and travel times",
    "professor": "university study: courses, lectures and their notes, notebooks, quizzes and flashcards, practice "
                 "and mock exams, exam dates and sign-ups (Esse3), study plans and review sessions, focus sessions, "
                 "course files, explaining course material",
    "coach": "sleep, bedtime and recovery, workouts and training, food and meals (logging, calories, targets), "
             "weight, habits and streaks, Apple Health numbers, Screen Time locks and app limits",
    "finance": "money: payments and spending, categories and budget, subscriptions, bank accounts and balances, "
               "purchases",
}

PROMPT = """You route a message the user sent to their personal assistant, Aide, which leads a team of specialists. \
Pick who should answer it.

The specialists:
{agents}

Pick "aide" when the message needs more than one specialist, when it's general (chat, opinions, general knowledge, \
web search, a place or a product, memory, routines, settings), or when you can't tell. A short follow-up ("and \
tomorrow?", "yes", "the second one") goes to whoever the conversation was with.

Reply with JSON only, no other text: {{"agent": "<one of: {ids}>", "p": <0 to 1, how sure you are>}}"""


@dataclass(frozen=True)
class Pick:
    agent: str
    p: float


class Router:
    def __init__(self, client, model: str, conn: sqlite3.Connection, budget: float = BUDGET,
                 threshold: float = THRESHOLD):
        self.client = client  # the Anthropic SDK through OpenRouter, as the agents use
        self.model = model
        self.conn = conn
        self.budget = budget
        self.threshold = threshold
        self.agents = tuple(a for a in SPECIALISTS if a in SCOPES)
        self.system = PROMPT.format(
            agents="\n".join(f"- {a}: {AGENTS[a].name}, {SCOPES[a]}" for a in self.agents),
            ids=", ".join((ORCHESTRATOR, *self.agents)))
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

    async def _ask(self, text: str, context: list[str], photos: int) -> Pick | None:
        lines = "\n".join(context[-CONTEXT:]) or "(none)"
        sent = f" [and {photos} photo{'s' if photos != 1 else ''}]" if photos else ""
        message = f"The conversation so far:\n{lines}\n\nThe new message:\n{text.strip()[:2000] or '(no text)'}{sent}"
        with usage.labels(purpose="route"):
            response = await self.client.beta.messages.create(
                model=self.model, max_tokens=60, system=self.system, thinking={"type": "disabled"},
                messages=[{"role": "user", "content": message}])
        answer = "".join(b.text for b in response.content if b.type == "text")
        return self.parse(answer)

    def parse(self, answer: str) -> Pick | None:
        """The pick in the model's answer, or None when it doesn't check out (not JSON, an agent not offered, no
        probability between 0 and 1)."""
        m = re.search(r"\{.*?\}", answer, re.S)
        if not m:
            return None
        try:
            data = json.loads(m.group(0))
            agent, p = str(data["agent"]).strip().lower(), float(data["p"])
        except (ValueError, KeyError, TypeError):
            return None
        if agent not in (ORCHESTRATOR, *self.agents) or not 0 <= p <= 1:
            return None
        return Pick(agent, p)
