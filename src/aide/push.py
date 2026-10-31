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
    last_push_at  TEXT,              -- UTC, last push APNs accepted
    app           TEXT NOT NULL DEFAULT 'ios'  -- ios or mac: the Mac app has its own bundle ID (the topic)
);
"""
APPS = ("ios", "mac")
# Alerts only the phone needs: a tram to catch is the phone's (silent pushes are the phone's too).
PHONE_ONLY = {"transit"}


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
        columns = {r[1] for r in self.conn.execute("PRAGMA table_info(devices)")}
        if "app" not in columns:  # a database from before the Mac app
            self.conn.execute("ALTER TABLE devices ADD COLUMN app TEXT NOT NULL DEFAULT 'ios'")
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

    def register(self, token: str, environment: str, name: str = "", app: str = "ios") -> None:
        if environment not in HOSTS:
            raise ValueError("environment must be sandbox or production")
        if app not in APPS:
            raise ValueError("app must be ios or mac")
        self.conn.execute(
            "INSERT INTO devices (token, environment, name, registered_at, app) VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT(token) DO UPDATE SET environment = excluded.environment, name = excluded.name, "
            "app = excluded.app",
            (check_token(token), environment, name, _now(), app))

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

    async def send(self, payload: dict, background: bool = False, collapse: str | None = None) -> tuple[int, int]:
        """Send one payload to every device. Returns (sent, failed); with push off, nothing is sent."""
        sent, failed, _ = await self._deliver(payload, background, collapse)
        return sent, failed

    async def _deliver(self, payload: dict, background: bool = False,
                       collapse: str | None = None) -> tuple[int, int, bool]:
        """(sent, failed, retry): `retry` when nothing went out but every failure can pass, so a later try may.
        `collapse`: a newer push with the same id replaces the older one in Notification Center."""
        devices = self.devices()
        if background or payload.get("aide", {}).get("kind") in PHONE_ONLY:
            devices = [d for d in devices if d["app"] == "ios"]
        if not self.enabled or not devices:
            return 0, len(devices), False
        headers = {
            "apns-push-type": "background" if background else "alert",
            "apns-priority": "5" if background else "10",
        }
        if collapse:
            headers["apns-collapse-id"] = collapse[:64]
        sent, retry = 0, True
        for d in devices:
            topic = f"{self.bundle_id}.mac" if d["app"] == "mac" else self.bundle_id
            status, reason = await self._send_one(d, payload, {"apns-topic": topic, **headers})
            if status == 200:
                sent += 1
            else:
                retry = retry and self.transient(status, reason)
        return sent, len(devices) - sent, retry and not sent

    async def _post(self, token: str, environment: str, payload: dict, headers: dict) -> tuple[int, str]:
        """One request to APNs: (status, reason), status 0 when it didn't get there."""
        if self._client is None:
            self._client = httpx.AsyncClient(http2=True, transport=self._transport, timeout=15)
        url = f"{HOSTS[environment]}/3/device/{token}"
        try:
            r = await self._client.post(url, json=payload,
                                        headers={**headers, "authorization": f"bearer {self._token()}"})
        except httpx.HTTPError as e:
            log.warning("push to %s… failed: %s", token[:8], e)
            return 0, ""
        if r.status_code == 200:
            return 200, ""
        try:
            reason = r.json().get("reason", "")
        except ValueError:
            reason = ""
        if r.status_code == 403 and reason in ("ExpiredProviderToken", "InvalidProviderToken"):
            self._jwt = None  # sign a fresh one next time
        return r.status_code, reason

    @staticmethod
    def gone(status: int, reason: str) -> bool:
        """APNs says the token is no good any more. Not BadDeviceToken: APNs also answers that for a good token sent
        to the other host (a Debug build installed over a TestFlight one, or the reverse), and the app registers
        again on launch with the right environment."""
        return status == 410 or reason == "Unregistered"

    @staticmethod
    def transient(status: int, reason: str) -> bool:
        """A failure that can pass: no answer, throttled, APNs down, or a JWT that expired (it's signed afresh)."""
        return status in (0, 429) or status >= 500 or reason == "ExpiredProviderToken"

    async def _send_one(self, device: dict, payload: dict, headers: dict) -> tuple[int, str]:
        token = device["token"]
        status, reason = await self._post(token, device["environment"], payload, headers)
        if status == 200:
            self.conn.execute("UPDATE devices SET last_push_at = ? WHERE token = ?", (_now(), token))
        elif self.gone(status, reason):
            log.info("APNs says device %s… is gone (%s): removing it", token[:8], reason or status)
            self.remove(token)
        elif reason == "BadDeviceToken":
            log.warning("APNs says device %s… is a bad token for %s: kept, the app's next registration fixes the "
                        "environment if that's it", token[:8], device["environment"])
        elif status:
            log.warning("APNs refused a push to %s…: %s %s", token[:8], status, reason)
        return status, reason

    async def send_live(self, token: str, environment: str, payload: dict, priority: int = 5) -> tuple[int, str]:
        """A Live Activity push (docs/API.md, "Live Activities") to a push-to-start or an activity's token."""
        if not self.enabled:
            return 0, ""
        headers = {"apns-topic": f"{self.bundle_id}.push-type.liveactivity", "apns-push-type": "liveactivity",
                   "apns-priority": str(priority)}
        return await self._post(token, environment, payload, headers)

    @staticmethod
    def _alert_payload(kind: str, title: str, body: str, level: str | None = None, **extra) -> dict:
        payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default", "thread-id": kind},
                   "aide": {"kind": kind, **extra}}
        if level:
            payload["aps"]["interruption-level"] = level
        return payload

    async def _alert(self, kind: str, title: str, body: str, level: str | None = None, collapse: str | None = None,
                     **extra) -> bool:
        sent, _ = await self.send(self._alert_payload(kind, title, body, level, **extra), collapse=collapse)
        return sent > 0

    async def send_reminder(self, reminder_id: str, title: str, body: str = "") -> bool | None:
        """True when it went out; None when it didn't but a later try may (no answer, throttled, APNs down)."""
        sent, _, retry = await self._deliver(self._alert_payload("reminder", title, body, reminder_id=reminder_id))
        return True if sent else None if retry else False

    async def send_digest(self, kind: str, greeting: str, month: date | None = None) -> bool:
        title = DIGEST_TITLES.get(kind) or f"{month or datetime.now():%B}"
        return await self._alert("digest", title, greeting, digest=kind)

    async def send_message(self, conversation_id: str, title: str, body: str, routine: int | None = None) -> bool:
        """`routine`: a routine's or watch's post, which the app shows as a note on Today."""
        return await self._alert("message", title, body, collapse=f"message-{conversation_id}",
                                 conversation_id=conversation_id,
                                 **({"routine": routine} if routine is not None else {}))

    async def send_lecture(self, lecture_id: str, title: str, body: str) -> bool:
        return await self._alert("lecture", title, body, lecture_id=lecture_id)

    async def send_moodle(self, title: str, body: str, login: bool = False, files: list[str] | None = None) -> bool:
        return await self._alert("moodle", title, body, **({"login": True} if login else {}),
                                 **({"files": files} if files else {}))

    async def send_errand(self, errand_id: int, conversation_id: str | None, title: str, body: str,
                          level: str | None = None) -> bool:
        """A browser errand that needs the user (time-sensitive: a login, a Confirm) or is over."""
        return await self._alert("errand", title, body, level=level, collapse=f"errand-{errand_id}", errand_id=errand_id,
                                 **({"conversation_id": conversation_id} if conversation_id else {}))

    async def send_transit(self, alert_id: int, title: str, body: str) -> bool:
        # Time-sensitive: it's worth breaking through a Focus, and stale a few minutes later.
        return await self._alert("transit", title, body, level="time-sensitive", alert_id=alert_id)

    async def request_location(self) -> bool:
        """Ask the phone for a fresh location fix (silent): a tram alert needs to know the walk."""
        sent, _ = await self.send({"aps": {"content-available": 1}, "aide": {"kind": "location"}}, background=True)
        return sent > 0

    async def send_test(self) -> tuple[int, int]:
        return await self.send({"aps": {"alert": {"title": "Aide", "body": "Push notifications work."},
                                        "sound": "default", "thread-id": "test"}, "aide": {"kind": "test"}})

    # -- silent sync -------------------------------------------------------

    def request_sync(self) -> None:
        """Reminders (or a count the phone writes to Health) changed on the server: tell the phone to sync, at most
        once per SYNC_EVERY seconds."""
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
