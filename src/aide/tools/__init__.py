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

    async def call(self, name: str, args: dict[str, Any]) -> str:
        tool = self._tools.get(name)
        if tool is None:
            raise KeyError(f"unknown tool {name!r}")
        return await tool.handler(**args)
