"""Live calls (#34): a realtime voice model does the listening and the speaking, and the agents still do the work.

Each request the voice hands over (a delegation) becomes an ordinary chat turn by voice (Agent.respond), with the
chat's agent, tools, memory and confirm queue. While it runs the voice gets private notes (the step it's on, still
working); then it reads the answer back in the first person. A yes or no to what the turn queued is decided here in
code (consent.py), and so is a goodbye. The chat keeps the spoken requests and the replies as normal turns, and one
row for the call (`calls`).

The voice model sits behind `LiveVoice` (gptlive.py is OpenAI's GPT-Live); this file doesn't know which it is. It
tells us only the words as it writes them down, in pieces, and that a request was handed over (no words with it, no
end of an utterance, no interruptions): those are worked out here from the pieces and the quiet between them."""

import asyncio
import logging
import re
import time
from dataclasses import dataclass, field
from typing import AsyncIterator, Awaitable, Callable, Protocol

from . import usage
from .agent import CONVERSATION, PENDING_TTL, Agent, Turn
from .consent import spoken_consent, spoken_goodbye
from .db import utcnow

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS calls (
    id INTEGER PRIMARY KEY,
    conversation TEXT NOT NULL,
    agent TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    seconds INTEGER,
    reason TEXT,
    requests INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS calls_conversation ON calls (conversation, started_at);
"""

# Money and messages that leave are confirmed on the screen only, never by a spoken yes.
SCREEN_ONLY = {"errand_go", "errand_drop", "send_mail", "reply_mail", "send_draft"}
PIECE_CHARS = 1200  # one append to the voice (its limit is 500 tokens)
PIECES = 3  # a longer answer is cut and ends with "The rest is in the chat."
SETTLE = 0.7  # quiet after the last words that ends an utterance
GRACE = 1.5  # how long a request waits for its first words to be written down
CONSENT_QUIET = 1.2  # a yes or no the voice didn't hand over is read after this much quiet
STATUS_EVERY = 30.0  # a "still working" note while a turn runs
PROGRESS_EVERY = 4.0  # at most one step note this often
GOODBYE_SECONDS = 4.0  # the voice says goodbye, then the call ends
IDLE_TICK = 15.0
PRICE_MINUTE = 0.05  # gpt-live-1, billed by the second (OpenAI, 2026-11)


# -- what the voice model sends ------------------------------------------------------------------------------------

@dataclass
class Audio:
    pcm: bytes  # PCM16 mono at LiveVoice.rate


@dataclass
class Heard:
    """A piece of the user's words as the voice model writes them down."""
    text: str


@dataclass
class Said:
    """A piece of the voice's own words as it speaks them."""
    text: str


@dataclass
class Delegation:
    """The voice hands a request over; its words are what was heard since the last one."""
    id: str


@dataclass
class Closed:
    reason: str


Event = Audio | Heard | Said | Delegation | Closed


class LiveVoice(Protocol):
    rate: int  # sample rate of the PCM16 mono audio, both ways
    seconds: float  # billed so far, as the provider counts it (0 when it doesn't say)

    async def send_audio(self, pcm: bytes) -> None: ...

    async def think(self, text: str, delegation: str | None = None) -> None:
        """A private note to the voice: what's going on. It isn't read out."""

    async def answer(self, delegation: str, pieces: list[str]) -> None:
        """The result of a delegation, read back in the first person."""

    async def say(self, text: str) -> None:
        """Have the voice say this now, unprompted (a result nobody handed over, hanging up)."""

    def events(self) -> AsyncIterator[Event]: ...

    async def close(self) -> None: ...


# Opens a voice for a call: (instructions) -> a connected LiveVoice.
Connect = Callable[[str], Awaitable[LiveVoice]]


# -- the call's record ---------------------------------------------------------------------------------------------

class CallStore:
    def __init__(self, conn):
        self.conn = conn
        conn.executescript(SCHEMA)

    def start(self, conversation: str, agent: str) -> int:
        with self.conn:
            return self.conn.execute("INSERT INTO calls (conversation, agent, started_at) VALUES (?, ?, ?)",
                                     (conversation, agent, utcnow().isoformat())).lastrowid

    def end(self, call_id: int, seconds: float, reason: str, requests: int) -> None:
        with self.conn:
            self.conn.execute("UPDATE calls SET ended_at = ?, seconds = ?, reason = ?, requests = ? WHERE id = ?",
                              (utcnow().isoformat(), round(seconds), reason, requests, call_id))

    def since(self, conversation: str, since: str | None = None) -> list[dict]:
        """The chat's calls that ended from `since` on (all of them without it), oldest first."""
        rows = self.conn.execute("SELECT * FROM calls WHERE conversation = ? AND ended_at >= ? ORDER BY started_at",
                                 (conversation, since or "")).fetchall()
        return [call_json(r) for r in rows]


def call_json(r) -> dict:
    return {"id": r["id"], "agent": r["agent"], "started_at": r["started_at"], "ended_at": r["ended_at"],
            "seconds": r["seconds"], "reason": r["reason"], "requests": r["requests"]}


# -- words for the voice -------------------------------------------------------------------------------------------

def speakable(text: str) -> str:
    """A chat reply as words to say: no markdown, links or ids, list lines as sentences."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)  # [label](url) -> label
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"^\s*#+\s*", "", text, flags=re.M)
    text = re.sub(r"^\s*(?:[-*•]|\d+[.)])\s+", "", text, flags=re.M)
    text = re.sub(r"[*_`|>]+", "", text)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return " ".join(line if line[-1] in ".!?:;," else line + "." for line in lines)


def pieces(text: str) -> list[str]:
    """The answer in up to PIECES pieces of PIECE_CHARS, cut between sentences (or words); a longer one is cut and
    ends with a pointer to the chat."""
    rest = " The rest is in the chat."
    out, current = [], ""
    for sentence in re.split(r"(?<=[.!?])\s+", text.strip()):
        while len(sentence) > PIECE_CHARS:  # one sentence too long for a piece: cut it at a word
            cut = sentence[:PIECE_CHARS].rsplit(" ", 1)[0] or sentence[:PIECE_CHARS]
            if current:
                out.append(current)
                current = ""
            out.append(cut)
            sentence = sentence[len(cut):].strip()
        joined = f"{current} {sentence}".strip()
        if len(joined) <= PIECE_CHARS:
            current = joined
        else:
            out.append(current)
            current = sentence
    if current:
        out.append(current)
    if len(out) > PIECES:
        out = out[:PIECES]
        last = out[-1]
        while len(last) + len(rest) > PIECE_CHARS:
            last = last.rsplit(" ", 1)[0]
        out[-1] = last + rest
    return out


def instructions(agent_name: str, recent: list[dict]) -> str:
    """The voice's standing instructions: who it is, when to hand over, how to wait, and the chat so far."""
    lines = []
    for m in recent:
        who = "User" if m["role"] == "user" else agent_name
        if text := " ".join((m.get("text") or "").split())[:400]:
            lines.append(f"{who}: {text}")
    chat = "\n".join(lines) or "(nothing yet)"
    return f"""You are {agent_name}, the user's personal assistant, on a voice call with them. Speak in the first \
person as {agent_name}. You are only the voice: an assistant behind you has the calendar, reminders, mail, study \
notes, health, money and every tool, and does the work.

# Handing over
- Delegate every request, question or answer to the assistant, even small ones, and every reply to a question you \
asked for it (a yes or a no, a choice, a time, a quiz answer). Never answer from what you know or guess: you don't \
have the user's data.
- Only greetings, thanks and "can you hear me" you answer yourself.
- While it works, say at most a short "on it" or "one moment"; don't fill the silence and don't guess the result. If \
the user asks how it's going, say what the last note told you.

# Reading back
- Say the result in your own voice, short and natural, as if you did it ("I've added it", "You've got two things \
tomorrow"). Don't read lists word for word: say the gist. Don't spell out links or ids.
- A quiz question: read it and its options exactly, then stop and wait.
- If the result asks the user something, ask it and stop.

# Talking
- Speak the language the user speaks (Italian or English; they mix them). Short turns. If they talk over you, stop \
and listen.
- Never say a thing is done before the assistant says it is. A yes or no to an action is the assistant's to read: \
delegate it.

# The chat so far
{chat}"""


# -- the call ------------------------------------------------------------------------------------------------------

@dataclass
class Utterance:
    text: str = ""
    started: float = 0.0  # monotonic
    last: float = 0.0
    echo: bool = False  # it started while the voice was talking
    delegated: bool = False  # a delegation took it
    acted: str | None = None  # what the call did with it on its own ("goodbye", "consent")


@dataclass
class Ears:
    """The user's words, cut into utterances by the quiet between pieces."""
    utterances: list[Utterance] = field(default_factory=list)
    changed: asyncio.Event = field(default_factory=asyncio.Event)

    def heard(self, text: str, speaking: bool) -> tuple[Utterance, bool]:
        """Add a piece; returns its utterance and whether it began one."""
        now = time.monotonic()
        current = self.utterances[-1] if self.utterances else None
        new = current is None or current.delegated or now - current.last >= SETTLE
        if new:
            current = Utterance(started=now, echo=speaking)
            self.utterances.append(current)
            del self.utterances[:-20]
        current.text += text
        current.last = now
        self.changed.set()
        return current, new

    def waiting(self) -> list[Utterance]:
        return [u for u in self.utterances if not u.delegated and u.text.strip()]

    async def take(self) -> list[Utterance]:
        """The utterances since the last delegation: waits up to GRACE for words, then until they settle."""
        deadline = time.monotonic() + GRACE
        while not self.waiting() and (left := deadline - time.monotonic()) > 0:
            self.changed.clear()
            try:
                await asyncio.wait_for(self.changed.wait(), left)
            except TimeoutError:
                break
        while (waiting := self.waiting()) and (quiet := time.monotonic() - waiting[-1].last) < SETTLE:
            await asyncio.sleep(SETTLE - quiet)
        taken = self.waiting()
        for u in taken:
            u.delegated = True
        return taken


_UNSURE = re.compile(r"\b(?:yes|yeah|ok|okay|sure|si|va bene|certo|fine|alright)\b")


class LiveCall:
    """One call in one chat. `send_json` and `send_audio` go to the phone; run() returns when the call is over."""

    def __init__(self, agent: Agent, voice: LiveVoice, calls: CallStore, conversation: str, agent_id: str,
                 send_json: Callable[[dict], Awaitable[None]], send_audio: Callable[[bytes], Awaitable[None]],
                 on_turn: Callable[[str, Turn], Awaitable[None]] | None = None, idle_minutes: float = 5):
        self.agent, self.voice, self.calls = agent, voice, calls
        self.conversation, self.agent_id = conversation, agent_id
        self.send_json, self.send_audio, self.on_turn = send_json, send_audio, on_turn
        self.idle = idle_minutes * 60
        self.ears = Ears()
        self.awaiting: list[int] = []  # queued actions asked about, waiting for a spoken yes or no
        self.tasks: set[asyncio.Task] = set()
        self.turns = 0  # chat turns running
        self.requests = 0
        self.ended: str | None = None
        self.bye = False
        self.started = time.monotonic()
        self.last_activity = self.started
        self.speaking_until = 0.0  # when the voice's audio sent so far stops playing on the phone
        self._settle: asyncio.Task | None = None
        self._done = asyncio.Event()

    # -- from the phone --

    async def audio_in(self, pcm: bytes) -> None:
        if not self.ended:
            await self.voice.send_audio(pcm)

    async def typed(self, text: str) -> None:
        """Words the app sends for the user ("Quiz me" from Quiz me by voice): a request at once."""
        self.last_activity = time.monotonic()
        self._spawn(self._request(text.strip()))

    async def end(self, reason: str = "hung up") -> None:
        if not self.ended:
            self.ended = reason
            self._done.set()

    # -- the call --

    async def run(self) -> str:
        call_id = self.calls.start(self.conversation, self.agent_id)
        await self._send({"type": "state", "state": "listening"})
        pump = asyncio.create_task(self._pump())
        idle = asyncio.create_task(self._watch_idle())
        try:
            await self._done.wait()
        finally:
            pump.cancel()
            idle.cancel()
            if self._settle:
                self._settle.cancel()
            if running := [t for t in self.tasks if not t.done()]:
                await asyncio.wait(running, timeout=90)  # a turn under way finishes and is saved
            try:
                await self.voice.close()
            except Exception:
                log.warning("live call: closing the voice failed", exc_info=True)
            seconds = self.voice.seconds or time.monotonic() - self.started
            self.calls.end(call_id, seconds, self.ended or "closed", self.requests)
            usage.record("openai", "gpt-live", cost=round(seconds / 60 * PRICE_MINUTE, 4), purpose="live",
                         agent=self.agent_id, conversation=self.conversation, ms=round(seconds * 1000))
            await self._send({"type": "ended", "reason": self.ended or "closed", "seconds": round(seconds)})
            log.info("live call in %s ended (%s) after %d s, %d requests", self.conversation, self.ended,
                     seconds, self.requests)
        return self.ended or "closed"

    async def _send(self, message: dict) -> None:
        try:
            await self.send_json(message)
        except Exception:
            pass  # the phone went; the endpoint ends the call

    def _spawn(self, coro) -> asyncio.Task:
        task = asyncio.create_task(coro)
        self.tasks.add(task)
        task.add_done_callback(self._finished)
        return task

    def _finished(self, task: asyncio.Task) -> None:
        self.tasks.discard(task)
        if not task.cancelled() and (e := task.exception()):
            log.error("live call: a task failed", exc_info=e)

    def _pending(self) -> list[dict]:
        return [a for a in self.agent.db.pending_actions(CONVERSATION, PENDING_TTL)
                if a["conversation"] == self.conversation]

    async def _pump(self) -> None:
        try:
            async for event in self.voice.events():
                await self._event(event)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("live call: the voice failed")
            await self.end("voice failed")
            return
        await self.end("voice closed")

    def _speaking(self) -> bool:
        return time.monotonic() < self.speaking_until

    async def _event(self, event: Event) -> None:
        match event:
            case Audio(pcm):
                now = time.monotonic()
                self.speaking_until = max(now, self.speaking_until) + len(pcm) / 2 / self.voice.rate
                await self.send_audio(pcm)
            case Heard(text):
                speaking = self._speaking()
                utterance, new = self.ears.heard(text, speaking)
                self.last_activity = time.monotonic()
                if new and speaking:
                    # Words over the voice: it stops for them, so what the phone hasn't played yet goes.
                    self.speaking_until = 0.0
                    await self._send({"type": "interrupted"})
                await self._send({"type": "caption", "who": "you", "text": text, "new": new})
                if self._settle:
                    self._settle.cancel()
                self._settle = asyncio.create_task(self._settled(utterance))
            case Said(text):
                await self._send({"type": "caption", "who": self.agent_id, "text": text})
            case Delegation(id):
                self._spawn(self._delegated(id))
            case Closed(reason):
                await self.end(reason)

    async def _settled(self, utterance: Utterance) -> None:
        """An utterance gone quiet: a goodbye ends the call; while a yes or no is awaited, one the voice didn't
        hand over is read here."""
        await asyncio.sleep(SETTLE)
        if utterance.delegated or utterance.acted or utterance.echo:
            return
        if spoken_goodbye(utterance.text):
            utterance.acted = "goodbye"
            self._spawn(self._goodbye())  # the voice says its own goodbye
            return
        if self.awaiting and spoken_consent(utterance.text) is not None:
            await asyncio.sleep(CONSENT_QUIET - SETTLE)
            if not utterance.delegated and self.awaiting:
                utterance.acted = "consent"
                await self.voice.say(await self._consent(utterance.text))

    async def _delegated(self, delegation: str) -> None:
        taken = await self.ears.take()
        words = " ".join(u.text.strip() for u in taken if not u.acted).strip()
        if not words and any(u.acted for u in taken):  # the call already did it (a goodbye, a yes after the quiet)
            await self.voice.think("That was already handled; don't repeat it.", delegation)
            return
        if self.awaiting and not any(u.echo for u in taken):
            if spoken_consent(words) is not None:
                await self.voice.answer(delegation, pieces(await self._consent(words)))
                return
            if len(words.split()) <= 3 and _UNSURE.search(words.lower()):  # "okay", "va bene": not clear enough
                await self.voice.answer(delegation, ["I didn't catch a clear yes or no. Shall I go ahead?"])
                return
        await self._request(words, delegation)

    async def _consent(self, words: str) -> str:
        """Confirm or cancel what's awaited; the words to say."""
        answer = bool(spoken_consent(words))
        ids, self.awaiting = self.awaiting, []
        if answer:
            said = f"Done. {speakable(await self.agent.confirm(CONVERSATION, ids, by_voice=True))}".strip()
        else:
            await self.agent.cancel(CONVERSATION, ids, by_voice=True)
            said = "Okay, I've left it."
        await self._send({"type": "answered", "ids": ids, "confirmed": answer})
        return said

    async def _request(self, words: str, delegation: str | None = None) -> None:
        async def reply(said: str) -> None:
            if delegation:
                await self.voice.answer(delegation, pieces(said))
            else:
                await self.voice.say(said)

        if not words:
            await reply("Sorry, I didn't catch that. Could you say it again?")
            return
        if spoken_goodbye(words):
            await reply("Bye!")
            await self._goodbye()
            return
        self.awaiting = []  # asked something else instead: the card stays on the screen to tap
        self.requests += 1
        before = {a["id"] for a in self._pending()}
        turn = await self._turn(words, delegation)
        if turn is None:
            await reply("Something went wrong on my side, sorry. It didn't work.")
            return
        if self.on_turn:
            await self.on_turn(words, turn)
        queued = [a for a in self._pending() if a["id"] not in before]
        said = speakable(turn.reply) or "Done, it's in the chat."
        if any(a["tool"] in SCREEN_ONLY for a in queued):
            said += " It's on your screen to confirm."
        if spoken := [a for a in queued if a["tool"] not in SCREEN_ONLY]:
            self.awaiting = [a["id"] for a in spoken]
            if not said.endswith("?"):
                said += " Shall I go ahead?"
        await self._send({"type": "state", "state": "listening"})
        await reply(said)

    async def _turn(self, words: str, delegation: str | None) -> Turn | None:
        await self._send({"type": "state", "state": "working"})
        steps: list[str] = []
        last_note = 0.0

        def on_step(_who: str, label: str) -> None:
            nonlocal last_note
            steps.append(label)
            self._spawn(self._send({"type": "state", "state": "working", "step": label}))
            if time.monotonic() - last_note >= PROGRESS_EVERY:
                last_note = time.monotonic()
                self._spawn(self.voice.think(f"Progress: {label}. Nothing is done yet.", delegation))

        async def still_working() -> None:
            while True:
                await asyncio.sleep(STATUS_EVERY)
                last = f"; the last one: {steps[-1]}" if steps else ""
                await self.voice.think(f"Still working ({len(steps)} steps so far{last}).", delegation)

        self.turns += 1
        status = asyncio.create_task(still_working())
        try:
            return await self.agent.respond(CONVERSATION, words, self.conversation, voice=True, on_step=on_step)
        except Exception as e:
            log.exception("live call: the turn failed")
            await self._send({"type": "error", "message": str(e)})
            return None
        finally:
            status.cancel()
            self.turns -= 1
            self.last_activity = time.monotonic()

    async def _goodbye(self) -> None:
        if self.bye:
            return
        self.bye = True
        await asyncio.sleep(GOODBYE_SECONDS)
        await self.end("goodbye")

    async def _watch_idle(self) -> None:
        while True:
            await asyncio.sleep(IDLE_TICK)
            if not self.turns and not self._speaking() and time.monotonic() - self.last_activity > self.idle:
                await self.voice.say("I'll hang up now. Call me back any time.")
                await asyncio.sleep(GOODBYE_SECONDS)
                await self.end("idle")
                return


class LiveCalls:
    """Calls for the API: on only with a voice to connect. A second call in a chat ends the first."""

    def __init__(self, agent: Agent, conn, connect: Connect | None = None, idle_minutes: float = 5):
        self.agent, self.store, self.connect, self.idle_minutes = agent, CallStore(conn), connect, idle_minutes
        self.active: dict[str, LiveCall] = {}

    @property
    def on(self) -> bool:
        return self.connect is not None
