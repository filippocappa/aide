"""Tool registry. Tools are the only code that touches external services."""

from dataclasses import dataclass
from typing import Any, Awaitable, Callable

ToolHandler = Callable[..., Awaitable[str]]


class ToolOutput(str):
    """A tool result: the text the model reads, plus data the app shows as cards under the reply.

    `attachment` is one docs/API.md attachment, e.g. {"type": "reminders", "reminders": [...]}.
    """

    attachment: dict | None

    def __new__(cls, text: str, attachment: dict | None = None):
        out = super().__new__(cls, text)
        out.attachment = attachment
        return out


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    input_schema: dict
    handler: ToolHandler
    # confirm=True: the agent queues the call and runs it only after the user's !yes.
    # describe(**args) says in one line what will happen, and raises if it can't happen.
    confirm: bool = False
    describe: ToolHandler | None = None
    # Argument naming what the action changes (e.g. event_id). A newly queued action on the
    # same target replaces older queued ones, so "no, make it 2pm" doesn't leave both waiting.
    target_arg: str | None = None

    def definition(self) -> dict:
        return {
            "name": self.name,
            "description": self.description,
            "input_schema": self.input_schema,
            "strict": True,
        }


class ToolRegistry:
    def __init__(self, tools: list[Tool]):
        # Keep insertion order: a stable tool list keeps the prompt cache warm.
        self._tools = {t.name: t for t in tools}

    def __iter__(self):
        return iter(self._tools.values())

    def definitions(self) -> list[dict]:
        return [t.definition() for t in self._tools.values()]

    def get(self, name: str) -> Tool:
        tool = self._tools.get(name)
        if tool is None:
            raise KeyError(f"unknown tool {name!r}")
        return tool

    async def call(self, name: str, args: dict[str, Any]) -> str:
        return await self.get(name).handler(**args)
