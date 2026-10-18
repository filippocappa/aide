"""Gmail over its REST API with an OAuth refresh token. Reads mail and sends it; nothing else.

The refresh token comes from `python -m aide.gmail_auth` (run once by hand) and lives in .env.
"""

import asyncio
import base64
import html
import logging
import re
import time
from email.message import EmailMessage

import httpx

log = logging.getLogger(__name__)

API = "https://gmail.googleapis.com/gmail/v1/users/me"
TOKEN_URL = "https://oauth2.googleapis.com/token"
# Read everything, send as the user. No modify/delete: Aide can't archive, label or trash mail.
SCOPES = ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.send"]


class GmailAuthError(RuntimeError):
    pass


class Gmail:
    def __init__(self, client_id: str, client_secret: str, refresh_token: str, http: httpx.AsyncClient | None = None):
        self._creds = {"client_id": client_id, "client_secret": client_secret, "refresh_token": refresh_token}
        self._http = http or httpx.AsyncClient(timeout=30)
        self._token = ""
        self._expires = 0.0
        self._me = ""

    async def _access_token(self) -> str:
        if time.monotonic() < self._expires - 60:
            return self._token
        r = await self._http.post(TOKEN_URL, data={**self._creds, "grant_type": "refresh_token"})
        if r.status_code in (400, 401):
            # invalid_grant: revoked, or a "Testing" consent screen's 7-day token ran out.
            log.error("Gmail token refresh failed: %s %s", r.status_code, r.text[:200])
            raise GmailAuthError("Gmail access has expired or was revoked. Run `uv run python -m aide.gmail_auth` again.")
        r.raise_for_status()
        body = r.json()
        self._token, self._expires = body["access_token"], time.monotonic() + body.get("expires_in", 3600)
        return self._token

    async def _request(self, method: str, path: str, **kwargs) -> dict:
        headers = {"Authorization": f"Bearer {await self._access_token()}"}
        r = await self._http.request(method, API + path, headers=headers, **kwargs)
        if r.status_code == 404:
            raise KeyError("no such message or thread")
        r.raise_for_status()
        return r.json()

    async def me(self) -> str:
        """The account's own address, cached."""
        if not self._me:
            self._me = (await self._request("GET", "/profile"))["emailAddress"]
        return self._me

    async def search(self, query: str, max_results: int) -> list[dict]:
        """Messages matching a Gmail search query, newest first, as metadata only."""
        listing = await self._request("GET", "/messages", params={"q": query, "maxResults": max_results})
        ids = [m["id"] for m in listing.get("messages", [])]
        return list(await asyncio.gather(*(self.message(i, full=False) for i in ids)))

    async def message(self, message_id: str, full: bool = True) -> dict:
        params = {"format": "full"} if full else {
            "format": "metadata", "metadataHeaders": ["From", "To", "Subject", "Date"]}
        return await self._request("GET", f"/messages/{message_id}", params=params)

    async def thread(self, thread_id: str) -> dict:
        return await self._request("GET", f"/threads/{thread_id}", params={"format": "full"})

    async def send(self, msg: EmailMessage, thread_id: str | None = None) -> dict:
        body = {"raw": base64.urlsafe_b64encode(msg.as_bytes()).decode()}
        if thread_id:
            body["threadId"] = thread_id
        return await self._request("POST", "/messages/send", json=body)


# -- reading messages ------------------------------------------------------------


def headers(msg: dict) -> dict[str, str]:
    """Header values by lower-case name (the first one wins)."""
    out: dict[str, str] = {}
    for h in msg.get("payload", {}).get("headers", []):
        out.setdefault(h["name"].lower(), h["value"])
    return out


def _decode(part: dict) -> str:
    data = part.get("body", {}).get("data")
    if not data:
        return ""
    raw = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
    charset = "utf-8"
    for h in part.get("headers", []):
        if h["name"].lower() == "content-type" and (m := re.search(r'charset="?([\w-]+)', h["value"], re.I)):
            charset = m.group(1)
    try:
        return raw.decode(charset, errors="replace")
    except LookupError:
        return raw.decode("utf-8", errors="replace")


def _parts(part: dict):
    yield part
    for sub in part.get("parts", []):
        yield from _parts(sub)


def html_to_text(markup: str) -> str:
    markup = re.sub(r"(?is)<(script|style|head)\b.*?</\1>", "", markup)
    markup = re.sub(r"(?i)<br\s*/?>|</(p|div|tr|li|h\d)>", "\n", markup)
    text = html.unescape(re.sub(r"<[^>]+>", "", markup))
    return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t\xa0]+", " ", text)).strip()


def body_text(msg: dict) -> str:
    """The readable body: the plain-text part if there is one, else the HTML part as text."""
    parts = list(_parts(msg.get("payload", {})))
    for mime, convert in (("text/plain", str), ("text/html", html_to_text)):
        texts = [_decode(p) for p in parts if p.get("mimeType") == mime and not p.get("filename")]
        if text := "\n\n".join(t for t in texts if t.strip()):
            return convert(text).strip()
    return ""


def attachments(msg: dict) -> list[str]:
    return [p["filename"] for p in _parts(msg.get("payload", {})) if p.get("filename")]
