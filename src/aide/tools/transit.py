"""GTT tools: stops, live arrivals and tram alerts (docs/API.md, "Transit"). Reading and setting alerts run
immediately; deleting an alert waits for the user's !yes."""

from ..db import utcnow
from ..transit import AlertStore, Location, Transit, line_key
from . import Tool

STOPS_NEAR = 4  # stops shown for "near me"
TIMES = 3  # arrivals shown per line and direction


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def transit_tools(transit: Transit, alerts: AlertStore, location: Location) -> list[Tool]:
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

    async def transit_arrivals(stop: str | None = None, line: str | None = None) -> str:
        now = utcnow()
        if stop and stop.strip():
            stops = [(s, None) for s in timetable.find(stop)][:6]
            if not stops:
                return f"No GTT stop matches {stop!r}."
        else:
            fix = await here()
            stops = timetable.near(fix["lat"], fix["lon"])
            if line:
                key = line_key(line)
                stops = [(s, d) for s, d in stops if any(l["name"] == key for l in timetable.lines(s["id"]))]
            stops = stops[:STOPS_NEAR]
            if not stops:
                return "No GTT stops near the phone" + (f" for line {line_key(line)}." if line else ".")
        arrivals = await transit.arrivals([s["id"] for s, _ in stops], line, now)
        out = []
        for s, d in stops:
            groups: dict[tuple, list] = {}
            for a in arrivals:
                if a.stop == s["id"]:
                    groups.setdefault((a.name(), a.headsign), []).append(a)
            if not groups:
                out.append(f"{label(s, d)}: nothing in the next hour" + (f" for line {line_key(line)}" if line else ""))
                continue
            rows = [f"- {name}" + (f" → {towards}" if towards else "") + ": " +
                    ", ".join(f"{a.minutes(now)} min" + ("" if a.live else " (timetable)") for a in times[:TIMES])
                    for (name, towards), times in groups.items()]
            out.append(f"{label(s, d)}:\n" + "\n".join(rows))
        return "\n".join(out) + "\nMinutes are live from GTT unless marked (timetable)."

    async def list_transit_alerts() -> str:
        found = alerts.all()
        return "\n".join(f"[{a['id']}] {alerts.describe(a)}" for a in found) if found else "No tram alerts."

    async def add_transit_alert(stop: str, line: str, time: str | None = None, days: list[int] | None = None,  # noqa: A002
                                minutes: int | None = None) -> str:
        a = alerts.create(one_stop(stop, line)["id"], line, time, days, minutes)
        return f"Set [{a['id']}]: {alerts.describe(a)}."

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
             "(else the timetable). Leave stop out for the stops near the user's phone.",
             _obj({"stop": {"type": "string", "description": stop_help},
                   "line": {"type": "string", "description": "only this line, e.g. 4, 15, M1"}}, []),
             transit_arrivals),
        Tool("list_transit_alerts", "List the tram alerts: id in brackets, line, stop, when, and how early.",
             _obj({}, []), list_transit_alerts),
        Tool("add_transit_alert", "Set a tram alert: a push on the user's phone when their GTT tram or bus is coming "
             "(\"your 4 is 9 min away, leave now\"), live. A one-off (the next one, or one around a time) or a "
             "commute (days and a time, every week). Runs immediately.",
             _obj({"stop": {"type": "string", "description": stop_help},
                   "line": {"type": "string", "description": "e.g. 4, 15, M1"}, **timing},
                  ["stop", "line"]), add_transit_alert),
        Tool("update_transit_alert", "Change a tram alert: stop, line, time, days, minutes (0: back to when it's time "
             "to leave), or turn it off and on (enabled). Pass only what changes. Runs immediately.",
             _obj({**aid, "stop": {"type": "string", "description": stop_help}, "line": {"type": "string"},
                   **timing, "enabled": {"type": "boolean"}}, ["alert_id"]), update_transit_alert),
        Tool("delete_transit_alert", "Delete a tram alert. Needs the user's confirmation: it is queued, and runs only "
             "when the user replies !yes.", _obj(aid, ["alert_id"]), delete_transit_alert, confirm=True,
             describe=describe_delete, target_arg="alert_id"),
    ]
