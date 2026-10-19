# Aide HTTP API, v1

The contract between the server (Ubuntu, `src/`) and the iOS app (`ios/`). See CLAUDE.md for how to change it.

## Connection

- **Base URL:** `https://cappa.<tailnet>.ts.net`. The server listens on `127.0.0.1:8787` only, and `tailscale serve` publishes it to the tailnet with a real HTTPS certificate (so iOS needs no security exceptions). Not reachable from the internet.
- **Auth:** every request except `/v1/health` sends `Authorization: Bearer <token>`. The token is `AIDE_API_TOKEN` in the server's `.env`. The user types it into the app's Settings once, and the app stores it in the Keychain. A missing or wrong token gets `401`.
- **Format:** JSON in and out, UTF-8. Field names are `snake_case`.
- **Times:** ISO 8601 with offset, e.g. `2026-10-20T15:00:00+02:00`. The server answers in its local zone (Europe/Rome). All-day dates are `YYYY-MM-DD`.
- **Errors:** non-2xx with `{"error": "human readable message"}`. A body that doesn't fit the schema is `400` (it was FastAPI's `422` before the digest change).

| Status | Meaning |
|---|---|
| 400 | Bad request body |
| 401 | Missing or wrong token |
| 409 | Sync conflict the server couldn't resolve (shouldn't happen; see Reminders) |
| 502 | An upstream (Claude, iCloud) failed. Safe to retry. |

## Health

`GET /v1/health` (no auth) → `200 {"ok": true, "version": "0.2.0"}`

## Chat

The conversation is shared with Discord: one assistant, one history, one confirmation queue.

`POST /v1/chat`
```json
{"text": "move the dentist to Friday at 10"}
```
→ `200`
```json
{
  "reply": "I queued the move to Friday 10:00–11:00.",
  "pending": [{"id": 42, "summary": "Move 'Dentist' from Tue 20 Oct 15:00–16:00 to Fri 23 Oct 10:00–11:00"}],
  "attachments": []
}
```
A reply can take 5–30 s (the model plus tools). Use a request timeout of at least 90 s and show a typing indicator.

`pending` lists the actions waiting for confirmation, written by code, not the model. When it isn't empty, show the summaries with **Confirm** and **Cancel** buttons.

`attachments` (always present, default `[]`) is structured data to draw as cards under the reply, written by code
from the tools the assistant used in that turn, not parsed from its text:

```json
"attachments": [
  {"type": "reminders", "reminders": [ /* Reminder objects, as in Reminders below */ ]},
  {"type": "events", "events": [ /* calendar event objects, as in /v1/today */ ]}
]
```
- `reminders`: when the assistant listed reminders, or created, changed or completed one, in that turn.
- `events`: when it listed or searched calendar events.
- At most one attachment per type; an item shown twice in a turn appears once, in its latest state. The app
  skips types it doesn't know.
- The model is told the app shows these as cards, so the text is a short sentence, not the list line by line.
  On Discord the same items are appended to the reply as a list.

`consulted` (always present, default `[]`) lists the agent ids Aide asked during that turn, in order, e.g.
`["coach"]` (see Agents). The app shows them above the reply as small Pebbles ("Asked Coach"). Cards from a
consulted agent's tools are in this reply's `attachments`.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/confirm` | `{}` | `{"result": "✓ Moved: …", "pending": []}`. Runs every pending action. |
| `POST /v1/cancel` | `{}` | `{"result": "Cancelled. Nothing was changed.", "pending": []}` |
| `POST /v1/new` | `{}` | `{"ok": true}`. Starts a fresh conversation (like `!new`). |
| `POST /v1/think` | `{}` | `{"ok": true}`. Smarter model for the rest of the conversation (like `!think`). |

`GET /v1/history?limit=50` → `{"messages": [{"role": "user" | "assistant", "text": "…", "ts": "…", "attachments": [ … ], "consulted": [ … ]}]}`
(`attachments` and `consulted` as in `/v1/chat`, `[]` on user messages and plain replies; reminders in them are reloaded as they are now,
so a reminder ticked since shows `completed: true`, and one deleted since shows `deleted: true`, so hide it). The current conversation's visible text, oldest first, so the chat screen can show what was said on Discord too. Tool calls and internal notes are left out.

## Conversations

The app keeps many chats; Discord stays on the one shared conversation. Every chat endpoint takes an optional `conversation_id`. **Omitted means the shared conversation, exactly as before**, so old clients keep working. Reminders, the confirmation queue and `POST /v1/confirm` / `/v1/cancel` stay global.

| Endpoint | Body / query | Response |
|---|---|---|
| `GET /v1/conversations` | | `{"conversations": [{"id": "c_91f…", "agent": "aide", "title": "Dentist on Friday" \| null, "preview": "last message text…", "updated_at": "2026-10-18T11:20:00+02:00"}]}` newest first. Includes the shared (Discord) conversation, titled "Discord" or similar. |
| `POST /v1/conversations` | `{}`, `{"agent": "coach"}`, or `{"digest": "daily" \| "evening"}` | The new conversation (same shape as a list row, `title: null`). `agent` defaults to `aide`; an unknown one is `400`. With `digest`, the chat is Aide's (`agent` is ignored) and starts with that digest's greeting as Aide's first message: it's in `/v1/history` and `preview`, and the model knows it said it. See Digest. |
| `DELETE /v1/conversations/{id}` | | `{"ok": true}`. The shared conversation can't be deleted (400). |
| `POST /v1/chat` | `{"text": "…", "conversation_id": "c_91f…"}` | Same as before, plus `"conversation_id"`. The server sets `title` from the first exchange. |
| `GET /v1/history` | `?limit=50&conversation_id=c_91f…` | As before, for that conversation. |
| `POST /v1/think` | `{"conversation_id": "c_91f…"}` (optional) | `{"ok": true}`. Smarter model for that conversation. |

The app creates a conversation with `POST /v1/conversations` before the first message of each new chat. If that returns 404 or 405 (older server), it falls back to the shared conversation.

Every conversation belongs to one agent (`agent`, see Agents), fixed when it's created. `POST /v1/chat` answers as
that agent. Chats from before agents existed, digest chats and the shared Discord conversation are `aide`'s.

## Agents

Aide is the orchestrator: you can ask it anything, and it asks the specialists when a question needs them. Each
specialist also has its own chats, with its own instructions, tools and memory. The list comes from the server, so
a new agent needs no app update.

`GET /v1/agents` →
```json
{"agents": [
  {"id": "aide", "name": "Aide", "role": "Talks to all of them", "color": "#34413F", "orchestrator": true,
   "starters": ["What's on today?", "Plan my week", "Remind me to "]},
  {"id": "secretary", "name": "Secretary", "role": "Calendar, reminders and mail", "color": "#3B6FD8",
   "starters": ["What's on my calendar today?", "Any mail I need to answer?", "Remind me to "]},
  {"id": "professor", "name": "Professor", "role": "Study and lectures", "color": "#7A4FD0",
   "starters": ["Explain ", "Make me a study plan for "]},
  {"id": "coach", "name": "Coach", "role": "Sleep, training and habits", "color": "#E0782F",
   "starters": ["How did I sleep this week?", "Should I train hard today?"]},
  {"id": "finance", "name": "Finance", "role": "Money and budgets", "color": "#B8921C",
   "starters": ["Help me set a monthly budget", "I spent "]}
]}
```
- The order is the order the app shows them in. `orchestrator` is true for exactly one agent (default false).
- `color` is Pebble's colour on light backgrounds (`#RRGGBB`). The app may lighten it in dark mode.
- `starters` are suggestions for an empty chat. One that ends in a space goes into the text field for you to
  finish; any other is sent as it is.

**What each one does** (server side; the app only shows them):

| Agent | Tools | Notes |
|---|---|---|
| `aide` | all of today's tools, plus `ask_agent` | Keeps the tools it has now, so quick things stay one step. It asks a specialist when the answer needs that specialist's own memory, judgment or tools (a study question, training advice, a budget). |
| `secretary` | calendar, reminders, mail, maps, web | Today's assistant, focused on the day: schedule, errands, mail. |
| `professor` | web, `fetch_page` | Explains, plans study, and later gets study notes and lecture audio (#3) and quizzes (#4). |
| `coach` | Apple Health, habits, calendar (read), web | Sleep, recovery, training, habits. Compares with your own usual numbers; never makes medical claims. |
| `finance` | web | No bank data yet: it keeps what you tell it (income, spending, goals) in its own memory. |

- **Asking an agent.** `ask_agent(agent, request)` runs one turn of that agent: its instructions, its tools, the
  shared memory plus its own, and the request (Aide puts the context it needs into it). It doesn't see Aide's chat
  and doesn't write to the agent's own chats. Its answer goes back to Aide, which replies, saying who it asked
  ("Coach thinks…"). Actions it queues join the usual confirmation queue; cards from its tools join the reply.
  At most 3 asks per turn, and an asked agent can't ask others.
- **Discord** talks to Aide, as before.

## Memory

Short facts Aide keeps between chats (preferences, names, routines). The server puts the items into the model's context at the start of every conversation and gives the model a `remember` tool to add one (adding is harmless, so it isn't queued; the model deleting one is, like other destructive actions).

Each item is **shared** (`"agent": null`: about you in general, every agent sees it) or **belongs to one agent**
(`"agent": "coach"`: only that agent sees it, e.g. training goals for the Coach, courses for the Professor). An
agent's context has the shared items plus its own. Aide sees only the shared ones and asks specialists for the rest.
`remember` in Aide's chats saves a shared item. In a specialist's chat the model chooses: shared for facts about
you that any agent could use (name, home, routines), its own for things only it needs. Items from before agents
existed are shared. An item saved with `"agent": "aide"` is stored as shared (`null`): Aide has no items of its own.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/memory` | | `{"items": [{"id": 7, "text": "Vegetarian", "agent": null, "created_at": "2026-10-18T11:20:00+02:00"}]}` newest first, all agents |
| `POST /v1/memory` | `{"text": "Vegetarian"}`, or with `"agent": "coach"` | The new item (`agent` omitted or null: shared; unknown agent: `400`) |
| `DELETE /v1/memory/{id}` | | `{"ok": true}` |

## Digest

A summary the server builds on a schedule: morning (`daily`), evening, weekly or monthly, plus the wake-up
briefing (`wake`), which runs when the user gets up instead of at a set time (see Apple Health). Its greeting opens a new chat (`POST /v1/conversations` with `digest`), the app shows the cards behind a "Details" link, and the server also sends it as a push notification and/or a Discord DM (see Push). Sections are structured, so the app draws cards instead of parsing text.

`GET /v1/digest?kind=daily` (`daily` default, `wake`, `evening`, `weekly`, `monthly`) →
```json
{
  "kind": "daily",
  "generated_at": "2026-10-19T08:00:03+02:00",
  "greeting": "Good morning. Two meetings today and three mails that need you.",
  "sections": [
    {"type": "calendar", "title": "Today", "events": [ /* same objects as a calendar event: id, title, calendar, start, end, all_day, location, recurring */ ]},
    {"type": "mail", "title": "Mail", "items": [{"id": "…", "from": "Dr. Rossi", "subject": "Appointment", "preview": "…", "received_at": "…", "unread": true}]},
    {"type": "reminders", "title": "Due today", "reminders": [ /* Reminder objects, plus "overdue": true | false */ ]},
    {"type": "habits", "title": "Habits", "habits": [ /* Habit objects, see below */ ]},
    {"type": "sleep", "title": "Last night", "sleep": { /* Sleep object, see Apple Health */ }, "usual_asleep_min": 438},
    {"type": "recovery", "title": "Recovery", "level": "good", "summary": "HRV above your usual, resting heart rate normal.",
     "hrv_ms": 61.5, "hrv_usual_ms": 55.0, "resting_hr": 52, "resting_hr_usual": 54},
    {"type": "text", "title": "Looking ahead", "text": "free-form markdown"}
  ]
}
```
The app skips section types it doesn't know. `404` if none has been generated yet; `400` for an unknown `kind`.

- **Morning and evening:** `daily` is the morning digest (the app calls it
  "Morning"). `evening` is for before bed: tomorrow's calendar ("Tomorrow"), reminders due by the end of tomorrow,
  habits not yet done today (`habits` section, only the undone ones), today's mail, and a short `text`
  wrap-up (titled "Wrap-up"). It always looks at tomorrow, whatever the clock says. Default time 22:00.
- **What it covers:** daily = one day, weekly = 7 days, monthly = to the end of the month. The period starts today,
  or tomorrow if the digest is made after 17:00 (so the Sunday 18:00 weekly covers Monday to Sunday). Section
  titles say which ("Today", "Tomorrow", "Next 7 days", "October"; reminders "Due today", "Due in October", …).
- **Live data:** `GET /v1/digest` builds the `calendar`, `mail`, `reminders` and `habits` sections again on every
  call, for the period the stored digest covers. Only `greeting`, `generated_at` and the `text` section are from the
  stored, scheduled generation. Completed or deleted reminders never appear. (`POST /v1/digest/run` returns the
  same thing, freshly made.)
- **Reminders:** open ones due by the end of the period, plus overdue ones from **today** only (since local
  midnight). Each has `"overdue": true` if its `due_at` has passed. Older overdue ones are left to the chat. Reminders with no
  due time aren't listed.
- **Mail:** what came into the inbox today, read or unread, newest first, up to 25, with `unread` per item. "Today"
  means since local midnight; for the morning digest, since the previous evening (the evening digest's time,
  default 22:00).
- **Greeting:** two or three spoken-style sentences: what's coming, what to do, and mail that seems to want an
  answer. No lists, no markdown. It's written to be read as a chat message, e.g. *"Tomorrow is light: the dentist
  at 15:00 and gym at 19:00. Still to do: pay the electricity bill and call Marco. 6 emails today; the one from
  Giulia about Saturday looks like it wants an answer."*
- **Opening a chat with it:** `POST /v1/conversations` with `{"digest": "evening"}` (or `daily`; any kind works)
  uses that kind's stored greeting if it still covers the same days as a digest made now would. Otherwise it makes
  a fresh digest first (5–30 s, not sent to Discord). The app picks `daily` before 17:00 and `evening` after.
  An unknown kind is `400`.
- **Only the greeting and the `text` section come from the model.** Everything else is data from code. If the
  model fails, the greeting is a plain one from code and there's no `text` section.
- **Sections can be missing:** `mail`, `reminders` and `habits` are left out when empty; `calendar` and `mail`
  when the source isn't set up or is down. `calendar` is kept when empty (nothing scheduled).
- **Sleep and recovery** (in `wake` and `daily` only, first in the list, live like the other data sections):
  `sleep` is last night (the stored health day for the digest's date) and appears once that night has been
  uploaded. `usual_asleep_min` is the median `asleep_min` of the 30 days before, or `null` with fewer than 7
  nights. `recovery` compares last night's `hrv_ms` and that day's `resting_hr` with their medians over the 30
  days before. It's left out until there are 14 days of both. `level` is set by code, not the model: `low` if HRV
  is under 85% of usual or resting HR is 5 or more above usual, `good` if HRV is at or above usual and resting HR
  at or below usual, otherwise `normal`. `summary` is one plain sentence from code. Both are comparisons with
  the user's own usual numbers, not medical advice, and are worded that way.
- **Schedule:** each enabled kind runs at its time. If the server was off then, it catches up within 6 hours,
  otherwise skips that one. A scheduled digest is also sent as a Discord DM when `discord` is true; `POST
  /v1/digest/run` isn't (you're looking at it). `day` 29–31 means the last day in shorter months.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/digest/run` | `{"kind": "daily"}` | The freshly generated digest (can take 5–30 s). For `wake` it's a test run: it doesn't count as the day's wake-up and isn't pushed. |
| `GET /v1/digest/settings` | | `{"daily": {"enabled": true, "time": "08:00"}, "wake": {"enabled": true}, "evening": {"enabled": true, "time": "22:00"}, "weekly": {"enabled": true, "weekday": 7, "time": "18:00"}, "monthly": {"enabled": true, "day": 1, "time": "09:00"}, "discord": true}` (times in the server zone, `weekday` 1 = Monday; `wake` has no time, it runs when you get up) |
| `PUT /v1/digest/settings` | the same object (all of it; `evening` and `wake` may be missing from older clients: keep their current values) | the saved settings; `400` if a time isn't `HH:MM` or a field is missing or out of range |

## Habits

Habit object: `{"id": 3, "name": "Gym", "cadence": {"type": "daily"} | {"type": "weekly", "per_week": 3}, "streak": 4, "done_today": false, "last_done": "2026-10-18" | null, "history": ["2026-10-18", "2026-10-17", …], "workouts": ["strength"]}`.

`workouts` (default `[]`) lists the Apple Watch workout types that check the habit by themselves (see Apple Health,
"Workout types"; `"any"` matches every type). When a health upload has a workout of a listed type that lasted at
least 10 minutes, the server checks the habit for the workout's local date. Each workout (by its `id`) checks a
habit at most once, so if you undo the check, a later upload of the same workout doesn't redo it.

`history` is every local date the habit was checked in the last 26 weeks (182 days, today included), newest first,
for a GitHub-style grid. Every endpoint that returns a Habit includes it, `POST /v1/habits/{id}/check` too, and
so does the `habits` digest section.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/habits` | | `{"habits": [Habit]}` |
| `POST /v1/habits` | `{"name": "Gym", "cadence": {"type": "weekly", "per_week": 3}, "workouts": ["strength"]}` (`workouts` optional) | the new Habit |
| `PATCH /v1/habits/{id}` | any of `name`, `cadence`, `workouts` | the updated Habit |
| `POST /v1/habits/{id}/check` | `{"date": "2026-10-18"}` (optional, default today; send `"done": false` to undo) | the updated Habit |
| `DELETE /v1/habits/{id}` | | `{"ok": true}` |

`streak` counts consecutive scheduled periods done: days for a daily habit, Monday-to-Sunday weeks with at least
`per_week` checks for a weekly one. Today (or this week) adds to the streak once it's done, and doesn't break it
while it's still in progress. Names are unique, ignoring case (a duplicate is `400`); checking a future date is
`400`; an unknown id is `404`.

The assistant also gets tools to add, check and list habits (deleting is queued for confirmation).

## Apple Health

The app reads Apple Health on the phone (sleep from the Apple Watch, heart rate, HRV, wrist temperature, steps,
workouts) and sends **one summary per local day**. Raw samples never leave the phone. (`GET /v1/health` is still
the server's liveness check; these routes sit under it and need the token like everything else.)

### Health day

```json
{
  "date": "2026-10-19",
  "sleep": {
    "bedtime": "2026-10-19T00:12:00+02:00",
    "wake": "2026-10-19T07:41:00+02:00",
    "asleep_min": 412, "in_bed_min": 449, "awake_min": 37,
    "deep_min": 58, "core_min": 251, "rem_min": 103
  },
  "resting_hr": 52,
  "hrv_ms": 61.5,
  "respiratory_rate": 14.2,
  "wrist_temp_c": 35.91,
  "steps": 8432,
  "active_kcal": 512,
  "exercise_min": 41,
  "workouts": [
    {"id": "6B1F0C2E-…", "type": "strength", "start": "2026-10-19T18:30:00+02:00",
     "end": "2026-10-19T19:22:00+02:00", "minutes": 52, "kcal": 310}
  ]
}
```
- **Missing or `null` means no data** for that field. Every number may be missing.
- `date` is the local calendar day. `steps`, `active_kcal`, `exercise_min` and `workouts` cover 00:00–24:00.
- `sleep` is the night that **ended** that morning: the longest stretch of sleep that ends between 18:00 the
  evening before and 18:00 on `date`, with gaps under an hour counted as part of it. Naps are left out. `bedtime`
  is when sleep started, `wake` when it ended, `in_bed_min` = `wake` − `bedtime`, `asleep_min` = the sleep stages
  added up, `awake_min` = time awake in between. `deep_min`, `core_min` and `rem_min` are `null` without a Watch.
- `resting_hr` (bpm) is Apple's resting heart rate for that day. `hrv_ms` is the average HRV (SDNN, Apple's
  measure) during that night's sleep, or over the day if there's none from the night. `respiratory_rate`
  (breaths/min) and `wrist_temp_c` (absolute °C, Series 8 and later) are averages over the night. The server
  compares them with the user's own past numbers; Apple's "baseline" isn't available to apps.
- `workouts[].id` is the HealthKit workout UUID: stable, so re-sending the same workout is harmless.

### Workout types

`strength`, `run`, `walk`, `hike`, `cycle`, `swim`, `hiit`, `yoga`, `pilates`, `core`, `dance`, `climb`,
`row`, `elliptical`, `stairs`, `cardio`, `martial_arts`, `sport` (team and racket sports), `other`. More may be
added; treat an unknown one like `other`.

### Endpoints

| Endpoint | Body / query | Response |
|---|---|---|
| `POST /v1/health/days` | `{"days": [Health day]}` (up to 90) | `{"ok": true, "saved": 7, "checked": [Habit]}`: `checked` = habits this upload checked through workouts |
| `GET /v1/health/days` | `?from=2026-10-01&to=2026-10-19` (both optional; default the last 30 days) | `{"days": [Health day]}`, newest first |
| `POST /v1/wake` | `{"at": "2026-10-19T07:42:10+02:00", "source": "shortcut", "day": Health day \| null}` | `{"started": true}`, or `{"started": false, "reason": "already"}` (`already`, `off`, `outside_hours`) |

- **Uploads replace by `date`.** A day that's sent again overwrites the stored one, because data arrives late
  (the Watch syncs the night after you wake, steps keep counting all day). So the app re-sends recent days:
  - on launch and on returning to the foreground: the last 7 days;
  - the first time (and whenever Health access is newly granted): the last 60 days, so baselines and "usual"
    numbers work from the first morning;
  - when HealthKit wakes the app in the background with new sleep or a new workout (right away) or new steps
    (at most hourly): the last 2 days.

### Wake-up briefing

A digest of kind `wake`, sent once per day when the user gets up. It comes **in addition to** the scheduled
morning digest, which runs at its time as before.

- **Wake signals.** Either of these, whichever comes first:
  1. `POST /v1/wake` from the app. iOS runs it from a Shortcuts automation (Sleep → "Waking Up" → Aide "I'm up").
     `day` is today's Health day if the app could read it (it can't while the phone is locked); it's saved as if
     it came from `/v1/health/days`. `source` is `shortcut` or `app` (the "I'm up" action run by hand).
  2. A `/v1/health/days` upload whose entry for today has `sleep.wake` in the last 3 hours. That counts as a
     wake-up at `sleep.wake`, so the briefing still comes without the Shortcut, just later (when the Watch syncs).
- **Once a day.** The first wake signal of a local day starts the briefing. Later ones return `already`. A signal
  outside 03:00–15:00 local returns `outside_hours`, and with `wake.enabled` false in the digest settings it
  returns `off`.
- **Waiting for the sleep data.** If there's no sleep for today yet when the signal comes, the server waits up to
  10 minutes for an upload that has it, then goes ahead anyway. The sections are live, so the sleep card appears
  in Details once the night arrives, even if the greeting didn't mention it.
- **Contents:** the `daily` sections for today (calendar, mail since last evening, reminders, habits), with
  `sleep` and `recovery` first. The greeting is spoken and knows the time: when you got up, how you slept compared
  with usual, recovery in a few words, then what's next and when to leave. Example: *"Morning. You're up at 8:10
  after 6h40, a bit under your usual, and your body looks recovered. Lecture at 9:30 in Città Studi: leave by 8:55
  by tram. Giulia replied about Saturday."* Travel time comes from Google Maps when the next event has a location
  and Maps is set up; otherwise the greeting just gives the time. The trip starts from home (the address in the
  assistant's memory if there is one, else the server's configured one) and aims to arrive 10 minutes before the
  event starts; leave-by times are rounded down to 5 minutes. The server asks for walking and public transport:
  if the walk is 35 minutes or less the greeting can give both ("walk: leave by 8:50, tram: leave by 9:05"),
  otherwise transit only. If memory says how the user gets to that place ("I always walk to uni"), only that
  way is used.
- **Delivery:** a `digest` push with `"digest": "wake"` (title "Good morning"), and a Discord DM when the digest
  settings' `discord` is true, like the scheduled digests.
- **Opening it:** `POST /v1/conversations` with `{"digest": "wake"}` uses today's wake greeting. If there's none
  today, it does what `daily` does. `GET /v1/digest?kind=wake` returns the latest one (`404` before the first).

### In chat

The assistant gets a read-only `health` tool over the stored days: sleep, resting heart rate, HRV, steps and
workouts for a date range, with averages, so "how did I sleep this week?" or "when did I last work out?" works.
Its answers are plain text; there are no health attachments yet.

## Today

`GET /v1/today` (optional `?date=YYYY-MM-DD`, default today) →
```json
{
  "date": "2026-10-18",
  "events": [
    {"id": "df2c…@aide", "title": "Drive to Malpensa", "calendar": "Transport",
     "start": "2026-10-18T14:00:00+02:00", "end": "2026-10-18T19:00:00+02:00",
     "all_day": false, "location": "Malpensa Airport", "recurring": false}
  ],
  "reminders": [ /* Reminder objects due that day or overdue and not completed */ ]
}
```
All-day events have `"all_day": true`, and `start`/`end` are dates, with `end` **exclusive**.

## Reminders

The server keeps the master list. Apple Reminders on the phone is a mirror the app keeps in sync, and only the app can write to it.

### Reminder object

```json
{
  "id": "6f1c2e…",                       // server id (UUID). Never changes.
  "title": "Call the dentist",
  "notes": "",
  "due_at": "2026-10-20T17:00:00+02:00", // or null: no due time
  "completed": false,
  "apple_id": "x-apple-reminder://…",    // EKReminder.calendarItemExternalIdentifier, or null if not on the phone yet
  "modified_at": "2026-10-18T11:20:00Z", // when the content last changed, on either side (UTC)
  "deleted": false                       // tombstone: delete it on the phone too
}
```

### Sync

`POST /v1/reminders/sync`
```json
{
  "cursor": "1712",   // from the previous sync; null on the first sync
  "changes": [        // reminders changed on the phone since the last sync
    {"id": "6f1c2e…" , "apple_id": "x-apple-…", "title": "…", "notes": "", "due_at": "…",
     "completed": true, "modified_at": "2026-10-18T11:25:03Z", "deleted": false},
    {"id": null, "apple_id": "x-apple-…", "title": "Buy milk", "notes": "", "due_at": null,
     "completed": false, "modified_at": "2026-10-18T11:26:10Z", "deleted": false}
  ]
}
```
- `id: null` means it was created on the phone. The server assigns an id and returns it.
- `modified_at` comes from `EKReminder.lastModifiedDate`.
- A reminder deleted on the phone is sent with `"deleted": true` and its `id`.

→ `200`
```json
{
  "cursor": "1720",
  "reminders": [ /* every reminder changed on the server since the request's cursor,
                    plus every reminder from `changes` in its final form (with ids) */ ]
}
```

**What the app does with the response:** for each reminder, create, update or delete the matching EKReminder (match by `apple_id`, or create it if `apple_id` is null). Give it an absolute EKAlarm at `due_at`, and send the new `apple_id` back in the next sync. Then store `cursor`.

**Conflicts:** if both sides changed the same reminder, the newer `modified_at` wins. Deletion beats edits.

**When to sync:** on app launch, on returning to the foreground, after every chat reply (the assistant may have created reminders), and on pull-to-refresh.

**Which list:** the app syncs **one** Apple Reminders list, chosen in Settings (default: the system default list). Reminders in other lists stay private to the phone.

**Notification rule (server side):** at `due_at`, if a reminder is still not completed and has no `apple_id` (it never reached the phone), the server sends a `reminder` push (see Push), or a Discord DM if no push was delivered. Otherwise Apple Reminders notifies, and the server stays quiet.

**Silent sync:** whenever reminders change on the server, it also sends a silent `sync` push, so the phone syncs (and sets the alarms) without the app being opened. iOS may delay or drop silent pushes, so the triggers above still apply.

## Push

The server notifies the phone through APNs. It sends only when it has a key (`APNS_*` in `.env`) and at least one registered device; otherwise it falls back to Discord DMs, as before.

### Devices

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/devices` | `{"token": "a1b2…", "environment": "sandbox" \| "production", "name": "Filippo's iPhone"}` | `{"ok": true}`. Adds or updates the device (keyed by `token`). |
| `GET /v1/devices` | | `{"devices": [{"token": "a1b2…", "environment": "sandbox", "name": "…", "registered_at": "…", "last_push_at": "…" \| null}]}` |
| `DELETE /v1/devices/{token}` | | `{"ok": true}`, also for an unknown token. |
| `POST /v1/devices/test` | `{}` | `{"sent": 1, "failed": 0}`. Sends a visible test push to every device. |

- `token` is the APNs device token as lowercase hex. `environment` is `sandbox` for Debug builds from Xcode and
  `production` for TestFlight and App Store builds. The server must send each token to the matching APNs host.
- The app registers on every launch (the token can change), and when notifications are turned on in Settings.
  A `404` means an older server: the app ignores it.
- When APNs answers that a token is invalid (`410`, or `400 BadDeviceToken`), the server deletes the device.

### Payloads

Every push carries an `aide` object saying what it is. The app ignores kinds it doesn't know.

| `aide.kind` | Type | When | Extra fields | On tap |
|---|---|---|---|---|
| `sync` | silent (`content-available: 1`, push type `background`, priority 5) | reminders changed on the server | | (not shown) the app runs a reminders sync |
| `reminder` | alert | due, but not on the phone (see the notification rule) | `reminder_id` | opens Today |
| `digest` | alert | a scheduled digest, or the wake-up briefing, is ready | `digest` (`daily`, `wake`, `evening`, `weekly`, `monthly`) | opens a new chat with that digest (`POST /v1/conversations` with `digest`) |
| `message` | alert | Aide writes first (future use: briefings, leave-now alerts) | `conversation_id` | opens that conversation |
| `test` | alert | `POST /v1/devices/test` | | nothing |

```json
{
  "aps": {"alert": {"title": "Morning", "body": "Two meetings today and three mails that need you."},
          "sound": "default", "thread-id": "digest"},
  "aide": {"kind": "digest", "digest": "daily"}
}
```
```json
{"aps": {"content-available": 1}, "aide": {"kind": "sync"}}
```
- Alert pushes use `thread-id` = the kind, so iOS groups them.
- A scheduled digest is pushed to every device. The Discord DM still follows the digest settings' `discord` flag,
  so turning it off leaves just the push.
- Silent `sync` pushes are coalesced: at most one per 10 seconds, so a burst of changes sends one.
