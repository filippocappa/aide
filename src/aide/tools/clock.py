"""Current date and time. Kept as a tool so the system prompt stays byte-stable for caching."""

from datetime import datetime
from zoneinfo import ZoneInfo

from . import Tool


def clock_tool(tz: ZoneInfo) -> Tool:
    async def get_current_time() -> str:
        now = datetime.now(tz)
        return f"{now:%A %d %B %Y, %H:%M} ({tz.key}, UTC{now:%z})"

    return Tool(
        name="get_current_time",
        description="Get the user's current local date, weekday and time. Call this before "
        "interpreting relative dates such as 'tomorrow' or 'next Friday'.",
        input_schema={"type": "object", "properties": {}, "required": [], "additionalProperties": False},
        handler=get_current_time,
    )
