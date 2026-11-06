import asyncio
import math

import pytest

from aide import livecall, localvoice
from aide.livecall import Audio, Delegation, Heard, LiveCall, Said, Speech
from aide.localvoice import FRAME, FRAME_SECONDS, Endpointer, LocalVoice, language, sentences, spoken

SPEECH = (1000).to_bytes(2, "little", signed=True) * FRAME
QUIET = b"\0\0" * FRAME


def frames(seconds: float, frame: bytes) -> bytes:
    return frame * round(seconds / FRAME_SECONDS)


class FakeBackend:
    def __init__(self, words="what's on tomorrow", done=0.0, turns=True, speech_seconds=0.2):
        self.turns = turns
        self.words, self.done, self.speech_seconds = words, done, speech_seconds
        self.heard, self.spoken, self.asked = [], [], 0
        self.calls = 0

    def vad(self):
        return lambda frame: 0.9 if frame[:2] != b"\0\0" else 0.05

    async def finished(self, pcm):
        self.asked += 1
        return self.done

    async def transcribe(self, pcm):
        self.heard.append(len(pcm))
        return self.words

    async def speak(self, text, language):
        self.spoken.append((text, language))
        yield b"\1\0" * round(24000 * self.speech_seconds)

    def opened(self):
        self.calls += 1

    def closed(self):
        self.calls -= 1


async def until(voice, kind, seconds=2.0):
    async def read():
        async for event in voice.events():
            if isinstance(event, kind):
                return event
    return await asyncio.wait_for(read(), seconds)


async def collect(voice, count, seconds=2.0):
    out = []

    async def read():
        async for event in voice.events():
            out.append(event)
            if len(out) >= count:
                return
    await asyncio.wait_for(read(), seconds)
    return out


def test_the_endpointer_starts_pauses_and_ends():
    ends = Endpointer(silence=1.0)
    steps = [ends.push(0.9) for _ in range(10)]
    assert steps[:4] == [None] * 4 and steps[4] == "start" and steps[5:] == [None] * 5
    steps = [ends.push(0.1) for _ in range(math.ceil(1.0 / FRAME_SECONDS))]
    assert steps.count("pause") == 1 and steps[-1] == "end" and not ends.talking


def test_a_short_sound_never_starts_and_middling_frames_keep_the_state():
    ends = Endpointer()
    assert [ends.push(p) for p in (0.9, 0.9, 0.1, 0.9)] == [None] * 4
    ends = Endpointer(silence=0.5)
    [ends.push(0.9) for _ in range(5)]
    assert all(ends.push(0.4) is None for _ in range(100)) and ends.talking  # between the lines: not quiet


def test_language_and_sentences():
    assert language("Cosa ho domani?") == "it"
    assert language("What do I have tomorrow?") == "en"
    assert language("Macroeconomia", default="it") == "it"
    assert sentences("Ok. Tomorrow you have macro at ten. Then the dentist at four!\nNothing else.") == [
        "Ok. Tomorrow you have macro at ten.", "Then the dentist at four!", "Nothing else."]


def test_clock_times_are_said_as_words():
    assert spoken("A run from 13:00 to 13:47, then dinner 20:00–22:00.", "en") == \
        "A run from 1 p.m. to 1 47 p.m., then dinner 8 p.m. to 10 p.m.."
    assert spoken("At 9:05, 12:00 and 00:00. Or 7:30 pm.", "en") == "At 9 oh 5 a.m., noon and midnight. Or 7 30 pm."
    assert spoken("Dalle 13:00 alle 13:47, poi 20:00-22:00 e alle 9:05.", "it") == \
        "Dalle 13 alle 13 e 47, poi 20 alle 22 e alle 9 e 5."
    assert spoken("It costs 9.50 and the score is 3-2.", "en") == "It costs 9.50 and the score is 3-2."


async def test_an_utterance_is_heard_and_handed_over():
    backend = FakeBackend()
    voice = LocalVoice(backend)
    await voice.send_audio(frames(0.5, QUIET) + frames(1.0, SPEECH) + frames(2.0, QUIET))
    events = await collect(voice, 3)
    assert isinstance(events[0], Speech)
    assert events[1] == Heard("what's on tomorrow") and isinstance(events[2], Delegation)
    assert backend.asked == 1  # asked at the pause, said no, so the long quiet ended it
    await voice.close()
    assert backend.calls == 0


async def test_the_turn_model_ends_it_at_the_pause():
    backend = FakeBackend(done=0.9)
    voice = LocalVoice(backend)
    await voice.send_audio(frames(1.0, SPEECH) + frames(0.4, QUIET))  # far less than SILENCE
    events = await collect(voice, 3)
    assert events[1] == Heard("what's on tomorrow")
    await voice.close()


async def test_audio_in_odd_sizes_is_cut_into_frames():
    backend = FakeBackend(turns=False)
    voice = LocalVoice(backend)
    audio = frames(1.0, SPEECH) + frames(1.0, QUIET)
    for i in range(0, len(audio), 1000):
        await voice.send_audio(audio[i:i + 1000])
    events = await collect(voice, 3)
    assert events[1] == Heard("what's on tomorrow") and backend.asked == 0


async def test_a_noise_is_dropped():
    voice = LocalVoice(FakeBackend(words=" ... "))
    await voice.send_audio(frames(1.0, SPEECH) + frames(2.0, QUIET))
    with pytest.raises(asyncio.TimeoutError):
        await collect(voice, 2, seconds=0.3)


async def test_it_speaks_a_sentence_at_a_time_in_the_language_of_the_text():
    backend = FakeBackend()
    voice = LocalVoice(backend)
    await voice.answer("u1", ["Domani hai macroeconomia alle dieci. Poi il dentista alle quattro."])
    events = await collect(voice, 4)
    assert [type(e) for e in events] == [Said, Audio, Said, Audio]
    assert [lang for _, lang in backend.spoken] == ["it", "it"]
    assert len(events[1].pcm) <= localvoice.CHUNK * 2


async def test_a_slow_turn_gets_a_filler_and_the_answer_stops_it(monkeypatch):
    monkeypatch.setattr(localvoice, "FILLER_AFTER", 0.05)
    monkeypatch.setattr(localvoice, "LONG_AFTER", 0.15)
    monkeypatch.setattr(localvoice, "STILL_EVERY", 10)
    monkeypatch.setattr(localvoice, "QUIET", 0)
    backend = FakeBackend(speech_seconds=0.01)
    voice = LocalVoice(backend, language="it")
    await voice.working("u1")
    events = await collect(voice, 2)
    assert events[0] == Said("Un attimo. ")
    await asyncio.sleep(0.15)
    await voice.say("Fatto.")
    await asyncio.sleep(0.3)
    assert [t for t, _ in backend.spoken] == ["Un attimo.", "Ancora un attimo.", "Fatto."]


async def test_a_long_turn_gets_a_different_line_each_time(monkeypatch):
    monkeypatch.setattr(localvoice, "FILLER_AFTER", 0.01)
    monkeypatch.setattr(localvoice, "LONG_AFTER", 0.03)
    monkeypatch.setattr(localvoice, "STILL_EVERY", 0.05)
    monkeypatch.setattr(localvoice, "QUIET", 0)
    backend = FakeBackend(speech_seconds=0.001)
    voice = LocalVoice(backend)
    await voice.working("u1")
    await asyncio.sleep(0.2)
    await voice.say("Done.")
    await asyncio.sleep(0.05)
    spoken = [t for t, _ in backend.spoken]
    assert spoken[:4] == ["One moment.", "Just a moment more.", "A few more seconds.", "Still working on it."]
    assert spoken[-1] == "Done." and len(set(spoken)) == len(spoken)


async def test_talking_over_it_stops_it():
    backend = FakeBackend(words="no wait", speech_seconds=3.0)
    voice = LocalVoice(backend)
    await voice.say("Tomorrow you have macroeconomics at ten. Then the dentist at four. Nothing else.")
    await collect(voice, 2)  # the first sentence
    await voice.send_audio(frames(0.1, SPEECH))  # a cough: not enough
    await voice.send_audio(frames(0.3, QUIET))
    assert voice._talking()
    backend.words = ""  # nor half a second of a loud noise, with no words in it
    await voice.send_audio(frames(0.5, SPEECH))
    assert voice._talking()
    await voice.send_audio(frames(2.0, QUIET))
    await asyncio.sleep(0.05)
    assert voice._talking()
    backend.words = "no wait"
    await voice.send_audio(frames(0.8, SPEECH))
    await until(voice, Speech)
    assert not voice._talking()
    await voice.send_audio(frames(2.0, QUIET))
    assert await until(voice, Heard) == Heard("no wait")
    assert len(backend.spoken) == 1  # the rest was never said


async def test_its_own_voice_doesnt_start_an_utterance(monkeypatch):
    backend = FakeBackend(speech_seconds=3.0)
    backend.vad = lambda: (lambda frame: 0.6 if frame[:2] != b"\0\0" else 0.05)  # echo: speech-ish, not sure
    voice = LocalVoice(backend)
    await voice.say("Tomorrow you have macroeconomics at ten.")
    await collect(voice, 2)
    await voice.send_audio(frames(1.0, SPEECH) + frames(2.0, QUIET))
    await asyncio.sleep(0.05)
    assert backend.heard == []


async def test_a_call_with_the_local_voice(monkeypatch):
    from aide.agent import Agent
    from aide.db import Database
    from aide.livecall import CallStore
    from aide.reminders import ReminderStore
    from aide.tools import ToolRegistry
    from aide.tools.reminders import reminder_tools
    from test_api import ROME, FakeClient, done

    for name, value in (("GRACE", 0.2), ("IDLE_TICK", 0.05), ("PROGRESS_EVERY", 0), ("STATUS_EVERY", 5)):
        monkeypatch.setattr(livecall, name, value)
    db = Database(":memory:")
    agent = Agent(FakeClient([done("You've got nothing tomorrow.")]), db,
                  ToolRegistry(reminder_tools(ReminderStore(db.conn), ROME)), model="m", delegate=False, tz=ROME)
    chat = agent.new_conversation(agent="secretary")["id"]
    backend = FakeBackend(speech_seconds=0.05)
    voice = LocalVoice(backend)
    sent = []

    async def send_json(m):
        sent.append(m)

    async def send_audio(pcm):
        sent.append(("audio", len(pcm)))

    async def on_turn(said, turn):
        pass

    c = LiveCall(agent, voice, CallStore(db.conn), chat, "secretary", send_json, send_audio, on_turn, idle_minutes=60)
    run = asyncio.create_task(c.run())
    await voice.send_audio(frames(1.0, SPEECH) + frames(2.0, QUIET))
    for _ in range(200):
        if backend.spoken:
            break
        await asyncio.sleep(0.01)
    assert backend.spoken == [("You've got nothing tomorrow.", "en")]
    assert any(isinstance(m, tuple) for m in sent)
    assert {"type": "caption", "who": "you", "text": "what's on tomorrow"} in sent or any(
        m.get("text") == "what's on tomorrow" for m in sent if isinstance(m, dict))
    await c.end("hangup")
    await asyncio.wait_for(run, 2)
    db.close()


async def test_a_voice_turn_returns_before_the_new_chats_title():
    from aide.agent import Agent
    from aide.db import Database
    from aide.tools import ToolRegistry
    from test_api import ROME, FakeClient, done

    db = Database(":memory:")
    client = FakeClient([done("Nothing tomorrow."), done("Tomorrow's plans")])
    agent = Agent(client, db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    chat = agent.new_conversation(agent="secretary")["id"]
    turn = await agent.respond("app", "what's on tomorrow", chat, voice=True)
    assert turn.reply == "Nothing tomorrow." and agent.db.app_conversation(chat)["title"] is None
    await asyncio.gather(*agent._titling)
    assert agent.db.app_conversation(chat)["title"] == "Tomorrow's plans"
    db.close()


async def test_handing_it_on_is_said_instead_of_one_moment(monkeypatch):
    monkeypatch.setattr(localvoice, "FILLER_AFTER", 0.1)
    monkeypatch.setattr(localvoice, "STILL_EVERY", 10)
    monkeypatch.setattr(localvoice, "STEP_WAIT", 0.02)
    backend = FakeBackend(speech_seconds=0.01)
    voice = LocalVoice(backend)
    await voice.working("u1")
    await voice.step("Asking Secretary")
    await voice.step("Asking Secretary")  # once a turn
    await voice.step("Checking the calendar")  # just spoke: not said
    await asyncio.sleep(0.15)
    assert [t for t, _ in backend.spoken] == ["I'm asking Secretary for you."]


async def test_a_step_after_a_quiet_while(monkeypatch):
    monkeypatch.setattr(localvoice, "FILLER_AFTER", 10)
    monkeypatch.setattr(localvoice, "STEP_GAP", 0.0)
    monkeypatch.setattr(localvoice, "STEP_WAIT", 0.0)
    backend = FakeBackend(speech_seconds=0.01)
    voice = LocalVoice(backend)
    await voice.working("u1")
    await voice.step("Checking the calendar")
    await asyncio.sleep(0.05)
    assert [t for t, _ in backend.spoken] == ["Checking the calendar."]
    it = LocalVoice(FakeBackend(speech_seconds=0.01), language="it")
    await it.working("u1")
    await it.step("Checking the calendar")  # English labels aren't read out in Italian
    await it.step("Asking Coach")
    await asyncio.sleep(0.05)
    assert [t for t, _ in it.backend.spoken] == ["Chiedo a Coach."]


async def test_a_quick_answer_needs_no_step_line(monkeypatch):
    monkeypatch.setattr(localvoice, "FILLER_AFTER", 10)
    monkeypatch.setattr(localvoice, "STEP_GAP", 0.0)
    monkeypatch.setattr(localvoice, "STEP_WAIT", 0.1)
    backend = FakeBackend(speech_seconds=0.01)
    voice = LocalVoice(backend)
    await voice.working("u1")
    await voice.step("Checking the calendar")
    await asyncio.sleep(0.03)
    await voice.say("You're free tomorrow.")
    await asyncio.sleep(0.2)
    assert [t for t, _ in backend.spoken] == ["You're free tomorrow."]


async def test_a_breath_between_a_step_line_and_the_answer(monkeypatch):
    monkeypatch.setattr(localvoice, "FILLER_AFTER", 10)
    monkeypatch.setattr(localvoice, "STEP_GAP", 0.0)
    monkeypatch.setattr(localvoice, "STEP_WAIT", 0.0)
    backend = FakeBackend(speech_seconds=0.5)
    voice = LocalVoice(backend)
    await voice.working("u1")
    await voice.step("Checking the calendar")
    await asyncio.sleep(0.02)
    await voice.say("You're free tomorrow.")
    await asyncio.sleep(0.1)
    events = []
    while not voice._events.empty():
        events.append(voice._events.get_nowait())
    silent = [e for e in events if type(e).__name__ == "Audio" and not any(e.pcm)]
    assert sum(len(a.pcm) for a in silent) == int(localvoice.BREATH * localvoice.RATE) * 2
    await voice.close()


async def test_one_moment_once_a_call(monkeypatch):
    monkeypatch.setattr(localvoice, "FILLER_AFTER", 0.02)
    monkeypatch.setattr(localvoice, "STILL_EVERY", 10)
    backend = FakeBackend(speech_seconds=0.01)
    voice = LocalVoice(backend, language="it")
    for _ in range(2):
        await voice.working("u1")
        await asyncio.sleep(0.08)
        await voice.say("Fatto.")
        await asyncio.sleep(0.05)
    assert [t for t, _ in backend.spoken] == ["Un attimo.", "Fatto.", "Fatto."]
