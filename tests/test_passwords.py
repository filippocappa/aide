import logging
import os
import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.passwords import WRITES_PER_HOUR, Locked, PasswordError, PasswordStore, Secret, load_key
from aide.push import Push
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry

from test_api import AUTH, ROME, TOKEN, FakeCalendar, FakeClient

PASSWORD = "Canary-Pw-7f3a9!"
USERNAME = "canary.user@edu.unito.it"
KEY = bytes(range(32))


def leaked(text: str | bytes) -> bool:
    if isinstance(text, bytes):
        return PASSWORD.encode() in text or USERNAME.encode() in text
    return PASSWORD in text


@pytest.fixture
def store():
    db = Database(":memory:")
    yield PasswordStore(db.conn, KEY)
    db.close()


# -- the store -------------------------------------------------------------------------


def test_round_trip_and_use(store):
    entry = store.add("UniTo", ["https://my.unito.it/", "esse3.unito.it"], USERNAME, PASSWORD)
    assert entry["sites"] == ["unito.it"]
    assert entry["username"] == USERNAME and "password" not in entry
    user, pw = store.use(entry["id"], "https://idp.unito.it/idp/profile/SAML2/POST/SSO", "the Esse3 reader")
    assert (user.reveal(), pw.reveal()) == (USERNAME, PASSWORD)
    assert store.entry(entry["id"])["used_by"] == "the Esse3 reader"


def test_secret_never_prints():
    s = Secret(PASSWORD)
    assert not leaked(repr(s)) and not leaked(str(s)) and not leaked(f"{s}") and not leaked(repr([s]))


@pytest.mark.parametrize("url", ["http://idp.unito.it/login", "https://unito.it.evil.com/x", "https://evil.com/?unito.it",
                                 "https://evilunito.it/", "ftp://unito.it/", "unito.it", "https://"])
def test_use_only_on_its_sites_over_https(store, url):
    entry = store.add("UniTo", ["unito.it"], USERNAME, PASSWORD)
    with pytest.raises(PasswordError) as e:
        store.use(entry["id"], url, "test")
    assert not leaked(str(e.value))


def test_nothing_plain_on_disk(tmp_path):
    db = Database(str(tmp_path / "aide.db"))
    s = PasswordStore(db.conn, KEY)
    entry = s.add("UniTo", ["unito.it"], USERNAME, PASSWORD)
    s.update(entry["id"], password=PASSWORD + "2")
    db.conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()
    for f in tmp_path.iterdir():
        assert not leaked(f.read_bytes()), f.name


def test_ciphertext_bound_to_row_field_and_sites(store):
    a = store.add("A", ["unito.it"], USERNAME, PASSWORD)
    b = store.add("B", ["unito.it"], "other", "other-pw")
    conn = store.conn
    # the password moved into the username field
    conn.execute("UPDATE passwords SET username = password WHERE id = ?", (a["id"],))
    assert store.entry(a["id"])["status"] == "unreadable"
    with pytest.raises(Locked):
        store.use(a["id"], "https://idp.unito.it/", "t")
    # another row's ciphertext
    conn.execute("UPDATE passwords SET password = (SELECT password FROM passwords WHERE id = ?) WHERE id = ?",
                 (a["id"], b["id"]))
    with pytest.raises(Locked):
        store.use(b["id"], "https://idp.unito.it/", "t")
    # sites edited in the database to send it elsewhere
    c = store.add("C", ["unito.it"], USERNAME, PASSWORD)
    conn.execute("UPDATE passwords SET sites = '[\"evil.com\"]' WHERE id = ?", (c["id"],))
    with pytest.raises(Locked):
        store.use(c["id"], "https://evil.com/", "t")


def test_wrong_key_locks_and_never_overwrites():
    db = Database(":memory:")
    PasswordStore(db.conn, KEY).add("UniTo", ["unito.it"], USERNAME, PASSWORD)
    wrong = PasswordStore(db.conn, os.urandom(32))
    assert wrong.locked and not wrong.enabled
    with pytest.raises(Locked):
        wrong.add("X", ["x.com"], "u", "p")
    assert wrong.status() == {"enabled": False, "locked": True, "entries": []}
    none = PasswordStore(db.conn, None)
    assert none.locked
    assert PasswordStore(db.conn, KEY).enabled  # the right key opens them again
    db.close()


def test_no_key_and_nothing_saved_is_just_off():
    db = Database(":memory:")
    s = PasswordStore(db.conn, None)
    assert not s.enabled and not s.locked
    with pytest.raises(Locked):
        s.add("UniTo", ["unito.it"], USERNAME, PASSWORD)
    db.close()


@pytest.mark.parametrize("site", ["1.2.3.4", "co.uk", "localhost", "", "not a site"])
def test_bad_sites(store, site):
    with pytest.raises(PasswordError):
        store.add("X", [site], USERNAME, PASSWORD)


def test_new_password_clears_wrong(store):
    entry = store.add("UniTo", ["unito.it"], USERNAME, PASSWORD)
    store.mark(entry["id"], "wrong")
    assert store.entry(entry["id"])["status"] == "wrong"
    store.update(entry["id"], name="UniTo SCU")
    assert store.entry(entry["id"])["status"] == "wrong"
    store.update(entry["id"], password="new")
    assert store.entry(entry["id"])["status"] == "ok"


def test_for_site(store):
    entry = store.add("UniTo", ["unito.it"], USERNAME, PASSWORD)
    assert store.for_site("unito.it")["id"] == entry["id"]
    assert store.for_site("amazon.it") is None


def test_load_key(tmp_path):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "aide-passwords").write_bytes(KEY)
    (creds / "aide-passwords").chmod(0o400)
    assert load_key(str(creds), tmp_path / "none") == KEY
    loose = tmp_path / "passwords.key"
    loose.write_bytes(KEY)
    loose.chmod(0o644)
    assert load_key("", loose) is None  # others can read it
    loose.chmod(0o400)
    assert load_key("", loose) == KEY
    short = tmp_path / "short.key"
    short.write_bytes(b"x" * 16)
    short.chmod(0o400)
    assert load_key("", short) is None
    assert load_key("", tmp_path / "missing") is None


def test_logs_hold_nothing(store, caplog):
    caplog.set_level(logging.DEBUG)
    entry = store.add("UniTo", ["unito.it"], USERNAME, PASSWORD)
    store.use(entry["id"], "https://idp.unito.it/", "t")
    with pytest.raises(PasswordError):
        store.use(entry["id"], "https://evil.com/", "t")
    PasswordStore(store.conn, os.urandom(32))
    assert not leaked(caplog.text) and USERNAME not in caplog.text


# -- the API -------------------------------------------------------------------------


class FakePush(Push):
    def __init__(self, conn):
        super().__init__(conn)
        self.sent = []

    async def send_passwords(self, title, body):
        self.sent.append((title, body))
        return True


@pytest.fixture
def api():
    db = Database(":memory:")
    store = ReminderStore(db.conn)
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    push = FakePush(db.conn)
    passwords = PasswordStore(db.conn, KEY)
    client = TestClient(create_app(agent, store, FakeCalendar([]), ROME, TOKEN, push=push, passwords=passwords))
    yield client, push, passwords, db
    db.close()


def test_api_write_only(api, caplog):
    caplog.set_level(logging.DEBUG)
    client, push, passwords, db = api
    bodies = []
    r = client.post("/v1/passwords", headers=AUTH,
                    json={"name": "UniTo", "sites": ["unito.it"], "username": USERNAME, "password": PASSWORD})
    assert r.status_code == 201
    bodies.append(r.text)
    entry_id = r.json()["id"]
    assert r.json()["username"] == USERNAME
    r = client.get("/v1/passwords", headers=AUTH)
    assert r.json()["enabled"] and r.json()["entries"][0]["sites"] == ["unito.it"]
    bodies.append(r.text)
    bodies.append(client.patch(f"/v1/passwords/{entry_id}", headers=AUTH, json={"password": PASSWORD + "x"}).text)
    # bad bodies: errors name the field, never the value
    for bad in ({"name": "U", "sites": ["unito.it"], "username": USERNAME, "password": PASSWORD * 100},
                {"name": "U", "sites": ["1.2.3.4"], "username": USERNAME, "password": PASSWORD},
                {"name": "U", "sites": ["unito.it"], "username": USERNAME, "password": PASSWORD, "extra": PASSWORD},
                {"name": "U", "sites": "unito.it", "username": USERNAME, "password": PASSWORD}):
        r = client.post("/v1/passwords", headers=AUTH, json=bad)
        assert r.status_code == 400, bad
        bodies.append(r.text)
    r = client.patch(f"/v1/passwords/{entry_id}", headers=AUTH, json={"sites": ["evil.com"], "password": PASSWORD})
    assert r.status_code == 400 and "sites" in r.json()["error"]
    bodies.append(r.text)
    assert passwords.entry(entry_id)["sites"] == ["unito.it"]
    bodies.append(client.delete(f"/v1/passwords/{entry_id}", headers=AUTH).text)
    assert not any(leaked(b) for b in bodies)
    assert not any(USERNAME in b for b in bodies[3:])  # errors and the delete: not even the username
    assert not leaked(caplog.text)
    # every change is in the feed and pushed
    titles = [r[0] for r in db.conn.execute("SELECT title FROM activity WHERE kind = 'passwords' ORDER BY id")]
    assert titles == ["Password for UniTo added", "Password for UniTo changed", "Password for UniTo deleted"]
    assert [t for t, _ in push.sent] == titles
    assert not any(leaked(t + b) for t, b in push.sent)


def test_api_needs_the_token(api):
    client = api[0]
    assert client.get("/v1/passwords").status_code == 401
    assert client.post("/v1/passwords", json={}).status_code == 401


def test_api_rate_limited(api):
    client = api[0]
    body = {"name": "U", "sites": ["unito.it"], "username": USERNAME, "password": PASSWORD}
    codes = [client.post("/v1/passwords", headers=AUTH, json=body).status_code for _ in range(WRITES_PER_HOUR + 1)]
    assert codes[:-1] == [201] * WRITES_PER_HOUR and codes[-1] == 429


def test_api_off_without_key():
    db = Database(":memory:")
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    client = TestClient(create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN))
    assert client.get("/v1/passwords", headers=AUTH).json() == {"enabled": False, "locked": False, "entries": []}
    r = client.post("/v1/passwords", headers=AUTH,
                    json={"name": "U", "sites": ["unito.it"], "username": USERNAME, "password": PASSWORD})
    assert r.status_code == 503
    assert client.patch("/v1/passwords/pw_x", headers=AUTH, json={"name": "x"}).status_code in (404, 503)
    db.close()


# -- kept away from the model --------------------------------------------------------


def test_no_tool_or_prompt_reaches_passwords():
    src = Path(__file__).resolve().parent.parent / "src" / "aide"
    pattern = re.compile(r"(from\s+\.+\s*import\s+[^\n]*\bpasswords\b|from\s+[.\w]*passwords\s+import|import\s+[.\w]*passwords)")
    allowed = {"__main__.py", "api.py", "passwords.py", "unito.py"}
    for f in src.rglob("*.py"):
        if f.name in allowed:
            continue
        assert not pattern.search(f.read_text()), f"{f.relative_to(src)} reaches the password store"
