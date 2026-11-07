"""UniTo's single sign-on for the server's own reads of Esse3 (#74), with the login saved in Settings → Passwords.

Plain HTTP, no model, no browser. A protected Esse3 page sends you to the university's IdP (Shibboleth): a storage
check form, the choice of how to log in (the university's own username and password, not SPID or CIE), the username
and password form, then a form that posts the SAML answer back to Esse3, which lands on the page asked for.

What keeps the password safe:
- every redirect and form is followed by hand and only within UniTo's hosts (`HOSTS`); anything else stops the login
  with nothing sent;
- the password is posted only to `https://idp.unito.it/idp/profile/SAML2/…`, and the store itself checks the address
  is https on the entry's sites (`PasswordStore.use`);
- the cookies live in memory only: after a restart the server logs in again;
- logs carry step names only, never an address with SAML in it or a page.

When it goes wrong: a wrong password marks the entry `wrong` and it's never tried again until the user changes it (so
the university doesn't lock the account); a page the server doesn't know (a second factor, a new password to set, a
consent screen) marks it `needs_you`, tried again once a day; each pushed once. A network failure waits 6 h.
"""

import logging
import time
from dataclasses import dataclass, field
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

import httpx

from . import activity
from .passwords import PasswordError, PasswordStore

log = logging.getLogger(__name__)

SITE = "unito.it"
IDP_HOST = "idp.unito.it"
IDP_PATH = "/idp/profile/SAML2/"
SP_HOSTS = {"esse3.unito.it", "my.unito.it"}
HOSTS = SP_HOSTS | {IDP_HOST}
BY = "the Esse3 reader"
MAX_STEPS = 10
MAX_REDIRECTS = 10
NETWORK_WAIT = 6 * 3600
NEEDS_YOU_WAIT = 24 * 3600
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"


class NoLogin(Exception):
    """No UniTo password saved, or the store is off or locked: nothing to do, quietly."""


class LoginFailed(Exception):
    """`kind`: wrong, needs_you, network, waiting. The message never holds a username, password or SAML."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


@dataclass
class Form:
    action: str | None
    method: str
    id: str | None
    fields: dict[str, str] = field(default_factory=dict)  # hidden inputs and named buttons, as they are
    names: set[str] = field(default_factory=set)  # every named field


class _Forms(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms: list[Form] = []
        self._cur: Form | None = None

    def handle_starttag(self, tag, attrs):
        a = {k: v or "" for k, v in attrs}
        if tag == "form":
            self._cur = Form(a.get("action") or None, (a.get("method") or "get").lower(), a.get("id") or None)
            self.forms.append(self._cur)
        elif tag in ("input", "button") and self._cur is not None and a.get("name"):
            self._cur.names.add(a["name"])
            if tag == "input" and a.get("type", "text").lower() == "hidden":
                self._cur.fields[a["name"]] = a.get("value", "")

    def handle_endtag(self, tag):
        if tag == "form":
            self._cur = None


def forms(html: str) -> list[Form]:
    p = _Forms()
    try:
        p.feed(html)
    except Exception:  # a broken page has no forms we trust
        return []
    return p.forms


def _https_on(url: str, hosts: set[str]) -> bool:
    u = urlparse(url)
    return u.scheme == "https" and (u.hostname or "") in hosts and u.port in (None, 443)


class UnitoSession:
    """An Esse3 session kept in memory. `get` reads a page, logging in first when the session is gone."""

    def __init__(self, passwords: PasswordStore, push=None, transport: httpx.AsyncBaseTransport | None = None,
                 clock=time.monotonic):
        self.passwords = passwords
        self.push = push
        self.clock = clock
        self.http = httpx.AsyncClient(timeout=30, transport=transport, follow_redirects=False,
                                      headers={"User-Agent": UA, "Accept-Language": "it-IT,it;q=0.9,en;q=0.8"})
        self._wait_until = 0.0  # no login before this (network trouble, or a page that needs the user)
        self.logged_in = False

    async def close(self) -> None:
        await self.http.aclose()

    def entry(self) -> dict:
        if not self.passwords.enabled:
            raise NoLogin("Passwords aren't on")
        entry = self.passwords.for_site(SITE)
        if entry is None:
            raise NoLogin("no UniTo password saved")
        return entry

    # -- reading --------------------------------------------------------------------

    async def get(self, url: str) -> httpx.Response:
        """A page on Esse3 (or my.unito.it), logged in."""
        if not _https_on(url, SP_HOSTS):
            raise ValueError("only Esse3 and MyUniTo pages")
        r = await self._follow(self.http.build_request("GET", url), within=SP_HOSTS)
        if not r.is_redirect:
            return r
        self.logged_in = False  # sent to the IdP (or somewhere else, which the login refuses)
        return await self._login(r)

    async def _follow(self, request: httpx.Request, within: set[str] = HOSTS) -> httpx.Response:
        """Send it and follow redirects by hand, each one within UniTo's hosts. A redirect out of `within` comes back
        as it is, not followed."""
        for _ in range(MAX_REDIRECTS):
            try:
                r = await self.http.send(request)
            except httpx.HTTPError as e:
                raise LoginFailed("network", f"UniTo didn't answer ({type(e).__name__})") from None
            if r.status_code >= 500:
                raise LoginFailed("network", f"UniTo answered {r.status_code}")
            if not r.is_redirect:
                return r
            target = urljoin(str(r.url), r.headers.get("location", ""))
            if within is not HOSTS and not _https_on(target, within):
                return r
            if not _https_on(target, HOSTS):
                raise LoginFailed("needs_you", "the login went to a page outside UniTo")
            request = self.http.build_request("GET", target)
        raise LoginFailed("needs_you", "the login went round in circles")

    # -- logging in ------------------------------------------------------------------

    async def _login(self, r: httpx.Response) -> httpx.Response:
        entry = self.entry()
        if entry["status"] == "wrong":
            raise LoginFailed("wrong", "the saved UniTo password is wrong: change it in Settings → Passwords")
        if self.clock() < self._wait_until:
            raise LoginFailed("waiting", "UniTo's login is waiting before trying again")
        try:
            r = await self._steps(entry, r)
        except LoginFailed as e:
            await self._failed(entry, e)
            raise
        if entry["status"] != "ok":
            self.passwords.mark(entry["id"], "ok")
        self.logged_in = True
        log.info("unito login: in")
        return r

    async def _steps(self, entry: dict, r: httpx.Response) -> httpx.Response:
        sent_password = False
        routed = 0
        for _ in range(MAX_STEPS):
            if r.is_redirect:  # from the first page, on its way to the IdP
                target = urljoin(str(r.url), r.headers.get("location", ""))
                if not _https_on(target, HOSTS):
                    raise LoginFailed("needs_you", "the login went to a page outside UniTo")
                r = await self._follow(self.http.build_request("GET", target))
                continue
            if r.url.host in SP_HOSTS:
                if r.status_code != 200:
                    raise LoginFailed("needs_you", f"Esse3 answered {r.status_code} after the login")
                return r
            if r.url.host != IDP_HOST:
                raise LoginFailed("needs_you", "the login went to a page outside UniTo")
            found = forms(r.text)
            password = next((f for f in found if "j_password" in f.names), None)
            saml = next((f for f in found if "SAMLResponse" in f.fields), None)
            storage = next((f for f in found if "shib_idp_ls_supported" in f.fields), None)
            routing = next((f for f in found if f.id == "triggerFlow"), None)
            if password is not None:
                if sent_password:  # the same form again: the IdP refused them
                    raise LoginFailed("wrong", "UniTo refused the saved password")
                action = urljoin(str(r.url), password.action or "")
                if not (_https_on(action, {IDP_HOST}) and urlparse(action).path.startswith(IDP_PATH)):
                    raise LoginFailed("needs_you", "UniTo's login form points somewhere unexpected")
                try:
                    user, pw = self.passwords.use(entry["id"], action, BY)
                except PasswordError as e:
                    raise LoginFailed("needs_you", str(e)) from None
                log.info("unito login: password form")
                data = {**password.fields, "j_username": user.reveal(), "j_password": pw.reveal(),
                        "_eventId_proceed": ""}
                del user, pw
                sent_password = True
                r = await self._follow(self.http.build_request("POST", action, data=data))
                del data
            elif saml is not None:
                action = urljoin(str(r.url), saml.action or "")
                if not _https_on(action, SP_HOSTS):
                    raise LoginFailed("needs_you", "UniTo's login answer points somewhere unexpected")
                log.info("unito login: saml post")
                r = await self._follow(self.http.build_request("POST", action, data=saml.fields))
            elif storage is not None:
                log.info("unito login: storage check")
                data = {**storage.fields, "shib_idp_ls_supported": "true", "_eventId_proceed": ""}
                r = await self._follow(self.http.build_request("POST", urljoin(str(r.url), storage.action or ""),
                                                               data=data))
            elif routing is not None and routed < 2:
                log.info("unito login: choose the university login")
                routed += 1
                data = {**routing.fields, "_eventId_routing": "", "selected_flow": "internal",
                        "auth_ctx": "authn/Password", "spid_idp": ""}
                r = await self._follow(self.http.build_request("POST", urljoin(str(r.url), routing.action or ""),
                                                               data=data))
            else:
                raise LoginFailed("needs_you", "UniTo showed a page Aide doesn't know (a code, a new password, "
                                               "a consent): log in once yourself")
        raise LoginFailed("needs_you", "the login took too many steps")

    async def _failed(self, entry: dict, e: LoginFailed) -> None:
        log.warning("unito login: %s", e.kind)
        if e.kind == "network":
            self._wait_until = self.clock() + NETWORK_WAIT
            return
        if e.kind == "needs_you":
            self._wait_until = self.clock() + NEEDS_YOU_WAIT
        if entry["status"] == e.kind:  # told already
            return
        self.passwords.mark(entry["id"], e.kind)
        if e.kind == "wrong":
            title = "UniTo password refused"
            body = (f"UniTo said the password for {entry['name']} in Aide is wrong. Change it in Settings → "
                    "Passwords; Aide won't try it again until then.")
        else:
            title = "UniTo login needs you"
            body = f"{e} Aide will try again tomorrow."
        activity.record(self.passwords.conn, "aide", "passwords", title)
        if self.push is not None:
            await self.push.send_passwords(title, body)
