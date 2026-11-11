"""Esse3 exam sign-ups for Professor: the sessions Esse3 lists with where each sign-up stands, and signing up or
cancelling, both queued: they run only when the user confirms, as the app's Sign me up (an errand in Aide's browser,
the result coming later by push and on the exam's sheet)."""

from collections.abc import Callable
from datetime import date

from ..esse3 import Esse3Reader, SignUpFailed, _id
from . import Tool, ToolOutput
from .pages import open_card


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def _day(iso: str | None) -> str:
    return f"{date.fromisoformat(iso):%a %d %b}" if iso else "?"


def esse3_tools(esse3: Esse3Reader, chat: Callable[[], str | None] = lambda: None) -> list[Tool]:
    """`chat`: the chat the tool runs for, where the errand's card and result are posted."""
    def session(date_id: str) -> tuple[dict, dict]:
        e = esse3.exam_for(date_id)
        if e is None:
            raise ValueError(f"No Esse3 session {date_id!r}: exam_signups lists them, each id in brackets.")
        return e, esse3.signup(date_id)

    def name(e: dict) -> str:
        return esse3._name(e) + (f" ({e['code']})" if e.get("code") else "")

    def state(s: dict) -> str:
        if s["busy"]:
            return f"Aide is {s['busy']} on Esse3 now" + (f" ({s['step']})" if s["step"] else "")
        if s.get("instead"):
            return (f"the user isn't taking this sitting: they're on the {_day(s['instead'])} one instead (don't "
                    "suggest signing up for this one)")
        out = {"booked": "signed up" + ("" if s["can_cancel"] else ", too late to cancel"),
               "open": f"sign-up open until {_day(s['closes'])}",
               "soon": f"sign-up opens {_day(s['opens'])}, closes {_day(s['closes'])}",
               "closed": "sign-up closed"}[s["state"]]
        if s["auto"] and s["state"] != "booked":
            out += "; queued: Aide signs the user up the moment it opens" + (
                f" ({_day(s['opens'])})" if s["state"] == "soon" else "")
        if s["errand_id"] and s["step"]:
            out += f"; waiting for the user: {s['step']}"
        if s["error"]:
            out += f"; last try failed: {s['error']}"
        return out

    async def exam_signups(course: str | None = None) -> str:
        today = esse3._today()
        want = (course or "").casefold()
        lines = []
        for e in esse3.exams():
            if e["day"] < today or (want and want not in e["course"].casefold() and want not in name(e).casefold()):
                continue
            s = esse3.signup(_id("exam", e))
            lines.append(f"[{_id('exam', e)}] {name(e)}, exam {_day(e['day'])} {e['day'][:4]}"
                         + (f" {e['time']}" if e["time"] else "") + f": {state(s)}")
        if not lines:
            status = esse3.status()
            if not status["connected"]:
                return "Esse3 isn't connected: the UniTo login goes in Settings → Passwords in the app."
            return "Esse3 lists no coming exam sessions" + (f" for {course!r}" if course else "") + "."
        return "\n".join(lines)

    async def describe_sign_up(date_id: str) -> str:
        e, s = session(date_id)
        if s["state"] == "booked":
            raise ValueError(f"The user is already signed up for {name(e)} on {_day(e['day'])}.")
        if s["state"] == "closed":
            raise ValueError(f"The sign-up for {name(e)} on {_day(e['day'])} has closed: nothing to queue.")
        if s["state"] == "soon":
            return (f"Sign up for {name(e)}'s exam on {_day(e['day'])} on Esse3 as soon as the sign-up opens "
                    f"({_day(s['opens'])})")
        return f"Sign up for {name(e)}'s exam on {_day(e['day'])} on Esse3 (open until {_day(s['closes'])})"

    async def sign_up_for_exam(date_id: str) -> ToolOutput:
        e, _ = session(date_id)
        try:
            s = await esse3.sign_up(date_id, chat())
        except SignUpFailed as x:
            return ToolOutput(f"Couldn't start: {x}")
        card = open_card(esse3._name(e), f"Exam {_day(e['day'])}", f"aide://study/{e['course_id']}") \
            if e.get("course_id") else None
        if s["state"] == "booked":
            text = "Already signed up."
        elif s["busy"]:
            text = ("Started: Aide is signing up on Esse3 now, its card in this chat. It takes a minute or two; the "
                    "result is posted here and pushed. Don't say it's done yet.")
        elif s["auto"]:
            text = f"Set: Aide signs the user up when the sign-up opens ({_day(s['opens'])}), with a push."
        else:
            text = state(s)
        return ToolOutput(text, card)

    async def describe_cancel(date_id: str) -> str:
        e, s = session(date_id)
        if s["state"] == "booked":
            if not s["can_cancel"]:
                raise ValueError(f"The sign-up window for {name(e)} on {_day(e['day'])} has closed: Esse3 no longer "
                                 "lets it be cancelled.")
            return f"Cancel the Esse3 sign-up for {name(e)}'s exam on {_day(e['day'])}"
        if s["auto"] or s["busy"]:
            return f"Don't sign up for {name(e)}'s exam on {_day(e['day'])}"
        raise ValueError(f"The user isn't signed up for {name(e)} on {_day(e['day'])}.")

    async def cancel_exam_signup(date_id: str) -> str:
        e, before = session(date_id)
        try:
            s = await esse3.cancel(date_id, chat())
        except SignUpFailed as x:
            return f"Couldn't start: {x}"
        if before["state"] != "booked":
            return "Done: Aide won't sign the user up for it."
        if s["busy"]:
            return ("Started: Aide is cancelling on Esse3 now, its card in this chat. The result is posted here and "
                    "pushed; don't say it's done yet.")
        return state(s)

    did = _obj({"date_id": {"type": "string", "description": "the session's id, in brackets in exam_signups"}},
               ["date_id"])
    return [
        Tool("exam_signups", "The exam sessions Esse3 (UniTo's MyUniTo) lists from today, each with its id in "
             "brackets and where its sign-up stands: signed up, open until, opens on, closed, whether Aide is on it "
             "now or signs up when it opens, and why the last try failed.",
             _obj({"course": {"type": "string", "description": "part of the course's name or code; all when left out"}},
                  []), exam_signups),
        Tool("sign_up_for_exam", "Sign the user up for an exam session on Esse3: now when its sign-up is open, else "
             "as soon as it opens. Only when the user asks. Queued: runs only when the user confirms; then Aide's "
             "browser signs up in a minute or two, and the result comes by push.", did, sign_up_for_exam,
             confirm=True, describe=describe_sign_up, target_arg="date_id"),
        Tool("cancel_exam_signup", "Cancel the user's Esse3 sign-up for an exam session (while its window is open), "
             "or a sign-up Aide was going to make when it opens. Only when the user asks. Queued: runs only when the "
             "user confirms.", did, cancel_exam_signup, confirm=True, describe=describe_cancel,
             target_arg="date_id"),
    ]
