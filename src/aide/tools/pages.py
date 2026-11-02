"""Opening a page of the app from chat: an `open` card (docs/API.md, "Attachments") with a button per page. The user
taps it; the app never jumps on its own. Some things only the phone can do (picking Screen Time apps, permissions,
the camera), so the agents send the user there with one of these."""

from urllib.parse import quote, urlencode

from . import Tool, ToolOutput

# page -> (button title, aide:// link). Course pages take the course id, filled in by open_page.
PAGES = {
    "today": ("Today", "aide://today"),
    "team": ("Your team", "aide://team"),
    "objectives": ("Objectives", "aide://objectives"),
    "health": ("Health", "aide://health"),
    "food": ("Food", "aide://food"),
    "screen": ("Screen time", "aide://screen"),
    "money": ("Money", "aide://money"),
    "banks": ("Banks", "aide://money/banks"),
    "study": ("Study", "aide://study"),
    "course": ("{course}", "aide://study/{id}"),
    "practice_exam": ("Practice exam", "aide://study/{id}/practice"),
    "study_session": ("Study", "aide://study/{id}/quiz"),
    "lesson": ("Lesson", "aide://study/{id}/lesson"),
    "settings": ("Settings", "aide://settings"),
    "settings_digests": ("Digests", "aide://settings/digests"),
    "settings_memory": ("Memory", "aide://settings/memory"),
    "settings_voice": ("Voice", "aide://settings/voice"),
    "settings_claude_plan": ("Claude plan", "aide://settings/plan"),
    "settings_browser": ("Browser", "aide://settings/browser"),
    "settings_nutrition": ("Nutrition targets", "aide://settings/nutrition"),
    "settings_videos": ("Videos", "aide://settings/videos"),
    "settings_notifications": ("Notifications", "aide://settings/notifications"),
    "settings_reminders": ("Reminders", "aide://settings/reminders"),
    "settings_apple_health": ("Apple Health", "aide://settings/health"),
    "settings_location_and_trams": ("Location and trams", "aide://settings/location"),
    "settings_screen_time": ("Screen Time", "aide://settings/screentime"),
    "settings_payments": ("Payments", "aide://settings/payments"),
    "settings_moodle": ("Moodle", "aide://settings/moodle"),
    "settings_obsidian": ("Obsidian", "aide://settings/obsidian"),
}
COURSE_PAGES = ("course", "practice_exam", "study_session", "lesson")


def open_card(title: str, subtitle: str | None, url: str) -> dict:
    """The `open` attachment with one button."""
    return {"type": "open", "open": [{"id": url, "title": title, "subtitle": subtitle or None, "url": url}]}


def page_tools(study=None, notebook=None) -> list[Tool]:
    async def open_page(page: str, course: str | None = None, topic: str | None = None,
                        note: str | None = None) -> str:
        if page not in PAGES:
            raise ValueError(f"no page {page!r}")
        title, url = PAGES[page]
        subtitle = note
        if page in COURSE_PAGES:
            if study is None or not course:
                raise ValueError(f"{page} needs the course (list_courses has their names)")
            await study.courses()
            found = study.course_by_name(course)
            if found is None:
                raise ValueError(f"no course called {course!r}; list_courses has their names")
            title, url = title.replace("{course}", found["name"]), url.replace("{id}", str(found["id"]))
            subtitle = subtitle or (found["name"] if page != "course" else None)
            if topic and page in ("lesson", "study_session"):
                if notebook is None:
                    raise ValueError("there's no notebook")
                t = notebook.find_topic(topic, found["id"])
                url += "?" + urlencode({"topic": t["public_id"], "title": t["title"]}, quote_via=quote)
                subtitle = note or t["title"]
            elif page == "lesson":
                raise ValueError("a lesson needs the topic (notebook lists them)")
        card = open_card(title, subtitle, url)
        return ToolOutput(f"A button to open {title} is under your reply; the user taps it to go there.", card)

    return [Tool(
        "open_page", "Put a button under your reply that opens a page of the app when the user taps it (the app "
        "never jumps by itself). Use it when the user asks to go somewhere or start something that happens in the "
        "app (a practice exam, a study session, a lesson), and for what only the phone can do: picking Screen Time "
        "apps, permissions, the server connection, the camera. course_* pages need `course`; a lesson needs "
        "`topic`, a study session may take one.",
        {"type": "object", "additionalProperties": False, "required": ["page"], "properties": {
            "page": {"type": "string", "enum": list(PAGES)},
            "course": {"type": "string", "description": "the course's name, for course, practice_exam, "
                       "study_session and lesson"},
            "topic": {"type": "string", "description": "a notebook topic's id or title, for lesson and study_session"},
            "note": {"type": "string", "description": "a few words under the button, e.g. what to do there"}}},
        open_page)]
