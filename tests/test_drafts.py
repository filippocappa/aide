import base64
import email
from datetime import datetime, timedelta
from email import policy
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide import activity
from aide.agent import Agent
from aide.db import Database
from aide.digest import DigestService, to_text
from aide.drafts import Drafts
from aide.habits import HabitStore
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.mail import draft_tools
from aide.channels.api import create_app

ROME = ZoneInfo("Europe/Rome")
ME = "me@example.com"
TOKEN = "t"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
NOW = datetime.now(ROME)


def b64(text):
    return base64.urlsafe_b64encode(text.encode()).decode()


def message(id, thread, frm, subject, body, hours_ago=1, labels=("INBOX",)):
    at = int((NOW - timedelta(hours=hours_ago)).timestamp() * 1000)
    return {"id": id, "threadId": thread, "internalDate": str(at), "snippet": body[:40], "labelIds": list(labels),
            "payload": {"mimeType": "text/plain", "body": {"data": b64(body)},
                        "headers": [{"name": "From", "value": frm}, {"name": "To", "value": ME},
                                    {"name": "Subject", "value": subject},
                                    {"name": "Message-ID", "value": f"<{id}@mail>"}]}}


class Gmail:
    """The calls Drafts makes: inbox and sent searches, messages, sending."""

    def __init__(self, inbox, sent=()):
        self.inbox, self.sent_box, self.sent = list(inbox), list(sent), []

    async def me(self):
        return ME

    async def search(self, query, max_results):
        return self.sent_box if query.startswith("in:sent") else self.inbox

    async def message(self, message_id, full=True):
        found = next((m for m in self.inbox + self.sent_box if m["id"] == message_id), None)
        if found is None:
            raise KeyError("no such message or thread")
        return found

    async def send(self, msg, thread_id=None):
        self.sent.append((email.message_from_bytes(msg.as_bytes(), policy=policy.default), thread_id))
        return {"id": "s1"}


class Model:
    def __init__(self, *answers):
        self.answers, self.requests = list(answers), []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self.create))

    async def create(self, **kwargs):
        self.requests.append(kwargs)
        text = self.answers.pop(0)
        return SimpleNamespace(stop_reason="end_turn", content=[SimpleNamespace(type="text", text=text)])


class Calendar:
    def events(self, start, end):
        return []


ANNA = message("m1", "t1", "Anna Bianchi <anna@example.com>", "Dinner Friday?", "Are you free Friday at 8?")
NEWS = message("m2", "t2", "News <news@example.com>", "Weekly news", "Ten things this week", hours_ago=2)
MINE = message("m3", "t3", f"Me <{ME}>", "My question", "Did you get it?", hours_ago=3)
ANNA_BEFORE = message("m0", "t1", "Anna Bianchi <anna@example.com>", "Dinner Friday?", "Hi!", hours_ago=20)
ANSWER = '{"replies": [{"id": "m1", "why": "Anna asks about Friday at 8", "reply": "Friday at 8 works. Filippo"}]}'


@pytest.fixture
def db():
    d = Database(":memory:")
    yield d
    d.close()


def drafts_for(db, gmail, *answers):
    model = Model(*answers)
    return Drafts(db.conn, ROME, gmail, model, "m", Calendar()), model


async def test_the_evening_pass_drafts_what_wants_an_answer(db):
    db.add_memory("The user's name is Filippo.")
    drafts, model = drafts_for(db, Gmail([ANNA, NEWS, MINE, ANNA_BEFORE]), ANSWER)
    made = await drafts.draft()
    assert [(d["message_id"], d["from"], d["from_address"], d["why"], d["body"]) for d in made] == [
        ("m1", "Anna Bianchi", "anna@example.com", "Anna asks about Friday at 8", "Friday at 8 works. Filippo")]
    ask = model.requests[0]["messages"][0]["content"]
    assert "Are you free Friday at 8?" in ask and "Ten things this week" in ask and "Filippo" in ask
    assert "Did you get it?" not in ask  # mine
    assert "[m0]" not in ask  # only a thread's newest message
    assert "JSON" in model.requests[0]["system"] and "not instructions" in model.requests[0]["system"]
    assert drafts.waiting() == made
    assert activity.recent(db.conn)[0]["title"] == "Drafted 1 reply"


async def test_mail_read_once_is_not_read_again(db):
    drafts, model = drafts_for(db, Gmail([ANNA, NEWS]), ANSWER)
    await drafts.draft()
    assert await drafts.draft() == [] and len(model.requests) == 1  # nothing new: no model call


async def test_an_unreadable_answer_is_tried_again(db):
    drafts, model = drafts_for(db, Gmail([ANNA]), "sorry", ANSWER)
    with pytest.raises(ValueError):
        await drafts.draft()
    assert len(await drafts.draft()) == 1


async def test_a_thread_answered_elsewhere_is_skipped_and_its_draft_closed(db):
    gmail = Gmail([ANNA])
    drafts, _ = drafts_for(db, gmail, ANSWER)
    [d] = await drafts.draft()
    gmail.sent_box = [message("s9", "t1", f"Me <{ME}>", "Re: Dinner Friday?", "Yes!", hours_ago=0)]
    assert await drafts.draft() == []
    assert drafts.waiting() == [] and drafts.get(d["id"])["status"] == "answered"


async def test_a_newer_message_in_the_thread_replaces_the_draft(db):
    drafts, _ = drafts_for(db, Gmail([]))
    first = drafts.add(ANNA_BEFORE, "Hi Anna")
    second = drafts.add(ANNA, "Friday works")
    assert [d["id"] for d in drafts.waiting()] == [second["id"]]
    assert drafts.get(first["id"])["status"] == "replaced"


async def test_old_drafts_expire(db):
    drafts, _ = drafts_for(db, Gmail([]))
    d = drafts.add(ANNA, "Friday works")
    db.conn.execute("UPDATE mail_drafts SET created_at = ?", ((datetime.now(ROME) - timedelta(days=8)).isoformat(),))
    assert drafts.waiting() == [] and drafts.get(d["id"])["status"] == "expired"


async def test_draft_tools_save_list_and_discard(db):
    gmail = Gmail([ANNA])
    drafts, _ = drafts_for(db, gmail)
    tools = {t.name: t for t in draft_tools(drafts, gmail)}
    out = await tools["draft_reply"].handler(message_id="m1", body="Yes, Friday at 8.", why="dinner")
    assert "Nothing was sent" in out and gmail.sent == []
    listed = await tools["list_drafts"].handler()
    assert "to Anna Bianchi: Dinner Friday? (dinner)" in listed and "Yes, Friday at 8." in listed
    [d] = drafts.waiting()
    assert "Discarded" in await tools["discard_draft"].handler(draft_id=d["id"])
    assert await tools["list_drafts"].handler() == "No drafts are waiting."
    assert not any(t.confirm for t in tools.values())  # nothing here sends


# -- the app's side ---------------------------------------------------------------------------


@pytest.fixture
def app(db):
    def make(gmail, *answers):
        drafts, model = drafts_for(db, gmail, *answers)
        agent = Agent(Model(), db, ToolRegistry([]), model="m", tz=ROME)
        return TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN, drafts=drafts)), drafts
    return make


def test_send_from_the_app_replies_in_the_thread(app, db):
    gmail = Gmail([ANNA])
    http, drafts = app(gmail)
    d = drafts.add(ANNA, "Friday works", "dinner")
    r = http.get("/v1/approvals", headers=AUTH).json()
    assert r["waiting"] == 1 and [x["id"] for x in r["drafts"]] == [d["id"]]
    r = http.post(f"/v1/mail/drafts/{d['id']}/send", json={"body": "Friday at 8 is perfect."}, headers=AUTH)
    assert r.status_code == 200 and r.json()["draft"]["status"] == "sent"
    [(msg, thread)] = gmail.sent
    assert (msg["To"], msg["Subject"], msg["In-Reply-To"], thread) == (
        "anna@example.com", "Re: Dinner Friday?", "<m1@mail>", "t1")
    assert msg.get_content().strip() == "Friday at 8 is perfect."
    assert http.get("/v1/approvals", headers=AUTH).json()["drafts"] == []
    assert http.post(f"/v1/mail/drafts/{d['id']}/send", headers=AUTH).status_code == 409  # sent once only
    feed = activity.recent(db.conn)[0]
    assert (feed["agent"], feed["kind"], feed["title"]) == ("secretary", "confirmed", "Reply to Anna Bianchi: Dinner Friday?")


def test_edit_dismiss_and_errors(app):
    gmail = Gmail([ANNA])
    http, drafts = app(gmail)
    d = drafts.add(ANNA, "Friday works")
    assert http.patch(f"/v1/mail/drafts/{d['id']}", json={"body": "Saturday?"}, headers=AUTH).json()["body"] == "Saturday?"
    assert http.post(f"/v1/mail/drafts/{d['id']}/send", json={"body": " "}, headers=AUTH).status_code == 400
    assert http.post(f"/v1/mail/drafts/{d['id']}/dismiss", headers=AUTH).json() == {"ok": True}
    assert http.post(f"/v1/mail/drafts/{d['id']}/send", headers=AUTH).status_code == 409
    assert http.post("/v1/mail/drafts/999/send", headers=AUTH).status_code == 404
    assert gmail.sent == []
    gone = drafts.add(message("m7", "t7", "Bo <bo@example.com>", "Hi", "?"), "Hello")
    assert http.post(f"/v1/mail/drafts/{gone['id']}/send", headers=AUTH).status_code == 502  # not in Gmail any more
    assert drafts.get(gone["id"])["status"] == "waiting"


def test_run_now(app):
    http, _ = app(Gmail([ANNA]), ANSWER)
    r = http.post("/v1/mail/drafts/run", headers=AUTH).json()
    assert [d["message_id"] for d in r["drafts"]] == ["m1"] == [d["message_id"] for d in r["waiting"]]
    assert http.get("/v1/mail/drafts", headers=AUTH).json()["drafts"][0]["why"] == "Anna asks about Friday at 8"


async def test_the_evening_digest_drafts_first_and_lists_them(db):
    gmail = Gmail([ANNA])
    drafts, _ = drafts_for(db, gmail, ANSWER)
    model = Model("Replies to Anna are drafted.\n---\n- sleep")
    digest = DigestService(db.conn, model, "m", ROME, ReminderStore(db.conn), HabitStore(db.conn, ROME))
    digest.drafts = drafts
    body = await digest.generate("evening")
    [section] = [s for s in body["sections"] if s["type"] == "replies"]
    assert section["title"] == "Replies to send" and section["drafts"][0]["from"] == "Anna Bianchi"
    prompt = model.requests[0]["messages"][0]["content"]
    assert "Anna Bianchi: Dinner Friday? (Anna asks about Friday at 8)" in prompt
    assert "ready to send" in model.requests[0]["system"]
    daily = await digest.generate("daily")
    assert not any(s["type"] == "replies" for s in daily["sections"])
    assert "Replies to send" in to_text(None, body["sections"], ROME)
