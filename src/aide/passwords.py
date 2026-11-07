"""Saved passwords (Settings → Passwords): logins the user adds in the app for the server's own code to use, never the
model's. The first user is the UniTo login (unito.py), so Esse3 can be read without the user logging in again.

How they're kept:
- The username and the password are encrypted with AES-256-GCM, a fresh nonce each time, as `v1 | nonce | ciphertext`.
  The associated data binds each one to its row, its field and its sites: a ciphertext moved to another row or field,
  or `sites` edited in the database, no longer decrypts.
- The key is 32 random bytes, never in the repo, `.env`, `data/` or the backups: a systemd credential
  (`deploy/aide-passwords.conf`, set up once, README "Passwords") handed to the service in its own private tmpfs,
  else an owner-only file. A check value tells a wrong key from a right one: with a wrong key nothing is shown or
  written, and a new key is never made over saved passwords.
- Sites are fixed when an entry is added: a password is only given out for an https address on one of them (`use`).
- Nothing here ever logs, returns or raises with a username or password; the API returns entries without them.
"""

import json
import logging
import os
import secrets
import sqlite3
import time
from collections import deque
from pathlib import Path
from urllib.parse import urlparse

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .browser import _SECOND_LEVEL, check_site, site_of
from .db import utcnow

log = logging.getLogger(__name__)

CREDENTIAL = "aide-passwords"  # the systemd credential's name
KEY_FILE = Path("~/.config/aide/passwords.key")  # the fallback, owner-only
VERSION = b"v1"
CHECK = b"aide passwords key check"
MAX_SITES = 5
MAX_NAME = 60
MAX_USERNAME = 256
MAX_PASSWORD = 1024
WRITES_PER_HOUR = 10
STATUSES = ("ok", "wrong", "needs_you")

SCHEMA = """
CREATE TABLE IF NOT EXISTS passwords (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    sites       TEXT NOT NULL,  -- JSON list of registrable domains, fixed when added (part of the encryption)
    username    BLOB NOT NULL,  -- encrypted
    password    BLOB NOT NULL,  -- encrypted
    status      TEXT NOT NULL DEFAULT 'ok',  -- ok, wrong (the site said so: not tried again), needs_you
    used_at     TEXT,  -- UTC
    used_by     TEXT,  -- what used it last ("the Esse3 reader")
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS password_meta (
    key   TEXT PRIMARY KEY,
    value BLOB NOT NULL
);
"""


class PasswordError(Exception):
    """Something the user can act on. Its message never holds a username or password."""


class Locked(PasswordError):
    """No key, or not the key the passwords were saved with."""


class TooMany(PasswordError):
    """More changes in the last hour than WRITES_PER_HOUR."""


class Secret:
    """A username or password on its way to a login form: it never prints."""
    __slots__ = ("_value",)

    def __init__(self, value: str):
        self._value = value

    def reveal(self) -> str:
        return self._value

    def __repr__(self) -> str:
        return "Secret(***)"

    __str__ = __repr__

    def __reduce__(self):
        raise TypeError("a Secret can't be pickled")


def load_key(credentials_dir: str | None = None, key_file: Path = KEY_FILE) -> bytes | None:
    """The key: the systemd credential when the service has one, else the owner-only file, else none (Passwords
    off). Only whether there is one is ever logged."""
    candidates = []
    if credentials_dir := credentials_dir if credentials_dir is not None else os.environ.get("CREDENTIALS_DIRECTORY"):
        candidates.append(Path(credentials_dir) / CREDENTIAL)
    candidates.append(key_file.expanduser())
    for path in candidates:
        try:
            if not path.is_file():
                continue
            if path.stat().st_mode & 0o077:
                log.warning("passwords off: the key file can be read by others (chmod 400 it)")
                return None
            key = path.read_bytes()
        except OSError as e:
            log.warning("passwords off: can't read the key (%s)", type(e).__name__)
            return None
        if len(key) != 32:
            log.warning("passwords off: the key isn't 32 bytes")
            return None
        return key
    return None


def normal_site(site: str) -> str:
    """A site the user typed (unito.it, my.unito.it, https://my.unito.it/…) as its registrable domain."""
    site = site.strip().lower()
    try:
        site = check_site(site_of(site))
    except ValueError:
        raise PasswordError("not a site: give a web address like unito.it") from None
    if site in _SECOND_LEVEL:
        raise PasswordError("not a site: give a web address like unito.it")
    return site


class PasswordStore:
    def __init__(self, conn: sqlite3.Connection, key: bytes | None):
        self.conn = conn
        self.conn.executescript(SCHEMA)
        self._aead = AESGCM(key) if key else None
        self._writes: deque[float] = deque()
        self.locked = False  # a key that isn't the one the passwords were saved with, or none with passwords saved
        self._check_key()

    # -- the key -----------------------------------------------------------------------

    def _check_key(self) -> None:
        row = self.conn.execute("SELECT value FROM password_meta WHERE key = 'check'").fetchone()
        saved = self.conn.execute("SELECT 1 FROM passwords LIMIT 1").fetchone() is not None
        if self._aead is None:
            self.locked = saved
            if saved:
                log.warning("passwords locked: there are saved passwords but no key")
            return
        if row is None:
            if saved:  # passwords without a check value: never written by this code; don't guess
                self.locked = True
                log.warning("passwords locked: saved passwords but no key check")
                return
            self.conn.execute("INSERT INTO password_meta (key, value) VALUES ('check', ?)",
                              (self._seal(CHECK, b"check"),))
            return
        try:
            ok = self._open(row[0], b"check") == CHECK
        except InvalidTag:
            ok = False
        if not ok:
            self.locked = True
            log.warning("passwords locked: the key isn't the one they were saved with")

    @property
    def enabled(self) -> bool:
        return self._aead is not None and not self.locked

    def _ready(self) -> AESGCM:
        if self._aead is None:
            raise Locked("Passwords aren't set up on the server (README, Passwords)")
        if self.locked:
            raise Locked("the server's passwords key isn't the one they were saved with")
        return self._aead

    def _seal(self, plain: bytes, aad: bytes) -> bytes:
        nonce = os.urandom(12)
        return VERSION + nonce + self._aead.encrypt(nonce, plain, aad)

    def _open(self, blob: bytes, aad: bytes) -> bytes:
        blob = bytes(blob)
        if blob[:2] != VERSION:
            raise InvalidTag()
        return self._aead.decrypt(blob[2:14], blob[14:], aad)

    @staticmethod
    def _aad(entry_id: str, field: str, sites: list[str]) -> bytes:
        return f"aide-pw:v1:{entry_id}:{field}:{','.join(sorted(sites))}".encode()

    def _encrypt(self, entry_id: str, field: str, sites: list[str], value: str) -> bytes:
        self._ready()
        return self._seal(value.encode(), self._aad(entry_id, field, sites))

    def _decrypt(self, entry_id: str, field: str, sites: list[str], blob: bytes) -> str:
        self._ready()
        return self._open(blob, self._aad(entry_id, field, sites)).decode()

    # -- writes ------------------------------------------------------------------------

    def _count_write(self) -> None:
        now = time.monotonic()
        while self._writes and now - self._writes[0] > 3600:
            self._writes.popleft()
        if len(self._writes) >= WRITES_PER_HOUR:
            raise TooMany("too many changes to passwords in the last hour: try again later")
        self._writes.append(now)

    @staticmethod
    def _check_fields(name: str | None = None, username: str | None = None, password: str | None = None) -> None:
        if name is not None and not (0 < len(name.strip()) <= MAX_NAME):
            raise PasswordError(f"name: 1 to {MAX_NAME} characters")
        if username is not None and not (0 < len(username) <= MAX_USERNAME):
            raise PasswordError(f"username: 1 to {MAX_USERNAME} characters")
        if password is not None and not (0 < len(password) <= MAX_PASSWORD):
            raise PasswordError(f"password: 1 to {MAX_PASSWORD} characters")

    def add(self, name: str, sites: list[str], username: str, password: str) -> dict:
        self._ready()
        self._check_fields(name, username, password)
        clean = sorted({normal_site(s) for s in sites})
        if not 0 < len(clean) <= MAX_SITES:
            raise PasswordError(f"sites: 1 to {MAX_SITES}")
        self._count_write()
        entry_id = "pw_" + secrets.token_hex(8)
        now = utcnow().isoformat()
        self.conn.execute(
            "INSERT INTO passwords (id, name, sites, username, password, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (entry_id, name.strip(), json.dumps(clean), self._encrypt(entry_id, "username", clean, username),
             self._encrypt(entry_id, "password", clean, password), now, now))
        return self.entry(entry_id)

    def update(self, entry_id: str, name: str | None = None, username: str | None = None,
               password: str | None = None) -> dict:
        self._ready()
        row = self._row(entry_id)
        self._check_fields(name, username, password)
        self._count_write()
        sites = json.loads(row["sites"])
        sets, args = ["updated_at = ?"], [utcnow().isoformat()]
        if name is not None:
            sets.append("name = ?")
            args.append(name.strip())
        if username is not None:
            sets.append("username = ?")
            args.append(self._encrypt(entry_id, "username", sites, username))
        if password is not None:  # a new password is worth trying again
            sets += ["password = ?", "status = 'ok'"]
            args.append(self._encrypt(entry_id, "password", sites, password))
        self.conn.execute(f"UPDATE passwords SET {', '.join(sets)} WHERE id = ?", (*args, entry_id))
        return self.entry(entry_id)

    def delete(self, entry_id: str) -> dict:
        row = self._row(entry_id)
        self._count_write()
        self.conn.execute("DELETE FROM passwords WHERE id = ?", (entry_id,))
        return {"id": entry_id, "name": row["name"]}

    def mark(self, entry_id: str, status: str) -> None:
        """What a login found: `wrong` (never tried again until the password changes) or `needs_you`."""
        if status not in STATUSES:
            raise ValueError(f"unknown status {status!r}")
        self.conn.execute("UPDATE passwords SET status = ? WHERE id = ?", (status, entry_id))

    # -- reads ------------------------------------------------------------------------

    def _row(self, entry_id: str) -> dict:
        cur = self.conn.execute("SELECT * FROM passwords WHERE id = ?", (entry_id,))
        names = [d[0] for d in cur.description]
        row = cur.fetchone()
        if row is None:
            raise KeyError(entry_id)
        return dict(zip(names, row))

    def _json(self, row: dict) -> dict:
        sites = json.loads(row["sites"])
        try:
            username = self._decrypt(row["id"], "username", sites, row["username"]) if self.enabled else None
        except (InvalidTag, UnicodeDecodeError):
            username = None
        return {"id": row["id"], "name": row["name"], "sites": sites, "username": username,
                "status": row["status"] if username is not None or not self.enabled else "unreadable",
                "used_at": row["used_at"], "used_by": row["used_by"], "updated_at": row["updated_at"]}

    def entry(self, entry_id: str) -> dict:
        return self._json(self._row(entry_id))

    def entries(self) -> list[dict]:
        cur = self.conn.execute("SELECT * FROM passwords ORDER BY name COLLATE NOCASE")
        names = [d[0] for d in cur.description]
        return [self._json(dict(zip(names, r))) for r in cur.fetchall()]

    def for_site(self, site: str) -> dict | None:
        """The entry for a site (no secrets), the most recently changed when there are several."""
        cur = self.conn.execute("SELECT * FROM passwords ORDER BY updated_at DESC")
        names = [d[0] for d in cur.description]
        for r in cur.fetchall():
            row = dict(zip(names, r))
            if site in json.loads(row["sites"]):
                return self._json(row)
        return None

    def status(self) -> dict:
        return {"enabled": self.enabled, "locked": self.locked,
                "entries": self.entries() if self.enabled else []}

    # -- use --------------------------------------------------------------------------

    def use(self, entry_id: str, url: str, by: str) -> tuple[Secret, Secret]:
        """The username and password, for a login form at `url`: only an https address on one of the entry's sites.
        Recorded as used by `by`."""
        self._ready()
        row = self._row(entry_id)
        sites = json.loads(row["sites"])
        parsed = urlparse(url)
        try:
            site = site_of(url) if parsed.scheme == "https" and parsed.hostname else None
        except ValueError:
            site = None
        if site is None or site not in sites:
            raise PasswordError(f"{row['name']}'s password is only for {', '.join(sites)} over https")
        try:
            username = self._decrypt(entry_id, "username", sites, row["username"])
            password = self._decrypt(entry_id, "password", sites, row["password"])
        except (InvalidTag, UnicodeDecodeError):
            raise Locked(f"{row['name']}'s password can't be read: add it again") from None
        self.conn.execute("UPDATE passwords SET used_at = ?, used_by = ? WHERE id = ?",
                          (utcnow().isoformat(), by, entry_id))
        return Secret(username), Secret(password)
