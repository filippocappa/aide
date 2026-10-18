"""Tool registry. Tools are the only code that touches external services."""

from dataclasses import dataclass
from typing import Any, Awaitable, Callable

ToolHandler = Callable[..., Awaitable[str]]


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

    def definitions(self) -> list[dict]:
        return [t.definition() for t in self._tools.values()]

    def get(self, name: str) -> Tool:
        tool = self._tools.get(name)
        if tool is None:
            raise KeyError(f"unknown tool {name!r}")
        return tool

    async def call(self, name: str, args: dict[str, Any]) -> str:
        return await self.get(name).handler(**args)
