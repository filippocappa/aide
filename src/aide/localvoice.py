"""A live call's voice on cappa's own GPU (livecall.LiveVoice): free, nothing leaves the house.

The ears: Silero tells speech from quiet in 32 ms frames; after a short pause the smart-turn model hears whether you
finished (a longer quiet ends it anyway), and Parakeet v3 writes the utterance down (Italian and English). Each
utterance is handed over as a request (`Heard`, then `Delegation`), so every one is a chat turn. The mouth: Kokoro,
a sentence at a time, in the reply's language (Heart in English, Sara in Italian). Talking over it stops it.

There's no model in between that chats: a request taking a while gets a short "one moment" and, every 20 s,
"still on it". The models themselves are in voicemodels.py (`Backend` here), loaded once and kept."""

import asyncio
import collections
import itertools
import logging
import re
import time
from typing import AsyncIterator, Callable, Protocol

from .livecall import Audio, Delegation, Event, Heard, Said, Speech

log = logging.getLogger(__name__)

RATE = 24000
FRAME = 768  # 32 ms at 24 kHz, one Silero window (512 samples at 16 kHz)
FRAME_SECONDS = FRAME / RATE
START_P, STOP_P = 0.5, 0.35  # speech above START_P, quiet below STOP_P, in between keeps the state
MIN_SPEECH = 0.16  # speech this long starts an utterance
PRE_ROLL = 0.3  # audio kept from before the start, so the first sound isn't clipped
PAUSE = 0.25  # quiet that asks the turn model whether you're done
SILENCE = 1.6  # quiet that ends an utterance whatever the turn model said
SILENCE_NO_TURNS = 0.7  # the same without a turn model
LONGEST = 30.0
DONE_P = 0.5  # the turn model's "finished" above this
BARGE_IN = 0.35  # speech this long over the voice stops it (a cough doesn't)
ECHO_P = 0.8  # while it speaks, only this sure a start counts (what's left of its own voice after echo cancelling)
CHUNK = RATE // 5 * 2  # audio goes out in 200 ms pieces (bytes)
AHEAD = 1.0  # the next sentence is made when what's been sent has less than this left to play
FILLER_AFTER = 1.5
STILL_EVERY = 20.0

FILLERS = {"en": ("One moment.", "Still on it."), "it": ("Un attimo.", "Ci sto ancora lavorando.")}


class Backend(Protocol):
    turns: bool  # has a turn model (else `finished` is never asked)

    def vad(self) -> Callable[[bytes], float]:
        """A fresh detector for one call: a FRAME of PCM16 at 24 kHz in, the chance it's speech out."""

    async def finished(self, pcm: bytes) -> float:
        """The chance an utterance (PCM16, 24 kHz) is a finished turn."""

    async def transcribe(self, pcm: bytes) -> str: ...

    def speak(self, text: str, language: str) -> AsyncIterator[bytes]:
        """PCM16 at 24 kHz for a sentence, as it's made."""

    def opened(self) -> None: ...

    def closed(self) -> None: ...


# -- what's pure ---------------------------------------------------------------------------------------------------

class Endpointer:
    """Utterances from Silero's per-frame chances: "start", "pause" (quiet long enough to ask the turn model) and
    "end" (quiet long enough, or too long an utterance)."""

    def __init__(self, silence: float = SILENCE):
        self.silence = silence
        self.talking = False
        self.run = 0  # speech frames in a row before a start
        self.frames = 0  # frames since the start
        self.voiced = 0  # speech frames since the start
        self.quiet = 0  # quiet frames in a row since the last speech

    def push(self, p: float) -> str | None:
        if not self.talking:
            self.run = self.run + 1 if p >= START_P else 0
            if self.run * FRAME_SECONDS >= MIN_SPEECH:
                self.talking, self.frames, self.voiced, self.quiet = True, self.run, self.run, 0
                return "start"
            return None
        self.frames += 1
        if p < STOP_P:
            self.quiet += 1
        else:
            self.quiet = 0
            self.voiced += p >= START_P
        if self.quiet * FRAME_SECONDS >= self.silence or self.frames * FRAME_SECONDS >= LONGEST:
            self.stop()
            return "end"
        if self.quiet == round(PAUSE / FRAME_SECONDS):
            return "pause"
        return None

    def stop(self) -> None:
        self.talking, self.run, self.quiet = False, 0, 0


_IT = set("il lo la le gli di del della delle dei che è non per una sono hai ho alle allo alla con mi ti ci si sì "
          "domani oggi grazie ciao cosa quando dove anche ma poi questo questa quello fatto fare va bene vuoi "
          "puoi devo c'è perché adesso dopo prima ancora ok".split())
_EN = set("the and is are you to of it that for on with have has what when where tomorrow today yes please "
          "thanks thank at can will your my this was there done want would could should then now let i'll i'm "
          "you're it's".split())


def language(text: str, default: str = "en") -> str:
    """"it" or "en", from the short words that give each away; `default` when it can't tell."""
    words = re.findall(r"[a-zà-ú']+", text.lower())
    it, en = sum(w in _IT for w in words), sum(w in _EN for w in words)
    return "it" if it > en else "en" if en > it else default


def sentences(text: str) -> list[str]:
    """A reply cut into sentences for the voice; very short ones go with the next so it doesn't sound choppy."""
    parts = [p.strip() for p in re.split(r"(?<=[.!?…:;])\s+|\n+", text) if p.strip()]
    out: list[str] = []
    for part in parts:
        if out and len(out[-1]) < 20:
            out[-1] = f"{out[-1]} {part}"
        else:
            out.append(part)
    return out


# -- the voice -----------------------------------------------------------------------------------------------------

class LocalVoice:
    rate = RATE
    settle = 0.0  # each Heard is a whole utterance
    provider, model, price_minute = "gpu", "parakeet+kokoro", 0.0

    def __init__(self, backend: Backend, language: str = "en"):
        self.backend = backend
        self.seconds = 0.0
        self.lang = language  # of the last thing heard
        self._vad = backend.vad()
        self._ends = Endpointer(SILENCE if backend.turns else SILENCE_NO_TURNS)
        self._buffer = bytearray()  # less than a frame
        self._before: collections.deque[bytes] = collections.deque(maxlen=round(PRE_ROLL / FRAME_SECONDS))
        self._utterance: bytearray | None = None
        self._barging = False  # started over the voice, not long enough yet to stop it
        self._events: asyncio.Queue[Event | None] = asyncio.Queue()
        self._lines: collections.deque[str] = collections.deque()
        self._mouth: asyncio.Task | None = None
        self._filler: asyncio.Task | None = None
        self._ears = asyncio.Lock()  # utterances written down in the order they were said
        self._tasks: set[asyncio.Task] = set()
        self._ids = itertools.count(1)
        self._playing_until = 0.0
        self._closed = False
        backend.opened()

    # -- the phone's microphone --

    async def send_audio(self, pcm: bytes) -> None:
        if self._closed:
            return
        self._buffer += pcm
        size = FRAME * 2
        while len(self._buffer) >= size:
            frame = bytes(self._buffer[:size])
            del self._buffer[:size]
            self._frame(frame, self._vad(frame))

    def _frame(self, frame: bytes, p: float) -> None:
        was = self._ends.talking
        if not was and p < ECHO_P and self._talking():
            p = min(p, STOP_P)
        step = self._ends.push(p)
        if not was and step is None:
            self._before.append(frame)
            return
        if step == "start":
            self._utterance = bytearray(b"".join(self._before))
            self._before.clear()
            self._barging = self._talking()
            if not self._barging:
                self._put(Speech())
        self._utterance += frame
        if self._barging and self._ends.voiced * FRAME_SECONDS >= BARGE_IN:
            self._hush()
        if step == "pause" and self.backend.turns:
            self._spawn(self._maybe_finished(self._utterance, self._ends.frames, self._ends.quiet))
        elif step == "end":
            self._finish()

    async def _maybe_finished(self, utterance: bytearray, at: int, quiet_then: int) -> None:
        """Ends the utterance at a pause if the turn model hears it finished and you're still quiet."""
        ends = self._ends
        p = await self.backend.finished(bytes(utterance))
        still_quiet = ends.talking and self._utterance is utterance and ends.quiet == quiet_then + ends.frames - at
        if p >= DONE_P and still_quiet:
            ends.stop()
            self._finish()

    def _finish(self) -> None:
        pcm, self._utterance = bytes(self._utterance or b""), None
        if pcm:
            self._spawn(self._write_down(pcm, self._barging))
        self._barging = False

    async def _write_down(self, pcm: bytes, barging: bool) -> None:
        async with self._ears:
            started = time.monotonic()
            try:
                text = (await self.backend.transcribe(pcm)).strip()
            except Exception:
                log.exception("live call: transcribing failed")
                return
            if not re.search(r"\w", text):
                return  # a noise
            log.info("live call heard %.1f s in %d ms", len(pcm) / 2 / RATE, (time.monotonic() - started) * 1000)
            if barging:
                self._hush()
            self.lang = language(text, self.lang)
            self._put(Heard(text))
            self._put(Delegation(f"u{next(self._ids)}"))

    # -- the voice --

    async def think(self, text: str, delegation: str | None = None) -> None:
        pass  # nothing listens to private notes here

    async def working(self, delegation: str | None) -> None:
        self._stop_filler()
        self._filler = self._spawn(self._fill())

    async def answer(self, delegation: str, pieces: list[str]) -> None:
        for piece in pieces:
            await self.say(piece)

    async def say(self, text: str) -> None:
        self._stop_filler()
        self._queue(text)

    def _queue(self, text: str) -> None:
        if self._closed or not text.strip():
            return
        self._lines.append(text)
        if self._mouth is None or self._mouth.done():
            self._mouth = self._spawn(self._speak())

    async def _fill(self) -> None:
        await asyncio.sleep(FILLER_AFTER)
        first, still = FILLERS.get(self.lang, FILLERS["en"])
        if not self._talking():
            self._queue(first)
        while True:
            await asyncio.sleep(STILL_EVERY)
            self._queue(still)

    async def _speak(self) -> None:
        while self._lines:
            text = self._lines.popleft()
            lang = language(text, self.lang)
            for sentence in sentences(text):
                if (left := self._playing_until - time.monotonic()) > AHEAD:
                    await asyncio.sleep(left - AHEAD)
                self._put(Said(sentence + " "))
                async for pcm in self.backend.speak(sentence, lang):
                    for i in range(0, len(pcm), CHUNK):
                        piece = pcm[i:i + CHUNK]
                        now = time.monotonic()
                        self._playing_until = max(now, self._playing_until) + len(piece) / 2 / RATE
                        self._put(Audio(piece))

    def _talking(self) -> bool:
        return (self._mouth is not None and not self._mouth.done()) or time.monotonic() < self._playing_until

    def _hush(self) -> None:
        """You talked over it: what's left unsaid goes."""
        self._barging = False
        self._lines.clear()
        self._stop_filler()
        if self._mouth and not self._mouth.done():
            self._mouth.cancel()
        self._mouth = None
        self._playing_until = 0.0
        self._put(Speech())

    def _stop_filler(self) -> None:
        if self._filler and not self._filler.done():
            self._filler.cancel()
        self._filler = None

    # -- plumbing --

    def _put(self, event: Event) -> None:
        if not self._closed:
            self._events.put_nowait(event)

    def _spawn(self, coro) -> asyncio.Task:
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._done)
        return task

    def _done(self, task: asyncio.Task) -> None:
        self._tasks.discard(task)
        if not task.cancelled() and (e := task.exception()):
            log.error("live call: the local voice failed", exc_info=e)

    async def events(self) -> AsyncIterator[Event]:
        while (event := await self._events.get()) is not None:
            yield event

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        for task in list(self._tasks):
            task.cancel()
        self._events.put_nowait(None)
        self.backend.closed()
