"""The page tools (open, read, find, look, click, type, choose, press, scroll, back) and the guard that keeps them from
changing anything, shared by errands (errands.py) and browsing in chat (#77).

`page_tools(browser, owner, guard)` builds them for one owner's page. Before an action that could buy, book, send,
sign up or delete (`commit_reason`, an Enter that `commits()`, a password or card field) the tools ask the guard:
an errand's (errands.py) lets a click through only once the user confirmed it; `PageGuard`, chat's, refuses outright
and says to start an errand instead.

In chat (`ChatBrowsing`), each conversation has one page in the reading browser (data/reading/, the one fetch_page
uses, with no saved logins), owner `chat:{conversation}`. It stays open IDLE seconds after its last use, for a
follow-up, then closes; a page's cookie banner is refused when it opens. A turn may make TURN_ACTIONS page calls (reads
included) in TURN_SECONDS; past that, the tools say to answer with what's there and offer an errand to go further.
"""

import asyncio
import base64
import logging
import re
import time
from typing import Callable
from urllib.parse import urlparse

from .browser import Browser, BrowserError, site_of
from .tools import Tool, ToolOutput

log = logging.getLogger(__name__)

IDLE = 5 * 60  # seconds a chat's page stays open after its last use
TURN_ACTIONS = 15  # page calls in one chat turn, reads included: it runs out before the turn's model rounds do
TURN_SECONDS = 90  # from the turn's first page action
PIECES = 3  # screenshots for a whole page (look_at_page with full)
CHECK_EVERY = 30  # seconds between looks for idle chat pages
IDP_HOST = "idp.unito.it"  # UniTo's login page (unito.IDP_HOST)

REFUSED = "that would change something: start_errand with the task instead"

# What a committing element is called in the page's code (ids, classes, test ids, form actions), whatever its text
# says: an icon-only pay button, or one worded unusually.
COMMIT_HINT = re.compile(
    r"place[-_ ]?(your[-_ ]?)?order|placeorder|buy[-_ ]?now|buynow|submit[-_ ]?order|submitorder|"
    r"confirm[-_ ]?(order|payment|purchase|booking)|complete[-_ ]?(order|purchase|checkout|booking)|"
    r"pay[-_ ]?now|\bpay\b|checkout[-_ ]?submit|order[-_ ]?submit|conferma[-_ ]?ordine|effettua[-_ ]?ordine", re.I)
# A checkout: a page where the next button may be the one that pays.
CHECKOUT_URL = re.compile(r"checkout|order[-_]?summary|/pay(ment)?\b|pagamento|riepilogo|order[-_]?review|/buy/|/spc/|conferma", re.I)
CHECKOUT_TEXT = re.compile(r"metodo di pagamento|payment method|totale (dell'?)?ordine|order total|totale da pagare|"
                           r"importo totale|riepilogo (dell'?)?ordine|order summary|review your order", re.I)
# There, a button that says only to go on (or nothing at all) may be the final one: it needs the Confirm too.
GO_ON = re.compile(r"^(procedi|prosegui|continua|avanti|conferma|vai|fatto|ok|next|continue|proceed|confirm|done|"
                   r"submit|go)\b|^[\W_]*$", re.I)
# Small controls that never buy: a quantity's + and −, a close button.
STEPPER = re.compile(r"qty|quantit|increment|decrement|stepper|minus|plus|close|dismiss|chiudi", re.I)
# A page that says an order went through.
PLACED_URL = re.compile(r"thank|grazie|order[-_]?(confirm|placed|complete|success)|confirmation|conferma[-_]?ordine|"
                        r"success", re.I)
PLACED = re.compile(r"thank you for your (order|purchase|booking)|order (confirmed|placed|received|complete)|"
                    r"grazie per (il tuo |l'|aver )?(ordin|acquist|prenot)|"
                    r"(ordine|prenotazione|order|booking)( n\.?| #| number)? ?[\w-]{0,20} (effettuat|confermat|ricevut|"
                    r"completat|placed|confirmed)|acquisto completato|booking confirmed", re.I)

# Buttons that commit: they need the user's Confirm. (Going to the checkout, adding to the cart, searching don't.)
COMMIT = re.compile(
    r"\b(acquista|compra( ora| adesso)?|ordina( ora)?|effettua (l'|il )?(ordine|pagamento)|invia (l'|il )?ordine|"
    r"conferma (e paga|l'ordine|ordine|acquisto|l'acquisto|prenotazione|la prenotazione|pagamento|il pagamento)|"
    r"paga( ora| adesso)?|prenota( ora| adesso)?|acquista ora|invia|iscriviti|registrati|abbonati|"
    r"disdici|annulla (l'|il )?(ordine|abbonamento|prenotazione)|elimina (il |l')?(account|profilo)|"
    r"buy( now)?|place (your |the )?order|order now|pay( now)?|book( now)?|purchase|checkout and pay|"
    r"confirm (and pay|order|purchase|booking|payment)|complete (purchase|order|booking|payment)|submit|send|"
    r"subscribe|sign up|register|unsubscribe|cancel (order|subscription|booking|membership)|"
    r"delete (account|profile)|close (account|profile))\b",
    re.I)
NEXT_FORM = re.compile(r"(avanti|indietro|next|previous|back|continua|continue|prosegui) (invia|submit) (il |the )?form"
                       # saying where it goes: "… e vai alla pagina seguente" (Edumeter's personal-details page)
                       r"( e (vai|torna) alla pagina (seguente|successiva|precedente)"
                       r"| and go to the (next|previous) page)?")
COMMIT_TEXT = 48  # characters: longer texts aren't buttons
KEYS = ("Enter", "Tab", "Escape", "ArrowDown", "ArrowUp", "Backspace")
# A form's button that logs in: chat never logs in (an errand does, with the saved logins).
LOGIN = re.compile(r"\b(accedi|entra|log ?in|sign ?in|login|continua con|continue with)\b", re.I)


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().lower()


def commits(text: str | None) -> bool:
    """A button's text that buys, books, sends, signs up or deletes. Only short texts: a long link is a product
    or an article ("… Paperback book"), not a button."""
    text = _norm(text or "")
    if (step := NEXT_FORM.fullmatch(text)) is not None:  # "Avanti Invia form": a page of a form, not the sending
        text = step.group(1)
    return 0 < len(text) <= COMMIT_TEXT and bool(COMMIT.search(text))


def at_checkout(url: str | None, text: str | None) -> bool:
    """The page is a checkout (its address, or what it says: a payment method, the order's total)."""
    return bool(CHECKOUT_URL.search(urlparse(url or "").path or "")) or bool(CHECKOUT_TEXT.search(text or ""))


def commit_reason(info: dict, url: str | None, page_text: str | None) -> str | None:
    """Why clicking this element (browser.inspect's) could buy, book, send or delete, or None. Its text (`commits`),
    what the page's code calls it (`COMMIT_HINT`), and on a checkout any button that only says to go on, or nothing."""
    text = info.get("text") or ""
    if commits(text):
        return "its text"
    if COMMIT_HINT.search(info.get("hints") or ""):
        return "what the page calls it"
    if at_checkout(url, page_text) and info.get("tag") in ("button", "input", "a", "div", "span", "img", "svg") \
            and info.get("type") not in ("text", "email", "tel", "search", "number", "checkbox", "radio") \
            and len(_norm(text)) <= COMMIT_TEXT and GO_ON.search(_norm(text)) \
            and not STEPPER.search(info.get("hints") or ""):
        return "on a checkout, a button that only says to go on"
    return None


def placed(url: str | None, heading: str | None) -> bool:
    """The page says an order (or a booking) went through."""
    return bool(PLACED_URL.search(urlparse(url or "").path or "")) or bool(PLACED.search(heading or ""))


def enter_sends(info: dict, url: str | None, page_text: str | None) -> bool:
    """Enter in this field (inspect's, or the focused element's) would send its form: a committing submit button,
    one the page's code calls so, or any form on a checkout."""
    return commits(info.get("submits")) or bool(COMMIT_HINT.search(info.get("submit_hints") or "")) or \
        bool(info.get("in_form") and at_checkout(url, page_text))


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


class PageGuard:
    """What the page tools ask around each action. This one is chat's: read-only. Anything that would change
    something is refused with REFUSED; an errand's guard (errands.py) asks the user to confirm instead."""

    def step(self, text: str, counts: bool = True, doing: str | None = None) -> None:
        """Before each action (`counts`: it's a browser action, not just reading); raise ValueError to stop it."""

    async def opening(self, url: str) -> None:
        if COMMIT_HINT.search(urlparse(url).path + "?" + urlparse(url).query):
            raise ValueError(f"That address looks like it places an order or pays: {REFUSED}.")
        if (urlparse(url).hostname or "").lower() == IDP_HOST:
            raise ValueError(f"That's a login: {REFUSED}.")

    async def opened(self, url: str) -> None:
        pass

    async def read(self) -> None:
        pass

    def commits(self, info: dict, url: str | None, page_text: str | None) -> str | None:
        """Why a click on this element would change something, or None."""
        return commit_reason(info, url, page_text)

    async def committing(self, ref: str, text: str, info: dict, why: str) -> str:
        """A click `commits` flagged: raise when it may not happen, else return the step's line."""
        raise ValueError(f"[{ref}] \"{text[:80]}\" could change something (buy, book, send, sign up, delete): "
                         f"{REFUSED}.")

    def sensitive(self) -> str:
        return f"That's a password or card field: {REFUSED}."

    async def typing(self, info: dict, press_enter: bool) -> None:
        """Before typing in a field that isn't a password or card one: chat doesn't fill in a login."""
        if info.get("type") == "email" or LOGIN.search(f"{info.get('submits') or ''} {info.get('submit_hints') or ''}"):
            raise ValueError(f"That's a login or sign-up form: {REFUSED}.")

    def enter(self) -> str:
        return f"Enter would send that form: {REFUSED}."

    async def after(self, what: str) -> None:
        """After a click, a choice or Back that wasn't confirmed: errands check the page didn't place an order."""


def page_tools(browser: Browser, owner: str, guard: PageGuard) -> list[Tool]:
    """The page tools for `owner`'s page in `browser`, each action passed by `guard` first."""
    b = browser

    async def open_page(url: str, doing: str | None = None) -> str:
        await guard.opening(url)
        guard.step(f"Opened {url[:120]}", doing=doing)
        heading = await b.open(owner, url)
        await guard.opened(url)
        return heading + "\n(read_page to see it)"

    async def read_page(everything: bool | None = None, doing: str | None = None) -> str:
        if doing:
            guard.step("Read the page", counts=False, doing=doing)
        text = await b.read(owner, bool(everything))
        await guard.read()
        return text

    async def find_on_page(text: str, doing: str | None = None) -> str:
        if doing:
            guard.step(f"Looked for \"{text[:60]}\"", counts=False, doing=doing)
        return await b.find(owner, text)

    async def screenshot(doing: str | None = None) -> ToolOutput:
        if doing:
            guard.step("Looked at the page", counts=False, doing=doing)
        data = await b.screenshot(owner)
        return ToolOutput("The visible part of the page:", image={"media_type": "image/jpeg",
                                                                   "data": base64.b64encode(data).decode()})

    async def click(ref: str, doing: str | None = None) -> str:
        info = await b.inspect(owner, ref)
        text = info["text"] or info["tag"]
        where = b.where(owner) or {}
        why = guard.commits(info, where.get("url"), await b.text(owner))
        if why:
            guard.step(await guard.committing(ref, text, info, why), doing=doing)
        else:
            guard.step(f"Clicked [{ref}] \"{text[:80]}\"", doing=doing)
        out = await b.click(owner, ref)
        if not why:
            await guard.after(text)
        return out

    async def type_text(ref: str, text: str, press_enter: bool | None = None, doing: str | None = None) -> str:
        info = await b.inspect(owner, ref)
        if info["sensitive"]:
            raise ValueError(guard.sensitive())
        await guard.typing(info, bool(press_enter))
        if press_enter and enter_sends(info, (b.where(owner) or {}).get("url"), await b.text(owner)):
            raise ValueError(guard.enter())
        guard.step(f"Typed \"{text[:60]}\" in [{ref}]" + (" and pressed Enter" if press_enter else ""), doing=doing)
        return await b.fill(owner, ref, text, bool(press_enter))

    async def select_option(ref: str, option: str, doing: str | None = None) -> str:
        guard.step(f"Chose \"{option[:60]}\" in [{ref}]", doing=doing)
        out = await b.choose(owner, ref, option)
        await guard.after(f"{option} (a drop-down)")
        return out

    async def press_key(key: str, doing: str | None = None) -> str:
        if key not in KEYS:
            raise ValueError(f"key must be one of {', '.join(KEYS)}")
        if key == "Enter" and enter_sends(await b.focused(owner), (b.where(owner) or {}).get("url"),
                                          await b.text(owner)):
            raise ValueError(guard.enter())
        guard.step(f"Pressed {key}", doing=doing)
        return await b.press(owner, key)

    async def scroll(direction: str, doing: str | None = None) -> str:
        guard.step(f"Scrolled {direction}", counts=False, doing=doing)
        return await b.scroll(owner, direction)

    async def go_back(doing: str | None = None) -> str:
        guard.step("Went back", doing=doing)
        out = await b.back(owner)
        await guard.after("Back")
        return out

    ref = {"type": "string", "description": "The number in brackets from read_page, like \"12\""}
    doing = {"doing": {"type": ["string", "null"], "description":
                       "One short line for the user on what you're doing and why, in the task's language, like "
                       "\"Checking the reviews on the Lodge\" or \"Cercando padelle in ghisa\" (under 60 characters)"}}
    return [
        Tool("open_page", "Open a web address (https://…) in the errand's browser.",
             _obj({**doing, "url": {"type": "string"}}, ["url"]), open_page),
        Tool("read_page", "The page's text and a [ref] for each thing to click, type in or choose: the visible "
             "part and a little around it, or `everything`.",
             _obj({**doing, "everything": {"type": ["boolean", "null"]}}, []), read_page),
        Tool("find_on_page", "Where some text is on the whole page, with the ref of what holds it.",
             _obj({**doing, "text": {"type": "string"}}, ["text"]), find_on_page),
        Tool("screenshot", "A picture of the visible part of the page, when the layout or an image matters.",
             _obj({**doing}, []), screenshot),
        Tool("click", "Click (tap) a link, button, checkbox or option by its ref.",
             _obj({**doing, "ref": ref}, ["ref"]), click),
        Tool("type_text", "Type in a text field by its ref, replacing what's there; press_enter to search.",
             _obj({**doing, "ref": ref, "text": {"type": "string"}, "press_enter": {"type": ["boolean", "null"]}},
                  ["ref", "text"]), type_text),
        Tool("select_option", "Choose an option of a drop-down (a select) by its text.",
             _obj({**doing, "ref": ref, "option": {"type": "string"}}, ["ref", "option"]), select_option),
        Tool("press_key", "Press a key on the focused element.",
             _obj({**doing, "key": {"type": "string", "enum": list(KEYS)}}, ["key"]), press_key),
        Tool("scroll", "Scroll the page a screen up or down.",
             _obj({**doing, "direction": {"type": "string", "enum": ["down", "up"]}}, ["direction"]), scroll),
        Tool("go_back", "The browser's Back.", _obj({**doing}, []), go_back),
    ]


# -- browsing in chat --------------------------------------------------------------------------------------------

ACTIONS = ("open", "read", "find", "click", "type", "select", "scroll", "back")
MOVES = {"open", "click", "type", "select", "scroll", "back"}  # actions after which the app gets the page's picture


class _Budget(PageGuard):
    """Chat's guard for one conversation: read-only (PageGuard), and the turn's budget of page actions."""

    def __init__(self, chats: "ChatBrowsing", conversation: str):
        self.chats, self.conversation = chats, conversation

    def step(self, text: str, counts: bool = True, doing: str | None = None) -> None:
        self.chats.spend(self.conversation)  # reads count too: a turn of reads used up the model's rounds (#77)

    async def opened(self, url: str) -> None:
        # A cookie banner covers the page and takes the clicks meant for it (#77: three rounds on SFS's schedule).
        await self.chats.browser.refuse_cookies(self.chats.owner(self.conversation))


class ChatBrowsing:
    """Each chat's page in the reading browser, for look_at_page and browse_page."""

    def __init__(self, browser: Browser, current: Callable[[], tuple[str, int]], idle: float = IDLE,
                 actions: int = TURN_ACTIONS, seconds: float = TURN_SECONDS):
        """`current()` gives the turn in progress: (its conversation, a number that changes with each turn)."""
        self.browser, self.current = browser, current
        self.idle, self.actions, self.seconds = idle, actions, seconds
        self._used: dict[str, float] = {}  # conversation -> monotonic time its page was last used
        self._turns: dict[str, tuple[int, int, float]] = {}  # conversation -> (turn, actions spent, first action)
        self._lock = asyncio.Lock()
        # One action at a time on a chat's page, in the order the model asked: it sends several in one round (open
        # and find together), and the tool calls of a round run at once.
        self._busy: dict[str, asyncio.Lock] = {}

    def _queue(self, conversation: str) -> asyncio.Lock:
        return self._busy.setdefault(conversation, asyncio.Lock())

    @staticmethod
    def owner(conversation: str) -> str:
        return f"chat:{conversation}"

    def spend(self, conversation: str, counts: bool = True) -> None:
        """One page call in this turn; ValueError past the turn's budget (calls or time)."""
        _, turn = self.current()
        now = time.monotonic()
        was, spent, started = self._turns.get(conversation, (None, 0, now))
        if was != turn:
            spent, started = 0, now
        if spent >= self.actions or now - started > self.seconds:
            raise ValueError(f"That's this turn's browsing ({self.actions} page calls, {self.seconds:.0f} s): "
                             "answer now with what you found, say what you tried, and offer an errand "
                             "(start_errand) to go further.")
        self._turns[conversation] = (turn, spent + (1 if counts else 0), started)
        self._used[conversation] = now

    def where(self, conversation: str) -> dict | None:
        return self.browser.where(self.owner(conversation))

    async def close_idle(self) -> None:
        """Close the chats' pages unused for `idle` seconds, then the browsers no page uses."""
        now = time.monotonic()
        async with self._lock:
            for conversation in [c for c, at in self._used.items() if now - at >= self.idle]:
                self._used.pop(conversation, None)
                self._turns.pop(conversation, None)
                try:
                    await self.browser.close(self.owner(conversation))
                except Exception:
                    log.warning("couldn't close %s's page", conversation, exc_info=True)
            try:
                await self.browser.prune()
            except Exception:
                log.warning("couldn't prune the reading browser", exc_info=True)

    async def run(self) -> None:
        while True:
            await asyncio.sleep(CHECK_EVERY)
            try:
                await self.close_idle()
            except Exception:
                log.exception("closing idle chat pages")

    async def look(self, url: str | None = None, full: bool | None = None) -> ToolOutput:
        conversation, _ = self.current()
        async with self._queue(conversation):
            return await self._look(conversation, url, full)

    async def _look(self, conversation: str, url: str | None, full: bool | None) -> ToolOutput:
        owner, guard = self.owner(conversation), _Budget(self, conversation)
        if url:
            await guard.opening(url)
            self.spend(conversation)
            await self.browser.open(owner, url)
            await guard.opened(url)
        elif self.browser.where(owner) is None:
            raise ValueError("No page is open in this chat: give the url.")
        else:
            self.spend(conversation)
        shots = await self.browser.screenshots(owner, PIECES if full else 1)
        where = self.browser.where(owner) or {}
        at = _short(where.get("url") or "")
        # The line is all later turns keep: it says the picture was there, so a follow-up doesn't doubt what was seen.
        pictures = "a screenshot" if len(shots) == 1 else f"{len(shots)} screenshots, top to bottom,"
        line = (f"({pictures} of {at}. You saw it in that turn, and what you said about it came from it; only this "
                "line is kept, so stand by it unless the user says it's wrong)")
        images = [{"media_type": "image/jpeg", "data": base64.b64encode(s).decode()} for s in shots]
        return ToolOutput(line, images=images, page=await self._thumbnail(conversation))

    async def browse(self, action: str, url: str | None = None, ref: str | None = None, text: str | None = None,
                     option: str | None = None, direction: str | None = None, everything: bool | None = None,
                     doing: str | None = None) -> ToolOutput:
        conversation, _ = self.current()
        async with self._queue(conversation):
            out = await self._browse(conversation, action, url, ref, text, option, direction, everything, doing)
            # The app shows the page as it is now while Aide works; reading it changes nothing to show.
            page = await self._thumbnail(conversation) if action in MOVES else None
        if action in ("click", "type", "select", "back"):
            out += "\n(The page may have changed: read it again for its new refs before the next click.)"
        return ToolOutput(out, page=page)

    async def _thumbnail(self, conversation: str) -> str | None:
        thumbnail = getattr(self.browser, "thumbnail", None)
        return await thumbnail(self.owner(conversation)) if thumbnail else None

    async def _browse(self, conversation: str, action: str, url: str | None, ref: str | None, text: str | None,
                      option: str | None, direction: str | None, everything: bool | None, doing: str | None) -> str:
        owner = self.owner(conversation)
        tools = {t.name: t.handler for t in page_tools(self.browser, owner, _Budget(self, conversation))}

        def need(name: str, value):
            if value in (None, ""):
                raise ValueError(f"{action} needs `{name}`.")
            return value
        if action != "open" and self.browser.where(owner) is None:
            raise ValueError("No page is open in this chat: open one first (action open with its url).")
        match action:
            case "open":
                return await tools["open_page"](need("url", url), doing)
            case "read":
                return await tools["read_page"](everything, doing)
            case "find":
                return await tools["find_on_page"](need("text", text), doing)
            case "click":
                return await tools["click"](need("ref", ref), doing)
            case "type":  # a search box or a filter: Enter only where it doesn't send a form (enter_sends)
                return await tools["type_text"](need("ref", ref), need("text", text), True, doing)
            case "select":
                return await tools["select_option"](need("ref", ref), need("option", option), doing)
            case "scroll":
                return await tools["scroll"](direction or "down", doing)
            case "back":
                return await tools["go_back"](doing)
        raise ValueError(f"action must be one of {', '.join(ACTIONS)}")


def _short(url: str) -> str:
    u = urlparse(url)
    return (u.netloc.removeprefix("www.") + u.path.rstrip("/"))[:100] or url[:100]


def browsing_tools(chats: ChatBrowsing) -> list[Tool]:
    """Aide's look_at_page and browse_page, in chat beside fetch_page."""
    async def look_at_page(url: str | None = None, full: bool | None = None) -> ToolOutput:
        try:
            return await chats.look(url, full)
        except BrowserError as e:
            raise ValueError(str(e)) from None

    async def browse_page(action: str, url: str | None = None, ref: str | None = None, text: str | None = None,
                          option: str | None = None, direction: str | None = None, everything: bool | None = None,
                          doing: str | None = None) -> str:
        try:
            return await chats.browse(action, url, ref, text, option, direction, everything, doing)
        except BrowserError as e:
            raise ValueError(str(e)) from None

    def look_step(a: dict) -> str:
        if a.get("url"):
            return f"Looking at {site_of(a['url']) if '.' in a['url'] else a['url']}"
        return "Looking at the page"

    def browse_step(a: dict) -> str | None:
        if a.get("doing"):
            return " ".join(str(a["doing"]).split())[:90]
        return {"open": f"Opening {site_of(a['url'])}" if a.get("url") and "." in a["url"] else "Opening the page",
                "read": "Reading the page", "find": f"Looking for “{a.get('text', '')}”",
                "click": "Clicking through", "type": f"Searching the site for “{a.get('text', '')}”",
                "select": f"Choosing {a.get('option', '')}".strip(), "scroll": "Scrolling",
                "back": "Going back"}.get(a.get("action"))

    nullable = lambda kind, about: {"type": [kind, "null"], "description": about}  # noqa: E731
    return [
        Tool("look_at_page", "See a web page as a picture: the visible part, or the whole page in up to "
             f"{PIECES} pieces with `full`. Use it when fetch_page's text looks empty or incomplete: a programme, menu "
             "or list posted as an image, names only in photos, a layout the text doesn't explain. Without `url`: "
             "the page this chat's browser is on (after browse_page).",
             _obj({"url": nullable("string", "https://… to open first; empty for the page already open"),
                   "full": nullable("boolean", f"the whole page, top to bottom, in up to {PIECES} pictures")}, []),
             look_at_page, step=look_step),
        Tool("browse_page", "Click through a web page in this chat's browser, read-only, when the answer is behind "
             "clicks: a tab, a filter, a \"View All\" that isn't a plain link, the site's own search, the pages of a "
             "list. Actions: open (url), read (its text with a [ref] for each thing to click; `everything` for the "
             "whole page), find (text), click (ref), type (ref and text: a search box or filter, then Enter), "
             "select (ref and option), scroll (direction), back. Anything that would buy, book, send, sign up or "
             f"log in is refused: that's start_errand. About {TURN_ACTIONS} calls a turn; the page stays open for "
             "a follow-up.",
             _obj({"action": {"type": "string", "enum": list(ACTIONS)},
                   "url": nullable("string", "for open: https://…"),
                   "ref": nullable("string", "for click, type, select: the number in brackets from read"),
                   "text": nullable("string", "for find: the words; for type: what to type"),
                   "option": nullable("string", "for select: the option's text"),
                   "direction": {"type": ["string", "null"], "enum": ["down", "up", None]},
                   "everything": nullable("boolean", "for read: the whole page, not just the screen"),
                   "doing": nullable("string", "one short line for the user on what you're doing, like "
                                               "\"Opening the speakers\" (under 60 characters)")},
                  ["action"]),
             browse_page, step=browse_step),
    ]
