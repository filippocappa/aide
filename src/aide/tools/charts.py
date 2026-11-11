"""draw_chart: a chart under the reply (#67; charts.py checks the spec and works out the numbers)."""

from ..charts import build, describe
from . import Tool, ToolOutput

_NUM = {"type": "number"}
_FORM = {"type": ["string", "number", "array"]}


def chart_tools() -> list[Tool]:
    async def draw_chart(**spec) -> ToolOutput:
        chart = build(spec)
        return ToolOutput(describe(chart), {"type": "charts", "charts": [chart]})

    curve = {"type": "object", "additionalProperties": False, "required": ["label"], "properties": {
        "label": {"type": "string", "description": "short: AD, SRAS, IS, LM, Demand"},
        "fn": {"type": "string", "description": "y as a formula in x: numbers, x, + - * / ^, sqrt, log, exp, min, max"},
        "x": {"type": "number", "description": "a vertical line at this x (LRAS, a quota) instead of fn"},
        "points": {"type": "array", "items": {"type": "array", "items": _NUM}, "description": "[[x, y], …] instead of fn"},
        "shift_to": {**_FORM, "description": "the curve after the change, in the same form as the curve: drawn "
                                             "next to the original, the app animates before → after"},
        "shift_label": {"type": "string", "description": "the shifted curve's label (default the label with ′)"},
        "dashed": {"type": "boolean"}}}
    point = {"type": "object", "additionalProperties": False, "required": ["label"], "properties": {
        "label": {"type": "string", "description": "E₀, E₁, A"},
        "at": {"type": "array", "items": {"type": "string"}, "description": "two curve labels: the point is where "
               "they meet, worked out here (prefer it to x and y for an equilibrium)"},
        "after": {"type": "boolean", "description": "with at: where the shifted curves meet"},
        "x": _NUM, "y": _NUM}}
    area = {"type": "object", "additionalProperties": False, "required": ["label"], "properties": {
        "label": {"type": "string", "description": "Consumer surplus, Deadweight loss"},
        "between": {"type": "array", "items": {"type": "string"}, "description": "two curve labels, upper first"},
        "from": _NUM, "to": _NUM, "after": {"type": "boolean"},
        "points": {"type": "array", "items": {"type": "array", "items": _NUM}, "description": "a polygon instead"}}}
    return [Tool(
        "draw_chart",
        "Draw a chart of the user's own case under your reply: curves on two axes (supply and demand, AD-AS, IS-LM, "
        "a cost curve, a function), a shift before → after (shift_to), equilibria where two curves meet (points "
        "with at), shaded areas. Use it when a picture of their case explains better than words or the notes' "
        "fixed figures (\"what happens to AD-AS after a tax cut\"). Pick axes that show the action, numbers that "
        "make the shapes clear (they're illustrative unless the user gave real ones), at most 6 curves. The result "
        "gives the points' numbers; say what the chart means, not what it looks like. Runs immediately.",
        {"type": "object", "additionalProperties": False,
         "required": ["title", "x_label", "y_label", "x_max", "y_max", "curves"],
         "properties": {"title": {"type": "string"}, "caption": {"type": "string", "description": "one line under it"},
                        "x_label": {"type": "string"}, "y_label": {"type": "string"},
                        "x_min": {**_NUM, "description": "default 0"}, "x_max": _NUM,
                        "y_min": {**_NUM, "description": "default 0"}, "y_max": _NUM,
                        "curves": {"type": "array", "items": curve}, "points": {"type": "array", "items": point},
                        "areas": {"type": "array", "items": area}}},
        draw_chart)]
