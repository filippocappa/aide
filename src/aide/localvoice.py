"""A live call's voice on cappa's own GPU (livecall.LiveVoice): free, nothing leaves the house.

The ears: Silero tells speech from quiet in 32 ms frames; after a short pause the smart-turn model hears whether you
finished (a longer quiet ends it anyway), and Parakeet v3 writes the utterance down (Italian and English). Each
utterance is handed over as a request (`Heard`, then `Delegation`), so every one is a chat turn. The mouth: Kokoro,
a sentence at a time, in the reply's language (Heart in English, Sara in Italian). Talking over it stops it.

There's no model in between that chats: a request taking a while gets a short "one moment" once a call (or "I'm asking
Secretary for you" when Aide hands it on, and the other steps when it's been quiet a while) and, every 20 s,
"still on it". The models themselves are in voicemodels.py (`Backend` here), loaded once and kept."""

import asyncio
import collections
import itertools
import logging
import re
import time
from typing import AsyncIterator, Callable, Protocol

from .lang import language  # noqa: F401  (also imported from here)
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
BARGE_IN = 0.7  # speech this long over the voice stops it (a cough or a knock doesn't; 0.35 s did, 2026-11-06);
# a shorter one stops it only once it's written down as words ("stop")
ECHO_P = 0.8  # while it speaks, only this sure a start counts (what's left of its own voice after echo cancelling)
CHUNK = RATE // 5 * 2  # audio goes out in 200 ms pieces (bytes)
AHEAD = 1.0  # the next sentence is made when what's been sent has less than this left to play
FILLER_AFTER = 3.0  # a turn this slow gets "one moment", once a call; an ask usually comes first and is said instead
LONG_AFTER = 8.0  # a longer turn gets a few more lines from then on, a different one each time,
STILL_EVERY = 7.0  # this far apart,
QUIET = 3.0  # and only after this long without a word

FILLERS = {"en": "One moment.", "it": "Un attimo."}
STILL = {"en": ("Just a moment more.", "A few more seconds.", "Still working on it.",
                "Bear with me, this one's taking a little longer."),
         "it": ("Ancora un attimo.", "Qualche secondo e ci sono.", "Ci sto ancora lavorando.",
                "Abbi pazienza, ci vuole un po' di più.")}
ASKING = {"en": "I'm asking {name} for you.", "it": "Chiedo a {name}."}  # an ask_agent step, always said
STEP_GAP = 4.0  # any other step is said only after this long without a word (English only: the labels are),
STEP_WAIT = 1.2  # and only if the answer hasn't come this long after the step started: a quick tool needs no
# "Checking the calendar." right before its answer (2026-11-06)
BREATH = 0.4  # silence between a status line ("One moment.", "Checking the calendar.") and the answer after it


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


_TIME = r"\b([01]?\d|2[0-3]):([0-5]\d)\b"
_RANGE = re.compile(_TIME + r"\s*[–—-]\s*" + r"(?=\b(?:[01]?\d|2[0-3]):[0-5]\d\b)")
_CLOCK = re.compile(_TIME + r"(\s*[ap]\.?\s?m\b\.?)?", re.I)


def spoken(text: str, language: str) -> str:
    """Clock times as Kokoro reads them well ("13:47" is "1 47 p.m." in English, "13 e 47" in Italian; read as it is
    it says "thirteen zero zero")."""
    text = _RANGE.sub(lambda m: f"{m[1]}:{m[2]} {'alle' if language == 'it' else 'to'} ", text)

    def say(m: re.Match) -> str:
        h, mins, half = int(m[1]), int(m[2]), m[3]
        if language == "it":
            return "mezzanotte" if h == mins == 0 else f"{h}" if not mins else f"{h} e {mins}"
        if half:
            return f"{h}{f' {mins:02d}' if mins >= 10 else f' oh {mins}' if mins else ''}{half}"
        if not mins and h in (0, 12):
            return "midnight" if h == 0 else "noon"
        minutes = "" if not mins else f" oh {mins}" if mins < 10 else f" {mins}"
        return f"{h % 12 or 12}{minutes} {'a.m.' if h < 12 else 'p.m.'}"
    return _CLOCK.sub(say, text)


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
        self._lines: collections.deque[tuple[str, bool]] = collections.deque()  # (text, a status line)
        self._mouth: asyncio.Task | None = None
        self._filler: asyncio.Task | None = None
        self._ears = asyncio.Lock()  # utterances written down in the order they were said
        self._tasks: set[asyncio.Task] = set()
        self._ids = itertools.count(1)
        self._playing_until = 0.0
        self._last_word = time.monotonic()  # when the voice last started a sentence (or the call began)
        self._steps_said: set[str] = set()  # this turn's steps already said
        self._fillered = False  # "one moment" said already in this call: once is enough
        self._stills = 0  # the longer lines said in this call, so the next is a different one
        self._turn_at = time.monotonic()  # when the turn being worked on began
        self._noting: asyncio.Task | None = None  # a step waiting STEP_WAIT before it's said
        self._after_status = False  # the last line said was a status line
        self.hushes = 0  # times you talked over it: a reply said as it's written stops at the next one (livecall)
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
        self._stop_note()
        self._steps_said = set()
        self._turn_at = time.monotonic()
        self._filler = self._spawn(self._fill())

    async def step(self, label: str) -> None:
        """A tool started in the turn: say who's been asked, or what it's doing if nothing's been said for a while."""
        if self._closed or label in self._steps_said:
            return
        if label.startswith("Asking "):
            note = ASKING.get(self.lang, ASKING["en"]).format(name=label.removeprefix("Asking ").strip())
        elif self.lang == "en" and not self._talking() and time.monotonic() - self._last_word >= STEP_GAP:
            note = label + "."
        else:
            return
        self._steps_said.add(label)
        if self._noting is None or self._noting.done():
            self._noting = self._spawn(self._note(note))

    async def _note(self, note: str) -> None:
        """A step's line, unless the answer comes first or the voice is already talking by then."""
        await asyncio.sleep(STEP_WAIT)
        if self._closed or self._talking():
            return
        self._stop_filler()  # said instead of "one moment"; the longer lines carry on
        self._queue(note, status=True)
        self._filler = self._spawn(self._fill(first=False))

    def _stop_note(self) -> None:
        if self._noting and not self._noting.done():
            self._noting.cancel()
        self._noting = None

    async def answer(self, delegation: str, pieces: list[str]) -> None:
        for piece in pieces:
            await self.say(piece)

    async def say(self, text: str) -> None:
        self._stop_filler()
        self._stop_note()
        self._queue(text)

    def say_part(self, text: str, more: bool = True) -> None:
        """A piece of the reply while the rest is still being written (#71), said after what's queued. `more`: the
        turn goes on (a tool may run after it), so the longer "still working" lines start again; the last piece
        stops them."""
        self._stop_filler()
        self._stop_note()
        self._queue(text)
        if more and not self._closed:
            self._filler = self._spawn(self._fill(first=False))

    def _queue(self, text: str, status: bool = False) -> None:
        if self._closed or not text.strip():
            return
        self._lines.append((text, status))
        if self._mouth is None or self._mouth.done():
            self._mouth = self._spawn(self._speak())

    async def _fill(self, first: bool = True) -> None:
        """"One moment" for a slow turn (once a call), then for a long one a different line every few seconds."""
        if first:
            await asyncio.sleep(FILLER_AFTER)
            if not self._talking() and not self._fillered:
                self._fillered = True
                self._queue(FILLERS.get(self.lang, FILLERS["en"]), status=True)
        await asyncio.sleep(max(0.0, self._turn_at + LONG_AFTER - time.monotonic()))
        while True:
            if not self._talking() and time.monotonic() - self._last_word >= QUIET:
                lines = STILL.get(self.lang, STILL["en"])
                self._queue(lines[self._stills % len(lines)], status=True)
                self._stills += 1
                await asyncio.sleep(STILL_EVERY)
            else:
                await asyncio.sleep(0.5)

    async def _speak(self) -> None:
        while self._lines:
            text, status = self._lines.popleft()
            lang = language(text, self.lang)
            breath = self._after_status and not status and time.monotonic() < self._playing_until + BREATH
            self._after_status = status
            for sentence in sentences(text):
                if (left := self._playing_until - time.monotonic()) > AHEAD:
                    await asyncio.sleep(left - AHEAD)
                self._put(Said(sentence + " "))
                self._last_word = time.monotonic()
                if breath:  # a moment between "Checking the calendar." and the answer, as a person would
                    breath = False
                    gap = bytes(int(BREATH * RATE) * 2)
                    self._playing_until = max(time.monotonic(), self._playing_until) + BREATH
                    self._put(Audio(gap))
                async for pcm in self.backend.speak(spoken(sentence, lang), lang):
                    for i in range(0, len(pcm), CHUNK):
                        piece = pcm[i:i + CHUNK]
                        now = time.monotonic()
                        self._playing_until = max(now, self._playing_until) + len(piece) / 2 / RATE
                        self._put(Audio(piece))

    def _talking(self) -> bool:
        return (self._mouth is not None and not self._mouth.done()) or time.monotonic() < self._playing_until

    def _hush(self) -> None:
        """You talked over it: what's left unsaid goes."""
        self.hushes += 1
        self._barging = False
        self._lines.clear()
        self._stop_filler()
        self._stop_note()
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
