"""Esse3 sign-ups as browser errands (#75): the login handed over as cookies, the guard on the clicks that commit, the
password nowhere the model or the logs can see, and an errand cut off by a restart never picked up again."""

import asyncio
import json
import logging

import httpx
import pytest

from aide.agent import CONVERSATION
from aide.db import Database
from aide.errands import ESSE3_SYSTEM, ESSE3_TOOLS, ErrandRunner, ErrandStore, esse3_commit, esse3_mismatch
from aide.passwords import PasswordStore
from aide.unito import UnitoSession
from test_agents import ROME, FakeClient, calls
from test_errands import FakeBrowser, next_phase, prompt_of
from test_unito import KEY, PASSWORD, USERNAME, FakeUniTo

BOOK = "https://esse3.unito.it/auth/studente/Appelli/DatiPrenotazioneAppello.do?APP_ID=1&ADSCE_ID=3"
CONFIRM = "https://esse3.unito.it/auth/studente/Appelli/ConfermaPrenotazione.do"
DONE = "https://esse3.unito.it/auth/studente/Appelli/EffettuaPrenotazioneAppello.do"
BOOKED = "https://esse3.unito.it/auth/studente/Appelli/BachecaPrenotazioni.do"
OTHER = "https://esse3.unito.it/auth/studente/Appelli/DatiPrenotazioneAppello.do?APP_ID=7&ADSCE_ID=5"

PAGES = {
    BOOK: ("Prenotazione appello", "MATHEMATICS FOR ECONOMICS II [SEM0251] Appello del 04/12/2026 09:30", {
        "1": {"text": "Prenotati all'appello", "tag": "input", "ids": "APP_ID=1&ADSCE_ID=3", "goes": CONFIRM},
        "2": {"text": "Prenota", "ids": "APP_ID=9"},
        "3": {"text": "Annulla", "goes": BOOKED}}),
    CONFIRM: ("Conferma", "Confermi la prenotazione a MATHEMATICS FOR ECONOMICS II del 04/12/2026?", {
        "4": {"text": "Conferma", "goes": DONE}}),
    DONE: ("Prenotazione effettuata", "Prenotazione effettuata: MATHEMATICS FOR ECONOMICS II, 04/12/2026", {
        "5": {"text": "Conferma"}}),
    OTHER: ("Prenotazione appello", "BUSINESS LAW [SEM0164] Appello del 10/12/2026", {
        "6": {"text": "Prenotati all'appello", "tag": "input", "ids": "APP_ID=7"}}),
    BOOKED: ("Bacheca prenotazioni", "MATHEMATICS FOR ECONOMICS II - [SEM0251] 04/12/2026 - 09:00. "
                                     "BUSINESS LAW - [SEM0164] 10/12/2026 - 14:00", {
        "7": {"text": "", "tag": "a", "hints": "CancellaPrenotazione.do"},
        "8": {"text": "", "tag": "a", "hints": "CancellaPrenotazione.do", "ids": "APP_ID=1"}}),
}

TARGET = {"action": "book", "key": "mathematics for economics ii|2026-12-04", "course": "MATHEMATICS FOR ECONOMICS II",
          "code": "SEM0251", "day": "2026-12-04", "day_it": "04/12/2026", "time": "09:30", "app_id": "1",
          "name": "Maths for economics II", "start_url": BOOK, "others": [["BUSINESS LAW", "10/12/2026"]]}


class EsseBrowser(FakeBrowser):
    def __init__(self):
        super().__init__(PAGES)
        self.cookies: list[tuple[str, list]] = []
        self.forgot: list[str] = []

    async def inspect(self, owner, ref):
        info = await super().inspect(owner, ref)
        return {**info, "ids": self._here(owner)[2][ref].get("ids", ""), "in_form": True}

    async def add_cookies(self, site, cookies):
        self.cookies.append((site, cookies))

    async def forget(self, site):
        self.forgot.append(site)
        return True


class FakeReader:
    def __init__(self):
        self.ended = []

    async def errand_ended(self, errand, kind, args):
        self.ended.append((errand["id"], kind, args))


@pytest.fixture
def env():
    db = Database(":memory:")
    browser = EsseBrowser()
    reader = FakeReader()

    def make(script=()):
        runner = ErrandRunner(ErrandStore(db.conn, ROME), browser, FakeClient(script), "m", CONVERSATION,
                              audit=db.audit)
        runner.esse3 = reader
        return runner
    yield make, db, browser, reader
    db.close()


def info(text="", ids="", hints="", tag="button"):
    return {"tag": tag, "text": text, "ids": ids, "hints": hints, "submits": "", "in_form": True}


def test_the_guard():
    page = "MATHEMATICS FOR ECONOMICS II [SEM0251] Appello del 04/12/2026"
    ok = esse3_mismatch(TARGET, info("Prenotati all'appello", "APP_ID=1"), BOOK, page)
    assert ok is None
    assert esse3_mismatch(TARGET, info("Conferma"), CONFIRM, page) is None
    assert "another session" in esse3_mismatch(TARGET, info("Prenota", "APP_ID=9"), BOOK, page)
    assert "doesn't show" in esse3_mismatch(TARGET, info("Prenota", "APP_ID=1"), BOOK, page.replace("04/12", "14/01"))
    assert "doesn't show" in esse3_mismatch(TARGET, info("Prenota"), OTHER, "BUSINESS LAW Appello del 10/12/2026")
    assert "cancel button" in esse3_mismatch(TARGET, info("", hints="CancellaPrenotazione.do"), BOOK, page)
    assert "not on Esse3" in esse3_mismatch(TARGET, info("Prenota", "APP_ID=1"), "https://evil.test/x", page)
    assert "not a sign-up" in esse3_mismatch(TARGET, info("Dettagli"), BOOK, page)
    # The bookings page shows another of the user's sessions: only a button tied to this one by its APP_ID.
    cancel = {**TARGET, "action": "cancel", "start_url": BOOKED}
    both = PAGES[BOOKED][1]
    assert "another of the user's sessions" in esse3_mismatch(cancel, info("", hints="CancellaPrenotazione.do"),
                                                              BOOKED, both)
    assert esse3_mismatch(cancel, info("", "APP_ID=1", "CancellaPrenotazione.do"), BOOKED, both) is None
    assert "sign-up button" in esse3_mismatch(cancel, info("Prenota", "APP_ID=1"), BOOKED, both)
    # What counts as committing on Esse3 (a bare Cancella too); moving on doesn't.
    for i in (info("Cancella"), info("", hints="CancellaPrenotazione.do", tag="a"), info("Prenotati"), info("Sì")):
        assert esse3_commit(i), i
    for i in (info("Avanti"), info("Continua"), info("Dettagli", tag="a")):
        assert esse3_commit(i) is None, i


async def test_a_sign_up_clicks_only_this_session(env):
    make, db, browser, reader = env
    runner = make([
        calls(("click", {"ref": "2"})),  # another session's Prenota: refused
        calls(("open_page", {"url": DONE})),  # the booking's own address: refused
        calls(("open_page", {"url": "https://www.google.com/"})),  # off Esse3: refused
        calls(("click", {"ref": "1"})),  # Prenotati: allowed
        calls(("click", {"ref": "4"})),  # Conferma: allowed
        calls(("click", {"ref": "5"})),  # a third: refused
        calls(("finish", {"result": "Booked", "ok": True})),
    ])
    cookies = [{"name": "esse3", "value": "ok", "url": "https://esse3.unito.it/"}]
    e = await runner.start_esse3(TARGET, cookies)
    assert browser.cookies == [("unito.it", cookies)]
    assert (e["conversation"], e["site"], e["status"]) == (None, "unito.it", "queued")
    e = await next_phase(runner)
    await asyncio.sleep(0)
    assert e["status"] == "done" and browser.clicked == ["Prenotati all'appello", "Conferma"]
    requests = runner.client.requests
    for i in (1, 2, 3, 6):
        [r] = [r for r in requests[i]["messages"][-1]["content"] if r["type"] == "tool_result"]
        assert r["is_error"], i
    assert ESSE3_SYSTEM[:60] in str(requests[0]["system"])
    assert {t["name"] for t in requests[0]["tools"]} <= ESSE3_TOOLS
    assert "Sign the user up for this exam session: MATHEMATICS FOR ECONOMICS II (SEM0251), on 04/12/2026" in \
        prompt_of(requests[0]) and "BUSINESS LAW on 10/12/2026. Never touch those" in prompt_of(requests[0])
    assert reader.ended == [(e["id"], "finish", {"ok": True, "result": "Booked"})]


async def test_a_questionnaire_waits_for_the_user(env):
    make, db, browser, reader = env
    runner = make([calls(("need_user", {"why": "other", "reason": "Esse3 asks for the questionnaire first."}))])
    e = await runner.start_esse3(TARGET, [])
    e = await next_phase(runner)
    await asyncio.sleep(0)
    assert e["status"] == "needs_you" and reader.ended == [(e["id"], "need_user", {
        "why": "other", "reason": "Esse3 asks for the questionnaire first."})]
    runner.cancel(e["id"])
    await asyncio.sleep(0)
    assert reader.ended[-1] == (e["id"], "cancelled", {})


async def test_a_restart_never_picks_it_up_again(env):
    make, db, browser, reader = env
    runner = make([])
    e = await runner.start_esse3(TARGET, [])
    runner.queue.get_nowait()
    runner.store.update(e["id"], status="running")
    worker = asyncio.create_task(runner.run())
    await asyncio.sleep(0.05)
    worker.cancel()
    e = runner.store.get(e["id"])
    assert e["status"] == "failed" and reader.ended == [(e["id"], "failed", {"result": e["result"]})]
    assert runner.client.requests == []


async def test_the_password_goes_only_to_the_idp(env, caplog):
    """The login is the server's: the browser gets cookies, the model the pages, and the password is in neither,
    nor in the steps, the audit log or the logs."""
    caplog.set_level(logging.DEBUG, logger="aide")
    make, db, browser, reader = env
    store = PasswordStore(db.conn, KEY)
    store.add("UniTo", ["unito.it"], USERNAME, PASSWORD)
    fake = FakeUniTo()
    session = UnitoSession(store, None, httpx.MockTransport(fake))
    try:
        cookies = await session.handoff("https://esse3.unito.it/auth/studente/Appelli/BachecaPrenotazioni.do")
    finally:
        await session.close()
    assert {c["name"] for c in cookies} == {"esse3", "JSESSIONID"}
    assert all(set(c) >= {"name", "value", "secure", "httpOnly"} and ("url" in c or "domain" in c) for c in cookies)
    assert all(c.get("url", "https://" + c.get("domain", "")).startswith(("https://esse3.unito.it",
                                                                           "https://idp.unito.it")) for c in cookies)
    runner = make([calls(("click", {"ref": "1"})), calls(("click", {"ref": "4"})),
                   calls(("finish", {"result": "Booked", "ok": True}))])
    e = await runner.start_esse3(TARGET, cookies)
    e = await next_phase(runner)
    seen = json.dumps(runner.client.requests, default=str) + json.dumps(e) + json.dumps(
        [dict(r) for r in db.conn.execute("SELECT * FROM audit_log")]) + caplog.text + json.dumps(browser.cookies)
    assert e["status"] == "done" and PASSWORD not in seen and USERNAME not in seen
    assert fake.carrying_password() == [("POST", "https://idp.unito.it/idp/profile/SAML2/Redirect/SSO?execution=e1s3")]
