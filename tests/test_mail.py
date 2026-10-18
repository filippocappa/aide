import base64
import email
import json
from email import policy
from pathlib import Path
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import httpx
import pytest

from aide.agent import Agent
from aide.db import Database
from aide.gmail import Gmail, GmailAuthError, body_text, html_to_text
from aide.gmail_auth import _save
from aide.tools import ToolRegistry
from aide.tools.mail import mail_tools

ROME = ZoneInfo("Europe/Rome")
ME = "me@example.com"


def b64(text: str) -> str:
    return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")


def message(id, thread, frm, subject, body, *, to=ME, cc=None, html=False, unread=False, extra=()):
    hdrs = [{"name": "From", "value": frm}, {"name": "To", "value": to}, {"name": "Subject", "value": subject},
            {"name": "Message-ID", "value": f"<{id}@mail>"}, *extra]
    if cc:
        hdrs.append({"name": "Cc", "value": cc})
    part = {"mimeType": "text/html" if html else "text/plain", "body": {"data": b64(body)}}
    return {"id": id, "threadId": thread, "internalDate": "1792321200000", "snippet": body[:40],
            "labelIds": ["INBOX", "UNREAD"] if unread else ["INBOX"],
            "payload": {"mimeType": "multipart/alternative", "headers": hdrs,
                        "parts": [part, {"mimeType": "application/pdf", "filename": "invoice.pdf", "body": {}}]}}


class FakeGoogle:
    """Answers the few Gmail endpoints Aide uses, and records what was sent."""

    def __init__(self, messages, token_status=200):
        self.messages = {m["id"]: m for m in messages}
        self.sent: list[dict] = []
        self.token_calls = 0
        self.token_status = token_status
        self.queries: list[str] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if request.url.host == "oauth2.googleapis.com":
            self.token_calls += 1
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_grant"})
            return httpx.Response(200, json={"access_token": "at", "expires_in": 3600})
        assert request.headers["Authorization"] == "Bearer at"
        if path.endswith("/profile"):
            return httpx.Response(200, json={"emailAddress": ME})
        if path.endswith("/messages/send"):
            self.sent.append(json.loads(request.content))
            return httpx.Response(200, json={"id": "sent1"})
        if path.endswith("/messages"):
            self.queries.append(request.url.params["q"])
            return httpx.Response(200, json={"messages": [{"id": i} for i in self.messages]})
        if "/messages/" in path:
            mid = path.rsplit("/", 1)[1]
            return httpx.Response(200, json=self.messages[mid]) if mid in self.messages else httpx.Response(404)
        if "/threads/" in path:
            tid = path.rsplit("/", 1)[1]
            return httpx.Response(200, json={"id": tid, "messages": [m for m in self.messages.values()
                                                                      if m["threadId"] == tid]})
        return httpx.Response(500)

    def sent_mail(self, i=-1):
        raw = base64.urlsafe_b64decode(self.sent[i]["raw"])
        return email.message_from_bytes(raw, policy=policy.default)


INBOX = [
    message("m1", "t1", "Anna Bianchi <anna@example.com>", "Dinner Friday?", "Are you free Friday at 8?",
            cc="bob@example.com, me@example.com", unread=True,
            extra=[{"name": "Reply-To", "value": "anna.b@example.com"}]),
    message("m2", "t1", ME, "Re: Dinner Friday?", "Yes!", to="anna@example.com"),
    message("m3", "t3", "Shop <news@shop.example>", "Sale",
            "<html><style>p{}</style><p>Big&nbsp;sale</p><p>Today &amp; tomorrow</p></html>", html=True),
]


@pytest.fixture
def google():
    return FakeGoogle(INBOX)


def tools_for(google):
    gmail = Gmail("cid", "secret", "rt", httpx.AsyncClient(transport=httpx.MockTransport(google)))
    return {t.name: t for t in mail_tools(gmail, ROME)}


async def test_search_lists_messages_and_refreshes_token_once(google):
    tools = tools_for(google)
    out = await tools["search_mail"].handler(query="from:anna")
    assert google.queries == ["from:anna"]
    assert "[m1] (thread t1)" in out and "Anna Bianchi <anna@example.com> · Dinner Friday? · unread" in out
    await tools["list_unread"].handler()
    assert google.queries[-1] == "is:unread in:inbox" and google.token_calls == 1


async def test_read_mail_prefers_plain_text_and_lists_attachments(google):
    out = await tools_for(google)["read_mail"].handler(message_id="m1")
    assert "From: Anna Bianchi" in out and "Are you free Friday at 8?" in out and "invoice.pdf" in out


async def test_html_only_mail_is_turned_into_text(google):
    out = await tools_for(google)["read_mail"].handler(message_id="m3")
    assert "Big sale\n" in out and "Today & tomorrow" in out and "<p>" not in out and "p{}" not in out


async def test_read_thread_has_every_message(google):
    out = await tools_for(google)["read_thread"].handler(thread_id="t1")
    assert "2 message(s)" in out and "Are you free" in out and "Yes!" in out


def test_body_text_handles_charset_and_padding():
    data = base64.urlsafe_b64encode("Città".encode("latin-1")).decode()
    msg = {"payload": {"mimeType": "text/plain", "body": {"data": data},
                       "headers": [{"name": "Content-Type", "value": 'text/plain; charset="iso-8859-1"'}]}}
    assert body_text(msg) == "Città"
    assert html_to_text("a<br>b") == "a\nb"


async def test_expired_refresh_token_says_how_to_fix_it():
    tools = tools_for(FakeGoogle(INBOX, token_status=400))
    with pytest.raises(GmailAuthError, match="gmail_auth"):
        await tools["list_unread"].handler()


async def test_reply_goes_to_reply_to_in_the_same_thread(google):
    tools = tools_for(google)
    summary = await tools["reply_mail"].describe(message_id="m1", body="Friday works.")
    assert summary.startswith('Reply to anna.b@example.com, subject "Re: Dinner Friday?":\nFriday works.')
    assert google.sent == []  # describing never sends
    await tools["reply_mail"].handler(message_id="m1", body="Friday works.")
    sent = google.sent_mail()
    assert google.sent[0]["threadId"] == "t1"
    assert sent["To"] == "anna.b@example.com" and sent["Cc"] is None
    assert sent["In-Reply-To"] == "<m1@mail>" and sent["References"] == "<m1@mail>"
    assert sent.get_content().strip() == "Friday works."


async def test_reply_all_copies_others_but_not_me(google):
    await tools_for(google)["reply_mail"].handler(message_id="m1", body="ok", reply_all=True)
    assert google.sent_mail()["Cc"] == "bob@example.com"


async def test_replying_to_my_own_message_goes_to_its_recipients(google):
    summary = await tools_for(google)["reply_mail"].describe(message_id="m2", body="Also, 8:30?")
    assert summary.startswith('Reply to anna@example.com, subject "Re: Dinner Friday?"')


@pytest.mark.parametrize("to", ["not an address", "", "a@b.com, nope"])
async def test_bad_recipients_fail_before_queueing(google, to):
    with pytest.raises(ValueError):
        await tools_for(google)["send_mail"].describe(to=to, subject="Hi", body="Hello")


async def test_header_injection_is_rejected(google):
    with pytest.raises(ValueError):
        await tools_for(google)["send_mail"].describe(to="a@b.com", subject="Hi\nBcc: x@evil.com", body="x")


# -- through the agent: queued, sent only on confirm -------------------------------------


class Block(SimpleNamespace):
    def to_dict(self):
        return dict(vars(self))


class FakeClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    async def _create(self, **kwargs):
        stop_reason, content = self.responses.pop(0)
        return SimpleNamespace(stop_reason=stop_reason, content=content)


async def test_sending_waits_for_confirmation(google):
    db = Database(":memory:")
    args = {"to": "anna@example.com", "subject": "Friday", "body": "See you at 8."}
    client = FakeClient([("tool_use", [Block(type="tool_use", id="t1", name="send_mail", input=args)]),
                         ("end_turn", [Block(type="text", text="Queued.")])])
    agent = Agent(client, db, ToolRegistry(list(tools_for(google).values())), model="m", tz=ROME)
    await agent.reply("main", "tell anna see you at 8")
    assert google.sent == []
    assert agent.pending("main") == ['Send email to anna@example.com, subject "Friday":\nSee you at 8.']
    result = await agent.confirm("main")
    assert result == "✓ Sent to anna@example.com: Friday" and len(google.sent) == 1
    assert google.sent_mail()["To"] == "anna@example.com"


async def test_cancel_sends_nothing(google):
    db = Database(":memory:")
    args = {"message_id": "m1", "body": "No thanks."}
    client = FakeClient([("tool_use", [Block(type="tool_use", id="t1", name="reply_mail", input=args)]),
                         ("end_turn", [Block(type="text", text="Queued.")])])
    agent = Agent(client, db, ToolRegistry(list(tools_for(google).values())), model="m", tz=ROME)
    await agent.reply("main", "say no to anna")
    await agent.cancel("main")
    assert await agent.confirm("main") == "Nothing is waiting for confirmation."
    assert google.sent == []


# -- auth script --------------------------------------------------------------------------


def test_save_replaces_the_line_and_keeps_the_rest(tmp_path: Path):
    env = tmp_path / ".env"
    env.write_text("A=1\nGMAIL_REFRESH_TOKEN=old\nB=2\n")
    _save(env, "GMAIL_REFRESH_TOKEN", "new")
    assert env.read_text() == "A=1\nGMAIL_REFRESH_TOKEN=new\nB=2\n"
    _save(env, "OTHER", "x")
    assert env.read_text().endswith("B=2\nOTHER=x\n") and env.stat().st_mode & 0o777 == 0o600
