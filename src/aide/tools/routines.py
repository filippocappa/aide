"""Routine tools. Listing, creating and changing run immediately; deleting waits for the user's !yes.

Each agent gets its own set: Aide manages every agent's routines (and picks the agent when creating one), the
others only their own (docs/API.md, "Routines").
"""

from ..agents import AGENTS
from ..routines import RoutineStore
from . import Tool


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def routine_tools(store: RoutineStore, agent: str, any_agent: bool = False) -> list[Tool]:
    """`any_agent`: manage every agent's routines, not only `agent`'s own."""
    owner = None if any_agent else agent

    async def list_routines() -> str:
        found = store.all(owner)
        return "\n".join(store.line(r) for r in found) if found else "No routines yet."

    async def create_routine(title: str, prompt: str, time: str, days: list[int], agent: str = agent,  # noqa: A002
                             watch: bool = False) -> str:
        if not any_agent and agent != owner:
            raise ValueError("you can only make routines for yourself")
        r = store.create(agent, title, prompt, time, days, watch=watch)
        return "Created (its own chat is in the app): " + store.line(r)

    async def update_routine(routine_id: int, title: str | None = None, prompt: str | None = None,
                             time: str | None = None, days: list[int] | None = None,  # noqa: A002
                             enabled: bool | None = None, watch: bool | None = None) -> str:
        store.find(routine_id, owner)
        r = store.update(routine_id, title=title, prompt=prompt, time=time, days=days, enabled=enabled, watch=watch)
        return "Updated: " + store.line(r)

    async def delete_routine(routine_id: int) -> str:
        r = store.find(routine_id)
        store.delete(routine_id)
        return f"Deleted routine: {AGENTS[r['agent']].name} · {r['title']} (its chat stays)"

    async def describe_delete(routine_id: int) -> str:
        r = store.find(routine_id, owner)
        return f"Delete the routine '{r['title']}' ({AGENTS[r['agent']].name}); its chat stays"

    rid = {"routine_id": {"type": "integer"}}
    schedule = {
        "time": {"type": "string", "description": "HH:MM, 24-hour, local time"},
        "days": {"type": "array", "items": {"type": "integer"},
                 "description": "ISO weekdays, 1 = Monday … 7 = Sunday; [] for every day"},
        "watch": {"type": "boolean", "description": "a watch: a check that posts only when something needs the "
                  "user (else it posts every run)"},
    }
    create = {"title": {"type": "string", "description": "short, e.g. Weekly recap"},
              "prompt": {"type": "string", "description": "what to do on each run, written as an instruction"},
              **schedule}
    if any_agent:
        create["agent"] = {"type": "string", "enum": list(AGENTS), "description": "who runs it; default you"}
    whose = "every agent's routines" if any_agent else "your routines"
    return [
        Tool("list_routines", f"List {whose}: id in brackets, title, days, time and the next run.",
             _obj({}, []), list_routines),
        Tool("create_routine", "Set up a routine: a job run on a schedule (weekly pattern of days and a time), "
             "posting in its own chat each time. Runs immediately.",
             _obj(create, ["title", "prompt", "time", "days"]), create_routine),
        Tool("update_routine", "Change a routine: its title, prompt, time, days, watch, or turn it off and on "
             "(enabled). Pass only what changes. Runs immediately.",
             _obj({**rid, "title": {"type": "string"}, "prompt": {"type": "string"}, **schedule,
                   "enabled": {"type": "boolean"}}, ["routine_id"]), update_routine),
        Tool("delete_routine", "Delete a routine (its chat stays). Needs the user's confirmation: it is queued, "
             "and runs only when the user replies !yes.", _obj(rid, ["routine_id"]),
             delete_routine, confirm=True, describe=describe_delete, target_arg="routine_id"),
    ]
