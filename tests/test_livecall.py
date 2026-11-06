import asyncio

import pytest
from fastapi.testclient import TestClient

from aide import livecall
from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.livecall import (Audio, CallStore, Delegation, Heard, LiveCall, LiveCalls, instructions, pieces,
                           speakable, unconfirmed)
from aide.reminders import ReminderStore
from aide.tools import Tool, ToolRegistry
from aide.tools.reminders import reminder_tools
from test_api import AUTH, ROME, TOKEN, FakeCalendar, FakeClient, call, done


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    for name, value in (("SETTLE", 0.05), ("GRACE", 0.2), ("CONSENT_QUIET", 0.1), ("GOODBYE_SECONDS", 0),
                        ("IDLE_TICK", 0.05), ("PROGRESS_EVERY", 0), ("STATUS_EVERY", 0.05)):
        monkeypatch.setattr(livecall, name, value)


class FakeLive:
    rate = 24000

    def __init__(self):
        self.seconds = 0.0
        self.queue: asyncio.Queue | None = None
        self.audio, self.thoughts, self.answers, self.said = [], [], [], []
        self.closed = False

    def push(self, event) -> None:
        self._q().put_nowait(event)

    def _q(self) -> asyncio.Queue:
        if self.queue is None:
            self.queue = asyncio.Queue()
        return self.queue

    async def send_audio(self, pcm):
        self.audio.append(pcm)

    async def think(self, text, delegation=None):
        self.thoughts.append((delegation, text))

    async def answer(self, delegation, parts):
        self.answers.append((delegation, " ".join(parts)))

    async def say(self, text):
        self.said.append(text)

    async def events(self):
        while (event := await self._q().get()) is not None:
            yield event

    async def close(self):
        self.closed = True


async def mail(to: str, body: str) -> str:
    return f"Sent to {to}"


async def describe_mail(to: str, body: str) -> str:
    return f"Send mail to {to}"


MAIL = Tool("send_mail", "Send mail.", {"type": "object", "properties": {"to": {"type": "string"},
            "body": {"type": "string"}}, "required": ["to", "body"], "additionalProperties": False},
            mail, confirm=True, describe=describe_mail)


@pytest.fixture
def setup():
    db = Database(":memory:")
    store = ReminderStore(db.conn)

    def make(responses=()):
        agent = Agent(FakeClient(responses), db, ToolRegistry([*reminder_tools(store, ROME), MAIL]), model="m",
                      delegate=False, tz=ROME)
        chat = agent.new_conversation(agent="secretary")["id"]
        voice, sent = FakeLive(), []

        async def send_json(m):
            sent.append(m)

        async def send_audio(pcm):
            sent.append(("audio", len(pcm)))

        turns = []

        async def on_turn(said, turn):
            turns.append((said, turn.reply))

        c = LiveCall(agent, voice, CallStore(db.conn), chat, "secretary", send_json, send_audio, on_turn,
                     idle_minutes=60)
        return c, voice, sent, turns, agent, store, chat
    yield make
    db.close()


async def until(check, seconds=2.0):
    for _ in range(int(seconds / 0.01)):
        if check():
            return
        await asyncio.sleep(0.01)
    raise AssertionError("timed out")


async def say(voice, words, delegation=None):
    voice.push(Heard(words))
    if delegation:
        voice.push(Delegation(delegation))


async def test_a_handed_over_request_is_a_chat_turn_by_voice_and_read_back(setup):
    c, voice, sent, turns, agent, store, chat = setup([done("You've got nothing tomorrow.")])
    run = asyncio.create_task(c.run())
    await say(voice, "what's on")
    await say(voice, " tomorrow", "item_1")
    await until(lambda: voice.answers)
    assert voice.answers == [("item_1", "You've got nothing tomorrow.")]
    assert turns == [("what's on tomorrow", "You've got nothing tomorrow.")]
    shown = agent.visible_history("app", conversation=chat)
    assert [m["text"] for m in shown] == ["what's on tomorrow", "You've got nothing tomorrow."]
    assert ", by voice" in str(agent.db.history(agent.db.app_conversation(chat)["id"])[0]["content"])
    await c.end()
    assert await run == "hung up"
    row = CallStore(agent.db.conn).since(chat)
    assert len(row) == 1 and row[0]["requests"] == 1 and row[0]["reason"] == "hung up" and voice.closed
    assert sent[-1]["type"] == "ended"


async def test_steps_go_to_the_voice_as_silent_notes(setup):
    c, voice, sent, *_ = setup([call("list_reminders"), done("Two reminders.")])
    run = asyncio.create_task(c.run())
    await say(voice, "what reminders do I have", "item_1")
    await until(lambda: voice.answers)
    assert ("item_1", "Progress: Checking the reminders. Nothing is done yet.") in voice.thoughts
    assert {"type": "state", "state": "working", "step": "Checking the reminders"} in sent
    await c.end()
    await run


async def test_the_team_talk_goes_to_the_phone_as_it_happens(setup):
    c, voice, sent, *_ = setup([done("Nothing tomorrow.")])
    asked = {"from": "aide", "to": "secretary", "text": "What's on tomorrow?", "ts": "2026-11-06T17:00:00+00:00"}

    async def respond(*args, on_team=None, **kwargs):
        on_team(asked)
        await until(lambda: {"type": "team", "message": asked} in sent)  # before the turn is over
        return await original(*args, **kwargs)

    original, c.agent.respond = c.agent.respond, respond
    run = asyncio.create_task(c.run())
    await say(voice, "what's on tomorrow", "item_1")
    await until(lambda: voice.answers)
    await c.end()
    await run


async def test_a_spoken_yes_confirms_and_an_unclear_one_is_asked_again(setup):
    c, voice, sent, turns, agent, store, chat = setup()
    rem = store.create("Bins")
    agent.client.responses = [call("delete_reminder", reminder_id=rem.id), done("I'll delete Bins.")]
    run = asyncio.create_task(c.run())
    await say(voice, "delete the bins reminder", "item_1")
    await until(lambda: voice.answers)
    assert voice.answers[-1] == ("item_1", "I'll delete Bins. Shall I go ahead?") and c.awaiting

    await say(voice, "okay", "item_2")
    await until(lambda: len(voice.answers) == 2)
    assert "clear yes or no" in voice.answers[-1][1] and store.open() and c.awaiting

    await say(voice, "yes, do it", "item_3")
    await until(lambda: len(voice.answers) == 3)
    assert voice.answers[-1][1].startswith("Done. ✓ Deleted reminder: Bins") and store.open() == []
    answered = next(m for m in sent if m.get("type") == "answered")
    assert answered["ids"] == [1] and answered["confirmed"] and answered["result"].startswith("✓")
    assert agent.client.responses == []  # no model call for the yes
    assert agent.visible_history("app", conversation=chat)[-1]["text"] == "✓ Deleted reminder: Bins"
    await c.end()
    await run


async def test_an_italian_call_hears_its_own_lines_in_italian(setup):
    c, voice, sent, turns, agent, store, chat = setup()
    rem = store.create("Bins")
    agent.client.responses = [call("delete_reminder", reminder_id=rem.id), done("Cancello il promemoria Bins.")]
    run = asyncio.create_task(c.run())
    await say(voice, "cancella il promemoria della spazzatura", "item_1")
    await until(lambda: voice.answers)
    assert voice.answers[-1] == ("item_1", "Cancello il promemoria Bins. Procedo?")
    await say(voice, "sì, fallo", "item_2")
    await until(lambda: len(voice.answers) == 2)
    assert voice.answers[-1][1] == "Fatto." and store.open() == []
    await c.end()
    await run


async def test_a_no_cancels_and_a_yes_nobody_handed_over_is_read_after_the_quiet(setup):
    c, voice, sent, turns, agent, store, chat = setup()
    a, b = store.create("Bins"), store.create("Milk")
    agent.client.responses = [call("delete_reminder", reminder_id=a.id), done("Delete Bins?"), done("Bins"),
                              call("delete_reminder", reminder_id=b.id), done("Delete Milk?")]  # "Bins": the title
    run = asyncio.create_task(c.run())
    await say(voice, "delete bins", "item_1")
    await until(lambda: voice.answers)
    await say(voice, "no, lascia stare", "item_2")
    await until(lambda: len(voice.answers) == 2)
    assert voice.answers[-1][1] == "Va bene, lascio stare." and [r.title for r in store.open()] == ["Bins", "Milk"]

    await say(voice, "delete milk", "item_3")
    await until(lambda: len(voice.answers) == 3)
    await say(voice, "yes")  # the voice didn't hand it over
    await until(lambda: voice.said)
    assert voice.said[0].startswith("Done.") and [r.title for r in store.open()] == ["Bins"]
    await c.end()
    await run


async def test_mail_is_confirmed_on_the_screen_not_by_voice(setup):
    c, voice, sent, turns, agent, *_ = setup([call("send_mail", to="Marco", body="Hi"), done("Mail for Marco.")])
    run = asyncio.create_task(c.run())
    await say(voice, "write to Marco", "item_1")
    await until(lambda: voice.answers)
    assert voice.answers[-1][1] == "Mail for Marco. It's on your screen to confirm." and c.awaiting == []
    await c.end()
    await run


async def test_words_over_the_voice_flush_the_phone_and_are_no_yes(setup):
    c, voice, sent, turns, agent, store, chat = setup()
    rem = store.create("Bins")
    agent.client.responses = [call("delete_reminder", reminder_id=rem.id), done("Delete Bins?")]
    run = asyncio.create_task(c.run())
    await say(voice, "delete bins", "item_1")
    await until(lambda: voice.answers)
    voice.push(Audio(b"\0\0" * 24000))  # a second of the voice asking
    await until(lambda: ("audio", 48000) in sent)
    await say(voice, "yes")  # its own words back through the speaker
    await until(lambda: {"type": "interrupted"} in sent)
    await asyncio.sleep(0.3)
    assert voice.said == [] and store.open() and c.awaiting
    await c.end()
    await run


async def test_a_goodbye_ends_the_call(setup):
    c, voice, *_ = setup()
    run = asyncio.create_task(c.run())
    await say(voice, "ok bye")
    assert await asyncio.wait_for(run, 2) == "goodbye"


async def test_quiet_hangs_up(setup):
    c, voice, *_ = setup()
    c.idle = 0.1
    assert await asyncio.wait_for(c.run(), 2) == "idle"
    assert voice.said == ["I'll hang up now. Call me back any time."]


async def test_the_app_can_say_words_for_the_user(setup):
    c, voice, sent, turns, *_ = setup([done("Question 1 of 5.")])
    run = asyncio.create_task(c.run())
    await c.typed("Quiz me")
    await until(lambda: voice.said)
    assert turns == [("Quiz me", "Question 1 of 5.")] and voice.said == ["Question 1 of 5."]
    await c.end()
    await run


def test_replies_become_words_in_pieces():
    assert speakable("**Tomorrow**\n- Dentist at 10\n- [Gym](https://x.y) at 18") == \
        "Tomorrow. Dentist at 10. Gym at 18."
    long = " ".join(f"Sentence number {i} is here." for i in range(200))
    parts = pieces(long)
    assert len(parts) == 3 and all(len(p) <= livecall.PIECE_CHARS for p in parts)
    assert parts[-1].endswith("The rest is in the chat.") and parts[0].startswith("Sentence number 0")
    assert pieces("Short.") == ["Short."]


def test_instructions_carry_the_chat_so_far():
    text = instructions("Professor", [{"role": "user", "text": "Quiz me"}, {"role": "assistant", "text": "Q1?"}])
    assert "You are Professor" in text and "User: Quiz me\nProfessor: Q1?" in text


def test_the_call_endpoint(monkeypatch):
    db = Database(":memory:")
    store = ReminderStore(db.conn)
    agent = Agent(FakeClient([done("Nothing tomorrow.")]), db, ToolRegistry(reminder_tools(store, ROME)),
                  model="m", delegate=False, tz=ROME)
    voices = []

    async def connect(text):
        voices.append(FakeLive())
        return voices[-1]

    off = TestClient(create_app(agent, store, FakeCalendar([]), ROME, TOKEN))
    assert off.get("/v1/voice", headers=AUTH).json() == {"live": False}
    client = TestClient(create_app(agent, store, FakeCalendar([]), ROME, TOKEN,
                                   calls=LiveCalls(agent, db.conn, connect)))
    assert client.get("/v1/voice", headers=AUTH).json() == {"live": True}
    chat = agent.new_conversation(agent="secretary")["id"]
    with pytest.raises(Exception):
        with client.websocket_connect(f"/v1/voice/call?conversation={chat}") as ws:  # no token
            ws.receive_json()
    with client.websocket_connect(f"/v1/voice/call?conversation={chat}", headers=AUTH) as ws:
        assert ws.receive_json() == {"type": "started", "rate": 24000, "agent": "secretary"}
        assert ws.receive_json() == {"type": "state", "state": "listening"}
        ws.send_bytes(b"\1\0" * 480)
        ws.send_json({"type": "say", "text": "what's on tomorrow"})
        turn = next(m for m in iter(ws.receive_json, None) if m["type"] == "turn")
        assert turn["text"] == "what's on tomorrow" and turn["reply"] == "Nothing tomorrow."
        ws.send_json({"type": "end"})
        ended = next(m for m in iter(ws.receive_json, None) if m["type"] == "ended")
        assert ended["reason"] == "hung up"
    assert voices[0].audio == [b"\1\0" * 480] and voices[0].said == ["Nothing tomorrow."]
    calls = client.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["calls"]
    assert [(c["agent"], c["requests"]) for c in calls] == [("secretary", 1)]
    # Only the calls from the first message shown on: a page of the last 2 messages starts after this one.
    agent.client.responses = [done("Hi.")]
    client.post("/v1/chat", json={"text": "hello", "conversation_id": chat}, headers=AUTH)
    assert client.get(f"/v1/history?conversation_id={chat}&limit=2", headers=AUTH).json()["calls"] == []
    assert len(client.get(f"/v1/history?conversation_id={chat}&limit=4", headers=AUTH).json()["calls"]) == 1
    db.close()


def test_a_queued_reply_loses_how_to_confirm_it():
    """The call asks right after, so "confirm it in the app" is dropped (Haiku kept saying it)."""
    assert unconfirmed("Ho preparato lo spostamento della corsa alle 18. Ti chiedo conferma nell'app per applicarlo.") \
        == "Ho preparato lo spostamento della corsa alle 18."
    assert unconfirmed("I'll move the run to 18:00. Tap Confirm in the app.") == "I'll move the run to 18:00."
    assert unconfirmed("Confermi?") == "Confermi?"  # nothing left: kept as it was
