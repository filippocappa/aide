"""Memory tools. Remembering runs immediately; forgetting waits for the user's !yes."""

from ..db import Database
from . import Tool

MAX_LENGTH = 500


def memory_tools(db: Database) -> list[Tool]:
    def find(memory_id: int):
        item = db.memory_item(memory_id)
        if item is None:
            raise KeyError(f"no memory with id {memory_id}")
        return item

    async def remember(text: str) -> str:
        text = " ".join(text.split())
        if not text:
            raise ValueError("nothing to remember")
        if len(text) > MAX_LENGTH:
            raise ValueError(f"keep it under {MAX_LENGTH} characters")
        if any(m["text"] == text for m in db.memories()):
            return f"Already remembered: {text}"
        item = db.add_memory(text)
        return f"Remembered: [{item['id']}] {item['text']}"

    async def forget(memory_id: int) -> str:
        item = find(memory_id)
        db.delete_memory(memory_id)
        return f"Forgot: {item['text']}"

    async def describe_forget(memory_id: int) -> str:
        return f"Forget '{find(memory_id)['text']}'"

    return [
        Tool("remember", "Save a short, lasting fact about the user (a preference, a name, a routine) so you know "
             "it in every future chat. One fact per call, written as a plain note. Runs immediately.",
             {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"],
              "additionalProperties": False}, remember),
        Tool("forget", "Delete a remembered fact, by the id shown in the memory list. Needs the user's confirmation: "
             "it is queued, and runs only when the user replies !yes.",
             {"type": "object", "properties": {"memory_id": {"type": "integer"}}, "required": ["memory_id"],
              "additionalProperties": False},
             forget, confirm=True, describe=describe_forget, target_arg="memory_id"),
    ]
