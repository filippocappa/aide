"""Browsing in chat (#77): the shared page tools' guard refusing in chat, screenshots as images for the model but
lines in the stored history, the turn's budget, a chat's page kept for a follow-up and closed when idle."""

import base64
import time
from datetime import timedelta

import pytest

from aide.agent import Agent
from aide.browsing import ChatBrowsing, PageGuard, browsing_tools, page_tools
from aide.db import Database
from aide.tools import Tool, ToolOutput, ToolRegistry
from test_agent import FakeClient, text, tool_use
from test_errands import FakeBrowser

SPEAKERS = "https://www.socialfootballsummit.com/en/sfs-26/speaker"
HOME = "https://www.socialfootballsummit.com/en"
SHOP = "https://shop.test/item"
LOGIN = "https://shop.test/login"

PAGES = {
    HOME: ("SFS 26", "Social Football Summit, 10–11 Nov", {
        "1": {"text": "View All", "tag": "a", "goes": SPEAKERS},
        "2": {"text": "Day 2", "tag": "button"},
        "3": {"text": "Iscriviti alla newsletter", "tag": "button"}}),
    SPEAKERS: ("Speakers", "Luigi De Siervo, CEO, Lega Serie A", {}),
    SHOP: ("Item", "Cast-iron pan 39,90 €", {
        "4": {"text": "Acquista ora", "tag": "button"},
        "5": {"text": "Cerca", "tag": "input", "submits": "Cerca"},
        "6": {"text": "Card number", "tag": "input", "sensitive": True},
        "7": {"text": "Promo", "tag": "input", "submits": "Invia ordine"}}),
    LOGIN: ("Login", "Accedi", {"8": {"text": "Username", "tag": "input", "submits": "Accedi"}}),
}


class Shots(FakeBrowser):
    def __init__(self):
        super().__init__(PAGES)
        self.closed, self.pruned = [], 0

    async def screenshots(self, owner, pieces=1):
        self._here(owner)
        return [b"\xff\xd8 shot %d" % i for i in range(pieces)]

    async def text(self, owner):
        return self._here(owner)[1]

    async def close(self, owner):
        self.closed.append(owner)
        self.at.pop(owner, None)

    async def prune(self):
        self.pruned += 1

    async def refuse_cookies(self, owner):
        self.refused = getattr(self, "refused", 0) + 1


class Turn:
    def __init__(self, conversation="c1"):
        self.conversation, self.number = conversation, 1

    def __call__(self):
        return self.conversation, self.number


@pytest.fixture
def chat():
    browser, turn = Shots(), Turn()
    chats = ChatBrowsing(browser, turn)
    tools = {t.name: t for t in browsing_tools(chats)}
    return browser, turn, chats, tools


async def browse(tools, **args):
    return await tools["browse_page"].handler(**args)


# -- the guard ---------------------------------------------------------------------------------------------------

async def test_chat_clicks_through_a_page_and_reads_the_list(chat):
    browser, _, _, tools = chat
    await browse(tools, action="open", url=HOME)
    assert browser.refused == 1  # its cookie banner, refused as it opens
    assert "[1]" in await browse(tools, action="read")
    await browse(tools, action="click", ref="1")
    assert browser.at["chat:c1"] == SPEAKERS
    assert "De Siervo" in await browse(tools, action="read")


async def test_chat_refuses_a_committing_click_and_says_start_errand(chat):
    browser, _, _, tools = chat
    await browse(tools, action="open", url=SHOP)
    with pytest.raises(ValueError, match="start_errand"):
        await browse(tools, action="click", ref="4")
    await browse(tools, action="open", url=HOME)
    with pytest.raises(ValueError, match="start_errand"):  # a newsletter's Iscriviti signs up
        await browse(tools, action="click", ref="3")
    assert browser.clicked == []


async def test_chat_refuses_card_fields_logins_and_enter_that_sends(chat):
    browser, _, _, tools = chat
    await browse(tools, action="open", url=SHOP)
    with pytest.raises(ValueError, match="password or card"):
        await browse(tools, action="type", ref="6", text="4111")
    with pytest.raises(ValueError, match="send that form"):
        await browse(tools, action="type", ref="7", text="PROMO")
    await browse(tools, action="type", ref="5", text="padella")  # a search box is fine
    await browse(tools, action="open", url=LOGIN)
    with pytest.raises(ValueError, match="login"):
        await browse(tools, action="type", ref="8", text="filippo")
    with pytest.raises(ValueError, match="pays"):
        await browse(tools, action="open", url="https://shop.test/checkout/place-order")
    with pytest.raises(ValueError, match="login"):
        await browse(tools, action="open", url="https://idp.unito.it/idp/profile/SAML2/Redirect/SSO")
    assert browser.typed == ["padella"]


async def test_the_shared_tools_ask_the_guard_before_a_commit():
    """The same page_tools errands use: a guard that allows a confirmed click lets it through."""
    class Allows(PageGuard):
        async def committing(self, ref, text, info, why):
            return f"Clicked the confirmed \"{text}\""

    browser = Shots()
    await browser.open("x", SHOP)
    refusing = {t.name: t.handler for t in page_tools(browser, "x", PageGuard())}
    with pytest.raises(ValueError):
        await refusing["click"]("4")
    allowing = {t.name: t.handler for t in page_tools(browser, "x", Allows())}
    await allowing["click"]("4")
    assert browser.clicked == ["Acquista ora"]


async def test_actions_sent_together_run_in_order(chat):
    """The model sends open and find in one round, and a round's calls run at once: find waits for open."""
    import asyncio
    browser, _, _, tools = chat
    opened, found = await asyncio.gather(browse(tools, action="open", url=HOME),
                                         browse(tools, action="find", text="View All"))
    assert opened.startswith("SFS 26") and found == "nothing"


async def test_browse_needs_an_open_page_and_its_arguments(chat):
    _, _, _, tools = chat
    with pytest.raises(ValueError, match="No page is open"):
        await browse(tools, action="read")
    with pytest.raises(ValueError, match="needs `url`"):
        await browse(tools, action="open")


# -- the budget and the session ----------------------------------------------------------------------------------

async def test_a_turn_has_a_budget_of_page_actions(chat):
    browser, turn, chats, tools = chat
    chats.actions = 3
    await browse(tools, action="open", url=HOME)
    await browse(tools, action="click", ref="1")
    await browse(tools, action="back")
    with pytest.raises(ValueError, match="offer an errand"):
        await browse(tools, action="open", url=HOME)
    turn.number += 1  # the next turn starts again
    await browse(tools, action="open", url=HOME)


async def test_a_turn_has_a_time_budget(chat):
    _, _, chats, tools = chat
    await browse(tools, action="open", url=HOME)
    convo, (number, spent, started) = "c1", chats._turns["c1"]
    chats._turns[convo] = (number, spent, started - chats.seconds - 1)
    with pytest.raises(ValueError, match="this turn's browsing"):
        await browse(tools, action="read", doing="Reading")


async def test_a_follow_up_reuses_the_open_page_and_each_chat_has_its_own(chat):
    browser, turn, _, tools = chat
    await browse(tools, action="open", url=HOME)
    await browse(tools, action="click", ref="1")
    turn.number += 1
    assert "De Siervo" in await browse(tools, action="read")  # the next turn goes on from the page
    turn.conversation = "c2"
    with pytest.raises(ValueError, match="No page is open"):
        await browse(tools, action="read")


async def test_a_chats_page_closes_after_it_sits_idle(chat):
    browser, _, chats, tools = chat
    await browse(tools, action="open", url=HOME)
    await chats.close_idle()
    assert browser.closed == []
    chats._used["c1"] = time.monotonic() - chats.idle - 1
    await chats.close_idle()
    assert browser.closed == ["chat:c1"] and browser.pruned == 2
    with pytest.raises(ValueError, match="No page is open"):
        await browse(tools, action="read")


async def test_look_at_page_returns_pictures_and_a_line(chat):
    _, _, _, tools = chat
    out = await tools["look_at_page"].handler(url=HOME)
    assert out.startswith("(a screenshot of socialfootballsummit.com/en. You saw it") and len(out.images) == 1
    whole = await tools["look_at_page"].handler(full=True)
    assert whole.startswith("(3 screenshots, top to bottom, of socialfootballsummit.com/en") and len(whole.images) == 3
    assert whole.image == whole.images[0]


async def test_look_at_page_without_a_page_asks_for_the_url(chat):
    _, _, _, tools = chat
    with pytest.raises(ValueError, match="give the url"):
        await tools["look_at_page"].handler()


async def test_steps_say_what_aide_is_doing(chat):
    _, _, _, tools = chat
    assert tools["browse_page"].step({"action": "click", "doing": "Opening Speaker"}) == "Opening Speaker"
    assert tools["browse_page"].step({"action": "open", "url": HOME}) == "Opening socialfootballsummit.com"
    assert tools["look_at_page"].step({"url": HOME}) == "Looking at socialfootballsummit.com"


# -- screenshots in the chat loop --------------------------------------------------------------------------------

def _shot(n):
    return {"media_type": "image/jpeg", "data": base64.b64encode(b"shot %d" % n).decode()}


async def look(n: int) -> ToolOutput:
    return ToolOutput(f"(a screenshot of site.test/{n})", images=[_shot(n)])


LOOK = ToolRegistry([Tool("look", "Look", {"type": "object", "properties": {"n": {"type": "integer"}},
                                           "required": ["n"], "additionalProperties": False}, look)])


@pytest.fixture
def db():
    d = Database(":memory:")
    yield d
    d.close()


def _results(request):
    return [b for m in request["messages"] if m["role"] == "user" and isinstance(m["content"], list)
            for b in m["content"] if b.get("type") == "tool_result"]


async def test_screenshots_reach_the_model_as_images_and_history_keeps_lines(db):
    client = FakeClient([
        ("tool_use", [tool_use("a", "look", {"n": 1})]),
        ("tool_use", [tool_use("b", "look", {"n": 2})]),
        ("tool_use", [tool_use("c", "look", {"n": 3})]),
        ("end_turn", [text("Twenty speakers.")]),
        ("end_turn", [text("And on day two…")]),
    ])
    agent = Agent(client, db, LOOK, model="fast-model", delegate=False)
    assert await agent.reply("discord", "who speaks?") == "Twenty speakers."

    first = _results(client.requests[1])[0]
    assert first["content"][0] == {"type": "text", "text": "(a screenshot of site.test/1)"}
    assert first["content"][1]["source"]["data"] == _shot(1)["data"]
    last = _results(client.requests[3])  # three looks: only the latest two are pictures
    assert last[0]["content"] == "(a screenshot of site.test/1)"
    assert [b["content"][1]["type"] for b in last[1:]] == ["image", "image"]

    conv = db.current_conversation("discord", timedelta(hours=1))
    stored = [b for m in db.history(conv) if isinstance(m["content"], list) for b in m["content"]
              if b.get("type") == "tool_result"]
    assert [b["content"] for b in stored] == [f"(a screenshot of site.test/{n})" for n in (1, 2, 3)]

    await agent.reply("discord", "and day two?")  # the next turn sends the lines, not the pictures
    assert all(isinstance(b["content"], str) for b in _results(client.requests[4]))


async def test_the_last_round_answers_with_tools_off(db, monkeypatch):
    """A long browse used up the rounds: the last request has no tools and says to answer now (#77)."""
    import aide.agent as agent_module
    monkeypatch.setattr(agent_module, "MAX_TOOL_ROUNDS", 3)
    client = FakeClient([
        ("tool_use", [tool_use("a", "look", {"n": 1})]),
        ("tool_use", [tool_use("b", "look", {"n": 2})]),
        ("end_turn", [text("Here's what the page shows so far.")]),
    ])
    agent = Agent(client, db, LOOK, model="fast-model", delegate=False)
    assert await agent.reply("discord", "who speaks?") == "Here's what the page shows so far."
    assert "tool_choice" not in client.requests[1]
    last = client.requests[2]
    assert last["tool_choice"] == {"type": "none"}
    assert last["messages"][-1]["content"][-1]["text"].startswith("That was the last step")
