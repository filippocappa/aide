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

Omitting `conversation_id` means the first chat (`main`, from before there were many). One confirmation queue for all chats. (There used to be a Discord bot sharing that chat; it was removed on 2026-10-21.)

`POST /v1/chat`
```json
{"text": "move the dentist to Friday at 10"}
```
With photos: `{"text": "", "photos": ["p_3f9a…"]}`. Upload each one first (see Photos); up to 4 per message, and
`text` may be empty when there are photos. An unknown photo id is `400`.
`"voice": true` (since 2026-10-27, default `false`) says the message was spoken in voice chat: the reply is then
written to be read aloud (short plain sentences, no lists or markdown, numbers and formulas in words).
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
- `meals`: when it logged, changed or listed meals (see Food), `{"type": "meals", "meals": [Meal]}`.
- `departures`: when it looked up GTT arrivals, a card per stop (see Transit), `{"type": "departures",
  "departures": [Board]}`.
- `files`: study files a message is about, to open (since 2026-10-26; see Study files), `{"type": "files", "files":
  [File]}`. On Professor's notebook proposals.
- `proposal`: a notebook proposal to answer right there (since 2026-10-26; see Notebook), `{"type": "proposal",
  "proposal": Proposal}`. `/v1/history` gives both as they are now: a proposal's `status`, and files still there.
- At most one attachment per type; an item shown twice in a turn appears once, in its latest state. The app
  skips types it doesn't know.
- The model is told the app shows these as cards, so the text is a short sentence, not the list line by line.

`consulted` (always present, default `[]`) lists the agent ids Aide asked during that turn, in order, e.g.
`["coach"]` (see Agents). Cards from a consulted agent's tools are in this reply's `attachments`.

`team` (always present, default `[]`) is what Aide and the agents it asked said to each other during that turn, in
order: each ask, then that agent's answer. The app draws it above the reply as a small group chat (see Agents,
"Team talk"). Old apps keep using `consulted`.

```json
"team": [
  {"from": "aide", "to": "coach", "text": "Filippo asks if he should go to the gym tonight. He slept 6h and has a full day.", "ts": "2026-10-19T18:02:11+02:00"},
  {"from": "coach", "to": "aide", "text": "HRV is 12% under his usual. An easy session is fine; skip heavy legs.", "ts": "2026-10-19T18:02:19+02:00"}
]
```

**Live, while Aide works.** With `"stream": true` in the body, `POST /v1/chat` answers with `text/event-stream`
instead of JSON, so the app can show each team message as it happens, and the reply as it's written:

```
event: team
data: {"from": "aide", "to": "coach", "text": "…", "ts": "…"}

event: team
data: {"from": "coach", "to": "aide", "text": "…", "ts": "…"}

event: text
data: {"delta": "Coach says", "restart": true}

event: text
data: {"delta": " go easy tonight.", "restart": false}

event: reply
data: { the usual /v1/chat body, including the whole "team" }
```
- Each event is one `event:` line, one `data:` line of JSON (no line breaks inside), then a blank line.
- `team` events come as they happen: the ask when Aide sends it (the app then shows that agent thinking), the
  answer when the agent is done. `reply` is always the last event, and the stream ends after it.
- `text` events are the chat's own agent writing its reply, a few words at a time (`delta`, append it). Only that
  agent's: the answers it gets from the others come as `team`. Text written before it uses a tool ("Let me
  check.") streams too; when it writes again after the tool, the first event has `"restart": true` (possibly with
  an empty `delta`): drop the draft and start over. Speaking it aloud as it comes is fine; already spoken stays
  spoken. `reply` has the final text: show that one. A server without `text` events just sends `reply`.
- A failure after the stream has started is `event: error` with `data: {"error": "…"}`, then the stream ends.
  Failures before it starts (401, 400…) are plain HTTP errors as usual.
- A server that doesn't know `stream` answers plain JSON; the app checks `Content-Type` and handles both.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/confirm` | `{}`, or `{"ids": [42]}` | `{"result": "✓ Moved: …", "pending": []}`. Runs every pending action, or only those (since 2026-10-22; see Activity and approvals). |
| `POST /v1/cancel` | `{}`, or `{"ids": [42]}` | `{"result": "Cancelled. Nothing was changed.", "pending": [ … ]}`: what's still waiting. |
| `POST /v1/new` | `{}` | `{"ok": true}`. Starts a fresh conversation (like `!new`). |
| `POST /v1/think` | `{}` | `{"ok": true}`. Smarter model for the rest of the conversation (like `!think`). |

### Voice

`POST /v1/transcribe` (optional `?language=it-IT`, the phone's speech language, a hint only) with the recording as
the body and `Content-Type: audio/wav` (16 kHz mono 16-bit is plenty), `audio/mp4` (AAC, `.m4a`) or `audio/mpeg`
→ `{"text": "Domani alle 9 ho il dentista"}`, or `{"text": ""}` when nothing was said. An audio model transcribes
it (about a second a sentence), in whatever language was spoken, Italian and English mixed included. Send the text
on with `/v1/chat` as usual. 400 for an empty body, 413 over 10 MB, 415 for another type, 502 if the model failed
(try again), 503 when the server has no OpenRouter key (then use the phone's own recogniser).

`GET /v1/history?limit=50` → `{"messages": [{"role": "user" | "assistant", "text": "…", "ts": "…", "attachments": [ … ], "consulted": [ … ], "team": [ … ]}]}`
(`attachments`, `consulted` and `team` as in `/v1/chat`, `[]` on user messages and plain replies; a user message
sent with photos also has `"photos": ["p_…"]`, absent otherwise; reminders in them are reloaded as they are now,
so a reminder ticked since shows `completed: true`, and one deleted since shows `deleted: true`, so hide it). The current conversation's visible text, oldest first, so the chat screen can show what was said before. Tool calls and internal notes are left out.

## Conversations

The app keeps many chats. Every chat endpoint takes an optional `conversation_id`. **Omitted means the shared conversation, exactly as before**, so old clients keep working. Reminders, the confirmation queue and `POST /v1/confirm` / `/v1/cancel` stay global.

| Endpoint | Body / query | Response |
|---|---|---|
| `GET /v1/conversations` | | `{"conversations": [{"id": "c_91f…", "agent": "aide", "title": "Dentist on Friday" \| null, "preview": "last message text…", "updated_at": "2026-10-18T11:20:00+02:00"}]}` newest first. Includes the first chat (`id` `main`), titled "First chat". |
| `POST /v1/conversations` | `{}`, `{"agent": "coach"}`, or `{"digest": "daily" \| "evening"}` | The new conversation (same shape as a list row, `title: null`). `agent` defaults to `aide`; an unknown one is `400`. With `digest`, the chat is Aide's (`agent` is ignored) and starts with that digest's greeting as Aide's first message: it's in `/v1/history` and `preview`, and the model knows it said it. See Digest. |
| `DELETE /v1/conversations/{id}` | | `{"ok": true}`. The shared conversation can't be deleted (400). |
| `POST /v1/chat` | `{"text": "…", "conversation_id": "c_91f…"}` | Same as before, plus `"conversation_id"`. The server sets `title` from the first exchange. |
| `GET /v1/history` | `?limit=50&conversation_id=c_91f…` | As before, for that conversation. |
| `POST /v1/think` | `{"conversation_id": "c_91f…"}` (optional) | `{"ok": true}`. Smarter model for that conversation. |

The app creates a conversation with `POST /v1/conversations` before the first message of each new chat. If that returns 404 or 405 (older server), it falls back to the shared conversation.

Every conversation belongs to one agent (`agent`, see Agents), fixed when it's created. `POST /v1/chat` answers as
that agent. Chats from before agents existed, digest chats and the first chat are `aide`'s.

## Agents

Aide is the orchestrator, the one you talk to first: it hands each request to the specialist whose work it is
and reports back (since 2026-10-21 it always delegates, and has no domain tools of its own). Each
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
  {"id": "coach", "name": "Coach", "role": "Sleep, training, food and habits", "color": "#23A26D",
   "starters": ["How did I sleep this week?", "Should I train hard today?", "What have I eaten today?"]},
  {"id": "finance", "name": "Finance", "role": "Money and budgets", "color": "#B8921C",
   "starters": ["Help me set a monthly budget", "I spent "]}
]}
```
- The order is the order the app shows them in. `orchestrator` is true for exactly one agent (default false).
- `color` is Pebble's colour on light backgrounds (`#RRGGBB`). The app may lighten it in dark mode.
- `starters` are suggestions for an empty chat. One that ends in a space goes into the text field for you to
  finish; any other is sent as it is.
- Each agent also has (left out above for length) what it runs on, for an info screen in the app:
  - `prompt`: its instructions, the fixed system prompt, as one text. Memory is separate (see Memory).
  - `tools`: the names of the tools it has on this server right now (web and maps only when their keys are set).
  - `connectors`: those tools grouped by what they reach, in a fixed order, each
    `{"id": "calendar", "name": "iCloud Calendar", "read_only": true, "tools": ["list_calendars", "list_events", "search_events"]}`.
    Ids: `calendar`, `reminders`, `mail`, `health`, `habits`, `web`, `maps`, `memory`, `routines`, `objectives`, `team`
    (`ask_agent`: Aide's, and each specialist's for its teammates). `read_only` is true when none of its tools here change anything. A connector it doesn't
    have here is left out. Show `name`; an unknown `id` is fine.

**What each one does** (server side; the app only shows them):

| Agent | Tools | Notes |
|---|---|---|
| `aide` | web, maps, `ask_agent` | Delegates everything in a specialist's area (calendar, reminders and mail to Secretary; health, food and habits to Coach; …) and answers small talk, web and maps itself. It sees every specialist's memory, to word its requests. Its `connectors` show only its own. |
| `secretary` | calendar, reminders, mail, maps, web | Today's assistant, focused on the day: schedule, errands, mail. |
| `professor` | web, `fetch_page` | Explains, plans study, and later gets study notes and lecture audio (#3) and quizzes (#4). |
| `coach` | Apple Health, habits, food, calendar (read), web | Sleep, recovery, training, food, habits. Compares with your own usual numbers; never makes medical claims. |
| `finance` | web | No bank data yet: it keeps what you tell it (income, spending, goals) in its own memory. |

- **Asking an agent.** `ask_agent(agent, request)` runs one turn of that agent: its instructions, its tools, the
  shared memory plus its own, and the request (Aide puts the context it needs into it), plus the photos you sent with that message. It doesn't see Aide's chat
  and doesn't write to the agent's own chats. Its answer goes back to Aide, which replies, saying who it asked
  ("Coach thinks…"). Actions it queues join the usual confirmation queue; cards from its tools join the reply.
  At most 3 asks per turn, and an asked agent can't ask others.
- **A specialist asking a teammate.** Every specialist has `ask_agent` too, for the other specialists, when the work
  needs a teammate's tools: Professor asks Secretary to put study sessions in the calendar. It works the same way
  (`[Asked by Professor]`, one stateless turn, at most 3, no asks from the one asked), and shows the same:
  `consulted` on the specialist's reply, and team messages `from: "professor"`, `to: "secretary"` and back.

### Team talk

The agents have a group chat of their own: every ask and every answer, from all the chats, is kept there as a message. In a chat with Aide the same messages show live above Aide's reply (`team`
in Chat); the Team chat on the app's home screen shows them all together.

`GET /v1/team?limit=100` →
```json
{"messages": [
  {"from": "aide", "to": "coach", "text": "…", "ts": "2026-10-19T18:02:11+02:00", "conversation_id": "c_91f…"},
  {"from": "coach", "to": "aide", "text": "…", "ts": "2026-10-19T18:02:19+02:00", "conversation_id": "c_91f…"}
]}
```
- The latest `limit` messages, oldest first. `text` is the whole ask (the `request` Aide wrote) or the whole
  answer (the agent's reply to Aide), never tool calls.
- `conversation_id` is the chat the exchange came from (Aide's, or a specialist's that asked a teammate), so the app can open it. Deleting that chat deletes its
  team messages too.
- Messages you write in the Team chat (below) are in here too: `from: "user"`, and `conversation_id: null` for
  everything said in the Team chat itself.

**Writing in the Team chat.** `POST /v1/team` with `{"text": "@coach how's my recovery?"}` →
`{"messages": [ …the new team messages, yours first… ], "pending": [ … ]}`
- `@id` mentions (`@coach`, `@secretary`; case-insensitive, names work too: `@Coach`) pick who answers, in
  the order mentioned, at most 3. Without a mention it's a follow-up: whoever answered your previous Team chat
  message answers again, if you sent that within the last 30 minutes. Otherwise Aide answers; it may ask the
  others (`ask_agent`), and those asks and answers are team messages like any other. `@aide` always goes to Aide.
- Your message has `from: "user"`, `to: "team"`. A reply in the Team chat has `to: "team"` too. Asks and
  answers inside a turn keep `from`/`to` as in Team talk above.
- Each agent answering sees the last 30 team messages (the ones from before plus those already written this
  turn), its usual instructions, tools and memory (shared plus its own), and knows it's in the group chat: short,
  only what it adds, no repeating the others. Agents don't start new rounds by mentioning each other.
- Actions an agent queues join the usual confirmation queue; `pending` is the queue after the turn, as in Chat.
- `"stream": true` streams it as in Chat: `event: working` with `data: {"agent": "coach"}` when an agent starts
  writing (the app shows it thinking), `event: team` for each new message as it's done (yours first), then
  `event: done` with the same body as the plain response, then the stream ends. `event: error` as in Chat.
- `400` for empty text or an unknown mention (`{"error": "No agent called @bob."}`).

## Routines

A routine is a job an agent runs on a schedule, like Coach's weekly recap or Secretary's Monday mail sweep. Each
routine has its own chat with its agent: every run posts there as that agent's message, so the agent's card on
the home screen shows it, and you can reply in that chat to carry on. You make routines in the app, or just by
asking an agent ("every Sunday at 18 recap my week").

```json
{"id": 3, "agent": "coach", "title": "Weekly recap",
 "prompt": "Recap my sleep, training and habits for the week, and suggest one thing for next week.",
 "time": "18:00", "days": [7], "enabled": true, "watch": false,
 "conversation_id": "c_7ab…", "next_run": "2026-10-25T18:00:00+02:00", "last_run": null}
```
- `time` is `HH:MM` local (`AIDE_TIMEZONE`). `days` are ISO weekdays, 1 = Monday … 7 = Sunday; `[]` means every
  day. `next_run` is `null` while `enabled` is false.
- `prompt` is what the agent is asked each run (the user never sees it in the chat). The run uses the agent's
  instructions, tools and memory (shared plus its own) and that routine chat's history, so it can say "better
  than last week".
- `conversation_id` is the routine's chat, created with the routine (`agent` as the routine's, `title` as the
  routine's, `routine` set, see below). Deleting the routine keeps the chat; deleting the chat deletes the routine.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/routines` | `?agent=coach` (optional) | `{"routines": [ … ]}`, by agent order, then `time`. |
| `POST /v1/routines` | `{"agent", "title", "prompt", "time", "days", "enabled", "watch"}` (`days` default `[]`, `enabled` default true, `watch` default false) | the new routine. `400` for an unknown agent, a bad time or an empty prompt. |
| `PATCH /v1/routines/{id}` | any of `title`, `prompt`, `time`, `days`, `enabled`, `watch` | the routine. |
| `DELETE /v1/routines/{id}` | | `{"ok": true}` |
| `POST /v1/routines/{id}/run` | `{}` | runs it now, as a scheduled run would (also when disabled), and returns `{"routine": …, "conversation_id": "c_7ab…", "spoke": true}` once the message is posted. `spoke` is false when a watch found nothing (nothing was posted). Can take 30 s. |

- **Each run** posts the agent's reply in the routine's chat, then sends an alert push
  (`aide.kind: "message"`, `conversation_id`, `routine` (its id, since 2026-10-26), title "Coach · Weekly recap",
  body the first line). Actions it queues join the usual confirmation queue, and the push says so.
- **In the app** (since 2026-10-26) a routine's or watch's posts are notes on the Today page (from
  `GET /v1/activity?kind=routine,watch`), and a push with `routine` opens Today on that note. The routine's chat
  stays as its log on the server and opens from the note, to reply; the Chats tab leaves routine chats out.
- A run missed while the server was down runs once when it's back, if it's less than 2 h late; else it's skipped.
- **In history**, a message a routine posted has `"routine": {"id": 3, "title": "Weekly recap"}` (absent on others).
  **In the conversation list**, a routine's chat has `"routine": 3` (absent or `null` on others).
- **By chat.** Every agent has `routines` tools: list its own, create, change (time, days, prompt, on/off). They
  run straight away (harmless, like `remember`), and the reply says what was set. Deleting one by chat is queued
  like other destructive actions. Aide can make routines for any agent; the others only for themselves.
- **Ideas.** `GET /v1/agents` gains `routine_ideas` per agent (default `[]`): `[{"title", "prompt", "time",
  "days"}]`, offered by the app as one-tap starting points. E.g. Coach "Weekly recap" (Sun 18:00), Secretary
  "Mail sweep" (Mon–Fri 09:00), Professor "Review what I studied" (Sun 17:00), Finance "Week's spending" (Sun
  19:00), Aide "Plan my week" (Sun 20:00). Schedules are weekly patterns only; monthly can come later.
  Each idea also has `watch` (see below).

### Watches

A watch is a routine with `"watch": true`: the agent checks on its own and speaks up only when something needs
you (#13). A mail that needs an answer, with the reply drafted; a clash tomorrow; low recovery before a hard
workout; a streak about to break.

- **A run** looks with the agent's tools. If nothing needs you, or the agent already said so in that chat and
  nothing changed, nothing is posted or pushed (`last_run` still moves on), and the chat's history keeps no trace
  of it. Otherwise its note is posted and alerted like any routine's.
- **Read-only.** During a watch run every tool that changes something is refused (calendar, reminders, mail,
  habits, memory, routines, the queue), so nothing is ever queued while you're not looking. The note suggests and
  drafts; you answer in that chat ("send it") and the usual confirmation follows.
- **At most 3 watch notes a day** across all watches. After the third, the day's remaining scheduled checks are
  skipped. `POST /v1/routines/{id}/run` always runs.
- **The starting watches** are set up by the server once (deleting one doesn't bring it back; it stays among the
  ideas): Secretary "Mail that needs you" (Mon–Fri 11:00) and "Tomorrow" (Sun–Thu 18:30), Coach "Recovery check"
  (every day 09:00) and "Habits tonight" (every day 20:30). Professor and Finance have none yet: no data of
  their own to watch.
- **By chat.** `create_routine` and `update_routine` take `watch` ("Coach, keep an eye on my sleep").
- A routine object without `watch` (an older server) is not a watch.

## Objectives

Each specialist (Secretary, Professor, Coach, Finance) keeps objectives for the **day**, the **week** and the
**month**. They propose them, you OK them, and most of them tick themselves from the data.

```json
{"id": "o_3f9a1c2b7d4e", "agent": "coach", "period": "week", "start": "2026-10-19", "end": "2026-10-25",
 "title": "Run 3 times", "why": "Building up to the half marathon",
 "measure": {"type": "habit", "habit": 4, "label": "check-ins of Run"},
 "progress": 1, "target": 3, "done": false, "steps": [], "status": "active", "parent": "o_91be0a7c55d2",
 "added_by": "agent"}
```
- `period` is `day`, `week` (Monday to Sunday) or `month`. `start` and `end` are local dates, both included.
- `status`: `proposed` (waiting for your OK), `active`, `dropped`, or `lapsed` (a proposal whose period ended
  without an OK; read-only).
- `measure` says what ticks it, with a readable `label`; `null` means you tick it. Types:
  `habit` {`habit`}: check-ins in the period (days done, for a limit or food habit). `practice` {`course`, `score`?}: practice exams finished (at
  `score`% or more). `notes` {`course`}: notebook topics written or revised (notes Aide wrote after your OK, or
  your edits in Obsidian; a topic counts once, added figures don't count). `food` {`metric`: `logged` | `protein_g` | `calories`}: days with meals logged, or at the
  goal (calories within 10%). `sleep` {`hours`}: nights at or over. `steps` {`steps`}: days at or over.
  `reminder` {`reminder`}: that reminder done (target 1). An unknown type is fine: show `label`.
- `progress` of `target` is worked out on every read (only days of the period so far count). `done` is true when
  `progress` reaches `target`, or when you ticked it (for one without a measure, `progress` is then 1).
- `steps`: a checklist, `[{"text": "Log in to Moodle", "done": true}, …]`, up to 10, often empty. On one without a
  measure, `progress` of `target` counts the steps done, and it's `done` when they all are; ticking it (`done`)
  ticks or unticks them all. On a measured one they're only a checklist. The planner may propose 2 to 5.
- `parent` is the week's or month's objective it serves, or `null`. `added_by` is `agent` or `user`.
- **Proposals.** A plan is made once per period, before the digest that opens it: the month's before the monthly
  digest (or the first morning digest of the month), the week's before the weekly one (or Monday's morning),
  the day's before the morning digest (or the wake-up briefing). Each goes higher levels first. One model call
  per plan, from the calendar, reminders, courses, exams and practice exams, habits, food, sleep and steps, memory,
  the objectives above and how the last period went: at most 2 a day (6 a day in all), 3 a week and 2 a month
  per specialist, none when there's nothing real to go on. A new plan replaces only the proposals still waiting.
  Titles state the period's total, matching `target` ("Sleep 7h or more on 5 nights this week").
- **Not habits** (since 2026-10-26): a day's objectives are never a habit's daily round ("Log your meals today",
  "Stretch today"); habits keep their own streaks. When a habit matters, the plan proposes a week or month target
  tied to it ("Hit the protein goal 5 days this week"). A day's proposal measured by a habit is left out.
- **When the study material changes** (a course's notes written or edited, its dates read anew), Professor's week
  and day are planned again, 10 min after the last change and at most every 30 min. A period is left alone when
  it hasn't been planned yet, or when Professor's objectives in it are all taken with none waiting. No push.
- **By chat.** Every agent has `objectives` tools: list, add (yours, so it starts `active`), change or tick or
  drop, accept proposals, and plan now. They run at once. Aide works with every specialist's; the others with
  their own.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/objectives` | `?date=2026-10-22` (optional, default today) | `{"day": Block, "week": Block, "month": Block}` for the periods around that date. A Block is `{"period", "start", "end", "planned": true, "objectives": [ … ]}`: by agent order, then oldest first; dropped ones left out. `planned` is false until that period's plan has been made. |
| `POST /v1/objectives` | `{"agent": "coach", "period": "day", "title": "Stretch", "why"?, "date"?, "steps"?: ["…"]}` | `201` and the new objective (`active`, `added_by: "user"`, no measure). `400` for Aide or an unknown agent or period, or an empty title. |
| `PATCH /v1/objectives/{id}` | any of `title`, `done` (true/false), `status` (`active` / `dropped`), `target`, `steps` (`[{"text", "done"}]`, replaces the list) | the objective. Ticking a proposal also accepts it. `404` if unknown. |
| `POST /v1/objectives/accept` | `{"period": "day", "date"?, "ids"?}` (no `ids`: all of that period's proposals) | that period's Block. `404` if an id isn't a proposal of that period. |
| `POST /v1/objectives/plan` | `{"period": "week", "date"?}` | proposes now (replacing those still waiting) and returns the Block. Can take 30 s. |

## Activity and approvals

What the agents did, and what's waiting for you, in one place outside the chats (#12, since 2026-10-22).

### Activity

`GET /v1/activity` (`?agent=coach`, `?kind=routine,watch`, `?before=81`, `?limit=100`, all optional; `limit` at
most 200) → `{"items": [Item], "next": 73}`, newest first. `next` is the `before` for the page after, or `null` at
the end. `kind` (since 2026-10-26) keeps only those kinds, comma-separated: `routine,watch` are the team's notes
on the app's Today page. An unknown `agent` is `400`. Lines are kept 90 days; the feed starts empty on 2026-10-22.

```json
{"id": 81, "ts": "2026-10-22T18:30:04+02:00", "agent": "secretary", "kind": "watch", "title": "Tomorrow",
 "detail": "Your 9:00 with Rossi clashes with the macro lecture.", "conversation_id": "c_7ab…"}
```
- `agent` is who did it. A change made by a specialist that Aide asked is the specialist's.
- `detail` is one line (at most 280 characters) or `null`. `conversation_id` is the chat it happened in (`main`
  for the first chat, `team` for the Team chat), or `null` (a digest, objectives): open it on a tap when it's set.
- `kind` (the app shows any other one as a plain line):

| `kind` | `title` | `detail` |
|---|---|---|
| `action` | what a tool changed: "Added a reminder", "Logged a meal", "Remembered something" | the tool's result |
| `queued` | the summary of an action now waiting for your OK | |
| `confirmed` / `failed` | the summary, once you confirmed it | the result, or the error |
| `cancelled` | the summary, when you cancelled it | |
| `routine` / `watch` | the routine's title: it posted in its chat | the first line it posted |
| `quiet` | the watch's title: it checked and nothing needed you (nothing was posted) | "Checked: nothing needed you." |
| `ask` | "Asked Coach" (always Aide's) | the request |
| `message` | the chat's title: a message no one asked for (lecture notes ready, a notebook proposal, its result) | its first line |
| `objectives` | "Proposed 2 objectives for the week" | their titles, `; ` between |
| `drafts` | "Drafted 2 replies" (Secretary's, see Mail drafts) | "Anna Bianchi: Dinner Friday?; …" |
| `digest` | "Morning digest", "Wake-up briefing", "Evening digest", "Weekly digest", "Monthly digest" (Aide's) | the greeting |

Reads (listing events, searching mail) aren't recorded.

### Approvals

`GET /v1/approvals` → everything waiting for your OK, and the routines coming up:
```json
{"waiting": 4,
 "actions": [{"id": 42, "summary": "Send the reply to Marco", "agent": "secretary", "conversation_id": "c_91f…",
              "created_at": "2026-10-22T10:02:11+02:00", "expires_at": "2026-10-22T10:32:11+02:00"}],
 "objectives": [ /* Objective objects with "status": "proposed", for this month, week and day */ ],
 "proposals": [ /* notebook Proposals still pending, plus "course_name" and "conversation_id" (the course chat, or null) */ ],
 "drafts": [ /* reply Drafts waiting to be sent, newest mail first (see Mail drafts) */ ],
 "writer": null,
 "upcoming": [ /* the next 5 enabled routines (watches too), soonest first: Routine objects */ ]}
```
- `waiting` counts actions, objectives, proposals, drafts and the writer's question: the app's badge.
- `actions`: the confirmation queue, with who queued it and from which chat. An action expires 30 min after it's
  queued. Confirm or cancel one with `POST /v1/confirm` / `/v1/cancel` and `{"ids": [42]}`.
- `objectives`: accept with `POST /v1/objectives/accept` (`period`, `date` = the objective's `start`, `ids`), drop
  with `PATCH /v1/objectives/{id}` (see Objectives).
- `proposals`: apply or decline with `/v1/proposals/{id}/apply` and `/decline` (see Notebook).
- `drafts` (since 2026-10-22): send, edit or dismiss with `/v1/mail/drafts/{id}/…` (see Mail drafts). Unlike
  an action, a draft doesn't expire for 7 days.
- `writer`: while note writing is paused at the Claude plan's limit, the `paused` object of `GET /v1/writer`
  (`since`, `resets_at`, …), else `null`. Answer with `POST /v1/writer/decide` (see Who writes the notes).

## Mail drafts

Replies to mail that wants an answer, written by Secretary for you to send with one tap (#7, since 2026-10-22).
Before the evening digest, Secretary reads the last 3 days' inbox (not promotions, social, updates or forums; not
threads you've answered since) and drafts a reply to each message that asks something of you, in its language and
your voice, using memory and the next 14 days of the calendar. Each message is read once. Secretary also drafts one
in chat when you ask ("draft a reply to Anna"). A new draft in a thread replaces the one waiting there.

**Nothing is sent until you tap Send.** `POST /v1/mail/drafts/{id}/send` is the confirmation, so it sends straight
away (only the app calls it; the model has no way to send a draft). In chat, "send it now" still goes through the
confirmation queue (`reply_mail`).

Draft:
```json
{"id": 3, "message_id": "18f…", "thread_id": "18f…", "from": "Anna Bianchi", "from_address": "anna@example.com",
 "subject": "Dinner Friday?", "preview": "Are you free Friday at 8?", "received_at": "2026-10-22T18:02:00+02:00",
 "why": "Anna asks if Friday at 8 works", "body": "Friday at 8 works for me. See you then!\nFilippo",
 "status": "waiting", "agent": "secretary", "created_at": "2026-10-22T21:55:10+02:00"}
```
- `why` may be `null`. `body` is the reply's plain text, without a subject or quoted text; it goes to the sender
  (or Reply-To) as "Re: subject", in the thread.
- `status`: `waiting`, then `sent`, `dismissed`, `answered` (you replied in that thread another way), `replaced`
  (a newer draft in the thread), or `expired` (7 days waiting). Only `waiting` ones are listed.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/mail/drafts` | | `{"drafts": [Draft]}`: the waiting ones, newest mail first. |
| `PATCH /v1/mail/drafts/{id}` | `{"body": "…"}` | the Draft, with the new text. |
| `POST /v1/mail/drafts/{id}/send` | `{}`, or `{"body": "…"}` to send your edited text | `{"ok": true, "draft": Draft}` (`status: "sent"`). `502` when Gmail refused it or the message is gone (the draft stays waiting), `503` without a mail account. |
| `POST /v1/mail/drafts/{id}/dismiss` | `{}` | `{"ok": true}`. |
| `POST /v1/mail/drafts/run` | `{}` | `{"drafts": [new Drafts], "waiting": [Draft]}`: the evening pass now. `502` if the model or Gmail failed. |

An unknown id is `404`; one that isn't waiting any more is `409`; an empty `body` is `400`. Sending and dismissing
show in the activity feed as `confirmed` / `cancelled` ("Reply to Anna Bianchi: Dinner Friday?").

## Memory

Short facts Aide keeps between chats (preferences, names, routines). The server puts the items into the model's context at the start of every conversation and gives the model a `remember` tool to add one (adding is harmless, so it isn't queued; the model deleting one is, like other destructive actions).

Each item is **shared** (`"agent": null`: about you in general, every agent sees it) or **belongs to one agent**
(`"agent": "coach"`: only that agent sees it, e.g. training goals for the Coach, courses for the Professor). An
agent's context has the shared items plus its own. Aide sees all of them, each specialist's marked with its name
(since 2026-10-21), so what you tell Secretary is known when you ask Aide; it can also forget any of them.
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
briefing (`wake`), which runs when the user gets up instead of at a set time (see Apple Health). The app shows the
latest one as the first card on its Today page (the greeting, then the day; "Details" opens the rest), and the
server also sends it as a push notification (see Push), whose tap opens Today. Sections are structured, so the app
draws cards instead of parsing text.

**Digests aren't chat messages** (since 2026-10-26): the app no longer opens a chat with the greeting from a
notification. `POST /v1/conversations` with `digest` still works (the app's "Reply" under the card uses it: a chat
you start, about that digest).

`GET /v1/digest?kind=daily` (`daily` default, `wake`, `evening`, `weekly`, `monthly`, or `latest`: whichever was
made last, since 2026-10-26) →
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
    {"type": "replies", "title": "Replies to send", "drafts": [ /* Draft objects, see Mail drafts; evening only */ ]},
    {"type": "objectives", "title": "Objectives for today", "period": "day", "start": "2026-10-19",
     "objectives": [ /* Objective objects, see Objectives */ ]},
    {"type": "text", "title": "Looking ahead", "text": "free-form markdown"}
  ]
}
```
The app skips section types it doesn't know. `404` if none has been generated yet; `400` for an unknown `kind`.

- **Morning and evening:** `daily` is the morning digest (the app calls it
  "Morning"). `evening` is for before bed: tomorrow's calendar ("Tomorrow"), reminders due by the end of tomorrow,
  habits not yet done today (`habits` section, only the undone ones), today's mail, the replies Secretary drafted
  just before it (`replies`, live: only those still waiting; since 2026-10-22, see Mail drafts), and a short `text`
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
  a fresh digest first (5–30 s, not pushed). The app picks `daily` before 17:00 and `evening` after.
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
- **Objectives** (live like the other data sections, left out when there are none): `daily` and `wake` show the
  day's (`active` and `proposed`), `evening` reviews today's (`active` only), `weekly` reviews last week's and shows
  the week's, `monthly` reviews last month's and shows the month's. The plans for those periods are made just
  before the digest (see Objectives), and the greeting says when proposals are waiting for an OK.
- **Schedule:** each enabled kind runs at its time. If the server was off then, it catches up within 6 hours,
  otherwise skips that one. `day` 29–31 means the last day in shorter months.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/digest/run` | `{"kind": "daily"}` | The freshly generated digest (can take 5–30 s). For `wake` it's a test run: it doesn't count as the day's wake-up and isn't pushed. |
| `GET /v1/digest/settings` | | `{"daily": {"enabled": true, "time": "08:00"}, "wake": {"enabled": true}, "evening": {"enabled": true, "time": "22:00"}, "weekly": {"enabled": true, "weekday": 7, "time": "18:00"}, "monthly": {"enabled": true, "day": 1, "time": "09:00"}}` (times in the server zone, `weekday` 1 = Monday; `wake` has no time, it runs when you get up) |
| `PUT /v1/digest/settings` | the same object (all of it; `evening` and `wake` may be missing from older clients: keep their current values) | the saved settings; `400` if a time isn't `HH:MM` or a field is missing or out of range |

## Photos

Photos go up first, then their ids go with a chat message (or `POST /v1/food/log`).

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/photos` | the image bytes, `Content-Type: image/jpeg` (or `image/png`, `image/webp`) | `{"id": "p_3f9a…"}`. `400` empty, `413` over 3.5 MB, `415` another type. |
| `GET /v1/photos/{id}` | | the image, with its content type. `404` unknown. |

The app sends JPEG, longest side at most 1568 px (what the model reads best). Photos are kept on the server and in
its backups. The model sees the last 3 photos of a chat as images; an older
one is only a mention, `[Photo p_…]`.

## Food

Meals, mostly from photos: the agent names the dish, estimates the portion and works out calories and macros. Coach
owns food (it sees it next to sleep, training and habits); Aide has the same tools.

Meal object:
```json
{"id": 12, "name": "Pasta al pomodoro", "eaten_at": "2026-10-21T13:10:00+02:00", "calories": 650,
 "protein_g": 20, "carbs_g": 110, "fat_g": 15, "water_ml": 0, "caffeine_mg": 0, "photo": "p_3f9a…",
 "notes": "about 120 g dry pasta"}
```
`photo` is null without one. Numbers are the model's estimates, rounded (calories to 10, grams to 1).
`water_ml` and `caffeine_mg` (since 2026-10-27) are 0 when there's none: a drink is logged like a meal ("an espresso
and 1 L of water" is one, 5 kcal, 1030 ml water, 65 mg caffeine).

**Apple Health** (since 2026-10-27): the app writes every meal of the last 14 days as its own food entry (a
`food` correlation: energy, protein, carbs, fat, and water and caffeine when not 0, named after the meal, with the
meal's id in its metadata), from `GET /v1/food/meals`, and changes or removes its entries when a meal changes or
goes. The server sends the silent `sync` push after every meal change, so this happens with the app closed too.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/food?date=2026-10-21` | (default today) | `{"date": "2026-10-21", "meals": [Meal] (by time), "totals": Totals, "goals": Goals}` |
| `GET /v1/food/meals?from=2026-10-15&to=2026-10-21` | (default the last 7 days; at most 92) | `{"meals": [Meal]}`, oldest first (since 2026-10-27, for Apple Health) |
| `GET /v1/food/days?from=2026-10-15&to=2026-10-21` | (default the last 7 days) | `{"days": [{"date": "2026-10-21", "totals": Totals, "meals": 3}]}`, oldest first, every day included (zeros when empty) |
| `POST /v1/food/log` | `{"photos": ["p_…"], "text": "half of it", "date": "2026-10-20"}` (`photos` or `text` needed; `text` and `date` optional) | `{"reply": "Pasta al pomodoro, about 650 kcal…", "meals": [Meal], "conversation_id": "c_…"}`: Coach logs it in its "Food log" chat (made once, then reused), so a correction can follow there. `meals` is the meals its tools showed: logged, changed or listed (can be empty when it only asked something). 5–30 s. |
| `PATCH /v1/food/meals/{id}` | any of `name`, `eaten_at`, `calories`, `protein_g`, `carbs_g`, `fat_g`, `water_ml`, `caffeine_mg`, `notes` | the Meal |
| `DELETE /v1/food/meals/{id}` | | `{"ok": true}` (the user deleting from the app: immediate) |
| `GET /v1/food/goals` | | Goals |
| `PUT /v1/food/goals` | Goals | Goals |

Totals: `{"calories": 1840, "protein_g": 96, "carbs_g": 210, "fat_g": 61, "water_ml": 1500, "caffeine_mg": 130}`
(the last two since 2026-10-27). Goals has the first four keys, each a
number or null (no goal); all null until set, here or by Coach in chat ("aim for 140 g protein").

The agents get `log_meal`, `update_meal`, `list_meals`, `set_food_goals` (immediate) and `delete_meal` (queued).
They log a meal when a photo shows food you're eating or ate, or when you say what you had, and say the estimate in
a line so you can correct it. A photo that isn't food is just a photo. Coach's role is now "Sleep, training, food and
habits" (since 2026-10-21), and the `food` connector ("Food log") shows on Coach and Aide.

## Study

Lectures and their notes, for Professor (since 2026-10-21). A lecture is a recording, photos of slides or notes,
or text, or a mix. The server transcribes a recording with Whisper on its GPU, then writes notes. When they're
ready, Professor posts a message in the course's chat and a `lecture` push goes out.

**Courses** are the event titles in the study calendar (`AIDE_STUDY_CALENDAR`, default `Work`) that come up at least
3 times from 120 days back to 120 days ahead (a one-off appointment isn't a course), less the titles in
`AIDE_STUDY_SKIP` (comma-separated, default `study`: your own study blocks). A course that has lectures stays when its
events end. A lecture is filed under the course whose
event is on when the recording starts (or starts within 15 minutes of it); otherwise it's unfiled (`course` null)
and the app asks. Exams come from `AIDE_EXAM_CALENDAR` (default `Exam`): an exam is a course's when its title
contains the course's name, in any case ("Macroeconomics exam").

Lecture object:
```json
{"id": "l_3f9a1c2b4d5e", "course": 2, "title": "The IS-LM model", "recorded_at": "2026-10-21T08:02:00+02:00",
 "duration_s": 5340, "photos": [], "has_audio": true, "status": "ready", "error": null,
 "summary": "How the goods and money markets settle together.", "updated_at": "2026-10-21T11:20:00+02:00"}
```
- `status`: `queued`, `transcribing` (only with a recording), `writing`, `ready` or `failed`. `error` is a short
  reason, when `failed`. A 90-minute lecture takes a few minutes.
- `title`: the user's, or the one the notes suggest when it was empty. `summary` is the notes' first line, for lists
  (null before they're written).
- The single-lecture GET and every write add `notes` (markdown), `text` (what the user typed with it), `language`
  (`en`, `it`, …, from the recording) and `files`: the ids of its slides (Study files, below; since 2026-10-21). `?transcript=true` adds `transcript`: paragraphs starting with time marks,
  `[12:30] …`.
- Notes always have the same sections, as `## ` headings, any left out when empty: Summary, Key concepts,
  Definitions, Formulas and examples, Questions to check yourself, Unclear in the recording.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/study` | | `{"courses": [Course], "unfiled": 1, "now": {"course": 2, "name": "macroeconomics", "ends": "2026-10-21T11:00:00+02:00"} or null, "transcription": true}`. `now` is the lecture on now (the recorder shows it). `transcription` false: the server can't take recordings (photos and text still work). |
| `POST /v1/study/courses/{id}/chat` | | `{"conversation_id": "c_…"}`: the course's Professor chat, made the first time (and again if deleted). `404` unknown course. |
| `GET /v1/lectures?course=2` | `course` an id, `none` for the unfiled, or left out for all; `limit` (default 100) | `{"lectures": [Lecture]}`, newest first |
| `POST /v1/lectures?recorded_at=2026-10-21T06:02:00Z&course=2&title=…` | the recording as the raw body, `Content-Type: audio/mp4` (or `audio/m4a`, `audio/x-m4a`, `audio/aac`, `audio/mpeg`, `audio/wav`, `audio/x-wav`), up to 400 MB | the Lecture, `202`, `queued`. `recorded_at` (with an offset; `Z` is safest in a query) is when the recording started, default now; `course` and `title` are optional (no `course`: filed by the calendar). `400` empty, bad `course` or no offset; `413` too big; `415` another type; `503` no transcription on this server. |
| `POST /v1/lectures` | JSON `{"photos": ["p_…"], "files": ["f_…"], "text": "…", "course": 2, "title": "…", "recorded_at": "…"}`, photos (up to 10, from `POST /v1/photos`), files (from `POST /v1/files`, which become its slides and move to its course) or text needed | the Lecture, `202`. `400` unknown photo or file. |
| `GET /v1/lectures/{id}?transcript=true&plain=true` | | the Lecture. `404` unknown. `plain=true`: `notes` for reading in the app (below, Notebook). |
| `PATCH /v1/lectures/{id}` | any of `title`, `course` (null: unfiled), `notes` | the Lecture. New notes keep the old ones for one undo, on the server. |
| `DELETE /v1/lectures/{id}` | | `{"ok": true}`, the recording too (the user deleting from the app: immediate) |
| `POST /v1/lectures/{id}/retry` | | the Lecture, `202`, `queued` again. `400` unless it `failed`. |

Course: `{"id": 2, "name": "macroeconomics", "lectures": 5, "files": 3, "last_lecture": "2026-10-21T08:02:00+02:00" or
null, "next_exam": {"date": "2026-11-10T09:00:00+01:00", "title": "Macroeconomics exam"} or null, "chat": "c_…" or null,
"notebook": {"topics": 11, "questions": 65, "proposals": 1, "writing": false} or null}`.
`files` counts its files (since 2026-10-21). `notebook` is null until the course's notebook is started (below);
`topics` counts the written ones, `proposals` the pending ones, `writing` is true while one is applied.
`chat` is null until the course has a chat; then the app opens it, else asks for one with the POST above.

The ready message in the course chat comes from Professor ("Notes from Tuesday's macroeconomics lecture…"); the
model's note before it is hidden from `/v1/history`. A lecture with no course gets the push but no chat message.
Recordings stay on the server until the lecture is deleted; they aren't in the backups (the notes and transcripts
are).

Professor gets `list_courses`, `list_lectures`, `read_lecture`, `search_study` (every word, accents ignored, with
snippets; notes, transcripts and file pages), `list_files`, `read_file` (by page range), `update_notes` (immediate,
keeps the previous version) and `delete_lecture` (queued), plus `list_events` to read the timetable and exams. Its
`study` connector is "Study notes". Aide hands study questions to Professor.

### Study files

PDFs: slides, handouts, the professor's notes (since 2026-10-21). A file belongs to a course (or none). Attached to a
lecture, it's that lecture's slides: the notes are written with them (their text and their most visual pages as
images), and a lecture that already has notes gets them rewritten (the old ones kept for one undo; the chat message
says "I rewrote the notes…"). A file not attached to a lecture is course material, which Professor searches page by
page and cites ("p. 34"). Files come from the app (`source` `upload`) or Moodle (`moodle`, below). A Moodle file put
up within 36 hours of a lecture of its course is attached to it by itself (at most 3 per lecture).

File object:
```json
{"id": "f_3f9a1c2b4d5e", "course": 2, "lecture": "l_…" or null, "name": "Week 3 slides.pdf", "section": "",
 "size": 2481920, "pages": 42, "scanned": false, "source": "upload", "added_at": "2026-10-21T12:00:00+02:00"}
```
- `scanned`: no text layer (a scan). The server reads each of its pages once with the model, from the page's
  image (pages with no text in other files too), in the background; from then on they're searched and read as text.
  A lecture still sees its pages as images.
- `section`: where it was on Moodle ("Week 3"), else empty.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/files?course=2&lecture=l_…&name=Week%203%20slides.pdf` | the PDF as the raw body, `Content-Type: application/pdf`, up to 100 MB | the File, `201`. `lecture` makes it the lecture's slides (and takes the lecture's course when `course` is left out). `name` gets `.pdf` if missing. `400` empty, not a PDF, bad `course`; `404` unknown lecture; `413` too big; `415` another type. |
| `GET /v1/files?course=2&lecture=l_…` | both optional | `{"files": [File]}`, by section, then name |
| `GET /v1/files/{id}` | | the File. `404` unknown. |
| `GET /v1/files/{id}/pdf` | | the PDF itself |
| `GET /v1/files/{id}/pages/{n}` | | page `n` (from 1) drawn as a JPEG: a figure in the notes. `404` unknown file or no such page. |
| `PATCH /v1/files/{id}` | any of `name`, `course` (null: unfiled), `lecture` (null: course material again) | the File. Attaching it to a lecture rewrites that lecture's notes. |
| `DELETE /v1/files/{id}` | | `{"ok": true}` (immediate). The lecture's notes stay as they are. |

Deleting a lecture keeps its files, as course material. Files are in the backups (`~/aide-backups/files`).

### Moodle

The university's Moodle (`AIDE_MOODLE_URL`, UniTo's `https://elearning.unito.it/sme`), since 2026-10-21: the
server keeps the PDFs of the user's current courses in the study files, every 4 hours and on demand.

**Logging in** goes through the university's single sign-on, in a browser sheet, so the password never reaches
the app or the server. It's the flow of Moodle's own app:
1. `POST /v1/moodle/login` gives `{"url": "https://…/admin/tool/mobile/launch.php?…", "scheme": "moodlemobile"}`.
2. The app opens `url` in an `ASWebAuthenticationSession` with callback scheme `scheme`. The user logs in; Moodle
   ends on an address starting `moodlemobile://token=`.
3. The app sends that whole address to `POST /v1/moodle/connect` `{"url": "moodlemobile://token=…"}`. The server
   checks it was signed for its login (each `login` is good once, for 15 minutes), keeps the token and syncs.

**Courses.** Each current Moodle course (from a month before it starts to a month after it ends) is matched to an
Aide course (Study): by itself when exactly one Aide course's name is in the Moodle course's name, else by the user.
Only matched courses are synced. A file the user deletes in Aide isn't downloaded again. When a sync brings at
most 3 new files for a course and one went up within 36 hours of a lecture, it becomes that lecture's slides and
the notes are written again.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/moodle` | | `{"enabled": true, "site": "https://elearning.unito.it/sme", "connected": true, "user": "Filippo Cappa", "last_sync": "2026-10-21T14:00:00+02:00" or null, "error": null or "the Moodle login has expired", "courses": [MoodleCourse]}`; `{"enabled": false}` without `AIDE_MOODLE_URL`. Not connected: `user` null, `courses` empty. |
| `POST /v1/moodle/login` | | `{"url", "scheme"}`, above. `503` not set up. |
| `POST /v1/moodle/connect` | `{"url": "moodlemobile://token=…"}` | `GET /v1/moodle`'s object. `400` not this server's login (or too old): log in again; `502` Moodle didn't take the token. |
| `POST /v1/moodle/sync` | | `202`, `GET /v1/moodle`'s object; the sync runs in the background (poll `GET`, `last_sync` changes). `409` not connected. |
| `PATCH /v1/moodle/courses/{id}` | `{"course": 2}` (an Aide course id; null: don't sync it) | the MoodleCourse. The user's choice is kept over the automatic one. `404` unknown. |
| `DELETE /v1/moodle` | | `GET /v1/moodle`'s object, logged out. The files stay. |

MoodleCourse: `{"id": 101, "name": "Macroeconomics 2026/27", "course": 2 or null, "matched": "auto" | "user" | null,
"files": 12}`. New files are pushed (`moodle`); an expired login is pushed once (`moodle` with `login: true`) and shows
as `error`: log in again.

### Obsidian vault

The server keeps an Obsidian vault of the notes and files (since 2026-10-21), served over WebDAV, which Obsidian's
Remotely Save plugin syncs to the phone and the Mac (README, "Obsidian"). Everything Aide writes is under `Aide/` in
the vault, a folder per course:
- with a notebook (below): `00 Introduction.md` (the exam, how to prepare, the topics, lectures and files), a page
  per topic (`01 The IS-LM model.md`), `Cards/` with each topic's flashcards for the Spaced Repetition plugin and
  `Images/` with the slides the topics show as figures;
  otherwise an index page named after the course (lectures, files, the next exam);
- `Sources/` with a page per lecture (`2026-10-21 The IS-LM model.md`: properties, the notes, "Expanded:" the
  topics it went into, the transcript folded), and `Files/` with the PDFs.

A page the user edits or deletes in Obsidian is theirs from then on: Aide doesn't change it or bring it back.
Except topic pages: the user's edits are read back into the notebook, and Aide's next change builds on them. And
cards files, which Aide only adds new cards to, at the end. It syncs within a minute of a change.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/vault` | | `{"enabled": true, "url": "https://cappa.<tailnet>.ts.net:8443", "user": "aide", "password": "…", "vault": "Uni"}`, what Remotely Save's WebDAV settings need (the vault in Obsidian must be named as `vault` says, since Remotely Save syncs a vault with the folder of its name); or `{"enabled": false}`. `url` may be null when the server doesn't know it. |

### Notebook

A course's notes by topic, since 2026-10-21 (`notebook.py`): an Introduction on the exam and a page per topic, each
with an explanation, key terms, formulas, worked examples, exam-style multiple-choice questions (answers folded) and
flashcards, built from the course's PDFs and lectures. In the vault as above.

**Nothing is written without the user's OK.** Starting a notebook writes the Introduction (from the Moodle course
page and the exam calendar) and proposes the topics; new material for a course with a notebook (a Moodle file, a
lecture's notes) gets a proposal of which topics to expand or add. Each proposal is posted in a Professor chat, with a
push (`message`), and answered there ("yes", "only 1 and 3", "also stress the graphs"), on its card, or through the
endpoints below. The outline goes in the course's chat; since 2026-10-26 each proposal for new material starts a chat
of its own ("Macroeconomics: Lecture Notes: Monetary Policy", `course` set on the conversation row like the course's
chat), with the files as a `files` card and the proposal as a `proposal` card under the message (Chat, attachments).
The message names the files and says how many topics it would expand or add; the items are on the card. A proposal waits until it's answered; applying runs in the background (a few minutes)
and posts the result in the same chat.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/notebook?course=2&plain=true` | | Notebook. `404` no such course. |
| `POST /v1/notebook?course=2` | | `202`, Notebook: the Introduction and the outline proposal are on their way. `409` it already has topics. |
| `POST /v1/notebook/figures?course=2` | | `202`, Notebook: every slide of the course gets one look (once; new files later), then figures go into the topics that miss good ones, from the pages they don't show yet. Nothing is rewritten; the result comes in the course chat. `409` no topics yet. |
| `GET /v1/topics/{id}?plain=true` | | Topic with `body` (markdown), `cards_list` `[{"q", "a"}]` and `sources` (`["Week 3 slides, p. 1–2"]`). `404`. In `body`, a figure is `![The IS curve shifting right](figure:f_…/12)`: page 12 of that study file, with its caption. |
| `GET /v1/proposals?course=2&status=pending` | | `{"proposals": [Proposal]}`; both optional; `status` `pending` (default) or `all`. |
| `POST /v1/proposals/{id}/apply` | `{"items": [1, 3], "note": "keep it short"}`, both optional (all items) | `202`, the Proposal, `status` `applying`. `400` an item out of range; `409` not pending. |
| `POST /v1/proposals/{id}/decline` | | the Proposal, `declined`. `409` not pending. |

Notebook: `{"course": 2, "started": true, "busy": false, "step": "Writing The IS-LM model, Crowding out" or null,
"exam": "20–35 multiple-choice questions, −0.25 for a wrong answer…" or null, "introduction": "markdown" or null,
"topics": [Topic], "proposals": [Proposal], "writing": Proposal or null}` (`busy`: being written; `step`: what
Professor is doing now, a line to show while `busy` (null otherwise, or right after a restart); pending proposals
only; `writing`: the proposal being applied, with its `progress`).

**`plain=true`** (on the notebook, a topic and a lecture): the notes as the app shows them. LaTeX becomes plain
Unicode ($\pi_{t-1}$ as πₜ₋₁) and `[[links]]` their text. Without it, the markdown is as in the vault.

**Progress.** A course's chat has `"course": 2` in the conversation list (`null` on other chats). While a proposal
is applied, `GET /v1/notebook?course=` has it as `writing`, with `"progress": {"done": 4, "total": 11}` (topics
finished, failed ones included; `progress` is null on proposals not being applied). `step` says which topics are
being written ("Writing The IS-LM model, Crowding out"); each topic's slides are looked at for figures as it's
written, so nothing holds up the first. The app polls it every few seconds while the course's chat is open and
`writing` isn't null; when it turns null, the result is in the chat.

Topic: `{"id": "t_…", "course": 2, "position": 1, "title": "The IS-LM model", "summary": "one line" or null,
"written": true, "sections": ["Explanation", "Key terms", …], "questions": 5, "cards": 12, "edited": false,
"updated_at": "…"}` (`edited`: the user changed it in Obsidian).

Proposal: `{"id": "p_…", "course": 2, "kind": "outline" | "update", "status": "pending" | "applying" | "applied" |
"declined" | "superseded" | "failed", "items": [{"n": 1, "topic": "t_…" or null (a new topic), "title": "…", "add":
"what it would write", "sources": ["Problem set 2, p. 1"]}], "material": ["Problem set 2"], "result": "Updated The
IS-LM model." or null, "progress": {"done": 4, "total": 11} or null, "conversation_id": "c_…" or null, "created_at":
"…"}`. A new outline supersedes a pending one. `conversation_id`: the chat it was posted in when it has its own
(null: the course's chat); the result of applying it is posted there too.

**Figures** come from a scan (since 2026-10-22): the cheap model looks at every slide once, small, and marks the
ones with a graph, diagram or chart worth showing, whatever their text. A topic's figures are picked from its marked
pages (up to 6 shown to the writer, at most 4 on a page). Files not scanned yet fall back to their pages with the
least text. The scan runs before notes are written, and with `POST /v1/notebook/figures`.

### Who writes the notes

Since 2026-10-22 (`engine.py`): the heavy study jobs (lecture notes, the notebook, the answer checks and the slide
scan) go through OpenRouter (paid, the default) or the user's Claude plan, through Claude Code logged in on the
server (`claude -p`; Sonnet writes, Haiku reads; no API key, so it counts against the plan's limits). Chat is
always OpenRouter.

Since 2026-10-26, a second switch, `background`, does the same for the work nobody waits on: routines and watches
(their tool loop runs in Claude Code through the Claude Agent SDK, with Aide's own tools, so queued actions and a
watch's read-only rule work as before), digest greetings and leave-by plans, mail drafts, chat titles and the
objectives planner. On the plan they use the same tier as on OpenRouter (Haiku, Sonnet for the planner). At the
plan's limit they go to OpenRouter without asking, until the reset; a routine whose run fails on the plan before
it calls any tool runs on OpenRouter instead. The two switches are independent.

When the plan's limit is reached mid-job, the job pauses and Professor asks in the course's chat
(with a push): wait for the reset, or finish on OpenRouter until then. Nothing goes to OpenRouter without that
answer; with no answer, the job carries on by itself after the reset. Professor's `notes_writer` tool switches and
answers too.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/writer` | | Writer |
| `PUT /v1/writer` | `{"engine": "claude" or "openrouter", "background": "claude" or "openrouter"}`, either or both | Writer. `409` Claude Code isn't on the server. |
| `POST /v1/writer/decide` | `{"use": "wait" or "openrouter"}` | Writer: the answer to a pause. `409` nothing is waiting. |

Writer: `{"engine": "openrouter", "background": "openrouter", "available": true, "usage": {"five_hour": {"used": 0.25, "resets_at": "…Z"},
"seven_day": {"used": 0.5, "resets_at": "…Z"}} or null, "paused": {"since": "…Z", "resets_at": "…Z" or null,
"window": "five_hour", "course": 2 or null} or null, "openrouter_until": "…Z" or null}`. `available`: Claude Code is
installed on the server. `usage`: the plan's windows as Claude Code last reported them (`used` from 0 to 1; null
until the plan has been used once). `openrouter_until`: the user chose OpenRouter at a pause, until then.

### Practice exams

Since 2026-10-21 (`quiz.py`): a practice exam from a notebook's own multiple-choice questions, scored like the exam
(right +1, wrong −0.25, blank 0). No model call. Questions last answered wrong or left blank come first, then those
never seen, then the ones answered right longest ago, spread over the topics, in a shuffled order. The app keeps the
time (`minutes`) and sends the answers at the end; when it's finished, Professor posts the score and the weakest
topics in the course's chat (and knows which questions were missed, to go through them there).

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/quizzes?course=2` | | Bank. `404` no such course. |
| `POST /v1/quizzes` | `{"course": 2, "count": 30, "minutes": 45, "topics": ["t_…"]}`; `count` 1–60 (default 30, fewer when the bank is smaller), `minutes` null (default) for untimed, `topics` null for all | `201`, Quiz without keys. `409` the notebook has no questions. |
| `GET /v1/quizzes/{id}` | | Quiz (with keys once finished). `404`. |
| `POST /v1/quizzes/{id}/finish` | `{"answers": {"1": "B", "2": null}}`, by question number; left out or null is blank | Quiz, finished. `409` already finished. |

Bank: `{"course": 2, "exam": "20 to 35 multiple-choice questions…" or null, "questions": 65, "unseen": 40,
"to_review": 6, "topics": [{"id": "t_…", "title": "…", "questions": 6}], "scoring": {"right": 1, "wrong": -0.25,
"blank": 0}, "past": [Quiz without questions, newest first, finished only]}`.

Quiz: `{"id": "x_…", "kind": "exam" or "chat" (since 2026-10-27), "course": 2, "minutes": 45 or null, "count": 30, "started_at": "…", "finished_at": "…" or null,
"score": null or {"points": 22.75, "max": 30, "right": 24, "wrong": 5, "blank": 1, "topics": [{"id": "t_…", "title":
"…", "right": 1, "wrong": 2, "blank": 0}] (weakest first)}, "questions": [{"n": 1, "topic": {"id": "t_…", "title":
"…"}, "text": "markdown", "options": [{"letter": "A", "text": "…"}]}]}`. Once finished, each question also has
`"answer": "B" or null, "key": "C", "correct": false, "explanation": "markdown"`. The notes' LaTeX comes as plain
Unicode in `text`, `options` and `explanation` ($\pi_{t-1}$ as πₜ₋₁).

### Quizzes and review sessions

Since 2026-10-27 (`quiz.py`, `reviews.py`, `tools/quiz.py`; #4).

**Quizzes in chat.** "Quiz me" in a course's Professor chat, typed or spoken, starts a quiz there: one question at a
time from the notebook's multiple-choice questions and its flashcards (what was missed last time first, then what's
never been asked, the same order as practice exams, which share the answers). For a flashcard the user answers in
their own words and Professor judges it. Each answer is recorded as it's given, so stopping halfway loses nothing.
Nothing new for the app to call: it's chat. To start one by voice, open the course chat in voice mode and send
"Quiz me" with `"voice": true` (the app's "Quiz me" in a course chat's ••• menu and on the course page).
- These quizzes are Quiz objects with `"kind": "chat"` (`GET /v1/quizzes/{id}` reads one); a flashcard question
  has `"type": "card"`, no `options`, and `answer` `"right"`, `"wrong"` or null. They're not in the bank's `past`,
  and don't count for practice-exam objectives; their answers do count in `unseen` and `to_review`.

**Review sessions.** Professor plans them with the user in the course chat (free time in the calendar, the exam date,
the weakest topics) and, once they agree, puts each in the timetable calendar as "Review: Macroeconomics" with the
topics in its notes. When one starts, Professor says so in the course chat with a push (a plain chat message push,
`conversation_id` the course chat) and offers the quiz on its topics. A session moved in the calendar is followed;
one deleted there is dropped. Review events never count as lectures or courses.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/reviews?course=2` | `course` optional (all courses without it) | `{"sessions": [Session]}`, not yet over, soonest first. `404` no such course. |
| `DELETE /v1/reviews/{id}` | | `{"ok": true}`; takes it off the calendar (the user's tap is the confirmation). `404`. |

Session: `{"id": "v_…", "course": 2, "start": "2026-10-28T15:00:00+01:00", "minutes": 90, "topics": ["The IS-LM
model", "Phillips curve"]}`.

## Habits

Habits are what you always do: they never end, and they keep a streak and a grid. (What a day, week or month is
about is an objective, see Objectives.)

Habit object: `{"id": 3, "name": "Gym", "cadence": {"type": "daily"} | {"type": "weekly", "per_week": 3} | {"type": "limit", "max": 5}, "streak": 4, "done_today": false, "last_done": "2026-10-18" | null, "history": ["2026-10-18", "2026-10-17", …], "workouts": ["strength"], "food": null, "count": null, "counts": {}, "health": null}`.

`workouts` (default `[]`) lists the Apple Watch workout types that check the habit by themselves (see Apple Health,
"Workout types"; `"any"` matches every type). When a health upload has a workout of a listed type that lasted at
least 10 minutes, the server checks the habit for the workout's local date. Each workout (by its `id`) checks a
habit at most once, so if you undo the check, a later upload of the same workout doesn't redo it.

`food` (since 2026-10-26, default `null`) ticks a habit from the food log, like a `food` objective: `"logged"` on
days with a meal logged, `"protein_g"` on days at the protein goal, `"calories"` on days within 10% of the calorie
goal (see Food). Those days count as checked, worked out on every read, so they can't be unchecked by hand; checks
by hand still add to them. "Eat healthy" with `"food": "logged"` ticks itself once a meal is in.

**Limit habits** (since 2026-10-26): `{"type": "limit", "max": 5}` is a daily count that has to stay at or under
`max` (1–100), like "5 coffees a day at most". You log each one (`POST /v1/habits/{id}/count`); nothing logged
means 0.
- `count` is today's count (`null` on other habits). `counts` maps each local date with a count in the last 26
  weeks to it, `{"2026-10-25": 3, …}` (only days over 0; `{}` on other habits), for the trend and the grid.
- A day is done when it ended at or under `max`, so `history` and `last_done` only hold days before today (from the
  day the habit became a limit habit; since 2026-10-27 a count for an earlier day moves that start back to it, so
  filled-in history counts). `done_today` says whether today is still within the limit so far.
- `streak` counts the days before today in a row that were done, and is 0 once today goes over.
- Checking a limit habit (`/check`) is `400`; the count is its check.
- `health` (since 2026-10-26, default `null`): a limit habit can also count from Apple Health. `"inhaler_usage"`
  follows the health day's `inhaler_usage` (Health's Inhaler Usage, where the user may log coffees). A day's count
  is then the larger of Health's number and what was logged here, so one logged in both places counts once. `/count`
  adds to the count as shown (Health's included); taking back can't go below Health's number. `400` on a habit
  that isn't a limit habit, or for another value.
- `health_logged` (since 2026-10-27, only on habits with `health`): each local date in the last 60 days (7 until
  2026-10-27's second change) with something logged through Aide (the app, a widget, or an agent's `count_habit` or
  `fill_habit_days`), net of take-backs, to that number: `{"2026-10-27": 2}`. The app writes these to Health as its
  own Inhaler Usage samples, so the user needn't log twice: for each of the last 60 days it adds or deletes its own
  samples (never the user's) until they match (`{}` or a missing day: 0). An app still on 7 days keeps working. The server sends a `sync` push after each count on such a habit.

`history` is every local date the habit was checked (or done, for the two kinds above) in the last 26 weeks (182
days, today included), newest first, for a GitHub-style grid. Every endpoint that returns a Habit includes it,
`POST /v1/habits/{id}/check` too, and so does the `habits` digest section.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/habits` | | `{"habits": [Habit]}` |
| `POST /v1/habits` | `{"name": "Gym", "cadence": {"type": "weekly", "per_week": 3}, "workouts": ["strength"], "food": null}` (`workouts`, `food`, `health` optional) | the new Habit |
| `PATCH /v1/habits/{id}` | any of `name`, `cadence`, `workouts`, `food`, `health` (`null` turns `food` or `health` off) | the updated Habit |
| `POST /v1/habits/{id}/check` | `{"date": "2026-10-18"}` (optional, default today; send `"done": false` to undo) | the updated Habit |
| `POST /v1/habits/{id}/count` | `{"add": 1}` (default 1; `-1` takes one back, never below 0), `"date"` optional (default today) | the updated Habit. `400` for a habit that isn't a limit habit, or a future date. |
| `DELETE /v1/habits/{id}` | | `{"ok": true}` |

`streak` counts consecutive scheduled periods done: days for a daily habit, Monday-to-Sunday weeks with at least
`per_week` checks for a weekly one. Today (or this week) adds to the streak once it's done, and doesn't break it
while it's still in progress. Names are unique, ignoring case (a duplicate is `400`); checking a future date is
`400`; an unknown id is `404`.

The assistant also gets tools to add, check, count and list habits (deleting is queued for confirmation), so "I
had another one" in chat logs one. Coach sees each limit habit's count today and the last 7 days.

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
  "inhaler_usage": 3,
  "naps": [{"start": "2026-10-19T14:05:00+02:00", "end": "2026-10-19T14:50:00+02:00", "asleep_min": 42}],
  "workouts": [
    {"id": "6B1F0C2E-…", "type": "strength", "start": "2026-10-19T18:30:00+02:00",
     "end": "2026-10-19T19:22:00+02:00", "minutes": 52, "kcal": 310}
  ]
}
```
- **Missing or `null` means no data** for that field. Every number may be missing.
- `date` is the local calendar day. `steps`, `active_kcal`, `exercise_min`, `inhaler_usage` and `workouts` cover
  00:00–24:00. `inhaler_usage` (since 2026-10-26) is Health's Inhaler Usage count, for a limit habit's `health`.
- `sleep` is the night that **ended** that morning: the longest stretch of sleep that ends between 18:00 the
  evening before and 18:00 on `date`, with gaps under an hour counted as part of it. Naps are left out of it. `bedtime`
  is when sleep started, `wake` when it ended, `in_bed_min` = `wake` − `bedtime`, `asleep_min` = the sleep stages
  added up, `awake_min` = time awake in between. `deep_min`, `core_min` and `rem_min` are `null` without a Watch.
- `naps` (since 2026-10-26; missing when there were none) is the day's other sleep: stretches that start after
  the night's `wake` (or midnight) and before the next midnight, 10 min to 4 h asleep, the same gap rule as the
  night; the next night (an early bedtime) isn't one.
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
- **Delivery:** a `digest` push with `"digest": "wake"` (title "Good morning"), like the scheduled digests.
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

**The app's Today page** (since 2026-10-26, #21) is built from these, each part loading on its own, so one slow
source (the calendar, mail) doesn't hold up the rest. There is no endpoint just for it.
1. The latest digest: `GET /v1/digest?kind=latest`.
2. Waiting for you: `GET /v1/approvals` (actions, proposed objectives, notebook proposals, mail drafts, the writer).
3. Habits and objectives: `GET /v1/habits` and `GET /v1/objectives` (Today / Week / Month).
4. Notes from the team: `GET /v1/activity?kind=routine,watch`, then the whole feed (`GET /v1/activity`).

`POST /v1/reminders/{id}/complete` with `{"completed": true}` (false: not done after all) → the Reminder object.
For the Today widget's tick box, which can't reach Apple Reminders: the server marks it (`modified_at` now, so it
wins the next sync) and sends a silent `sync`, so the app ticks it in Apple Reminders too. `404` for an unknown id.

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
  "deleted": false,                      // tombstone: delete it on the phone too
  "list": "Groceries"                    // its Apple Reminders list, by name; null: the default list
}
```

### Sync

`POST /v1/reminders/sync`
```json
{
  "cursor": "1712",   // from the previous sync; null on the first sync
  "lists": ["Reminders", "Groceries"],  // every Apple Reminders list on the phone, in its order
  "default_list": "Reminders",          // where reminders without a list go
  "changes": [        // reminders changed on the phone since the last sync
    {"id": "6f1c2e…" , "apple_id": "x-apple-…", "title": "…", "notes": "", "due_at": "…",
     "completed": true, "modified_at": "2026-10-18T11:25:03Z", "deleted": false, "list": "Reminders"},
    {"id": null, "apple_id": "x-apple-…", "title": "Buy milk", "notes": "", "due_at": null,
     "completed": false, "modified_at": "2026-10-18T11:26:10Z", "deleted": false, "list": "Groceries"}
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

**Which lists:** every Apple Reminders list. Each reminder carries its list by name (`list`), so the agents can
put one in a list ("milk to Groceries"), move it, or look at one list. The app sends `lists` and `default_list`
with every sync, and the agents may only use those names. Moving a reminder to another list on the phone is a
change like any other. A reminder with `list: null`, or a list the phone no longer has, goes to `default_list`
(the one chosen in Settings, else the system default), and the app then reports where it went. A change without
`list` (an app from before lists) leaves the reminder's list as it is, and a sync without `lists` keeps the last
ones.

**Notification rule (server side):** at `due_at`, if a reminder is still not completed and has no `apple_id` (it never reached the phone), the server sends a `reminder` push (see Push), once. Otherwise Apple Reminders notifies, and the server stays quiet.

**Silent sync:** whenever reminders change on the server, it also sends a silent `sync` push, so the phone syncs (and sets the alarms) without the app being opened. iOS may delay or drop silent pushes, so the triggers above still apply.

## Transit (GTT)

Turin's buses, trams and metro: live arrivals and tram alerts, a push like "Tram 4 in 7 min: leave now". The server
reads GTT's timetable (rebuilt every night) and its live feed; the agents (Aide and Secretary) answer "when's the next
4?" and set alerts in chat. The app shares the phone's location, so an alert knows the walk to the stop, and lists the
alerts in Settings. Off with `AIDE_GTT=0` on the server: the alert endpoints are then `404`.

### Location

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/location` | `{"lat": 45.0625, "lon": 7.6756, "accuracy": 12, "at": "2026-10-22T08:01:00+02:00"}` | `{"ok": true}` |

- `accuracy` in metres, optional. `at` is when the fix was taken, with its offset (default now); a fix older than the
  one the server has is ignored. Only the latest fix is kept.
- The app sends one when iOS reports a significant move (about 500 m, also with the app closed), when it comes to
  the foreground, and when a silent `location` push asks for one (see Push). That needs "Always" location access.
- An alert that fires "when it's time to leave" wants a fix under 10 minutes old: while it's watching, the server
  asks for one (a `location` push) at most every 5 minutes. Without any fix it assumes a 5 minute walk and says so.
- Since 2026-10-27, **while a tram Live Activity is on** the app follows the phone closely (background location
  updates, the blue pill in the status bar) and sends a fix every 20 s or so, or after 40 m, until the last tram
  activity ends. The server uses fixes under 2 minutes old and 200 m accuracy to follow the user (see Live
  Activities, `tram`).

### Departures

`transit_arrivals` in chat comes with a `departures` attachment: a Board per stop with something coming.

```json
{
  "id": "1687:4:Politecnico",
  "stop": {"id": "1687", "code": "253", "name": "Porta Nuova"},
  "at": "2026-10-22T06:00:00Z",
  "distance": 180, "walk": 170,
  "line": "4",
  "to": {"name": "Politecnico", "stops": ["812", "813"]},
  "lines": [
    {"line": "4", "vehicle": "Tram", "towards": "Falchera",
     "arrivals": [
       {"at": "2026-10-22T06:07:00Z", "scheduled": "2026-10-22T06:05:00Z", "live": true, "delay": 120,
        "to_at": "2026-10-22T06:32:00Z", "to_stop": "813"},
       {"at": "2026-10-22T06:15:00Z", "scheduled": "2026-10-22T06:15:00Z", "live": false, "delay": null}
     ]}
  ]
}
```
- `at`: when the board was made. `distance` (metres) and `walk` (seconds) from the phone's last fix (under 2 hours
  old, stop under 2 km away), else null.
- `line`: the line asked for, or null. `to`: where the user is going (null if not asked): only lines that get there
  without a change are kept, and each arrival has `to_at` (the delay carried on) and `to_stop` (the sign's number).
- `lines`: by line and direction, soonest first, up to 4 arrivals each. `at` is expected (live delay included),
  `scheduled` the timetable; `live` false means timetable only, `delay` seconds late (negative early), null then.
- `vehicle`: `Tram`, `Bus`, `Metro` or `Train`.

| Endpoint | Query | Response |
|---|---|---|
| `GET /v1/transit/departures` | `stop` (the board's stop id), `line`, `to` (stop ids, comma-separated), `to_name` | a Board |

The app refreshes a card on screen with it (every 30 s or so), from the card's own `stop.id`, `line`, `to.stops`
and `to.name`. `404` for an unknown stop or GTT off, `400` for an unknown line.

| `GET /v1/transit/nearby` | | `{"boards": [Board], "fix_at": "2026-10-22T08:01:00+02:00" \| null}` |

For the departures widget: Boards for the 2 stops nearest the phone's last fix (under 2 hours old, stops within
400 m, nearest first; each side of the road counts, so it's often both directions) that have something in the next
hour. No usable fix: `boards` empty and `fix_at` the old fix's time or null. `404` with GTT off.

### Tram alerts

An alert watches one line at one stop (each side of the road is its own stop, with the number on its sign):

- **Commute** (`days` set): on those ISO weekdays (`[]` every day), the first tram from about `time` (5 min before
  it at the earliest). Watched from 30 min before `time` to 30 min after; at most one push a day.
- **One-off** (`days` null, `once` true): the next tram (watched for 2 hours), or the first from about `time` (today,
  or tomorrow if that's gone). Deleted once it fires or ends.
- **When:** `minutes` null pushes a few minutes before it's time to leave: when the tram is the walk from the phone
  to the stop, plus 2 minutes at the stop, plus 3 to get going, away (since 2026-10-27; it was the walk plus 2). So
  "Tram 4 in 10 min: leave in 3 min", or "leave now" when that's under a minute. A tram you can't reach in time is
  skipped. `minutes: 10` pushes when it's 10 minutes away.
- Times are live from GTT where it has them (a trip's delay carried on to the later stops), else the timetable,
  and the push says which, and whether GTT's live feed is down. It also says where the tram is ("3 stops away, near
  Politecnico", or when it leaves its first stop).

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/transit/alerts` | | `{"alerts": [alert]}` |
| `PATCH /v1/transit/alerts/{id}` | any of `{"time": "08:20", "days": [1,2,3,4,5], "minutes": 10 \| null, "enabled": false}` | the alert |
| `DELETE /v1/transit/alerts/{id}` | | `{"ok": true}` |

Alerts are made in chat ("every weekday tell me when to leave for the 4 at Porta Nuova around 8:10"); the app lists,
edits and deletes them.

```json
{
  "id": 1, "line": "4", "vehicle": "Tram", "towards": ["Falchera"],
  "stop": {"id": "1687", "code": "253", "name": "Porta Nuova"},
  "time": "08:10", "days": [1, 2, 3, 4, 5], "once": false, "minutes": null, "enabled": true, "event": null,
  "summary": "Tram 4 at Porta Nuova (stop 253), towards Falchera: Mon–Fri around 08:10, when it's time to leave"
}
```
- `vehicle` is `Tram`, `Bus`, `Metro` or `Train`, `towards` the line's directions from this stop. `summary` is the
  whole alert in a line, for the list.
- `event` (since 2026-10-26): the calendar event a leave-now alert was set for, as `"Macroeconomics at 09:30"`, else
  null. Its push ends with "For Macroeconomics at 09:30."

### Leaving for an event

Since 2026-10-26 the server sets tram alerts for the calendar by itself: for a timed event with a place in the next 3
hours, it asks Maps for the ways there by transit from where the phone is (to be there 10 min early). An event with
no place takes it from memory when the notes say where such events are (a lecture: the uni). Of the ways whose first
ride is a GTT line, it takes the one leaving latest on the line memory says the user prefers there ("I take the 10 to
uni"), else on a frequent line (at least 4 an hour at that stop), else the latest. When leaving for it is under 45 minutes away, it sets a one-off alert for that line at that stop around its
departure, with `event` set, and the alert pushes "Tram 4 in 7 min: leave now" as any other
(live times, the walk from the phone, the Live Activity). Until then the way is looked up again every 10 minutes, or
after a 300 m move.

- One alert per event. Deleting it in the app is final for that event; an event that moves or is deleted takes its
  alert with it.
- None when the phone is within 500 m of the place or over 20 km away, when a note in memory says the user walks,
  drives or cycles there, when the first ride isn't GTT's (a train), or when one of the user's alerts for that line
  already watches that time.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/transit/settings` | | `{"calendar": true}` |
| `PATCH /v1/transit/settings` | `{"calendar": false}` | the settings |

`calendar` (default true) turns the event alerts on or off. `404` when the server can't make them (GTT off, or no
calendar or Maps key).

## Screen Time

Locks shield the phone's apps on a schedule or for a while (since 2026-10-27, #23). The server keeps the locks; the
phone sets them itself with Apple's Screen Time API (DeviceActivity and ManagedSettings), so they start and end on
time with the app closed. What a lock shields is chosen on the phone and never leaves it (Apple's tokens are
device-only): every app except the ones the user allows (Phone and emergency calls always work). Coach sets locks in
chat (`lock_now`, `add_lock_schedule`); ending one early there is queued and needs the user's reason.

- **One-off** (`once` true): from `starts_at` to `ends_at`, 15 minutes to 24 hours. Dropped once over.
- **Schedule** (`once` false): every week from `start` to `end` (HH:MM local; an `end` before `start` is the next
  morning, and the two can't be the same) on the ISO weekdays in `days` it starts on (`[]` every day). At least 15 minutes (DeviceActivity's floor).
- **Unlocking early** takes a reason, which Coach sees for a week. A one-off is gone; a schedule is open until this
  time's end (`open_until`) and comes back next time. A lock that's on can't be moved or turned off with `PATCH`:
  that's unlocking early.
- **Strict** (`strict` true): once on, it ends early only with an emergency pass (`"pass": true` on the unlock,
  still with a reason); there are 3 a calendar month (`passes`). It can't be loosened (`strict: false`) or deleted
  while it's on, and Coach can't end it from chat. Making a lock strict is fine any time. While one is on, the app
  locks its Screen Time page, leaving only the emergency pass.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/locks` | | `{"locks": [lock], "device": {"authorized": true, "allowed_apps": 3, "at": "…"}, "passes": {"left": 2, "month": 3, "renews": "2026-11-01", "used": [{"title", "reason", "at"}]}}` |
| `POST /v1/locks` | `{"title": "Focus", "minutes": 60}` (a one-off from now) or `{"title": "Bedtime", "start": "23:00", "end": "07:00", "days": []}`; either with `"strict": true` | the lock |
| `PATCH /v1/locks/{id}` | any of `{"title", "start", "end", "days", "enabled", "strict"}` (a one-off: only `title` and `strict`) | the lock; `400` for a lock that's on now (but the title, or making it strict) |
| `POST /v1/locks/{id}/unlock` | `{"reason": "a call with my sister"}`; a strict lock also `"pass": true` | `{"lock": lock}` (a schedule), `{"lock": null}` (a one-off, now gone); `400` if it isn't on, if it's strict without a pass, or no passes are left |
| `DELETE /v1/locks/{id}` | | `{"ok": true}`; `400` for a strict lock that's on |
| `PUT /v1/locks/device` | `{"authorized": true, "allowed_apps": 3}` | what the server now knows |

```json
{
  "id": 2, "title": "Bedtime", "once": false, "start": "23:00", "end": "07:00", "days": [7, 1, 2, 3, 4],
  "starts_at": null, "ends_at": null, "enabled": true, "strict": false, "agent": "coach",
  "locked": true, "until": "2026-10-28T07:00:00+01:00", "open_until": null, "next": "2026-10-28T23:00:00+01:00",
  "summary": "Sun, Mon, Tue, Wed, Thu 23:00–07:00"
}
```
- `locked` and `until`: on right now, until then. `open_until`: unlocked early, open until then. `next`: the next
  start (null for a one-off already started, or a schedule that's off). `agent`: who set it, null for the user.
- Every change (from chat or the app) sends a silent `sync` push; the app fetches the list and sets the device's
  schedules (one DeviceActivity per lock, repeating daily for a schedule; the monitor checks `days` and
  `open_until` when it starts). It also syncs after every chat turn and when it opens.
- Which apps a lock covers is picked on the phone and stays there (Apple's app tokens only mean something on that
  device): the usual "everything but these", or per lock its own, either everything but some apps or only some
  (`LockBook.apps`). A lock without its own, like one set in chat, uses the usual.
- The app sends `PUT /v1/locks/device` when it opens and when Screen Time access or the allowed apps change, so the
  agents can say when locks won't hold.

## Push

The server notifies the phone through APNs. It sends only when it has a key (`APNS_*` in `.env`) and at least one registered device; otherwise nothing is sent and everything is still in the app.

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
| `sync` | silent (`content-available: 1`, push type `background`, priority 5) | reminders changed on the server, a habit with `health` was counted, a meal or a Screen Time lock changed | | (not shown) the app runs a reminders sync, writes `health_logged` and meals to Health, and sets the locks |
| `reminder` | alert | due, but not on the phone (see the notification rule) | `reminder_id` | opens Today |
| `digest` | alert | a scheduled digest, or the wake-up briefing, is ready | `digest` (`daily`, `wake`, `evening`, `weekly`, `monthly`) | opens Today on the digest (since 2026-10-26; before: a new chat with it) |
| `message` | alert | an agent writes first: a routine or watch, lecture notes, a notebook proposal | `conversation_id`, `routine` (a routine's or watch's post only) | with `routine`: opens Today on that note; else that conversation |
| `lecture` | alert | a lecture's notes are ready, or it failed (title "Professor · macroeconomics") | `lecture_id` | opens that lecture |
| `moodle` | alert | a Moodle sync brought new files (title "Moodle · 3 new files", a line per course naming them: "Macroeconomics: Lecture Notes: Monetary Policy, Lect: Monetary Policy"), or the login expired | `files` (the new files' ids, up to 20; since 2026-10-26), `login` (true: log in again) | lists the new files (`GET /v1/files/{id}`), each opening its PDF; the Moodle login with `login` |
| `transit` | alert, `interruption-level: time-sensitive` | a tram alert fires ("Tram 4 in 7 min: leave now") | `alert_id` | nothing special (opens the app) |
| `location` | silent (like `sync`) | a tram alert wants to know where the phone is | | (not shown) the app sends a fresh fix to `POST /v1/location` |
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
- A scheduled digest is pushed to every device.
- Silent `sync` pushes are coalesced: at most one per 10 seconds, so a burst of changes sends one.

## Live Activities

Three kinds on the Lock Screen and in the Dynamic Island, all drawn by the app's widget extension:

- **`tram`**: a tram alert's countdown. When an alert fires, the server starts it (APNs push-to-start) instead of
  the `transit` push, then keeps it live (the tram's expected time, its delay, the next one) until the tram has left,
  or, once the user is on it, until they get off.
- **`agent`**: an agent at work. The app starts one when it sends a chat or Team chat message; the server keeps it
  up to date (asking another agent, writing) and ends it with the reply's first line, so a reply that comes in with
  the phone locked lights up the screen. The server also starts one for each scheduled routine run (not watches),
  and since 2026-10-27 one for Professor writing notes (a notebook proposal being applied, a lecture's notes).
- **`event`** (since 2026-10-27): the next calendar event's countdown, started by the server 30 minutes before a
  timed event ("Macroeconomics in 30 min · Aula 5"), unless leave-now has set a tram alert for it.

The app needs iOS 17.2 for push-to-start; older phones get the plain pushes as before.

### Tokens

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/live/tokens` | `{"kind": "tram" \| "agent" \| "event", "token": "80f1…", "environment": "sandbox" \| "production"}` | `{"ok": true}` |
| `DELETE /v1/live/tokens/{kind}` | | `{"ok": true}` |
| `POST /v1/live/activities` | `{"key": "agent:3f2a…", "token": "a91c…", "environment": "sandbox"}` | `{"ok": true}` |
| `DELETE /v1/live/activities/{key}` | | `{"ok": true}`, also for an unknown key |
| `GET /v1/live/settings` | | `{"events": true}` |
| `PATCH /v1/live/settings` | `{"events": false}` | the settings |

- `/v1/live/tokens`: a **push-to-start** token (`Activity<…>.pushToStartTokenUpdates`), one per kind; a new one
  replaces the old. The app sends it on launch and when it changes, and deletes it when Live Activities are turned
  off for Aide in iOS Settings. With no `tram` token the server sends the plain `transit` push.
- `/v1/live/activities`: one activity's **update** token (`activity.pushTokenUpdates`), by the `key` in its
  attributes. For an activity the server started, the app gets its token in a short background wake and sends it.
  The app deletes the key when it ends an activity itself (the reply came in with the app open); the server then
  stops pushing. Keys and tokens older than 12 hours are dropped. Since 2026-10-27, an activity the server started
  and ended before its token came (a short job) is ended as soon as the token comes, within an hour.
- `/v1/live/settings` (since 2026-10-27): `events` (default true) turns the `event` countdowns on or off.
- Tokens are hex, like device tokens; `environment` as for devices. A token APNs refuses (`410`, `BadDeviceToken`)
  is deleted.

### Pushes

Push type `liveactivity`, topic `<bundle id>.push-type.liveactivity`, to the token. Priority 5 for routine updates
(no budget), 10 for start, end and updates with an `alert`.

```json
{"aps": {"timestamp": 1761120120, "event": "start",
         "attributes-type": "TramActivityAttributes",
         "attributes": {"key": "tram:1:7712345:20261022", "line": "4", "vehicle": "Tram", "stop": "Porta Nuova",
                        "code": "253", "towards": "Falchera", "alert": 1},
         "content-state": {"at": 1761120540, "leave": 1761120120, "walk": 300, "live": true, "delay": 120,
                           "next": 1761121140, "gone": false},
         "stale-date": 1761120660,
         "alert": {"title": "Tram 4 in 7 min: leave now", "body": "Porta Nuova (stop 253), towards Falchera. …",
                   "sound": "default"}}}
```

- Field names in `attributes` and `content-state` are what ActivityKit decodes, so they're single words (no
  snake_case), and **times are Unix seconds** (not ISO strings).
- `event` is `start` (push-to-start, with `attributes-type`, `attributes` and `alert`), `update` or `end` (with
  `dismissal-date`, Unix seconds; now dismisses it at once).

**`tram`** (`TramActivityAttributes`). Attributes: `key` (`tram:<alert id>:<trip>:<service day>`), `line`,
`vehicle` (`Tram`, `Bus`, `Metro`, `Train`), `stop` (name), `code` (the sign's number), `towards` (or null),
`alert` (the alert's id). Content state:

| Field | Meaning |
|---|---|
| `at` | when the tram is expected at the stop (live delay included) |
| `leave` | when to leave: `at` minus the walk minus 2 minutes (so you're at the stop early), or null for an "N minutes away" alert |
| `walk` | seconds from the phone to the stop, or null when the location isn't known |
| `live` | false: timetable only |
| `delay` | seconds late (negative: early), null when not live |
| `next` | the next one's expected time, or null |
| `gone` | the tram has left the stop (the last update, sent with `end`) |
| `stops` | since 2026-10-27: the stops it has still to reach before yours (0: yours is its next), or null |
| `near` | since 2026-10-27: the stop it's at or has just left (its first stop, before it sets off), or null |
| `starts` | since 2026-10-27: when it leaves its first stop, if it hasn't yet; else null |
| `feed_down` | since 2026-10-27: GTT's live feed isn't coming through, so `live` is false for every tram |
| `at_stop` | since 2026-10-27: the phone is at the stop (show that instead of when to leave) |
| `riding` | since 2026-10-27: the user is on it. Then `at` is when it gets to `to` (or, without one, to `near`), `near` is its next stop, `stops` the stops before `to` (0: `to` is next; null without `to`), and `leave`, `walk`, `delay`, `next` are null |
| `to` | since 2026-10-27: where the user gets off (the first ride's stop from Maps, for leave-now and "be there by"), or null |

The server updates it every 30 s or so when `at` or `leave` moves by 30 s or more, or the tram reaches another stop
(`stops`, `near`, `starts`), or `live`, `next`, `feed_down` or `at_stop` change, sets `stale-date` to `at` plus 2
minutes.

Since 2026-10-27 it follows the user with the app's fixes (see Location):
- **Before the tram:** the walk and `leave` are worked out again from each fix, and the tram is the first the user
  can make: an earlier one once they're closer (or at the stop), a later one when they can no longer make it (a
  minute's hurry allowed). A switch is an `update` with an `alert` ("Tram 4 in 2 min"); the key stays the same.
- **When it comes:** a phone moving along its line, away from the stop, is on board: `riding`. Still at the stop 90 s
  after the tram's time, the user missed it, and the next one is followed (with an alert). Neither (off the line, or
  no fixes): it ends as before, about 1 minute after `at`; with fixes, a fix has up to 4 minutes to say.
- **On board:** an `update` with an `alert` ("Porta Susa is next": get off at the next stop) when `to` is next; the
  end, dismissed 2 minutes later, once it has reached `to`, the phone is 600 m from the tram's stretch of line (they got
  off), or it's at its last stop. The end state has `riding` and `gone` true.

**`agent`** (`AgentActivityAttributes`). Attributes: `key` (`agent:<conversation id>`, the Team chat's is
`agent:team`), `agent` (its id; for the Team chat, whoever answers first), `name`, `color` ("#RRGGBB"),
`conversation` (the conversation id, or `team`), `title` (the routine's title, or null for a chat). Content state:

| Field | Meaning |
|---|---|
| `status` | `working`, `asking` (Aide asked another agent), `writing` (the reply is coming), `done`, `failed` |
| `detail` | a few words for `asking` ("Asking Coach") or `failed`; else empty |
| `text` | `done`: the reply's first line, cut to about 140 characters; else empty |
| `since` | when it started working |

- A chat turn: the app starts the activity (status `working`) and registers its key; the server sends `update`s as
  the turn goes (each ask; `writing` once, when the reply starts), at most one per 2 seconds, priority 5. About 3 s
  after the turn ends, if the key is still there, it sends an `update` with `done` and an `alert` (the agent's name,
  the first line), then an `end` dismissed after 30 minutes. A failed turn ends with `failed`, no alert.
- A scheduled routine (not a watch): the server push-to-starts it (key `agent:<routine conversation id>`,
  `title` the routine's), with a quiet alert (title "Coach · Weekly plan", body "Working on it", no sound; a start needs one).
  When the run ends it sends `end` with `done`, dismissed at once: the `message` push that follows is the
  notification.
- A notes job (since 2026-10-27): the server push-starts it under the key `notes:<proposal id>` (a notebook
  proposal being applied) or `notes:<lecture id>` (a lecture of a course), agent `professor`, `conversation` the chat
  the result goes to (the proposal's own, else the course's), `title` the course's name, with a quiet alert
  ("Professor · Macroeconomics", "Writing 5 topics"). Updates as it goes (status `writing`, `detail` the step:
  "Transcribing the lecture", "Writing the notes", "Writing The IS-LM model, Crowding out"), at most one per 2 s,
  then `end` with `done` (`text` the result) or `failed`, dismissed at once: the `message` or `lecture` push that
  follows is the notification. Its content state has two more fields, `done` (topics written so far, failed ones
  included) and `total` (the topics being written); both null on lecture notes and absent on every other agent
  activity.
- Tapping the activity opens the conversation (`aide://conversation/<id>`; the Team chat: `aide://team`).

**`event`** (`EventActivityAttributes`). Attributes: `key` (`event:<12 hex of the uid's hash>:<start, Unix>`),
`title`, `calendar`. Content state: `start` and `end` (Unix seconds; `end` null when there's none), `place` (the
event's location, or null) and `started` (it has begun: the last update).

- Started 30 minutes before a timed (not all-day) event, in any calendar, with a quiet alert ("Macroeconomics in 30
  min", body the place, else "At 09:00"); `stale-date` 10 minutes after the start.
- Not for an event leave-now has set a tram alert for (the tram's activity takes you there); a tram alert set while
  it's on ends it at once.
- An `update` when the event moves or its place changes; `end` with `started` true at the start, dismissed 10
  minutes later; `end` dismissed at once when the event is deleted.
- Tapping it opens Today (`aide://today`).

## Widgets

The app's widget extension reads the server itself, with the server URL and token the app shares with it (an App
Group keychain item), and draws from the last good answer when the server can't be reached. The app reloads the
widgets after a sync, a chat reply, a check-in and the like. They use these endpoints, nothing widget-only except
`POST /v1/reminders/{id}/complete` and `GET /v1/transit/nearby`:

| Widget | Reads | Taps |
|---|---|---|
| Today | `GET /v1/today` | a reminder's tick box: `POST /v1/reminders/{id}/complete`; the rest: `aide://today` |
| Health | `GET /v1/food`, `GET /v1/habits` | a habit: `POST /v1/habits/{id}/check`, a limit habit's +1: `POST /v1/habits/{id}/count`; the rest: `aide://health` (the tab) |
| Objectives | `GET /v1/objectives` (the day's, then the week's) | a hand-ticked one: `PATCH /v1/objectives/{id}` `{"done": true}`; the rest: `aide://objectives` (Today's habits and objectives) |
| Team | `GET /v1/agents` | an agent: `aide://agent/<id>` (its latest chat); the Lock Screen's "Talk to Aide": `aide://voice` |
| Departures | `GET /v1/transit/nearby` | opens the app |
