"""Discord adapter: DMs from the owner in, replies out. Everyone else is ignored."""

import logging

import anthropic
import discord

from ..agent import Agent

log = logging.getLogger(__name__)

DISCORD_LIMIT = 2000
CHANNEL = "discord"


def split_message(text: str, limit: int = DISCORD_LIMIT) -> list[str]:
    """Split on paragraph, then line, then hard boundaries to fit Discord's message limit."""
    chunks: list[str] = []
    while len(text) > limit:
        cut = text.rfind("\n\n", 0, limit)
        if cut <= 0:
            cut = text.rfind("\n", 0, limit)
        if cut <= 0:
            cut = limit
        chunks.append(text[:cut].rstrip())
        text = text[cut:].lstrip("\n")
    if text:
        chunks.append(text)
    return chunks


class AideBot(discord.Client):
    def __init__(self, agent: Agent, owner_id: int):
        # DMs carry message content without the privileged message_content intent.
        super().__init__(intents=discord.Intents.default())
        self.agent = agent
        self.owner_id = owner_id
        self._announced = False

    async def on_ready(self) -> None:
        log.info("connected as %s", self.user)
        if not self._announced:  # on_ready also fires on every gateway reconnect
            self._announced = True
            await self.notify_owner("Aide is up.")

    async def notify_owner(self, text: str) -> None:
        try:
            owner = await self.fetch_user(self.owner_id)
            for chunk in split_message(text):
                await owner.send(chunk)
        except discord.DiscordException:
            log.exception("could not DM owner")

    async def on_message(self, message: discord.Message) -> None:
        if message.author.id != self.owner_id or not isinstance(message.channel, discord.DMChannel):
            return
        text = message.content.strip()
        if not text:
            return
        if text == "!new":
            self.agent.reset(CHANNEL)
            await message.channel.send("Started a new conversation.")
            return
        if text.startswith("!think"):
            self.agent.think(CHANNEL)
            text = text.removeprefix("!think").strip()
            if not text:
                await message.channel.send("Using the smarter model for the rest of this conversation.")
                return

        async with message.channel.typing():
            try:
                reply = await self.agent.reply(CHANNEL, text)
            except anthropic.RateLimitError:
                reply = "I'm being rate limited right now. Try again in a minute."
            except anthropic.APIConnectionError:
                reply = "I can't reach the Claude API right now. Try again shortly."
            except anthropic.APIStatusError as e:
                log.error("API error %s: %s", e.status_code, e.message)
                reply = f"The Claude API returned an error ({e.status_code})."
            except Exception:
                log.exception("turn failed")
                reply = "Something went wrong on my side. It's in the logs."
        for chunk in split_message(reply):
            await message.channel.send(chunk)
