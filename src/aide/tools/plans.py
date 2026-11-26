"""propose_events: several calendar events proposed together (plans.py). They show in the chat as an events card
marked Proposed, and go in the calendar only when the user taps Add there."""

import asyncio
from collections.abc import Callable

from ..notebook import NotebookStore
from ..plans import PlanStore
from ..study import SESSION_NOTES, SESSION_PREFIXES, StudyStore
from . import Tool, ToolOutput

TIME_HELP = "Local time as YYYY-MM-DDTHH:MM, or YYYY-MM-DD for an all-day event (then end is the last day)."


def plan_tools(plans: PlanStore, study: StudyStore | None, notebook: NotebookStore | None,
               where: Callable[[], tuple[str | None, str]]) -> list[Tool]:
    """`where()` is the chat of the turn in progress and the agent proposing."""

    async def propose_events(events: list[dict]) -> str:
        names = await asyncio.to_thread(plans.cal.calendars)
        items = []
        for e in events:
            item = {k: e[k] for k in ("title", "start", "end") if k in e}
            item |= {k: e[k] for k in ("location", "notes") if e.get(k)}
            if e.get("course"):
                if study is None or notebook is None:
                    raise ValueError("there are no courses on this server")
                await study.courses()
                course = study.course_by_name(e["course"])
                if course is None:
                    raise ValueError(f"no course called {e['course']!r}; list_courses has their names")
                topics = [notebook.find_topic(t, course["id"])["title"] for t in e.get("topics") or []]
                name = course["name"][:1].upper() + course["name"][1:]
                if len(e["start"]) == 10:
                    raise ValueError("a review session has a start time, not just a day")
                kind = e.get("kind") or "review"
                item |= {"title": SESSION_PREFIXES[kind] + name, "calendar": study.study_calendar,
                         "course_id": course["id"], "kind": kind, "topics": topics, "notes": SESSION_NOTES[kind]
                         + ("\nTopics: " + "; ".join(topics) if topics else "")}
            else:
                if not e.get("calendar"):
                    raise ValueError(f"{e['title']}: give its calendar (list_calendars)")
                if e["calendar"] not in names:
                    raise ValueError(f"no calendar named {e['calendar']!r}; see list_calendars")
                item["calendar"] = e["calendar"]
            items.append(item)
        conversation, agent = where()
        plan = plans.propose(conversation, agent, items)
        lines = "\n".join(f"- {plans.line(i)}" for i in plan["items"])
        return ToolOutput(f"Proposed {len(items)} event(s) as plan {plan['public_id']}. They're not in the calendar "
                          f"yet: the user adds them (all, or some) with a tap on the card under your reply.\n{lines}",
                          {"type": "events", "events": plans.card_items(plan)})

    item = {"type": "object", "additionalProperties": False, "required": ["title", "start", "end"], "properties": {
        "title": {"type": "string", "description": "Ignored for a study session (it's \"Study: <course>\", \"Practice: …\" or \"Review: …\")"},
        "start": {"type": "string", "description": TIME_HELP},
        "end": {"type": "string", "description": TIME_HELP},
        "calendar": {"type": "string", "description": "Exact name from list_calendars; not for a review session"},
        "location": {"type": "string"},
        "notes": {"type": "string"},
        "course": {"type": "string", "description": "For a study session: the course's name. Professor follows "
                   "it and, when it starts, offers the lesson (study) or a quiz (practice, review)."},
        "kind": {"type": "string", "enum": list(SESSION_PREFIXES), "description": "A study session's kind: study "
                 "to learn topics the user doesn't know yet (the exam plan's learn phase), practice for questions "
                 "on ones learnt, review to go back over them near the exam. Default review."},
        "topics": {"type": "array", "items": {"type": "string"},
                   "description": "A study session's topic titles or ids"}}}
    return [Tool("propose_events", "Propose several calendar events at once (a study plan, a week's sessions) for "
                 "the user to add with a tap. Nothing goes in the calendar until they do; the card under your reply "
                 "shows them on a week view, marked Proposed. An item with a course is a study session (its kind).",
                 {"type": "object", "additionalProperties": False, "required": ["events"],
                  "properties": {"events": {"type": "array", "items": item}}}, propose_events)]
