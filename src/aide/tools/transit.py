"""GTT tools: stops, live arrivals and tram alerts (docs/API.md, "Transit"). Reading and setting alerts run
immediately; deleting an alert waits for the user's !yes."""

import re
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from ..db import utcnow
from ..leave import LeaveWatcher
from ..transit import AlertStore, AlertWatcher, Boards, Location, Transit, line_key
from . import Tool, ToolOutput

STOPS_NEAR = 4  # stops shown for "near me"
TIMES = 3  # arrivals shown per line and direction


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def transit_tools(transit: Transit, alerts: AlertStore, location: Location, boards: Boards,
                  watcher: AlertWatcher | None = None) -> list[Tool]:
    timetable = transit.timetable

    async def here() -> dict:
        fix = await location.fresh()
        if fix is None:
            raise ValueError("the phone hasn't shared its location (Settings → Location in the app): ask the user "
                             "for the stop's number or name")
        return fix

    def label(stop: dict, distance: float | None = None) -> str:
        return f"{stop['name']} (stop {stop['code']}" + (f", {round(distance)} m" if distance is not None else "") + ")"

    def lines_text(stop: dict) -> str:
        return "; ".join(f"{l['vehicle']} {l['name']}" + (f" → {' / '.join(l['headsigns'][:2])}" if l["headsigns"] else "")
                         for l in timetable.lines(stop["id"])) or "no lines"

    def one_stop(stop: str, line: str | None) -> dict:
        """The stop an alert is for: exactly one, or a ValueError listing the choices."""
        found = timetable.find(stop)
        if line:
            key = line_key(line)
            found = [s for s in found if any(l["name"] == key for l in timetable.lines(s["id"]))]
        if not found:
            raise ValueError(f"no GTT stop matches {stop!r}" + (f" with line {line_key(line)}" if line else ""))
        if len(found) > 1:
            options = "\n".join(f"- {label(s)}: {lines_text(s)}" for s in found[:12])
            raise ValueError(f"{len(found)} stops match; ask the user which one (the direction tells them apart), then "
                             f"pass its number:\n{options}")
        return found[0]

    async def transit_stops(query: str | None = None) -> str:
        if query and query.strip():
            found = [(s, None) for s in timetable.find(query)]
            where = f"matching {query.strip()!r}"
        else:
            fix = await here()
            found = timetable.near(fix["lat"], fix["lon"])
            where = "near the phone"
        if not found:
            return f"No GTT stops {where}."
        return f"GTT stops {where}:\n" + "\n".join(f"- {label(s, d)}: {lines_text(s)}" for s, d in found[:12])

    def when(a, now) -> str:
        text = f"{a.minutes(now)} min"
        if not a.live:
            return text + " (timetable)"
        late = round((a.delay or 0) / 60)
        return text + (f" ({late} late)" if late > 0 else f" ({-late} early)" if late < 0 else "")

    async def transit_arrivals(stop: str | None = None, line: str | None = None, to: str | None = None) -> ToolOutput:
        now = utcnow()
        if stop and stop.strip():
            stops = [(s, None) for s in timetable.find(stop)][:6]
            if not stops:
                raise ValueError(f"no GTT stop matches {stop!r}")
        else:
            fix = await here()
            stops = timetable.near(fix["lat"], fix["lon"])
            if line:
                key = line_key(line)
                stops = [(s, d) for s, d in stops if any(l["name"] == key for l in timetable.lines(s["id"]))]
            stops = stops[:STOPS_NEAR]
            if not stops:
                return ToolOutput("No GTT stops near the phone" + (f" for line {line_key(line)}." if line else "."))
        dest = await boards.destination(to) if to and to.strip() else None
        arrivals = await transit.arrivals([s["id"] for s, _ in stops], line, now, to=dest["stops"] if dest else None)
        out, cards = [], []
        for s, d in stops:
            groups: dict[tuple, list] = {}
            for a in arrivals:
                if a.stop == s["id"]:
                    groups.setdefault((a.name(), a.headsign), []).append(a)
            if not groups:
                out.append(f"{label(s, d)}: nothing in the next hour" + (f" for line {line_key(line)}" if line else "")
                           + (f" going to {dest['name']}" if dest else ""))
                continue
            rows = []
            for (name, towards), times in groups.items():
                row = f"- {name}" + (f" → {towards}" if towards else "") + ": " + \
                      ", ".join(when(a, now) for a in times[:TIMES])
                if dest and times[0].to_at:
                    row += f"; the first gets to {dest['name']} at {times[0].to_at.astimezone(timetable.tz):%H:%M}"
                rows.append(row)
            out.append(f"{label(s, d)}:\n" + "\n".join(rows))
            cards.append(await boards.board(s, line, dest, now, arrivals))
        if dest and not cards:
            out.append(f"No direct line to {dest['name']} in the next hour: the user may need to change.")
        text = "\n".join(out) + "\nMinutes are live from GTT unless marked (timetable). The app shows these as cards."
        return ToolOutput(text, {"type": "departures", "departures": cards} if cards else None)

    async def list_transit_alerts() -> str:
        found = alerts.all()
        return "\n".join(f"[{a['id']}] {alerts.describe(a)}" for a in found) if found else "No tram alerts."

    async def add_transit_alert(stop: str, line: str, time: str | None = None, days: list[int] | None = None,  # noqa: A002
                                minutes: int | None = None, right_away: bool | None = None) -> str:
        before = {x["id"] for x in alerts.all()}
        a = alerts.create(one_stop(stop, line)["id"], line, time, days, minutes, right_away=bool(right_away))
        out = f"{'Already set, kept' if a['id'] in before else 'Set'} [{a['id']}]: {alerts.describe(a)}."
        if watcher and watcher.followed(a["stop"], a["line"]):
            out += " Its countdown is already on the phone's Lock Screen: that one goes on, no second one."
        elif a["right_away"]:
            out += " The countdown appears on the phone within about 30 seconds."
        return out

    async def update_transit_alert(alert_id: int, stop: str | None = None, line: str | None = None,
                                   time: str | None = None, days: list[int] | None = None,  # noqa: A002
                                   minutes: int | None = None, enabled: bool | None = None) -> str:
        current = alerts.get(alert_id)
        stop_id = one_stop(stop, line or current["line"])["id"] if stop else None
        a = alerts.update(alert_id, stop=stop_id, line=line_key(line) if line else None, time=time, days=days,
                          minutes=minutes, enabled=enabled)
        return f"Updated [{a['id']}]: {alerts.describe(a)}."

    async def delete_transit_alert(alert_id: int) -> str:
        a = alerts.get(alert_id)
        alerts.delete(alert_id)
        return f"Deleted the tram alert: {alerts.describe(a)}"

    async def describe_delete(alert_id: int) -> str:
        return f"Delete the tram alert: {alerts.describe(alerts.get(alert_id))}"

    stop_help = "the number on the stop's sign (best: each side of the road has its own) or its name"
    timing = {
        "time": {"type": "string", "description": "HH:MM local: the tram to catch is the first from about then. "
                 "Leave out for the next one"},
        "days": {"type": "array", "items": {"type": "integer"},
                 "description": "repeat on these ISO weekdays (1 = Monday … 7 = Sunday; [] every day): a commute, "
                 "needs time. Leave out for a one-off"},
        "minutes": {"type": "integer", "description": "alert when the tram is this many minutes from the stop. Leave "
                    "out to alert when it's time to leave: the walk from where the phone is, plus 2 minutes"},
    }
    aid = {"alert_id": {"type": "integer"}}
    return [
        Tool("transit_stops", "Find GTT stops (Turin's buses, trams and metro) by number or name, or near where the "
             "user's phone is now (leave query out). Lists each stop's number, name and lines with directions.",
             _obj({"query": {"type": "string", "description": stop_help}}, []), transit_stops),
        Tool("transit_arrivals", "When the next GTT trams, buses and metro come to a stop, in minutes, live from GTT "
             "(else the timetable), how late, and with `to` which go there directly and when they arrive. Leave stop "
             "out for the stops near the user's phone. The app shows the result as departure cards.",
             _obj({"stop": {"type": "string", "description": stop_help},
                   "line": {"type": "string", "description": "only this line, e.g. 4, 15, M1"},
                   "to": {"type": "string", "description": "where the user is going: a GTT stop's name or number, or "
                          "a place in Turin (\"Politecnico\", \"Piazza della Repubblica\", an address; from memory for "
                          "their usual places). Only lines that get there without a change are kept"}}, []),
             transit_arrivals),
        Tool("list_transit_alerts", "List the tram alerts: id in brackets, line, stop, when, and how early.",
             _obj({}, []), list_transit_alerts),
        Tool("add_transit_alert", "Set a tram alert: when the user's GTT tram or bus is coming (\"your 4 is 9 min "
             "away, leave now\"), the phone shows a Live Activity: a live countdown on the Lock Screen and in the "
             "Dynamic Island, with where the tram is, when to leave, and the ride once they're on (a plain push if "
             "Live Activities are off). A one-off (the next one, or one around a time) or a commute (days and a time, "
             "every week). \"Start the live activity\" or \"follow my tram\" means a one-off with right_away. "
             "Runs immediately.",
             _obj({"stop": {"type": "string", "description": stop_help},
                   "line": {"type": "string", "description": "e.g. 4, 15, M1"}, **timing,
                   "right_away": {"type": "boolean", "description": "one-offs: start the countdown now for the next "
                                  "tram the user can make, instead of when it's time to leave"}},
                  ["stop", "line"]), add_transit_alert),
        Tool("update_transit_alert", "Change a tram alert: stop, line, time, days, minutes (0: back to when it's time "
             "to leave), or turn it off and on (enabled). Pass only what changes. Runs immediately.",
             _obj({**aid, "stop": {"type": "string", "description": stop_help}, "line": {"type": "string"},
                   **timing, "enabled": {"type": "boolean"}}, ["alert_id"]), update_transit_alert),
        Tool("delete_transit_alert", "Delete a tram alert. Needs the user's confirmation: it is queued, and runs only "
             "when the user replies !yes.", _obj(aid, ["alert_id"]), delete_transit_alert, confirm=True,
             describe=describe_delete, target_arg="alert_id"),
    ]


def leave_tools(leave: LeaveWatcher, tz: ZoneInfo) -> list[Tool]:
    """leave_for: "I need to be at uni at 9:30, what do I take?", answered and set up as leave-now for an event."""

    def by(value: str, now: datetime) -> datetime:
        value = value.strip()
        if re.fullmatch(r"\d{1,2}:\d{2}", value):
            h, m = map(int, value.split(":"))
            at = now.astimezone(tz).replace(hour=h, minute=m, second=0, microsecond=0)
            return at if at > now else at + timedelta(days=1)  # 9:30 asked at 22:00 is tomorrow's
        at = datetime.fromisoformat(value)
        return at if at.tzinfo else at.replace(tzinfo=tz)

    def clock(at: datetime) -> str:
        local = at.astimezone(tz)
        return f"{local:%H:%M}" if local.date() == datetime.now(tz).date() else f"{local:%a %d %b %H:%M}"

    def rides(route: dict) -> list[str]:
        out = []
        for t in (s["transitDetails"] for leg in route.get("legs", []) for s in leg.get("steps", [])
                  if s.get("transitDetails")):
            stops, tl = t.get("stopDetails", {}), t.get("transitLine", {})
            vehicle = tl.get("vehicle", {}).get("name", {}).get("text", "")
            name = f"{vehicle + ' ' if vehicle else ''}{tl.get('nameShort') or tl.get('name') or '?'}"
            times = [datetime.fromisoformat(stops[k].replace("Z", "+00:00")) if stops.get(k) else None
                     for k in ("departureTime", "arrivalTime")]
            out.append(f"{name}{' towards ' + t['headsign'] if t.get('headsign') else ''}: "
                       f"{clock(times[0]) if times[0] else '?'} from {stops.get('departureStop', {}).get('name', '?')}, "
                       f"{clock(times[1]) if times[1] else '?'} at {stops.get('arrivalStop', {}).get('name', '?')}")
        return out

    async def leave_for(destination: str, arrive_by: str) -> str:
        now = utcnow()
        arrive = by(arrive_by, now)
        if arrive - now > timedelta(days=2):
            raise ValueError("only for the next two days: plan further ahead with travel_time")
        t = await leave.trip(destination, arrive, now)
        if t["there"]:
            return f"The user is already at {destination} (or within a few minutes' walk): no tram needed."
        out = []
        if t["late"]:
            out.append(f"Too late to be there by {clock(arrive)} on transit; the first way from now:")
        out.append(f"Leave {'where the user is' if t['from'] == 'here' else 'home'} by {clock(t['leave'])}: "
                   f"{max(1, round(t['walk'] / 60))} min walk to {t['stop']['name']} (stop {t['stop']['code']}), "
                   f"there 2 min before line {t['line']} at {clock(t['departs'])}.")
        out += [f"- {r}" for r in rides(t["route"])]
        if t["alert"]:
            out.append(f"Tram alert [{t['alert']['id']}] set: about 3 min before it's time to leave, the phone shows "
                       "the countdown (Lock Screen and Dynamic Island) with the tram's live position, or a push; it "
                       "follows the live times, so a late tram moves it. Deleting it in the app (or "
                       "delete_transit_alert) stops it.")
        elif t["covered"]:
            out.append("The user's own tram alert for that line already covers it: no new one.")
        return "\n".join(out)

    return [
        Tool("leave_for", "The user needs to be somewhere by a time and asks what to take or when to leave (\"I need "
             "to be at uni at 9:30\"). Finds the GTT way there from where their phone is (else home), on the line "
             "memory says they prefer if it fits, leaving as late as still gets them there, and sets a one-off tram "
             "alert for its first ride: when it's time to leave the phone shows the tram's live countdown. Use it "
             "instead of travel_time plus add_transit_alert. Runs immediately.",
             {"type": "object", "properties": {
                 "destination": {"type": "string", "description": "the place's real name or address (from memory for "
                                 "\"uni\", \"the gym\"), not a nickname"},
                 "arrive_by": {"type": "string", "description": "HH:MM (the next one: tomorrow's if today's has gone) or "
                               "YYYY-MM-DDTHH:MM, local"}},
              "required": ["destination", "arrive_by"], "additionalProperties": False}, leave_for),
    ]
