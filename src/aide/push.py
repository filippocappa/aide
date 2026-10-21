"""Push notifications through APNs. Payloads and devices are in docs/API.md, "Push".

Token-based auth: a JWT signed ES256 with the .p8 key, reused for about 50 minutes (Apple wants it
refreshed at most every 20 and at least every 60). Without a key, push is off: nothing is sent, and
what was to be pushed stays in the app.
"""

import asyncio
import logging
import sqlite3
import time
from datetime import date, datetime, timezone
from pathlib import Path

import httpx
import jwt

log = logging.getLogger(__name__)

HOSTS = {"sandbox": "https://api.sandbox.push.apple.com", "production": "https://api.push.apple.com"}
JWT_TTL = 50 * 60  # seconds
SYNC_EVERY = 10  # seconds: at most one silent sync push per this long
DIGEST_TITLES = {"daily": "Morning", "wake": "Good morning", "evening": "Evening", "weekly": "This week"}  # monthly: the month's name

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    token         TEXT PRIMARY KEY,  -- APNs device token, lowercase hex
    environment   TEXT NOT NULL,     -- sandbox or production: which APNs host
    name          TEXT NOT NULL DEFAULT '',
    registered_at TEXT NOT NULL,     -- UTC
    last_push_at  TEXT               -- UTC, last push APNs accepted
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def check_token(token: str) -> str:
    token = token.strip().lower()
    if not token or len(token) % 2 or any(c not in "0123456789abcdef" for c in token):
        raise ValueError("token must be the APNs device token in hex")
    return token


class Push:
    def __init__(self, conn: sqlite3.Connection, key_path: Path | str | None = None, key_id: str | None = None,
                 team_id: str | None = None, bundle_id: str | None = None,
                 transport: httpx.AsyncBaseTransport | None = None):
        self.conn = conn
        self.conn.executescript(SCHEMA)
        self.key_id, self.team_id, self.bundle_id = key_id, team_id, bundle_id
        self._key: str | None = None
        if key_path and key_id and team_id and bundle_id:
            try:
                self._key = Path(key_path).expanduser().read_text()
            except OSError as e:
                log.error("APNs key %s unreadable (%s): push notifications off", key_path, e)
        self._transport = transport
        self._client: httpx.AsyncClient | None = None
        self._jwt: tuple[str, float] | None = None
        self._sync_task: asyncio.Task | None = None
        self._sync_again = False

    @property
    def enabled(self) -> bool:
        return self._key is not None

    async def close(self) -> None:
        if self._sync_task:
            self._sync_task.cancel()
        if self._client:
            await self._client.aclose()

    # -- devices -----------------------------------------------------------

    def register(self, token: str, environment: str, name: str = "") -> None:
        if environment not in HOSTS:
            raise ValueError("environment must be sandbox or production")
        self.conn.execute(
            "INSERT INTO devices (token, environment, name, registered_at) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(token) DO UPDATE SET environment = excluded.environment, name = excluded.name",
            (check_token(token), environment, name, _now()))

    def devices(self) -> list[dict]:
        rows = self.conn.execute("SELECT * FROM devices ORDER BY registered_at").fetchall()
        return [dict(r) for r in rows]

    def remove(self, token: str) -> None:
        self.conn.execute("DELETE FROM devices WHERE token = ?", (token.strip().lower(),))

    # -- sending -----------------------------------------------------------

    def _token(self) -> str:
        now = time.time()
        if self._jwt is None or now - self._jwt[1] > JWT_TTL:
            signed = jwt.encode({"iss": self.team_id, "iat": int(now)}, self._key, algorithm="ES256",
                                headers={"kid": self.key_id})
            self._jwt = (signed, now)
        return self._jwt[0]

    async def send(self, payload: dict, background: bool = False) -> tuple[int, int]:
        """Send one payload to every device. Returns (sent, failed); with push off, nothing is sent."""
        devices = self.devices()
        if not self.enabled or not devices:
            return 0, len(devices)
        if self._client is None:
            self._client = httpx.AsyncClient(http2=True, transport=self._transport, timeout=15)
        headers = {
            "apns-topic": self.bundle_id,
            "apns-push-type": "background" if background else "alert",
            "apns-priority": "5" if background else "10",
        }
        sent = 0
        for d in devices:
            if await self._send_one(d, payload, headers):
                sent += 1
        return sent, len(devices) - sent

    async def _send_one(self, device: dict, payload: dict, headers: dict) -> bool:
        token = device["token"]
        url = f"{HOSTS[device['environment']]}/3/device/{token}"
        try:
            r = await self._client.post(url, json=payload,
                                        headers={**headers, "authorization": f"bearer {self._token()}"})
        except httpx.HTTPError as e:
            log.warning("push to %s… failed: %s", token[:8], e)
            return False
        if r.status_code == 200:
            self.conn.execute("UPDATE devices SET last_push_at = ? WHERE token = ?", (_now(), token))
            return True
        try:
            reason = r.json().get("reason", "")
        except ValueError:
            reason = ""
        if r.status_code == 410 or reason == "BadDeviceToken":
            log.info("APNs says device %s… is gone (%s): removing it", token[:8], reason or r.status_code)
            self.remove(token)
        else:
            if r.status_code == 403 and reason in ("ExpiredProviderToken", "InvalidProviderToken"):
                self._jwt = None  # sign a fresh one next time
            log.warning("APNs refused a push to %s…: %s %s", token[:8], r.status_code, reason)
        return False

    async def _alert(self, kind: str, title: str, body: str, **extra) -> bool:
        payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default", "thread-id": kind},
                   "aide": {"kind": kind, **extra}}
        sent, _ = await self.send(payload)
        return sent > 0

    async def send_reminder(self, reminder_id: str, title: str, body: str = "") -> bool:
        return await self._alert("reminder", title, body, reminder_id=reminder_id)

    async def send_digest(self, kind: str, greeting: str, month: date | None = None) -> bool:
        title = DIGEST_TITLES.get(kind) or f"{month or datetime.now():%B}"
        return await self._alert("digest", title, greeting, digest=kind)

    async def send_message(self, conversation_id: str, title: str, body: str) -> bool:
        return await self._alert("message", title, body, conversation_id=conversation_id)

    async def send_test(self) -> tuple[int, int]:
        return await self.send({"aps": {"alert": {"title": "Aide", "body": "Push notifications work."},
                                        "sound": "default", "thread-id": "test"}, "aide": {"kind": "test"}})

    # -- silent sync -------------------------------------------------------

    def request_sync(self) -> None:
        """Reminders changed on the server: tell the phone to sync, at most once per SYNC_EVERY seconds."""
        if not self.enabled:
            return
        if self._sync_task and not self._sync_task.done():
            self._sync_again = True  # the running task sends once more when its quiet time ends
            return
        try:
            self._sync_task = asyncio.get_running_loop().create_task(self._sync_loop())
        except RuntimeError:  # no event loop (a script or a test touching the store): nothing to notify
            pass

    async def _sync_loop(self) -> None:
        while True:
            self._sync_again = False
            try:
                await self.send({"aps": {"content-available": 1}, "aide": {"kind": "sync"}}, background=True)
            except Exception:
                log.exception("sync push failed")
            await asyncio.sleep(SYNC_EVERY)
            if not self._sync_again:
                return
