"""Memory tools. Remembering runs immediately; forgetting waits for the user's !yes.

Each agent gets its own pair: it sees and dedupes against the shared items plus its own. Aide saves shared items
only; a specialist picks the scope (docs/API.md, "Memory").
"""

import re
from difflib import SequenceMatcher

from ..db import Database
from . import Tool

MAX_LENGTH = 500
SIMILAR = 0.85  # character similarity above which two facts count as the same one, reworded

# Words that don't change what a fact says ("User's name is X" = "Name: X" = "My name is X").
STOPWORDS = set("""
a an the is are was were be been am i im me my mine user users their theirs they he she his her hers
of to in on at for with and or by as that this has have had
""".split())
# Extra words that flip a fact rather than add detail to it: never merged silently.
NEGATIONS = {"not", "no", "never", "dont", "doesnt", "isnt", "arent", "wasnt", "cant", "wont", "anymore", "nor"}


def _words(text: str) -> list[str]:
    return [w for w in re.findall(r"\w+", text.casefold().replace("'", "")) if w not in STOPWORDS]


def memory_tools(db: Database, agent: str = "aide", scoped: bool = False) -> list[Tool]:
    """`scoped`: the agent can save items of its own, not only shared ones."""
    def find(memory_id: int, visible: bool = False):
        item = db.memory_item(memory_id)
        if item is None or visible and item["agent"] not in (None, agent):
            raise KeyError(f"no memory with id {memory_id}")
        return item

    async def remember(text: str, scope: str = "shared") -> str:
        text = " ".join(text.split())
        if not text:
            raise ValueError("nothing to remember")
        if len(text) > MAX_LENGTH:
            raise ValueError(f"keep it under {MAX_LENGTH} characters")
        new = set(_words(text))
        leaving = db.memories_being_forgotten()  # a correction: the old fact is on its way out
        owner = agent if scoped and scope == "own" else None
        for item in db.memories(agent):
            if item["id"] in leaving:
                continue
            old = set(_words(item["text"]))
            if new and new <= old:  # same fact, or the saved one already says more
                return f"Already saved, nothing added: [{item['id']}] {item['text']}"
            if old and old < new and not (new - old) & NEGATIONS:  # adds detail: keep one, the fuller
                db.set_memory_text(item["id"], text)
                return f"Already saved; updated it with the new detail: [{item['id']}] {text}"
            if SequenceMatcher(None, " ".join(_words(item["text"])), " ".join(_words(text))).ratio() >= SIMILAR:
                return (f"Not saved: a very similar fact is already saved: [{item['id']}] {item['text']}. "
                        f"If the user is correcting it, queue forget for [{item['id']}] and then remember the new one.")
        item = db.add_memory(text, owner)
        return f"Remembered: [{item['id']}] {item['text']}"

    async def forget(memory_id: int) -> str:
        item = find(memory_id)
        db.delete_memory(memory_id)
        return f"Forgot: {item['text']}"

    async def describe_forget(memory_id: int) -> str:
        return f"Forget '{find(memory_id, visible=True)['text']}'"

    properties = {"text": {"type": "string"}}
    if scoped:
        properties["scope"] = {"type": "string", "enum": ["shared", "own"],
                               "description": "shared: any assistant can use it (name, home, routines); "
                                              "own: only you need it"}
    return [
        Tool("remember", "Save a short, lasting fact about the user (a preference, a name, a routine) so you know "
             "it in every future chat. Check the saved facts first and don't save one that's already there. "
             "One fact per call, written as a plain note. Runs immediately; a duplicate is not saved twice.",
             {"type": "object", "properties": properties, "required": list(properties),
              "additionalProperties": False}, remember),
        Tool("forget", "Delete a remembered fact, by the id shown in the memory list. Needs the user's confirmation: "
             "it is queued, and runs only when the user replies !yes.",
             {"type": "object", "properties": {"memory_id": {"type": "integer"}}, "required": ["memory_id"],
              "additionalProperties": False},
             forget, confirm=True, describe=describe_forget, target_arg="memory_id"),
    ]
