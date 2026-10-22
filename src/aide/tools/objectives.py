"""Objective tools (docs/API.md, "Objectives"). They run immediately: objectives are the user's own plan, and the
user's word in chat is the OK.

Each agent gets its own set, like routines: Aide works with every specialist's objectives (and names the specialist
when adding one), the others only their own.
"""

from ..agents import SPECIALISTS
from ..objectives import MEASURES, PERIODS, ObjectivePlanner, ObjectiveStore
from . import Tool


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def objective_tools(store: ObjectiveStore, planner: ObjectivePlanner | None, agent: str,
                    any_agent: bool = False) -> list[Tool]:
    owner = None if any_agent else agent
    mine = None if any_agent else [agent]

    def listing(period: str) -> list[str]:
        found = store.objectives(period, store.today(), mine)
        return [store.line(o) for o in found]

    async def list_objectives(period: str | None = None) -> str:
        out = []
        for p in [period] if period else PERIODS:
            lines = listing(p)
            out.append(f"{p.capitalize()}: " + ("\n" + "\n".join(lines) if lines else "none"))
        return "\n".join(out)

    async def add_objective(period: str, title: str, why: str = "", track: str | None = None,
                            habit_id: int | None = None, course_id: int | None = None, min_score: float | None = None,
                            food: str | None = None, hours: float | None = None, steps: int | None = None,
                            reminder_id: str | None = None, target: int | None = None, agent: str = agent) -> str:
        if not any_agent and agent != owner:
            raise ValueError("you can only add objectives of your own")
        if agent not in SPECIALISTS:
            raise ValueError("objectives belong to a specialist: pass agent")
        measure = None
        if track:
            measure = {"type": track, "habit": habit_id, "course": course_id, "score": min_score, "metric": food,
                       "hours": hours, "steps": steps, "reminder": reminder_id}
        o = store.add(agent, period, store.today(), title, why, measure, target)
        return "Added: " + store.line(o)

    async def update_objective(objective_id: str, title: str | None = None, done: bool | None = None,
                               drop: bool | None = None, target: int | None = None) -> str:
        store.find(objective_id, owner)
        o = store.update(objective_id, title=title, done=done, target=target,
                         status=None if drop is None else "dropped" if drop else "active")
        return "Updated: " + store.line(o)

    async def accept_objectives(period: str, objective_ids: list[str] | None = None) -> str:
        taken = store.accept(period, store.today(), objective_ids, owner)
        return ("Accepted:\n" + "\n".join(store.line(o) for o in taken)) if taken else "Nothing was waiting for an OK."

    async def plan_objectives(period: str) -> str:
        if planner is None:
            return "Objectives can't be planned on this server."
        made = await planner.plan(period, store.today(), mine)
        if not made:
            return "Nothing to propose for now."
        return ("Proposed (they wait for the user's OK; accept_objectives once they agree):\n"
                + "\n".join(store.line(o) for o in made))

    period = {"type": "string", "enum": list(PERIODS)}
    oid = {"objective_id": {"type": "string", "description": "the id in brackets, o_…"}}
    add = {
        "period": period,
        "title": {"type": "string", "description": "short, in the imperative: Run 3 times"},
        "why": {"type": "string"},
        "track": {"type": "string", "enum": list(MEASURES), "description":
                  "what ticks it by itself: habit (habit_id: check-ins), practice (course_id, min_score: practice "
                  "exams), food (food: days logged or at a goal), sleep (hours: nights at or over), steps (steps: days "
                  "at or over), reminder (reminder_id: done). Leave out: the user ticks it"},
        "habit_id": {"type": "integer"}, "course_id": {"type": "integer"},
        "min_score": {"type": "number", "description": "percent"},
        "food": {"type": "string", "enum": ["logged", "protein_g", "calories"]},
        "hours": {"type": "number"}, "steps": {"type": "integer"}, "reminder_id": {"type": "string"},
        "target": {"type": "integer", "description": "how many (times, days, exams) in the period; default 1"},
    }
    if any_agent:
        add["agent"] = {"type": "string", "enum": list(SPECIALISTS), "description": "whose objective it is"}
    whose = "every specialist's" if any_agent else "your"
    return [
        Tool("list_objectives", f"List {whose} objectives for today, this week and this month (or one period): id in "
             "brackets, progress, done, and whether it's still a proposal waiting for the user's OK.",
             _obj({"period": period}, []), list_objectives),
        Tool("add_objective", "Add an objective the user asked for, for today, this week or this month. It starts "
             "accepted. Tie it to a measure (track) when one fits, so it ticks itself.",
             _obj(add, ["period", "title", *(["agent"] if any_agent else [])]), add_objective),
        Tool("update_objective", "Change an objective: its title or target, tick it done (or not), or drop it "
             "(drop false takes it back). Ticking a proposal also accepts it.",
             _obj({**oid, "title": {"type": "string"}, "done": {"type": "boolean"}, "drop": {"type": "boolean"},
                   "target": {"type": "integer"}}, ["objective_id"]), update_objective),
        Tool("accept_objectives", f"The user OKs {whose} proposed objectives for a period: all of them, or only "
             "objective_ids.", _obj({"period": period, "objective_ids": {"type": "array", "items": {"type": "string"}}},
                                   ["period"]), accept_objectives),
        Tool("plan_objectives", f"Propose {whose} objectives for today, this week or this month now, from the "
             "calendar, habits, courses and the rest (replacing proposals still waiting). Use when the user asks for "
             "a plan; they're proposed every morning, week and month anyway.",
             _obj({"period": period}, ["period"]), plan_objectives),
    ]
