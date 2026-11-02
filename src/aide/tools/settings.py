"""Aide's settings tools: every server-side setting the app's Settings pages change, read and changed from chat.
A change runs at once (it's the user asking, and each is undone the same way); it goes in the Activity feed like any
other write. The settings that live only on the phone get a button to their page instead."""

from typing import Callable

from ..digest import ALL_KINDS
from ..engine import ENGINES
from . import Tool, ToolOutput
from .pages import open_card

DIGEST_NAMES = {"daily": "Morning digest", "wake": "Wake-up briefing", "evening": "Evening digest",
                "weekly": "Weekly digest", "monthly": "Monthly digest"}
WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
# Kept on the phone (its keychain), so only its page can change them: key -> (what, page title, link).
PHONE = {
    "voice.language": ("the voice chat's language", "Voice", "aide://settings/voice"),
    "voice.speak_replies": ("whether replies are read out", "Voice", "aide://settings/voice"),
    "study.practice_answers": ("when a practice exam shows the answers", "Settings", "aide://settings"),
    "reminders.default_list": ("the Apple Reminders list new reminders go in", "Reminders",
                               "aide://settings/reminders"),
    "connection": ("the server address and token", "Settings", "aide://settings"),
    "permissions": ("what iOS lets Aide use (notifications, Health, location, Screen Time)", "Settings",
                    "aide://settings"),
}


def _bool(value: str) -> bool:
    v = str(value).strip().lower()
    if v in ("on", "true", "yes", "1", "enabled"):
        return True
    if v in ("off", "false", "no", "0", "disabled"):
        return False
    raise ValueError(f"{value!r} isn't on or off")


def settings_tools(digest: Callable, live, leave: Callable, engine) -> list[Tool]:
    """`digest` and `leave` are getters: those services are made after the tools (leave may be None)."""

    def current() -> dict[str, tuple[str, str]]:
        """key -> (value, what it is)."""
        out: dict[str, tuple[str, str]] = {}
        if (d := digest()) is not None:
            for kind, cfg in d.settings().items():
                name = DIGEST_NAMES[kind]
                out[f"digest.{kind}.enabled"] = ("on" if cfg["enabled"] else "off", name)
                if "time" in cfg:
                    out[f"digest.{kind}.time"] = (cfg["time"], f"{name}: when")
                if "weekday" in cfg:
                    out[f"digest.{kind}.weekday"] = (WEEKDAYS[cfg["weekday"] - 1], f"{name}: which day")
                if "day" in cfg:
                    out[f"digest.{kind}.day"] = (str(cfg["day"]), f"{name}: day of the month")
        s = live.settings()
        out["live.events"] = ("on" if s["events"] else "off", "Live Activity counting down to the next event")
        out["live.locks"] = ("on" if s["locks"] else "off", "Live Activity while a Screen Time lock holds")
        if (lv := leave()) is not None:
            out["leave.calendar"] = ("on" if lv.settings()["calendar"] else "off",
                                     "tram alerts to leave for calendar events")
        out["writer.engine"] = (engine.engine, "who writes study notes: claude (the Claude plan) or openrouter")
        out["background.engine"] = (engine.background, "who does background work (routines, watches, digests, "
                                    "drafts): claude or openrouter")
        return out

    def listing() -> str:
        lines = [f"{k} = {v} ({what})" for k, (v, what) in current().items()]
        lines.append("On the phone only (its page): " + ", ".join(PHONE))
        return "\n".join(lines)

    async def settings() -> str:
        return listing()

    async def change_setting(key: str, value: str) -> str:
        if key in PHONE:
            what, title, url = PHONE[key]
            return ToolOutput(f"{what.capitalize()} is kept on the phone, so it's changed there: the button under "
                              "your reply opens the page.", open_card(title, f"Change {what}", url))
        have = current()
        if key not in have:
            raise ValueError(f"no setting {key!r}. The settings: {', '.join([*have, *PHONE])}")
        value = str(value).strip()
        group, *rest = key.split(".")
        if group == "digest":
            kind, field = rest
            d = digest()
            s = d.settings()
            cfg = dict(s[kind])
            if field == "enabled":
                cfg["enabled"] = _bool(value)
            elif field == "time":
                cfg["time"] = value if len(value) == 5 else value.zfill(5)
            elif field == "weekday":
                names = [w.lower() for w in WEEKDAYS]
                v = value.lower()
                day = next((i + 1 for i, w in enumerate(names) if w.startswith(v[:3])), None) if not v.isdigit() \
                    else int(v)
                if day is None:
                    raise ValueError(f"{value!r} isn't a weekday")
                cfg["weekday"] = day
            elif field == "day":
                cfg["day"] = int(value)
            d.save_settings({**s, kind: cfg})
        elif group == "live":
            live.update_settings(**{rest[0]: _bool(value)})
        elif group == "leave":
            leave().update_settings(calendar=_bool(value))
        elif group in ("writer", "background"):
            if value not in ENGINES:
                raise ValueError(f"{key} is one of {', '.join(ENGINES)}")
            if value == "claude" and not engine.available:
                raise ValueError("Claude Code isn't installed on the server, so the plan can't be used")
            (engine.set_engine if group == "writer" else engine.set_background)(value)
        new, what = current()[key]
        return f"{what}: {have[key][0]} → {new}"

    async def run_digest(kind: str = "daily") -> str:
        body = await digest().generate(kind)
        return ToolOutput(f"Written: {DIGEST_NAMES[kind]}. Its greeting: {body['greeting']}\nIt's on Today (the "
                          "button opens it).", open_card("Today", DIGEST_NAMES[kind], "aide://today"))

    return [
        Tool("settings", "Aide's settings with their values, as key = value (what it is): the digests' schedule, the "
             "Live Activities, tram alerts for events, who writes notes and does background work; and which are "
             "kept on the phone.", {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
             settings),
        Tool("change_setting", "Change one setting when the user asks: a key from settings, and the value (on/off, "
             "HH:MM, a weekday, a day of the month, claude/openrouter). Runs immediately. For a setting kept on the "
             "phone it puts a button to its page under your reply instead.",
             {"type": "object", "additionalProperties": False, "required": ["key", "value"], "properties": {
                 "key": {"type": "string", "description": "e.g. digest.evening.time, live.events, writer.engine"},
                 "value": {"type": "string"}}}, change_setting),
        Tool("run_digest", "Write a digest now (the wake-up briefing, the evening one…) when the user asks for it "
             "again or fresh; it's shown on Today. Takes a little while.",
             {"type": "object", "additionalProperties": False, "required": ["kind"], "properties": {
                 "kind": {"type": "string", "enum": list(ALL_KINDS)}}}, run_digest),
    ]
