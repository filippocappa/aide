import asyncio
import logging
from urllib.parse import parse_qs, unquote_plus

import httpx
import pytest

from aide.db import Database
from aide.passwords import PasswordStore
from aide.unito import LoginFailed, NoLogin, UnitoSession, forms

PASSWORD = "Canary-Pw-7f3a9!"
USERNAME = "canary.user"
KEY = bytes(range(32))
ESSE3 = "https://esse3.unito.it/auth/studente/Appelli/Appelli.do"
SSO = "https://idp.unito.it/idp/profile/SAML2/Redirect/SSO"

STORAGE = f"""<html><form action="/idp/profile/SAML2/Redirect/SSO?execution=e1s1" method="post">
<input type="hidden" name="shib_idp_ls_success.shib_idp_session_ss" value="false" />
<input type="hidden" name="shib_idp_ls_supported" value="" /><input type="hidden" name="_eventId_proceed" value="" />
<input type="submit" value="Continue" /></form></html>"""
ROUTING = """<html><form id="triggerFlow" action="/idp/profile/SAML2/Redirect/SSO?execution=e1s2" method="post">
<input type="hidden" name="_eventId_routing" value="" /><input type="hidden" name="selected_flow" value="" />
<input type="hidden" name="auth_ctx" value="" /><input type="hidden" name="spid_idp" value="" /></form>
<button onclick="triggerFlow('Password', '', 'internal')">UniTo</button></html>"""
LOGIN = """<html><form id="triggerFlow" action="/idp/profile/SAML2/Redirect/SSO?execution=e1s3" method="post">
<input type="hidden" name="_eventId_routing" value="" /><input type="hidden" name="selected_flow" value="" />
<input type="hidden" name="auth_ctx" value="" /><input type="hidden" name="spid_idp" value="" /></form>
<form class="row" action="{action}" method="post" novalidate>
<input type="text" id="username" name="j_username" value="" /><input type="password" id="password" name="j_password" />
<button type="submit" name="_eventId_proceed">Sign in</button></form>{error}</html>"""
SAML = """<html><body onload="document.forms[0].submit()"><form action="{action}" method="post">
<input type="hidden" name="RelayState" value="ss:mem:abc" /><input type="hidden" name="SAMLResponse" value="PHNhbWw+" />
<input type="submit" value="Continue" /></form></body></html>"""


class FakeUniTo:
    """Esse3 and the IdP, recording every request."""

    def __init__(self, password=PASSWORD, after_login=None, idp_detour=None, form_action="/idp/profile/SAML2/Redirect/SSO?execution=e1s3",
                 saml_action="https://esse3.unito.it/Shibboleth.sso/SAML2/POST", down=False):
        self.password, self.after_login, self.idp_detour = password, after_login, idp_detour
        self.form_action, self.saml_action, self.down = form_action, saml_action, down
        self.requests: list[tuple[str, str, bytes]] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        body = request.content
        self.requests.append((request.method, str(request.url), body))
        if self.down:
            raise httpx.ConnectError("down")
        host, path, query = request.url.host, request.url.path, request.url.params
        cookies = request.headers.get("cookie", "")
        if host == "esse3.unito.it" and path == "/Shibboleth.sso/SAML2/POST":
            return httpx.Response(302, headers={"location": ESSE3, "set-cookie": "esse3=ok; Path=/; Secure"})
        if host == "esse3.unito.it":
            if "esse3=ok" in cookies:
                return httpx.Response(200, html="<html>APPELLI PAGE</html>")
            return httpx.Response(302, headers={"location": f"{SSO}?SAMLRequest=abc&RelayState=ss%3Amem%3Aabc"})
        if host == "idp.unito.it":
            step = query.get("execution")
            if request.method == "GET" and "SAMLRequest" in query:
                return httpx.Response(302, headers={"location": self.idp_detour or f"{SSO}?execution=e1s1",
                                                    "set-cookie": "JSESSIONID=x; Path=/idp; Secure"})
            if request.method == "GET" and step == "e1s1":
                return httpx.Response(200, html=STORAGE)
            if request.method == "POST" and step == "e1s1":
                return httpx.Response(302, headers={"location": f"{SSO}?execution=e1s2"})
            if request.method == "GET" and step == "e1s2":
                return httpx.Response(200, html=ROUTING)
            if request.method == "POST" and step == "e1s2":
                form = parse_qs(body.decode())
                assert form["selected_flow"] == ["internal"] and form["auth_ctx"] == ["authn/Password"]
                return httpx.Response(200, html=LOGIN.format(action=self.form_action, error=""))
            if request.method == "POST" and step == "e1s3":
                form = parse_qs(body.decode())
                if form.get("j_password") == [self.password] and form.get("j_username") == [USERNAME]:
                    if self.after_login:
                        return httpx.Response(200, html=self.after_login)
                    return httpx.Response(200, html=SAML.format(action=self.saml_action))
                return httpx.Response(200, html=LOGIN.format(action=self.form_action,
                                                             error="<p class='alert-danger'>Wrong</p>"))
        return httpx.Response(404, html="no")

    def carrying_password(self):
        return [(m, u) for m, u, b in self.requests
                if PASSWORD in unquote_plus(b.decode(errors="replace")) or PASSWORD in unquote_plus(u)]


class FakePush:
    def __init__(self):
        self.sent = []

    async def send_passwords(self, title, body):
        self.sent.append((title, body))
        return True


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


@pytest.fixture
def make():
    db = Database(":memory:")
    store = PasswordStore(db.conn, KEY)
    made = []

    def build(fake: FakeUniTo, save=True):
        if save:
            store.add("UniTo", ["unito.it"], USERNAME, PASSWORD)
        push, clock = FakePush(), Clock()
        session = UnitoSession(store, push, httpx.MockTransport(fake), clock=clock)
        made.append(session)
        return session, store, push, clock

    yield build
    for s in made:
        asyncio.run(s.close())
    db.close()


def run(coro):
    return asyncio.run(coro)


def test_logs_in_and_reads(make, caplog):
    caplog.set_level(logging.DEBUG, logger="aide")  # httpx logs requests at INFO; the server keeps it at WARNING
    fake = FakeUniTo()
    session, store, push, _ = make(fake)

    async def go():
        first = await session.get(ESSE3)
        n = len(fake.requests)
        again = await session.get(ESSE3)  # the session is kept: no login
        return first, again, len(fake.requests) - n

    first, again, extra = run(go())
    assert "APPELLI PAGE" in first.text and "APPELLI PAGE" in again.text and extra == 1
    assert fake.carrying_password() == [("POST", f"{SSO}?execution=e1s3")]
    entry = store.for_site("unito.it")
    assert entry["status"] == "ok" and entry["used_by"] == "the Esse3 reader"
    assert PASSWORD not in caplog.text and USERNAME not in caplog.text and "SAMLRequest" not in caplog.text
    assert push.sent == []


def test_wrong_password_once_then_never(make):
    fake = FakeUniTo(password="something else")
    session, store, push, clock = make(fake)
    with pytest.raises(LoginFailed) as e:
        run(session.get(ESSE3))
    assert e.value.kind == "wrong" and store.for_site("unito.it")["status"] == "wrong"
    assert len(push.sent) == 1 and PASSWORD not in push.sent[0][1]
    clock.t += 10 * 86400
    with pytest.raises(LoginFailed) as e:
        run(session.get(ESSE3))
    assert e.value.kind == "wrong"
    assert len(fake.carrying_password()) == 1 and len(push.sent) == 1
    # a new password is tried again
    store.update(store.for_site("unito.it")["id"], password="something else")
    fake.requests.clear()
    assert "APPELLI PAGE" in run(session.get(ESSE3)).text


@pytest.mark.parametrize("fake", [
    FakeUniTo(idp_detour="https://evil.com/idp/profile/SAML2/Redirect/SSO?execution=e1s1"),
    FakeUniTo(idp_detour="http://idp.unito.it/idp/profile/SAML2/Redirect/SSO?execution=e1s1"),
    FakeUniTo(form_action="https://idp.unito.it.evil.com/idp/profile/SAML2/Redirect/SSO?execution=e1s3"),
    FakeUniTo(form_action="http://idp.unito.it/idp/profile/SAML2/Redirect/SSO?execution=e1s3"),
    FakeUniTo(form_action="https://idp.unito.it/somewhere/else"),
    FakeUniTo(form_action="https://esse3.unito.it/idp/profile/SAML2/Redirect/SSO"),
], ids=["foreign redirect", "http redirect", "look-alike form", "http form", "other path", "other host"])
def test_password_never_leaves_the_idp(make, fake):
    session, store, push, _ = make(fake)
    with pytest.raises(LoginFailed) as e:
        run(session.get(ESSE3))
    assert e.value.kind == "needs_you"
    assert fake.carrying_password() == []
    assert not any(u.startswith("https://evil.com") or u.startswith("http://") for _, u, _ in fake.requests)
    assert store.for_site("unito.it")["status"] == "needs_you" and len(push.sent) == 1


def test_saml_answer_only_to_unito(make):
    fake = FakeUniTo(saml_action="https://evil.com/Shibboleth.sso/SAML2/POST")
    session, store, push, _ = make(fake)
    with pytest.raises(LoginFailed) as e:
        run(session.get(ESSE3))
    assert e.value.kind == "needs_you"
    assert not any("evil.com" in u for _, u, _ in fake.requests)


def test_unknown_page_needs_you_and_waits_a_day(make):
    consent = """<html><form action="/idp/profile/SAML2/Redirect/SSO?execution=e1s4" method="post">
    <input type="hidden" name="_shib_idp_consentIds" value="mail" /><input type="submit" name="_eventId_proceed" /></form></html>"""
    fake = FakeUniTo(after_login=consent)
    session, store, push, clock = make(fake)
    with pytest.raises(LoginFailed) as e:
        run(session.get(ESSE3))
    assert e.value.kind == "needs_you" and len(push.sent) == 1
    n = len(fake.requests)
    with pytest.raises(LoginFailed) as e:
        run(session.get(ESSE3))
    assert e.value.kind == "waiting" and len(fake.carrying_password()) == 1
    assert len(fake.requests) == n + 1  # the page only: its redirect to the IdP isn't followed
    clock.t += 86400 + 1
    fake.after_login = None
    assert "APPELLI PAGE" in run(session.get(ESSE3)).text
    assert store.for_site("unito.it")["status"] == "ok" and len(push.sent) == 1


def test_network_waits_six_hours(make):
    fake = FakeUniTo()
    session, store, push, clock = make(fake)
    # Esse3 answers but the IdP doesn't
    real = fake.__call__

    def flaky(request):
        if request.url.host == "idp.unito.it" and request.url.params.get("execution") == "e1s1":
            raise httpx.ConnectTimeout("slow")
        return real(request)

    session.http._transport = httpx.MockTransport(flaky)
    with pytest.raises(LoginFailed) as e:
        run(session.get(ESSE3))
    assert e.value.kind == "network" and push.sent == [] and store.for_site("unito.it")["status"] == "ok"
    session.http._transport = httpx.MockTransport(fake)
    with pytest.raises(LoginFailed) as e:
        run(session.get(ESSE3))
    assert e.value.kind == "waiting"
    clock.t += 6 * 3600 + 1
    assert "APPELLI PAGE" in run(session.get(ESSE3)).text


def test_no_password_saved(make):
    session, *_ = make(FakeUniTo(), save=False)
    with pytest.raises(NoLogin):
        run(session.get(ESSE3))


def test_only_unito_pages():
    db = Database(":memory:")
    session = UnitoSession(PasswordStore(db.conn, KEY), None, httpx.MockTransport(FakeUniTo()))
    for url in ("https://evil.com/", "http://esse3.unito.it/", "https://idp.unito.it/idp/"):
        with pytest.raises(ValueError):
            run(session.get(url))
    run(session.close())
    db.close()


def test_forms_parser():
    found = forms(LOGIN.format(action="/a", error=""))
    assert [f.id for f in found] == ["triggerFlow", None]
    assert {"j_username", "j_password", "_eventId_proceed"} <= found[1].names
    assert forms("<form><input name='x' type='hidden' value='1'></form>")[0].fields == {"x": "1"}
