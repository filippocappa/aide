"""Mail tools. Reading runs immediately; sending and replying wait for the user's !yes."""

import re
from datetime import datetime
from email.message import EmailMessage
from email.utils import getaddresses, parseaddr
from zoneinfo import ZoneInfo

from ..gmail import Gmail, attachments, body_text, headers
from . import Tool

MAX_RESULTS = 25
BODY_LIMIT = 6000  # one message
THREAD_LIMIT = 15000  # a whole thread
PREVIEW_LIMIT = 600  # body shown in the confirmation summary
ADDRESS = re.compile(r"^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$")


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def _clip(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit].rstrip() + f"\n[… {len(text) - limit} more characters]"


def _addresses(value: str) -> list[str]:
    """Bare addresses from a header or a comma-separated list. Raises on anything that isn't one."""
    out = [addr for _, addr in getaddresses([value]) if addr]
    for addr in out:
        if not ADDRESS.match(addr):
            raise ValueError(f"not an email address: {addr!r}")
    return out


def mail_tools(gmail: Gmail, tz: ZoneInfo) -> list[Tool]:
    def when(msg: dict) -> str:
        return f"{datetime.fromtimestamp(int(msg['internalDate']) / 1000, tz):%a %d %b %Y %H:%M}"

    def line(msg: dict) -> str:
        h = headers(msg)
        unread = " · unread" if "UNREAD" in msg.get("labelIds", []) else ""
        return (f"[{msg['id']}] (thread {msg['threadId']}) {when(msg)} · {h.get('from', '?')} · "
                f"{h.get('subject') or '(no subject)'}{unread}\n    {msg.get('snippet', '')}")

    def full(msg: dict, limit: int) -> str:
        h = headers(msg)
        out = [f"[{msg['id']}] {when(msg)}", f"From: {h.get('from', '?')}", f"To: {h.get('to', '')}"]
        if h.get("cc"):
            out.append(f"Cc: {h['cc']}")
        out.append(f"Subject: {h.get('subject') or '(no subject)'}")
        if files := attachments(msg):
            out.append("Attachments: " + ", ".join(files))
        return "\n".join(out) + "\n\n" + _clip(body_text(msg) or "(no text)", limit)

    async def listing(query: str, max_results: int | None) -> str:
        found = await gmail.search(query, max(1, min(max_results or 10, MAX_RESULTS)))
        return "\n".join(line(m) for m in found) if found else "No messages found."

    async def search_mail(query: str, max_results: int | None = None) -> str:
        return await listing(query, max_results)

    async def list_unread(max_results: int | None = None) -> str:
        return await listing("is:unread in:inbox", max_results)

    async def read_mail(message_id: str) -> str:
        return full(await gmail.message(message_id), BODY_LIMIT)

    async def read_thread(thread_id: str) -> str:
        thread = await gmail.thread(thread_id)
        msgs = thread.get("messages", [])
        each = max(1000, THREAD_LIMIT // max(1, len(msgs)))
        return f"Thread {thread_id}, {len(msgs)} message(s), oldest first:\n\n" + "\n\n---\n\n".join(
            full(m, each) for m in msgs)

    # -- outgoing: built the same way for the summary and for the real send ------------

    def outgoing(to: list[str], subject: str, body: str, cc: list[str]) -> EmailMessage:
        if not to:
            raise ValueError("no recipient")
        if not body.strip():
            raise ValueError("the message is empty")
        msg = EmailMessage()
        msg["To"] = ", ".join(to)
        if cc:
            msg["Cc"] = ", ".join(cc)
        msg["Subject"] = subject
        msg.set_content(body)
        return msg

    def summary(verb: str, msg: EmailMessage, body: str) -> str:
        cc = f", cc {msg['Cc']}" if msg["Cc"] else ""
        return f"{verb} to {msg['To']}{cc}, subject \"{msg['Subject']}\":\n{_clip(body.strip(), PREVIEW_LIMIT)}"

    def new_mail(to: str, subject: str, body: str, cc: str | None) -> EmailMessage:
        return outgoing(_addresses(to), subject, body, _addresses(cc or ""))

    async def reply_to(message_id: str, body: str, reply_all: bool) -> tuple[EmailMessage, str]:
        original = await gmail.message(message_id)
        h = headers(original)
        me = (await gmail.me()).lower()
        to = _addresses(h.get("reply-to") or h.get("from", ""))
        if parseaddr(h.get("from", ""))[1].lower() == me:  # replying to my own message: same recipients
            to = _addresses(h.get("to", ""))
        cc: list[str] = []
        if reply_all:
            seen = {a.lower() for a in to} | {me}
            for addr in _addresses(h.get("to", "")) + _addresses(h.get("cc", "")):
                if addr.lower() not in seen:
                    seen.add(addr.lower())
                    cc.append(addr)
        subject = h.get("subject", "")
        if not subject.lower().startswith("re:"):
            subject = f"Re: {subject}".strip()
        msg = outgoing(to, subject, body, cc)
        if msg_id := h.get("message-id"):
            msg["In-Reply-To"] = msg_id
            msg["References"] = f"{h.get('references', '')} {msg_id}".strip()
        return msg, original["threadId"]

    async def send_mail(to: str, subject: str, body: str, cc: str | None = None) -> str:
        await gmail.send(new_mail(to, subject, body, cc))
        return f"Sent to {to}: {subject}"

    async def describe_send(to: str, subject: str, body: str, cc: str | None = None) -> str:
        return summary("Send email", new_mail(to, subject, body, cc), body)

    async def reply_mail(message_id: str, body: str, reply_all: bool = False) -> str:
        msg, thread_id = await reply_to(message_id, body, reply_all)
        await gmail.send(msg, thread_id)
        return f"Replied to {msg['To']}: {msg['Subject']}"

    async def describe_reply(message_id: str, body: str, reply_all: bool = False) -> str:
        msg, _ = await reply_to(message_id, body, reply_all)
        return summary("Reply" + (" all" if reply_all else ""), msg, body)

    count = {"max_results": {"type": "integer", "description": f"1–{MAX_RESULTS}, default 10"}}
    return [
        Tool("search_mail", "Search the user's Gmail with Gmail search syntax (from:, to:, subject:, after:YYYY/MM/DD, "
             "has:attachment, is:unread, plain words). One line per message, newest first, with the message id "
             "in brackets and the thread id.",
             _obj({"query": {"type": "string"}, **count}, ["query"]), search_mail),
        Tool("list_unread", "List unread messages in the inbox, newest first.", _obj(count, []), list_unread),
        Tool("read_mail", "Read one message in full, by message id.",
             _obj({"message_id": {"type": "string"}}, ["message_id"]), read_mail),
        Tool("read_thread", "Read a whole conversation, by thread id, oldest message first.",
             _obj({"thread_id": {"type": "string"}}, ["thread_id"]), read_thread),
        Tool("send_mail", "Send a new email as the user. Needs the user's confirmation: it is queued, and runs only "
             "when the user replies !yes. Plain text body; write it the way the user would.",
             _obj({"to": {"type": "string", "description": "Comma-separated addresses"},
                   "subject": {"type": "string"}, "body": {"type": "string"},
                   "cc": {"type": "string", "description": "Comma-separated addresses"}}, ["to", "subject", "body"]),
             send_mail, confirm=True, describe=describe_send),
        Tool("reply_mail", "Reply to a message, in its thread. Needs the user's confirmation: it is queued, and runs "
             "only when the user replies !yes. Goes to the sender (or Reply-To); reply_all adds the other recipients.",
             _obj({"message_id": {"type": "string"}, "body": {"type": "string"},
                   "reply_all": {"type": "boolean"}}, ["message_id", "body"]),
             reply_mail, confirm=True, describe=describe_reply, target_arg="message_id"),
    ]
