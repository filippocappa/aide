"""Live calls (#34): a realtime voice model does the listening and the speaking, and the agents still do the work.

Each request the voice hands over (a delegation) becomes an ordinary chat turn by voice (Agent.respond), with the
chat's agent, tools, memory and confirm queue. While it runs the voice gets private notes (the step it's on, still
working); then it reads the answer back in the first person. A yes or no to what the turn queued is decided here in
code (consent.py), and so is a goodbye. The chat keeps the spoken requests and the replies as normal turns, and one
row for the call (`calls`).

The voice sits behind `LiveVoice`: localvoice.py (Parakeet, Kokoro and a turn detector on cappa's GPU, the usual one)
or gptlive.py (OpenAI's GPT-Live); this file doesn't know which it is. It tells us only the words as it writes them
down, in pieces, and that a request was handed over (no words with it, no end of an utterance): those are worked out
here from the pieces and the quiet between them. A voice that knows when you start talking says so (`Speech`), and
the phone stops playing at once."""

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
from .lang import language

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

# What the call says itself, in the language last spoken.
LINES = {
    "en": {"go_ahead": "Shall I go ahead?", "on_screen": "It's on your screen to confirm.",
           "unclear": "I didn't catch a clear yes or no. Shall I go ahead?", "done": "Done.",
           "left": "Okay, I've left it.", "again": "Sorry, I didn't catch that. Could you say it again?",
           "bye": "Bye!", "failed": "Something went wrong on my side, sorry. It didn't work.",
           "in_chat": "Done, it's in the chat.", "hang_up": "I'll hang up now. Call me back any time.",
           "rest": "The rest is in the chat."},
    "it": {"go_ahead": "Procedo?", "on_screen": "Te l'ho messo sullo schermo da confermare.",
           "unclear": "Non ho capito se è un sì o un no. Procedo?", "done": "Fatto.",
           "left": "Va bene, lascio stare.", "again": "Scusa, non ho capito. Puoi ripetere?",
           "bye": "Ciao!", "failed": "Qualcosa è andato storto da parte mia, scusa. Non ha funzionato.",
           "in_chat": "Fatto, è nella chat.", "hang_up": "Chiudo la chiamata. Richiamami quando vuoi.",
           "rest": "Il resto è nella chat."},
}


def line(key: str, lang: str) -> str:
    return LINES.get(lang, LINES["en"])[key]


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
class Speech:
    """The user started talking (a voice that can tell before the words are written down): over the voice, it stops."""


@dataclass
class Delegation:
    """The voice hands a request over; its words are what was heard since the last one."""
    id: str


@dataclass
class Closed:
    reason: str


Event = Audio | Heard | Said | Speech | Delegation | Closed


class LiveVoice(Protocol):
    rate: int  # sample rate of the PCM16 mono audio, both ways
    seconds: float  # billed so far, as the provider counts it (0 when it doesn't say)
    # Optional, read with getattr: `settle` (the quiet that ends an utterance; 0 when each Heard is a whole one),
    # `provider`, `model` and `price_minute` (for usage), `working(delegation)` (a turn started: say "one moment" if
    # it takes a while).

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


_HOW_TO_CONFIRM = re.compile(r"conferm|confirm|nell'app|in the app|\btap|tocca", re.I)


def unconfirmed(said: str) -> str:
    """A reply that queued something without its sentences on how to confirm it ("Ti chiedo conferma nell'app."):
    the call asks itself, right after. The prompt says so, but Haiku kept saying it."""
    sentences = re.split(r"(?<=[.!?])\s+", said.strip())
    kept = [s for s in sentences if not _HOW_TO_CONFIRM.search(s)]
    return " ".join(kept) if kept else said


def pieces(text: str, lang: str = "en") -> list[str]:
    """The answer in up to PIECES pieces of PIECE_CHARS, cut between sentences (or words); a longer one is cut and
    ends with a pointer to the chat."""
    rest = " " + line("rest", lang)
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
    settle: float | None = None  # None: SETTLE

    def heard(self, text: str, speaking: bool) -> tuple[Utterance, bool]:
        """Add a piece; returns its utterance and whether it began one."""
        now = time.monotonic()
        current = self.utterances[-1] if self.utterances else None
        new = current is None or current.delegated or now - current.last >= self._settle()
        if new:
            current = Utterance(started=now, echo=speaking)
            self.utterances.append(current)
            del self.utterances[:-20]
        current.text += text
        current.last = now
        self.changed.set()
        return current, new

    def _settle(self) -> float:
        return SETTLE if self.settle is None else self.settle

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
        while (waiting := self.waiting()) and (quiet := time.monotonic() - waiting[-1].last) < self._settle():
            await asyncio.sleep(self._settle() - quiet)
        taken = self.waiting()
        for u in taken:
            u.delegated = True
        return taken


_UNSURE = re.compile(r"\b(?:yes|yeah|ok|okay|sure|si|va bene|certo|fine|alright)\b")


# -- the reply said as it's written (#71) -------------------------------------------------------------------------

FIRST_PIECE = 20  # a piece shorter than this waits for the next sentence ("Sure." alone sounds choppy)
_END = re.compile(r"(?<=[.!?…:;])\s+|\n")
_LIST_MARK = re.compile(r"\s*\d+[.)]")


def _finished(text: str) -> int:
    """How much of the text being written is whole sentences or lines: the index after the last end ("1." starting
    a list line isn't one)."""
    last = 0
    for m in _END.finditer(text):
        start = text.rfind("\n", 0, m.start()) + 1
        if m.group() != "\n" and _LIST_MARK.fullmatch(text[start:m.start()]):
            continue
        last = m.end()
    return last


class Spoken:
    """A turn's reply said while the model writes it: each finished sentence goes to the voice as the next one is
    written, so the first is heard ~0.5 s after Haiku starts, not after the whole reply. Every model round's text is
    said, the one before a tool call too ("Let me check your calendar.", said instead of a step line); a round's
    unfinished end is dropped when a tool call follows it. Once the turn has queued an action, the model's sentences
    on how to confirm it are left out (the call asks itself). Talked over: the rest isn't said (it's in the chat)."""

    def __init__(self, call: "LiveCall", before: set[int], lang: str):
        self.call, self.voice, self.before, self.lang = call, call.voice, before, lang
        self.unsaid = ""  # written, not said yet
        self.last = ""  # the last model round's text: the reply
        self.chars = 0
        self.started = False  # something was said
        self.hushes = 0
        self.queued = False
        self.hushed = self.cut = False

    def feed(self, piece: str, restart: bool) -> None:
        if restart:  # tools ran: what was left unsaid came before them
            self.unsaid, self.last = "", ""
            self.queued = self.queued or bool(self.call._queued_since(self.before))
        self.unsaid += piece
        self.last += piece
        if self.started and self.voice.hushes != self.hushes:
            self.hushed = True
        if self.hushed or self.cut:
            return
        end = _finished(self.unsaid)
        if end and len(self.unsaid[:end].strip()) >= FIRST_PIECE:
            self._say(self.unsaid[:end])
            self.unsaid = self.unsaid[end:]

    def end(self, after: str) -> None:
        """The turn is over: the rest of the reply, then the call's own lines (`after`: "Shall I go ahead?")."""
        if self.started and self.voice.hushes != self.hushes:
            self.hushed = True
        if self.hushed:
            return
        rest = "" if self.cut else self._words(self.unsaid)
        self.unsaid = ""
        self.voice.say_part(f"{rest} {after}".strip(), more=False)

    def _say(self, text: str) -> None:
        if not (text := self._words(text)):
            return
        if not self.started:
            self.started, self.hushes = True, self.voice.hushes
            self.call._spawn(self.call._send({"type": "state", "state": "listening"}))
        self.voice.say_part(text)

    def _words(self, text: str) -> str:
        text = speakable(text)
        if self.queued:
            text = " ".join(s for s in re.split(r"(?<=[.!?])\s+", text) if not _HOW_TO_CONFIRM.search(s))
        if not text.strip():
            return ""
        if self.chars + len(text) > PIECE_CHARS * PIECES:
            text, self.cut = line("rest", self.lang), True
        self.chars += len(text)
        return text


class LiveCall:
    """One call in one chat. `send_json` and `send_audio` go to the phone; run() returns when the call is over."""

    def __init__(self, agent: Agent, voice: LiveVoice, calls: CallStore, conversation: str, agent_id: str,
                 send_json: Callable[[dict], Awaitable[None]], send_audio: Callable[[bytes], Awaitable[None]],
                 on_turn: Callable[[str, Turn], Awaitable[None]] | None = None, idle_minutes: float = 5,
                 team_json: Callable[[dict], dict] = lambda t: t):
        self.agent, self.voice, self.calls = agent, voice, calls
        self.team_json = team_json
        self.conversation, self.agent_id = conversation, agent_id
        self.send_json, self.send_audio, self.on_turn = send_json, send_audio, on_turn
        self.idle = idle_minutes * 60
        self.ears = Ears(settle=getattr(voice, "settle", None))
        self.awaiting: list[int] = []  # queued actions asked about, waiting for a spoken yes or no
        self.lang = getattr(voice, "lang", "en")  # of the last words heard: the call's own lines are in it
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
        self._spawn(self.agent.warm_voice(self.agent_id))  # ready by the first question
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
            price = getattr(self.voice, "price_minute", PRICE_MINUTE)
            usage.record(getattr(self.voice, "provider", "openai"), getattr(self.voice, "model", "gpt-live"),
                         cost=round(seconds / 60 * price, 4), purpose="live", agent=self.agent_id,
                         conversation=self.conversation, ms=round(seconds * 1000))
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

    def _queued_since(self, before: set[int]) -> list[dict]:
        return [a for a in self._pending() if a["id"] not in before]

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
                self.lang = language(text, self.lang)
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
            case Speech():
                self.last_activity = time.monotonic()
                if self._speaking():
                    self.speaking_until = 0.0
                    await self._send({"type": "interrupted"})
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
                await self.voice.answer(delegation, pieces(await self._consent(words), self.lang))
                return
            if len(words.split()) <= 3 and _UNSURE.search(words.lower()):  # "okay", "va bene": not clear enough
                await self.voice.answer(delegation, [line("unclear", self.lang)])
                return
        await self._request(words, delegation)

    async def _consent(self, words: str) -> str:
        """Confirm or cancel what's awaited; the words to say."""
        answer = bool(spoken_consent(words))
        ids, self.awaiting = self.awaiting, []
        if answer:
            result = await self.agent.confirm(CONVERSATION, ids, by_voice=True)
            # The tool's result is in English: an Italian call hears just "Fatto."
            said = line("done", "it") if self.lang == "it" else f"Done. {speakable(result)}".strip()
        else:
            result = await self.agent.cancel(CONVERSATION, ids, by_voice=True)
            said = line("left", self.lang)
        await self._send({"type": "answered", "ids": ids, "confirmed": answer, "result": result})
        return said

    async def _request(self, words: str, delegation: str | None = None) -> None:
        async def reply(said: str) -> None:
            if delegation:
                await self.voice.answer(delegation, pieces(said, self.lang))
            else:
                await self.voice.say(said)

        if not words:
            await reply(line("again", self.lang))
            return
        if spoken_goodbye(words):
            await reply(line("bye", self.lang))
            await self._goodbye()
            return
        self.awaiting = []  # asked something else instead: the card stays on the screen to tap
        self.requests += 1
        before = {a["id"] for a in self._pending()}
        lang = language(words, self.lang)
        stream = Spoken(self, before, lang) if hasattr(self.voice, "say_part") else None
        started = time.monotonic()
        turn = await self._turn(words, delegation, stream.feed if stream else None)
        if turn is None:
            await reply(line("failed", self.lang))
            return
        took = time.monotonic() - started
        if self.on_turn:
            await self.on_turn(words, turn)
        log.info("live call turn: %d ms, sent after %d ms", took * 1000, (time.monotonic() - started) * 1000)
        queued = [a for a in self._pending() if a["id"] not in before]
        streamed = stream is not None and stream.started
        said = speakable(stream.last if streamed else turn.reply) or ("" if streamed else line("in_chat", lang))
        if queued:
            said = unconfirmed(said)
        after = ""
        if any(a["tool"] in SCREEN_ONLY for a in queued):
            after += " " + line("on_screen", lang)
        if spoken := [a for a in queued if a["tool"] not in SCREEN_ONLY]:
            self.awaiting = [a["id"] for a in spoken]
            if not (said + after).endswith("?"):
                after += " " + line("go_ahead", lang)
        if streamed:
            stream.queued = stream.queued or bool(queued)
            stream.end(after.strip())
            return
        await self._send({"type": "state", "state": "listening"})
        await reply(said + after)

    async def _turn(self, words: str, delegation: str | None,
                    on_text: Callable[[str, bool], None] | None = None) -> Turn | None:
        await self._send({"type": "state", "state": "working"})
        steps: list[str] = []
        last_note = 0.0

        def on_step(_who: str, label: str) -> None:
            nonlocal last_note
            steps.append(label)
            self._spawn(self._send({"type": "state", "state": "working", "step": label}))
            if step := getattr(self.voice, "step", None):  # a voice that says the steps itself (the local one)
                self._spawn(step(label))
            elif time.monotonic() - last_note >= PROGRESS_EVERY:
                last_note = time.monotonic()
                self._spawn(self.voice.think(f"Progress: {label}. Nothing is done yet.", delegation))

        async def still_working() -> None:
            while True:
                await asyncio.sleep(STATUS_EVERY)
                last = f"; the last one: {steps[-1]}" if steps else ""
                await self.voice.think(f"Still working ({len(steps)} steps so far{last}).", delegation)

        self.turns += 1
        if working := getattr(self.voice, "working", None):
            await working(delegation)
        status = asyncio.create_task(still_working())
        try:
            return await self.agent.respond(CONVERSATION, words, self.conversation, voice=True, on_step=on_step,
                                            on_team=self._team, on_text=on_text)
        except Exception as e:
            log.exception("live call: the turn failed")
            await self._send({"type": "error", "message": str(e)})
            return None
        finally:
            status.cancel()
            self.turns -= 1
            self.last_activity = time.monotonic()

    def _team(self, message: dict) -> None:
        """An ask or an answer between the agents, shown on the phone as it happens (the chat's `team` events)."""
        self._spawn(self._send({"type": "team", "message": self.team_json(message)}))

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
                await self.voice.say(line("hang_up", self.lang))
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
