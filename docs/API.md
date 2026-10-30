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
- `events`: when it listed, searched, created or proposed calendar events. All of a turn's go in one card, in time
  order (since 2026-10-29). An item may carry `change` (since 2026-10-29; absent on a plain listing): `"found"` (a
  search hit), `"created"` (made this turn) or `"proposed"` (in a plan, not yet in the calendar; see Events and plans).
- `meals`: when it logged, changed or listed meals (see Food), `{"type": "meals", "meals": [Meal]}`.
- `departures`: when it looked up GTT arrivals, a card per stop (see Transit), `{"type": "departures",
  "departures": [Board]}`.
- `routes`: when it worked out how long it takes to get somewhere with Google Maps (`travel_time`; since
  2026-10-27), a card per route, `{"type": "routes", "routes": [Route]}`. A Route: `{"id", "mode": "drive" | "walk" |
  "bicycle" | "transit", "from", "to"` (as asked: an address, a place, or "where you are"), `"duration"` (seconds,
  with live traffic when driving), `"usual"` (seconds without traffic, driving only, else `null`), `"distance"`
  (metres), `"depart"`, `"arrive"` (UTC ISO 8601 or `null`: driving, walking and cycling set off now or at the asked
  time; transit, the first ride's departure and the last ride's arrival), `"rides"` (transit, in order, else `[]`:
  `{"line", "vehicle": "Tram" | "Metro" | "Train" | "Bus", "towards", "from", "depart", "to", "arrive"}`, any of them
  `null` when Maps doesn't say), `"url"` (Google Maps directions)`}`.
- `files`: study files a message is about, to open (since 2026-10-26; see Study files), `{"type": "files", "files":
  [File]}`. On Professor's notebook proposals.
- `proposal`: a notebook proposal to answer right there (since 2026-10-26; see Notebook), `{"type": "proposal",
  "proposal": Proposal}`. `/v1/history` gives both as they are now: a proposal's `status`, and files still there.
- `errands`: a browser errand's card (since 2026-10-27; see Browser errands), `{"type": "errands", "errands":
  [Errand]}`: when Aide started or looked up one, and on the messages an errand posts in its chat (needs you, a
  question, ready to confirm, failed). A message's card is the errand as it was then; fetch
  `GET /v1/errands/{id}` for now. Since 2026-10-28 the closing message of a finished errand carries no card of its
  own: the first one follows the errand to its end.
- `purchases`: an order an errand placed (since 2026-10-27; see Browser errands), `{"type": "purchases",
  "purchases": [Purchase]}`, on the errand's last message and when Finance lists them.
- `products`: what an errand found, best first (since 2026-10-28; see Browser errands), `{"type": "products",
  "errand_id": 7, "site": "amazon.it", "products": [Product]}`, on the errand's closing message. The text above it
  is short (which one and why); the cards carry names, prices and links.
- `videos`: a YouTube video Aide or Professor is reading or has read (since 2026-10-30; see Videos), `{"type":
  "videos", "videos": [VideoCard]}`: when one is started (`queued`), on the brief when it's ready, and when it
  failed. `/v1/history` gives each card as the video is now, drops the cards of deleted videos, and shows a video's
  card only on the latest message that has it.
- `quiz`: a finished practice or mock exam (since 2026-10-31; see Practice exams), `{"type": "quiz", "quiz": Quiz
  without questions}`, on Professor's message with the result. The score, right, wrong and blank and the topics are
  on the card; the message's text is what to go over (and an open question's marks).
- `review`: a review session starting (since 2026-10-31; see Quizzes and review sessions), `{"type": "review",
  "review": Session plus "name" (the course's)}`, on Professor's message when it starts.
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
  {"from": "aide", "to": "coach", "text": "The user asks if they should go to the gym tonight. He slept 6h and has a full day.", "ts": "2026-10-19T18:02:11+02:00"},
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
- A quiet turn (an agent asked, a long tool) gets a comment line `: ping` every 15 s (since 2026-10-29), so the
  connection stays open; skip lines that start with `:`.
- **The turn goes on if the app hangs up** (the app in the background, the network gone): the server finishes it
  and saves it as usual. Meanwhile `GET /v1/history` for that chat has `working` (below); once it's gone, the reply
  is in the history. If the app hung up and the agent's Live Activity is gone too, the reply comes as a `message`
  push (see Push).

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

`GET /v1/history?limit=50` → `{"messages": [{"role": "user" | "assistant", "text": "…", "ts": "…", "attachments": [ … ], "consulted": [ … ], "team": [ … ]}], "smart": false}` (`smart`: Think harder is on in that chat, since 2026-10-30)
(`attachments`, `consulted` and `team` as in `/v1/chat`, `[]` on user messages and plain replies; a user message
sent with photos also has `"photos": ["p_…"]`, absent otherwise; reminders in them are reloaded as they are now,
so a reminder ticked since shows `completed: true`, and one deleted since shows `deleted: true`, so hide it). The current conversation's visible text, oldest first, so the chat screen can show what was said before. Tool calls and internal notes are left out.

While a turn runs in that chat (since 2026-10-29), the history also has `"working": {"agent": "aide", "text":
"plan my week", "photos": [], "since": "2026-10-29T15:03:12+01:00"}`: the message being answered, which isn't in
`messages` yet (a turn is saved when it ends), and who answers. Absent otherwise. An app that lost the stream shows
the message with the agent working, and asks again every few seconds until `working` is gone.

## Conversations

The app keeps many chats. Every chat endpoint takes an optional `conversation_id`. **Omitted means the shared conversation, exactly as before**, so old clients keep working. Reminders, the confirmation queue and `POST /v1/confirm` / `/v1/cancel` stay global.

| Endpoint | Body / query | Response |
|---|---|---|
| `GET /v1/conversations` | | `{"conversations": [{"id": "c_91f…", "agent": "aide", "title": "Dentist on Friday" \| null, "preview": "last message text…", "updated_at": "2026-10-18T11:20:00+02:00"}]}` newest first. Includes the first chat (`id` `main`), titled "First chat". A chat with a turn running has `"working": true` (since 2026-10-29). `?q=dentist` (since 2026-10-30): only the chats whose title or messages have it (any case), each with `match`, the latest message line that has it cut to ~50 characters each side (`null` when only the title has it). |
| `POST /v1/conversations` | `{}`, `{"agent": "coach"}`, or `{"digest": "daily" \| "evening"}` | The new conversation (same shape as a list row, `title: null`). `agent` defaults to `aide`; an unknown one is `400`. With `digest`, the chat is Aide's (`agent` is ignored) and starts with that digest's greeting as Aide's first message: it's in `/v1/history` and `preview`, and the model knows it said it. See Digest. |
| `DELETE /v1/conversations/{id}` | | `{"ok": true}`. The shared conversation can't be deleted (400). |
| `POST /v1/chat` | `{"text": "…", "conversation_id": "c_91f…"}` | Same as before, plus `"conversation_id"`. The server sets `title` from the first exchange. |
| `GET /v1/history` | `?limit=50&conversation_id=c_91f…` | As before, for that conversation. |
| `POST /v1/think` | `{"conversation_id": "c_91f…", "on": true}` (both optional) | `{"ok": true, "smart": true}`. Smarter model for that conversation; `"on": false` (since 2026-10-30) goes back to the usual one. `GET /v1/history` says which with `smart`. |

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
 "summary": "Your week's sleep, training and habits in short, with one thing to try next.",
 "conversation_id": "c_7ab…", "next_run": "2026-10-25T18:00:00+02:00", "last_run": null}
```
- `summary` (since 2026-10-30) is one line for the app, to the user: what the routine does, shown under its title.
  The ideas and the starting watches have one (filled in on older ones by title); an agent gives one when it makes a
  routine by chat. `null` on a routine made in the app without one: show the first sentence of `prompt`.
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
| `POST /v1/routines` | `{"agent", "title", "prompt", "time", "days", "enabled", "watch", "summary"}` (`days` default `[]`, `enabled` default true, `watch` default false) | the new routine. `400` for an unknown agent, a bad time or an empty prompt. |
| `PATCH /v1/routines/{id}` | any of `title`, `prompt`, `time`, `days`, `enabled`, `watch`, `summary` | the routine. |
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
  "days", "summary"}]`, offered by the app as one-tap starting points. E.g. Coach "Weekly recap" (Sun 18:00), Secretary
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
 "errands": [ /* browser errands waiting for you: status needs_you or interrupted (see Browser errands) */ ],
 "objectives": [ /* Objective objects with "status": "proposed", for this month, week and day */ ],
 "proposals": [ /* notebook Proposals still pending, plus "course_name" and "conversation_id" (the course chat, or null) */ ],
 "drafts": [ /* reply Drafts waiting to be sent, newest mail first (see Mail drafts) */ ],
 "writer": null,
 "upcoming": [ /* the next 5 enabled routines (watches too), soonest first: Routine objects */ ]}
```
- `waiting` counts actions, objectives, proposals, drafts, errands and the writer's question: the app's badge.
- `actions`: the confirmation queue, with who queued it and from which chat. An action expires 30 min after it's
  queued. Confirm or cancel one with `POST /v1/confirm` / `/v1/cancel` and `{"ids": [42]}`. Since 2026-10-27 an
  action can carry a `detail` object to draw instead of the plain summary (absent otherwise); so far only an errand's
  order, `{"kind": "purchase", …}` (see Browser errands). `detail` is on `pending` rows too.
- `errands` (since 2026-10-27): Errand objects that need you (log in, answer, or go on after a restart); open the
  live view, answer with `POST /v1/errands/{id}/reply`, or cancel.
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
 "why": "Anna asks if Friday at 8 works", "body": "Friday at 8 works for me. See you then!\nMarco",
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
    {"type": "sleep", "title": "Last night", "sleep": { /* Sleep object, see Apple Health */ }, "usual_asleep_min": 438,
     "score": 84},
    {"type": "recovery", "title": "Recovery", "level": "good", "summary": "HRV above your usual, resting heart rate normal.",
     "score": 72, "hrv_ms": 61.5, "hrv_usual_ms": 55.0, "resting_hr": 52, "resting_hr_usual": 54},
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
  Since 2026-10-30 both carry `score`, the day's Sleep and Recovery scores (Apple Health, "Scores"; `null` while
  they can't be worked out). When the recovery `score` is there, `level` comes from it (under 34 `low`, under 67
  `normal`, else `good`) instead of the rule above.
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
owns food (it sees it next to sleep, training and habits); Aide hands meals to Coach.

Meal object:
```json
{"id": 12, "name": "Pasta al pomodoro", "eaten_at": "2026-10-21T13:10:00+02:00", "calories": 650,
 "protein_g": 20, "carbs_g": 110, "fat_g": 15, "water_ml": 0, "caffeine_mg": 0, "photo": "p_3f9a…",
 "notes": "about 120 g dry pasta", "emoji": "🍝"}
```
`photo` is null without one. `emoji` (since 2026-10-29, always there) is Coach's for the meal, else one guessed from
the name (`🍽️` when nothing fits); the app's list shows it and the photo only on the meal's page. Numbers are rounded (calories to 10, grams to 1): the model's estimates, or (since
2026-10-29) added up by the server from the meal's items, each a saved food's values per 100 g times the grams eaten.
A meal logged from items has them as the first line of `notes` (`"Items: Yogurt greco 0% 170 g, Fiocchi d'avena 40 g"`),
then whatever the model noted; no new fields.
`water_ml` and `caffeine_mg` (since 2026-10-27) are 0 when there's none: a drink is logged like a meal ("an espresso
and 1 L of water" is one, 5 kcal, 1030 ml water, 65 mg caffeine).
On `GET /v1/food` and in chat's `meals` cards (since 2026-10-29, not on `/v1/food/meals`) a Meal also has its items
and their quality:
```json
"items": [{"name": "Mela", "grams": 150, "kcal": 78, "grade": "a", "nova": 1, "quality": 100}], "quality": 97
```
`quality` (0–100, null without enough data) is the day score's quality recipe on the meal alone (and each item's on
the item alone), with fibre, fruit and veg and salt counted per 2000 kcal of it, so a plate of vegetables is full of
fibre for its calories and a pastry isn't. `grade` is the item's Nutri-Score, `nova` its processing group, each null
when its food doesn't say. A meal logged without items has `"items": []` and `"quality": null`.
Since 2026-10-30 a Meal also has `quality_parts`, what its `quality` is made of (null with no items): `{"nutrients":
{"score": 100, "weight": 50}, "processing": {"score": 100, "weight": 25}, "grades": {"score": 87, "weight": 25}}`,
each part's `score` 0–100 or null without data, as the day score's `parts` (below), `weight` in % of the quality.

**Apple Health** (since 2026-10-27): the app writes every meal of the last 14 days as its own food entry (a
`food` correlation: energy, protein, carbs, fat, and water and caffeine when not 0, named after the meal, with the
meal's id in its metadata), from `GET /v1/food/meals`, and changes or removes its entries when a meal changes or
goes. The server sends the silent `sync` push after every meal change, so this happens with the app closed too.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/food?date=2026-10-21` | (default today) | `{"date": "2026-10-21", "meals": [Meal] (by time), "totals": Totals, "goals": Goals, "base": Goals, "left": Goals, "bonus": Bonus, "score": Score \| null}`: since 2026-10-29 `goals` is the **day's** targets (the base plus its workouts), `base` the rest-day ones, `left` the goals minus the totals (null without a goal; negative when over) |
| `GET /v1/food/meals?from=2026-10-15&to=2026-10-21` | (default the last 7 days; at most 92) | `{"meals": [Meal]}`, oldest first (since 2026-10-27, for Apple Health) |
| `GET /v1/food/days?from=2026-10-15&to=2026-10-21` | (default the last 7 days) | `{"days": [{"date": "2026-10-21", "totals": Totals, "meals": 3, "score": 82}]}`, oldest first, every day included (zeros when empty; `score` null when nothing was eaten, since 2026-10-29) |
| `POST /v1/food/log` | `{"photos": ["p_…"], "text": "half of it", "date": "2026-10-20", "barcodes": ["8001505005707"]}` (`photos` or `text` needed; `text`, `date` and `barcodes` optional; `barcodes`, at most 4, are the ones the app read in the photos, and Coach looks each up) | `{"reply": "Pasta al pomodoro, about 650 kcal…", "meals": [Meal], "conversation_id": "c_…"}`: Coach logs it in its "Food log" chat (made once, then reused), so a correction can follow there. `meals` is the meals its tools showed: logged, changed or listed (can be empty when it only asked something). 5–30 s. |
| `PATCH /v1/food/meals/{id}` | any of `name`, `eaten_at`, `calories`, `protein_g`, `carbs_g`, `fat_g`, `water_ml`, `caffeine_mg`, `notes` | the Meal |
| `DELETE /v1/food/meals/{id}` | | `{"ok": true}` (the user deleting from the app: immediate) |
| `GET /v1/food/barcode/{code}` | | `{"food": Food \| null}` (since 2026-10-29): a scanned barcode's saved food, else Open Food Facts' product (saved on the way); `null` when neither has it. 502 when Open Food Facts can't be reached. No model call. |
| `POST /v1/food/label` | `{"barcode": "8000000000001", "photo": "p_…", "name": "Avena"}` (`name` optional) | `{"food": Food}`: one model call reads the nutrition facts in the photo (per 100 g, the serving, the name and brand when shown) and saves them for the barcode, so the next scan finds it. 422 with the reason when it can't be read (try another photo). 5–30 s. |
| `POST /v1/food/foods/{id}/log` | `{"grams": 30, "date": "2026-10-28", "conversation_id": "…"}` (all optional) | `{"meal": Meal}`: logs a saved food as a meal, the server's own sum (no model call). No `grams`: the usual portion, else one serving, else 400. The meal is named after the food (and its brand), `notes` is its items line, and the grams become the usual portion. Coach also posts "Logged …" with its `meals` card in the Coach chat `conversation_id` names (where it was scanned), else in the Food log chat (since 2026-10-29). |
| `GET /v1/food/goals` | | Goals (the base) |
| `PUT /v1/food/goals` | Goals | Goals (sets the base) |
| `GET /v1/food/targets` | | Targets (since 2026-10-29), plus `"coach": {"model": "Claude Sonnet 5.5", "via": "plan"}`: who answers a proposal (`via`: `plan`, the Claude plan through Claude Code; `openrouter` or `api`, paid per token), and `"weight"`: the weight summary ("Apple Health", Weight) |
| `PUT /v1/food/targets` | any of `base` (Goals), `workouts` (any of its keys), `profile` (any of its keys; `null` clears one) | Targets; 400 with the reason when a value is out of range |
| `POST /v1/food/targets/propose` | optional `{"answers": [{"question": "Is 65 kg still right?", "answer": "66 now"}]}` (up to 4; empty answers are left out) | `{"base": Goals, "workouts": {"on": true, "share": 0.8, "carbs_pct": 75}, "why": "You run 4 times a week…", "questions": ["Is 65 kg still right?"]}`: Coach's proposal (one model call, 5–30 s) from the profile, 60 days of Apple Health (resting and active energy, workouts with distance and pace, VO2 max, weight; the Watch's resting energy, not a formula) and the last 14 days of food. `questions` (since 2026-10-29, up to 2, often none) are what would change the numbers; the app sends the answers back with the questions for a new proposal. Nothing is saved: the app shows it and PUTs what the user keeps. 502 when the model fails or answers oddly. |

Totals: `{"calories": 1840, "protein_g": 96, "carbs_g": 210, "fat_g": 61, "water_ml": 1500, "caffeine_mg": 130}`
(the last two since 2026-10-27). Goals has the first four keys, each a
number or null (no goal); all null until set, here or by Coach in chat ("aim for 140 g protein").

**Targets and the day score** (since 2026-10-29). Targets:
```json
{"base": {"calories": 2500, "protein_g": 140, "carbs_g": 300, "fat_g": 80},
 "workouts": {"on": true, "share": 1.0, "carbs_pct": 80},
 "profile": {"weight_kg": 74, "height_cm": 180, "age": 22, "sex": "male", "goal": "perform",
             "note": "Half marathon in March"}}
```
- `base` is the rest day (the same as Goals). On a day with workouts, their Watch kcal times `share` (0–1.5) is
  added: `carbs_pct` (0–100) of it as carbs (4 kcal/g), the rest as fat (9 kcal/g); protein stays. Calories round to 10.
- Only workouts the Watch recorded count. (Until 2026-10-30 a run in today's calendar counted before it happened,
  `planned: true`; it's gone: the run may not happen, and its length was a guess. `planned` stays, always false.)
- `profile` (each key may be null; `sex` is `male` or `female`, `goal` `lose`, `keep`, `gain` or, since 2026-10-29,
  `perform`: eating for training and racing at a steady weight) is what proposals start from; the app fills it from
  Apple Health. `note` (since 2026-10-29, up to 500 characters) is what the user tells Coach in their own words.
- Targets are optional: without them the day score is quality alone.

Bonus: `{"kcal": 656, "planned": false, "share": 1.0, "workouts": [{"type": "run", "kcal": 656, "minutes": 54}]}`;
`{"kcal": 0, "planned": false, "workouts": []}` without any. `share` (since 2026-10-30) is the targets' `workouts.share` the workouts' kcal were multiplied by.

Score: `{"score": 82, "final": false, "numbers": 90, "quality": 70, "graded": 0.85, "grades": {"a": 640, "b": 300,
"c": 400, "d": 0, "e": 120}, "parts": {"nutrients": 74, "processing": 60, "grades": 68}, "nutrients": {...},
"processing": {"upf_pct": 26, "score": 60}}`, null before anything's eaten. 0–100, no model call:
- `numbers` (60%): calories within 10% of the day's target, carbs and fat within 15%, protein at or above it get full
  marks, falling to 0 at 50% off (weights 40, 30, 15, 15). Today isn't `final`: only going over costs, as there's
  still time to eat. A day without goals is quality alone.
- `quality` (40%), since 2026-10-29 three `parts`, each 0–100 or null without enough data, weighed 50/25/25 (and
  again over those there are; null, and the score is numbers alone, when none is):
  - `nutrients` (50%): the mean of the day's nutrients against guidelines, each scored on a straight line:

    | key | value | full marks | 0 |
    |---|---|---|---|
    | `fibre` | `{"g": 22, "target": 30, "score": 60}` | ≥ 30 g | ≤ 10 g |
    | `fruit_veg` | `{"g": 310, "target": 400, "score": 78}` (fruit, veg and legumes) | ≥ 400 g | 0 g |
    | `sat_fat` | `{"pct": 9.2, "limit": 10, "score": 100}` (% of the day's kcal) | ≤ 10% | ≥ 20% |
    | `sugars` | `{"pct": 12.1, "limit": 10, "score": 86}` (free sugars: those not from fruit and veg) | ≤ 10% | ≥ 25% |
    | `salt` | `{"g": 4.1, "limit": 5, "score": 100}` | ≤ 5 g | ≥ 10 g |

    Each is null unless items that carry it are half the day's kcal. Limits are scaled up to the whole day by that
    share; fibre and fruit and veg aren't (missing data earns nothing), and before the day's over (not `final`)
    they're 100, as there's still time.
  - `processing` (25%): `upf_pct`, the share of the kcal (of those with a NOVA group) from ultra-processed foods
    (NOVA 4); ≤ 10% is 100, 50% or more is 0. Null when foods with a NOVA group are under half the day's kcal.
  - `grades` (25%): the day's items' grades weighted by their kcal (A 100, B 75, C 50, D 25, E 0); null when graded
    items are under half the day's kcal (`graded` is that share). `grades` is the kcal eaten per grade.

  Meals logged without items have none of these.

A food's grade is its Nutri-Score (the 2023 rules, with their own for fats, oils and nuts, drinks, cheese and red
meat; so extra virgin olive oil is B): Open Food Facts' when it has one, else worked out from its numbers per 100 g.
Food has `grade` (`a`–`e`, null when it can't be worked out) and `nova` (the processing group 1–4: Open Food Facts',
or Coach's estimate for a plain food; null without). Coach gives a new food's sugars, saturated fat, fibre, salt, fruit
and veg share, kind and NOVA group as it logs it, and a nutrition label's photo is read for them too (all but NOVA).

Coach gets `log_meal`, `update_meal`, `list_meals`, `set_food_goals` (immediate) and `delete_meal` (queued).
It logs a meal when a photo shows food you're eating or ate, or when you say what you had, and says the numbers in
a line so you can correct it. A photo that isn't food is just a photo. Coach's role is now "Sleep, training, food and
habits" (since 2026-10-21), and the `food` connector ("Food log") shows on Coach.

**Saved foods** (since 2026-10-29, server only): the foods you eat, per 100 g, with your usual portion (the last one
you had) and how often you eat them. Coach looks each item up with `find_food` before guessing: the saved foods
first, then Open Food Facts (packaged food; by name, or exactly by barcode, which saves it). What isn't there comes
from `web_search`, a nutrition label in a photo, or Coach's own estimate for a plain food, saved once with
`save_food` (`update_food` corrects one), so the same food gives the same numbers every time. `log_meal` and
`update_meal` take only `items` (a saved food with its grams, or a new food with Coach's numbers per 100 g, saved as
it's logged), and the server adds them up; Coach can't log totals guessed in one go any more. Open Food Facts' "100 g"
serving with nothing else said is its placeholder, not a serving.

Food object: `{"id": 7, "name": "Nocciolata", "brand": "Rigoni di Asiago", "barcode": "8001505005707", "kcal_100g":
544, "protein_100g": 8.1, "carbs_100g": 54, "fat_100g": 32, "serving_g": 15, "usual_g": 30, "source": "off", "grade": "e",
"nova": 4}` (`grade` and `nova` since 2026-10-29); per
100 ml for a drink; `serving_g` and `usual_g` can be null; `source` is `off` (Open Food Facts), `label`, `web`,
`estimate` or `user`. Barcodes in the app (since 2026-10-29): it reads them in a meal's photos on the phone. One
photo with a barcode is a lone packet: `GET /v1/food/barcode/{code}`, how much (empty is the usual portion or one
serving), `POST /v1/food/foods/{id}/log`, no model call; a barcode nobody has asks for a photo of its label, `POST
/v1/food/label`, then the same. More photos go to `POST /v1/food/log` with their `barcodes`. Coach's chats read them too: one photo with a barcode
opens the same sheet, logged with that chat's `conversation_id`.

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
Since 2026-10-31 it also has `"mastery": [{"id": "t_…", "title": "…", "known": 4, "learning": 2, "unseen": 3}]`, a
row per written topic in the notebook's order: its multiple-choice questions and flashcards last answered right
(`known`), wrong or blank (`learning`), never (`unseen`), from every practice exam, mock and quiz. The app draws a dot
per topic from it.
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
| `GET /v1/moodle` | | `{"enabled": true, "site": "https://elearning.unito.it/sme", "connected": true, "user": "Marco Rossi", "last_sync": "2026-10-21T14:00:00+02:00" or null, "error": null or "the Moodle login has expired", "courses": [MoodleCourse]}`; `{"enabled": false}` without `AIDE_MOODLE_URL`. Not connected: `user` null, `courses` empty. |
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
- with a notebook (below): `00 Introduction.md` (the exam, how to prepare, the topics, practice, lectures and files),
  a page per topic (`01 The IS-LM model.md`), `Formulas.md` (every topic's formulas), `Exercises/` (a topic's
  solved exercises, `01 The IS-LM model.md`), `Cards/` with each topic's flashcards for the Spaced Repetition plugin and
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
| `GET /v1/notebook/formulas?course=2&plain=true` | | `{"course": 2, "body": "markdown"}`: the formula sheet (below). `body` is `""` when no topic has formulas. `404` no such course. |
| `GET /v1/topics/{id}?plain=true` | | Topic with `body` (markdown), `cards_list` `[{"q", "a"}]` and `sources` (`["Week 3 slides, p. 1–2"]`). `404`. In `body`, a figure is `![The IS curve shifting right](figure:f_…/12)`: page 12 of that study file, with its caption. |
| `GET /v1/proposals?course=2&status=pending` | | `{"proposals": [Proposal]}`; both optional; `status` `pending` (default) or `all`. |
| `POST /v1/proposals/{id}/apply` | `{"items": [1, 3], "note": "keep it short"}`, both optional (all items) | `202`, the Proposal, `status` `applying`. `400` an item out of range; `409` not pending. |
| `POST /v1/proposals/{id}/decline` | | the Proposal, `declined`. `409` not pending. |

Notebook: `{"course": 2, "started": true, "busy": false, "step": "Writing The IS-LM model, Crowding out" or null,
"exam": "20–35 multiple-choice questions, −0.25 for a wrong answer…" or null, "introduction": "markdown" or null,
"topics": [Topic], "proposals": [Proposal], "writing": Proposal or null, "formulas": 3, "exercises": 2, "mocks": 1}` (`busy`: being written;
`step`: what Professor is doing now, a line to show while `busy` (null otherwise, or right after a restart); pending
proposals only; `writing`: the proposal being applied, with its `progress`; `formulas`, since 2026-10-29: how many
topics have formulas, 0 when there's no formula sheet to show; `exercises`, since 2026-10-29: how many topics have
exercises, below; `mocks`, since 2026-10-29: how many mock exams it has, below).

**Formula sheet** (since 2026-10-29): the Formulas section of every written topic, in the notebook's order, each
under a `## [[Topic title]]` heading (with `plain`, just the title). No model writes it: it's put together on every
read, so it always matches the topics. In the vault it's `Formulas.md` in the course's folder, linked from the
Introduction's Practice list, and like any page Aide writes, it's left alone once the user edits it. To change a
formula, edit the topic.

**`plain=true`** (on the notebook, a topic and a lecture): the notes as the app shows them. LaTeX becomes plain
Unicode ($\pi_{t-1}$ as πₜ₋₁) and `[[links]]` their text. Without it, the markdown is as in the vault.
**`latex=true`** with it (on the notebook's `introduction`, the formula sheet, a topic's `body`, an exercise set and a
lecture's `notes`): a `$$…$$` formula on its own line or lines (in a callout too, a full stop after it allowed) stays
LaTeX, `$$` included, for the app to draw; maths inside a sentence is still Unicode. Flashcards and questions stay
Unicode. **`inline=true`** with both: the maths inside sentences stays LaTeX too, as `\(…\)` (its whitespace made
single spaces), so `$P_{i,t}$ is the price` comes as `\(P_{i,t}\) is the price`; a `$` left in the text is money.

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

### Exercises

Since 2026-10-29: a set of solved exercises per topic, for practice beyond the topic's questions. Only the course's
own exercises (since 2026-10-29, later the same day: no new ones of Aide's). Writing them, in the background (a few
minutes for a whole notebook):
- the course's files of exercises (by name or Moodle section: problem sets and their solutions, exercise sessions,
  review or example questions, past exams, mock exams) are matched to the topics by the cheap model, once per run,
  a solution's pages with its exercise's topic;
- each topic's set is written by the smart model from its notes, how the exam works (the Introduction's "The exam"
  and "How to prepare") and its exercise pages: every exercise on them, past exams first, copied as it is and solved,
  following the course's own solution where it has one (`solution:` in its heading);
- the other final answers are worked out again by a second, blind solver; where they differ, the smart model fixes
  the solution or says it stands (`checked`).

Writing a topic's set again replaces it; a topic none of the sheets practises has no set (an old one is removed).
`POST` answers `409` when the course has no exercise files at all. The result comes in the course's chat, with a push (`message`). Professor
writes them on request (`write_exercises`) and goes through one in chat (`read_exercises`: the statement first,
the solution once the user has tried).

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/notebook/exercises?course=2` | | `{"course": 2, "sets": [Exercise set without body]}`, in the notebook's order. `404` no such course. |
| `POST /v1/notebook/exercises?course=2` | `{"topics": ["t_…"]}`, optional (every written topic) | `202`, Notebook (`busy`, `step` "Writing exercises 3/11"). `400` a topic not in the course; `409` no topic written yet, or a named one isn't. `404`. |
| `GET /v1/exercises/{id}?plain=true` | | Exercise set with `body` and `sources`. `404`. |

Exercise set: `{"id": "e_…", "course": 2, "topic": {"id": "t_…", "title": "The IS-LM model"}, "count": 8,
"from_material": 8, "new": 0, "checked": true, "updated_at": "…"}` (`new` is 0 on sets written since the change); in full also `"body": "markdown"` and
`"sources": ["Problem set 2, p. 1–3"]` (the exercise pages it drew on). `checked`: the final answers went through the
second solver (false: none has a final result, or the check failed).

Body: one block per exercise, nothing else:
```
**Exercise 1.** (from: Problem set 2, p. 3; solution: Solution problem set 2, p. 4)     or (new), on old sets
The statement, with its data.
> [!success]- Solution
> Step by step…
> **Answer:** ΔY = 200
```
The solution is a folded callout, like a question's answer: closed until tapped. `**Answer:**` is there when the
exercise has a final result. In the vault: `Exercises/01 The IS-LM model.md` in the course's folder (the topic page's
number and name), linked from the topic page's `exercises:` property and the Introduction's Practice list.

### Mock exams

Since 2026-10-29: a paper like the real exam, to take under exam conditions in the app (as a Quiz, below) or on paper
from the vault. Written in the background by the smart model in one go (a few minutes), from how the exam works (the
Introduction), every topic's notes and, when the course has them, its past exams (exercise files named like past
exams, mocks or *esame 2025*), for the style; earlier mocks' questions aren't asked again. It follows the real exam:
its kinds of questions (multiple choice, open questions, exercises), points, time and scoring (when the format isn't
known: 20 multiple-choice and 2 open questions, 60 minutes). The multiple-choice keys are checked blind like a
topic's. The result comes in the course's chat, with a push. Professor writes one on request (`write_mock_exam`) and
sees how they went (`study_progress`).

Past exams (since 2026-10-29): with `past=true` the course's own papers (its past exams and the mock exams it gave
out: exercise files named like *mock*, *esame 2025*, *Example questions*) are copied instead, as they are, one smart
model call each: every question, its words, data, options and points, answered from the paper's own key when it has
one, else worked out; those keys are checked blind and only a key and its explanation can change. Each becomes a Mock
exam with `source` and the paper's own `title` ("Mock exam 2026"), taken like any other. A paper already copied is
left alone. Professor: `write_mock_exam` with `past: true`.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/notebook/mocks?course=2` | | `{"course": 2, "mocks": [Mock exam]}`: the course's own papers first, then the written ones, each oldest first. `404` no such course. |
| `POST /v1/notebook/mocks?course=2` | | `202`, Notebook (`busy`, `step` "Writing a mock exam"). `409` no topic written yet. `404`. |
| `POST /v1/notebook/mocks?course=2&past=true` | | `202`, Notebook (`step` "Copying past exams 1/2"). `409` no topic written yet, or no papers among its files. `404`. |
| `GET /v1/mocks/{id}?plain=true` | | Mock exam with `questions` (no keys) and `body` (the paper, no answers). `404`. |

Mock exam: `{"id": "m_…", "course": 2, "number": 1, "title": "Mock exam 1", "source": null or {"id": "f_…", "name":
"Example Questions Midterm.pdf"} (the course's own paper, copied; numbered apart from the written ones), "minutes": 90 or null, "scoring":
{"right": 1, "wrong": 0, "blank": 0}, "count": 16, "mcq": 15, "open": 1, "points": 30, "created_at": "…", "taken": 2,
"best": 24.5 or null, "last": Quiz without questions or null}` (`scoring`: a multiple-choice answer's points;
`points`: the most the paper scores). On `GET /v1/mocks/{id}` also `"questions": [{"n": 16, "type": "mcq" or "open",
"points": 15 or null (multiple choice: `scoring.right`), "text": "markdown", "options": [{"letter": "A", "text": "…"}]
(empty for open ones)}]` and `"body"`. Taking it: `POST /v1/quizzes` with `mock` (Practice exams, below).

In the vault: `Mock exams/Mock exam 1.md` (a copied paper: `Past exams/Mock exam 2026.md`) in the course's folder, linked from the Introduction's Practice list: the
time, points and scoring, the paper as it would be printed, then `## Answers` (each question's key or model answer,
and an open question's marking, as folded callouts).

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
topics in the course's chat (and knows which questions were missed, to go through them there). Since 2026-10-31 the
score is a `quiz` card on that message (Chat, attachments) and the push says it in a line.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/quizzes?course=2` | | Bank. `404` no such course. |
| `POST /v1/quizzes` | `{"course": 2, "count": 30, "cards": 5, "exercises": 2, "minutes": 45, "topics": ["t_…"]}`; `count` the multiple-choice questions, 0–60 (default 30, fewer when the bank is smaller), `cards` flashcards and `exercises` the course's own exercises (since 2026-10-31, default 0; 60 in all at most), `minutes` null (default) for untimed, `topics` null for all. Or `{"course": 2, "mock": "m_…"}` (since 2026-10-29): that mock exam, its time and scoring | `201`, Quiz without keys. `409` the notebook has no questions. `404` the mock isn't the course's. |
| `GET /v1/quizzes/{id}` | | Quiz (with keys once finished). `404`. |
| `POST /v1/quizzes/{id}/check` | `{"n": 3, "answer": "B"}` (since 2026-10-31): one question answered while taking it, as in `finish` (a flashcard's `"right"` or `"wrong"`, an open one's `{"text", "photos"}`, null blank). The answer is final: `finish` keeps it over what it's sent | That Question with its key, as once finished (an open one with `model_answer` and `rubric`, `awarded` and `correct` null until marked). `409` checked already or finished; `404` no such question, or a chat quiz. |
| `POST /v1/quizzes/{id}/finish` | `{"answers": {"1": "B", "2": null, "16": {"text": "…", "photos": ["p_…"]}}}`, by question number; left out or null is blank. An open question's answer: typed `text`, photos of the work on paper (`POST /v1/photos`, up to 4), or both | Quiz, finished. `409` already finished. |

Bank: `{"course": 2, "exam": "20 to 35 multiple-choice questions…" or null, "questions": 65, "unseen": 40,
"to_review": 6, "cards": 40, "exercises": 12, "topics": [{"id": "t_…", "title": "…", "questions": 6, "cards": 4,
"exercises": 1, "known": 4, "learning": 2, "unseen": 4}], "scoring": {"right": 1, "wrong": -0.25,
"blank": 0}, "past": [Quiz without questions, newest first, finished only]}`.

Quiz: `{"id": "x_…", "kind": "exam" or "chat" (since 2026-10-27), "title": "Practice exam", "Mock exam 1" or "Quiz" (since 2026-10-31), "course": 2, "minutes": 45 or null, "count": 30, "started_at": "…", "finished_at": "…" or null,
"score": null or {"points": 22.75, "max": 30, "right": 24, "wrong": 5, "blank": 1, "topics": [{"id": "t_…", "title":
"…", "right": 1, "wrong": 2, "blank": 0}] (weakest first)}, "questions": [{"n": 1, "topic": {"id": "t_…", "title":
"…"}, "text": "markdown", "options": [{"letter": "A", "text": "…"}]}]}`. Once finished, each question also has
`"answer": "B" or null, "key": "C", "correct": false, "explanation": "markdown"`. The notes' LaTeX comes as plain
Unicode in `text`, `options` and `explanation` ($\pi_{t-1}$ as πₜ₋₁).

Since 2026-10-31 a practice exam can mix kinds, in this order: the multiple-choice questions (shuffled), then the
flashcards (`"type": "card"`, no `options`; the user turns it and says `"right"` or `"wrong"`; `key` is the card's
answer, there from the start since the card is turned before it's marked; right 1, wrong 0, no penalty), then the course's own exercises (`"type": "open"`, `"points": 1`, marked after
the finish like a mock's open answers, against the course's solution). Every question has `"source": {"kind":
"course", "name": "Esercitazione 3, p. 2"}` (the course's own material: an exercise sheet, a paper the course gave out)
or `{"kind": "professor", "name": null}` (written by Professor: the notebook's questions and flashcards, its mocks);
null on quizzes from before. A Quiz has `"checked": [1, 3]`, the questions answered with `check`, which come with
their key already.

Mock exams (since 2026-10-29): `kind` is `"mock"`, with `"mock": "m_…"` (null otherwise) and its `"scoring"` (on
every quiz: the practice exam's is right 1, wrong −0.25, blank 0); `score.points` and `max` count by it. A question can
be `"type": "open"` with its `"points"`, and no `options`. Open answers are marked after the finish by the smart
model, against the question's model answer and marking (photos read as images): until then `score` has `"grading":
true` (a mock's score always has `grading`, and since 2026-10-31 any quiz with an open question), the open ones count 0, and the app polls `GET /v1/quizzes/{id}` every few
seconds. Professor posts the result in the course's chat once they're marked. Once finished, an open question has
`"answer": null, "response": {"text": "…", "photos": ["p_…"]} or null (blank), "awarded": 9.5 or null (not marked:
the marking failed; it counts 0), "feedback": "…" or null, "correct": true (awarded at least half its points),
"model_answer": "…", "rubric": "…"` (no `key` or `explanation`). Objectives count mock exams as practice exams.

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
one deleted there is dropped. Review events never count as lectures or courses. Since 2026-10-31 that message
carries a `review` card (Chat, attachments) with the session's time, length and topics.

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
`max` (1–100), like "3 coffees a day at most". You log each one (`POST /v1/habits/{id}/count`); nothing logged
means 0.
- `count` is today's count (`null` on other habits). `counts` maps each local date with a count in the last 26
  weeks to it, `{"2026-10-25": 3, …}` (only days over 0; `{}` on other habits), for the trend and the grid.
- A day is done when it ended at or under `max`, so `history` and `last_done` only hold days before today (from the
  day the habit became a limit habit; since 2026-10-27 a count for an earlier day moves that start back to it, so
  filled-in history counts). `done_today` says whether today is still within the limit so far.
- `streak` counts the days before today in a row that were done, and is 0 once today goes over.
- Checking a limit habit (`/check`) is `400`; the count is its check.
- `health` (since 2026-10-26, default `null`): a limit habit can also count from Apple Health. `"inhaler_usage"`
  follows the health day's `inhaler_usage` (Health's Inhaler Usage, where the user may log the habit). A day's count
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

The assistant also gets tools to add, check, count and list habits (deleting is queued for confirmation), so "had
another coffee" in chat logs one. Coach sees each limit habit's count today and the last 7 days.

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
  "sleep_hr": 47,
  "sleep_hr_low": 43,
  "hrv_ms": 61.5,
  "respiratory_rate": 14.2,
  "wrist_temp_c": 35.91,
  "steps": 8432,
  "active_kcal": 512,
  "resting_kcal": 1790,
  "exercise_min": 41,
  "inhaler_usage": 3,
  "naps": [{"start": "2026-10-19T14:05:00+02:00", "end": "2026-10-19T14:50:00+02:00", "asleep_min": 42}],
  "workouts": [
    {"id": "6B1F0C2E-…", "type": "strength", "start": "2026-10-19T18:30:00+02:00",
     "end": "2026-10-19T19:22:00+02:00", "minutes": 52, "kcal": 310},
    {"id": "A04C…", "type": "run", "start": "2026-10-19T07:30:00+02:00",
     "end": "2026-10-19T08:24:00+02:00", "minutes": 54, "kcal": 656, "km": 9.8}
  ],
  "weight_kg": 74.2,
  "vo2max": 51.3,
  "max_hr": 184,
  "hr_minutes": [[90, 212.5], [95, 96.0], [100, 41.5], [140, 12.0], [145, 18.5], [150, 9.0]],
  "hr_hourly": [52, 50, 49, null, 48, 50, 51, 74, 98, 81, …, 66]
}
```
Each workout may also carry `"avg_hr": 151, "max_hr": 184`.
- **Missing or `null` means no data** for that field. Every number may be missing.
- `date` is the local calendar day. `steps`, `active_kcal`, `exercise_min`, `inhaler_usage` and `workouts` cover
  00:00–24:00. `inhaler_usage` (since 2026-10-26) is Health's Inhaler Usage count, for a limit habit's `health`.
  `resting_kcal` (since 2026-10-29) is Health's Resting Energy for the day (the Watch's basal burn), for the food
  targets' proposal.
- `sleep` is the night that **ended** that morning: the longest stretch of sleep that ends between 18:00 the
  evening before and 18:00 on `date`, with gaps under an hour counted as part of it. Naps are left out of it. `bedtime`
  is when sleep started, `wake` when it ended, `in_bed_min` = `wake` − `bedtime`, `asleep_min` = the sleep stages
  added up, `awake_min` = time awake in between. `deep_min`, `core_min` and `rem_min` are `null` without a Watch.
- `naps` (since 2026-10-26; missing when there were none) is the day's other sleep: stretches that start after
  the night's `wake` (or midnight) and before the next midnight, 10 min to 4 h asleep, the same gap rule as the
  night; the next night (an early bedtime) isn't one.
- `resting_hr` (bpm) is Apple's resting heart rate for that day (worked out mostly while awake; often not there yet
  in the morning). `sleep_hr` (since 2026-10-30) is the average heart rate during that night's sleep stages (awake
  stretches left out), and `sleep_hr_low` the lowest average of 3 readings in a row (~15 min) in them; both need 6
  readings asleep. `hrv_ms` is the average HRV (SDNN, Apple's
  measure) during that night's sleep, or over the day if there's none from the night. `respiratory_rate`
  (breaths/min) and `wrist_temp_c` (absolute °C, Series 8 and later) are averages over the night. The server
  compares them with the user's own past numbers; Apple's "baseline" isn't available to apps.
- `workouts[].km` (since 2026-10-29) is the workout's distance, when it has one. `weight_kg` is the day's latest
  body mass, `vo2max` Apple's latest VO2 max estimate that day (mL/kg/min); both only on days with a sample. The food
  targets' proposal reads them.
- `workouts[].id` is the HealthKit workout UUID: stable, so re-sending the same workout is harmless.
- Heart rate (since 2026-10-30, for Strain; summaries, raw samples never leave the phone): `hr_minutes` is the day's
  minutes per 5-bpm bucket, `[bpm_floor, minutes]`, from 90 bpm up, buckets with no time left out. Each heart-rate
  sample counts until the next one, at most 10 min. `hr_hourly` is 24 averages (00:00 to 23:00, `null` for an hour
  with no sample), for the day chart. `max_hr` is the day's highest sample. `workouts[].avg_hr` and `max_hr` come from
  the workout's own heart-rate statistics.

### Workout types

`strength`, `run`, `walk`, `hike`, `cycle`, `swim`, `hiit`, `yoga`, `pilates`, `core`, `dance`, `climb`,
`row`, `elliptical`, `stairs`, `cardio`, `martial_arts`, `sport` (team and racket sports), `other`. More may be
added; treat an unknown one like `other`.

### Endpoints

| Endpoint | Body / query | Response |
|---|---|---|
| `POST /v1/health/days` | `{"days": [Health day]}` (up to 90) | `{"ok": true, "saved": 7, "checked": [Habit]}`: `checked` = habits this upload checked through workouts |
| `GET /v1/health/days` | `?from=2026-10-01&to=2026-10-19` (both optional; default the last 30 days) | `{"days": [Health day]}`, newest first |
| `GET /v1/health/scores` | `?date=2026-10-19` (default today) | the day's Scores, below |
| `GET /v1/health/scores/history` | `?days=30&to=2026-10-19` (`days` 1–366, default 30; `to` default today) | `{"days": [{"date", "sleep", "recovery", "strain"}]}`: each day's three scores (`null` where there's none), newest first |
| `POST /v1/wake` | `{"at": "2026-10-19T07:42:10+02:00", "source": "shortcut", "day": Health day \| null}` | `{"started": true}`, or `{"started": false, "reason": "already"}` (`already`, `off`, `outside_hours`) |

- **Uploads replace by `date`.** A day that's sent again overwrites the stored one, because data arrives late
  (the Watch syncs the night after you wake, steps keep counting all day). So the app re-sends recent days:
  - on launch and on returning to the foreground: the last 7 days;
  - the first time (and whenever Health access is newly granted): the last 60 days, so baselines and "usual"
    numbers work from the first morning;
  - when HealthKit wakes the app in the background with new sleep or a new workout (right away) or new steps
    (at most hourly): the last 2 days.

### Scores

Three 0–100 numbers for a day, worked out by the server from the stored days (`scores.py`), so the app, Coach,
the digests and the widgets all see the same ones. Each compares the day with the user's own past (medians over
the weeks before), in the spirit of Whoop and Bevel. The formulas are Aide's own and may be tuned. They are not
medical advice.

```json
{
  "date": "2026-10-30",
  "sleep": {
    "score": 71, "asleep_min": 400, "need_min": 486, "debt_min": 58,
    "need": {"need": 486, "base": 458, "strain": 12, "debt": 16},
    "contributors": [
      {"key": "duration", "label": "Hours vs need", "value": "6h40 of 8h06", "score": 56, "weight": 50, "usual": "7h52", "diff_min": -72},
      {"key": "deep", "label": "Deep sleep", "value": "0h52 · 13%", "score": 80, "weight": 15, "usual": "0h58 · 12%", "diff_min": -6},
      {"key": "rem", "label": "REM sleep", "value": "1h39 · 25%", "score": 100, "weight": 15, "usual": "1h45 · 22%", "diff_min": -6},
      {"key": "efficiency", "label": "Time asleep in bed", "value": "91%", "score": 50, "weight": 5, "usual": "97%", "diff_min": null},
      {"key": "consistency", "label": "Bed and wake vs usual", "value": "bed 0h38 later, up on time", "score": 82, "weight": 15, "usual": null, "diff_min": null}
    ]
  },
  "recovery": {
    "score": 72, "level": "good", "calibrating": null, "flags": [],
    "contributors": [
      {"key": "hrv", "label": "HRV", "value": 61.5, "usual": 55.0, "unit": "ms", "score": 93, "weight": 30},
      {"key": "hrv_week", "label": "HRV, last 7 days", "value": 57.2, "usual": 55.0, "unit": "ms", "score": 74, "weight": 20},
      {"key": "sleep_hr", "label": "Heart rate asleep", "value": 47, "usual": 49, "unit": "bpm", "score": 82, "weight": 25},
      {"key": "sleep", "label": "Sleep", "value": 71, "usual": null, "unit": "%", "score": 66, "weight": 15},
      {"key": "load", "label": "Training load", "value": 1.12, "usual": 1.0, "unit": "×", "score": 59, "weight": 10}
    ]
  },
  "strain": {
    "score": 41, "trimp": 79.3, "estimated": false, "target": [55, 80], "rest_hr": 53, "max_hr": 192,
    "zones": [14, 22, 18, 6, 0], "zone_bpm": [123, 137, 150, 164, 178, 192],
    "workouts": [{"id": "A04C…", "type": "run", "minutes": 54, "strain": 38}]
  },
  "load": {"acute": 62.1, "chronic": 55.4, "ratio": 1.12, "label": "building", "acute_strain": 34, "chronic_strain": 31,
           "days": [40, 0, 55, 12, 61, 30, 41],
           "why": "The last 7 days averaged 34% strain a day, 12% more than your 4-week average of 31% (1.12×): 1–1.3× builds it."},
  "vitals": {
    "hrv_ms": {"value": 61.5, "usual": 55.0, "low": 49.2, "high": 60.8},
    "sleep_hr": {"value": 47, "usual": 49, "low": 47, "high": 51},
    "resting_hr": {"value": 52, "usual": 54, "low": 52, "high": 56},
    "respiratory_rate": {"value": 14.2, "usual": 14.0, "low": 13.6, "high": 14.4},
    "wrist_temp_c": {"value": 35.91, "usual": 35.88, "low": 35.73, "high": 36.03},
    "asleep_min": {"value": 400, "usual": 438, "low": 413, "high": 463}
  },
  "line": "Recovery 72% after 6h40 asleep: a good day to push, aim for 55–80% strain."
}
```
- **`sleep`** (`null` without a night): time asleep against the night's need 50% (each share of the need missed
  costs 2.5 times that: 90% of it scores 75, 80% scores 50), deep share of the night 15% (full at 15%, none at 5%), REM
  share 15% (full at 23%, none at 10%), asleep / in bed 5% (full at 97%, none at 85%; the Watch's "in bed" is mostly
  the sleep itself, so this is nearly always high), and bedtime and wake against the medians of
  the 14 nights before 15% (their average offset: full within 20 min, none at 2 h; needs 5 nights). A part without
  data (no stages, no history) is left out (`score` and `value` `null`) and the rest re-weighted. Since 2026-10-30
  each part has its **`usual`**, written like `value` (the median of the 30 nights before: time asleep, deep and REM
  with their share, asleep / in bed; null for consistency, which is already against the usual, and with fewer than 5
  nights), and **`diff_min`**, the night's minutes minus the usual (duration, deep, REM; else null).
  Weights were 45/15/15/10/15 before 2026-10-30, and a missed need cost twice its share.
  **`need`** is learnt from the user's own nights, as Oura does: `base` is the mean of up to 90 nights before with the
  shortest and longest 10% left out, kept within 7h30–9h30 (8h with fewer than 14 nights); `strain` adds 0.3 min per %
  of the day before's strain (Whoop: a hard day asks for more); `debt` is half of what the 3 nights before were short
  of `base`, net of what they were over, at most 45 min. `need_min` is their sum (`need.need`). `debt_min` is the net
  shortfall against `base` over the last 3 nights, this one included.
- **`recovery`** (`null` without last night's `hrv_ms`): ln HRV (30%), the 7-day mean of ln HRV against the rolling
  7-day means of the 60 days before (`hrv_week`, 20%; Plews and Buchheit: the week's trend says more than one
  morning; needs 4 of the 7 days), heart rate asleep (`sleep_hr`, 25%, lower is better; as Oura and Whoop read the
  night; `resting_hr`, Apple's resting HR, in its place until 14 days have `sleep_hr`), the sleep score (15%) and the training load's
  ratio (`load`, 10%: up to 1.05 costs nothing, each 0.25 above it is a spread), each as how far it is from the
  user's usual (median and spread of the 60 days before) and combined into a score where a usual night lands around
  60. A part without data is left out and the rest re-weighted. While fewer than 14 days of HRV are
  stored: `score` and `level` `null`, `calibrating: {"days": 9, "needs": 14}`. `flags`: `respiratory_rate` (1 or more
  breaths/min above usual) and `wrist_temp` (0.5 °C or more above), each caps the score at 50. `level`: under 34
  `low`, under 67 `normal`, else `good`. A contributor's `score` is that part alone on the same scale.
- **`strain`** (`null` without a stored day): cardio load from heart rate. Banister's TRIMP over `hr_minutes`
  (heart-rate reserve from `rest_hr`, the 30-day median resting HR, to `max_hr`: the middle of the 3 highest workout
  maxes of 90 days, so one strap spike doesn't count, else the day max, never under 208 − 0.7 × age from the food
  profile), counting only time above 40% of the reserve; `score` = 100 × (1 − e^(−TRIMP/150)). Without `hr_minutes`, from the workouts (`avg_hr` × minutes, else
  kcal / 5) and `estimated: true`. `target` is the day's band from recovery (`good` 55–80, `normal` 35–60, `low`
  10–35; `null` without recovery). `zones` are minutes in 50–60, 60–70, 70–80, 80–90 and 90–100% of the reserve;
  `zone_bpm` is where zones 1–5 start in bpm, then `max_hr`.
  Each workout carries its own `strain`.
- **`load`**: the last 7 days' average TRIMP against the last 28's, **up to the day before** (since 2026-10-30: a
  day under way counted as a rest day, so every morning looked like detraining); `ratio` under 0.8 `detraining`, under
  1.0 `maintaining`, up to 1.3 `building`, above `overreaching`. `null` with fewer than 14 days stored in the 28.
  Since 2026-10-30: `acute_strain` and `chronic_strain`, the two averages as strain %; `days`, those 7 days' strain,
  oldest first (null for a day not stored); `why`, one sentence saying what the label rests on.
- **`vitals`**: each night number with its usual (median of the 60 days before) and usual range (`low`–`high`,
  one spread either side), for the app's gauges. `usual`, `low` and `high` are `null` with fewer than 14 days.
- **`line`**: one sentence from code, no model call.

### Coach's take

`POST /v1/health/insight` `{"kind": "sleep" | "recovery" | "strain", "date": "2026-10-30"}` (`date` optional,
default today) → `{"kind", "date", "text"}`: a few plain sentences from Coach on what drove that score, the pattern
behind it over the last weeks, and one thing to do. One model call (the background engine) with the day's scores,
30 days of them, 14 raw days and Coach's memory; nothing is stored. 502 when the model doesn't answer. Asked for
from the score's page, never on its own.

### Weight

Since 2026-10-29. The user's weight from two places: Apple Health (each day's `weight_kg`, as uploaded) and readings
logged through Aide (in chat, "72.4 this morning", or the app's Log weight). A day's reading is the last one logged
through Aide that day, else Health's. The phone writes Aide's readings to Health itself, like a limit habit's counts.

| Endpoint | Body / query | Response |
|---|---|---|
| `GET /v1/health/weight` | `?days=90` (1–366) | `{"readings": [Reading], "summary": Summary, "logged": [Logged]}` |
| `POST /v1/health/weight` | `{"kg": 72.4, "at": "2026-10-29T07:40:00+01:00"}` (`at` optional, now; needs a UTC offset) | `{"weight": Logged, "summary": Summary}`; 400 outside 25–300 kg or in the future |
| `DELETE /v1/health/weight/{id}` | | `{"ok": true, "summary": Summary}`; 404 when it's gone |

- **Reading:** `{"date": "2026-10-29", "kg": 72.4, "source": "aide", "id": 3}`, one a day, oldest first; `source`
  is `aide` (with its `id`) or `health`.
- **Logged:** `{"id": 3, "at": "2026-10-29T06:40:00+00:00", "kg": 72.4}`, every reading logged through Aide in the
  last 90 days, oldest first. **The app mirrors these to Health** as Body Mass samples carrying the id in their
  metadata (`AideWeight`): it adds the missing ones and deletes its own samples whose id isn't listed any more. It
  never touches other samples. It does this on launch, on foreground and on a silent `sync` push (each change here
  sends one).
- **Summary:**
  ```json
  {"latest": {"date": "2026-10-29", "kg": 72.4}, "days_since": 0, "average_kg": 72.25, "change_kg": -0.3,
   "rate_kg_week": -0.1, "goal": "gain", "pace_kg_week": {"low_kg": 0.04, "high_kg": 0.09}, "verdict": "below"}
  ```
  - `average_kg` is the mean of the last 7 days' readings.
  - `change_kg` is that average against the one 3 weeks before.
  - `rate_kg_week` is the slope of a straight line through the last 28 days' readings. It needs 3 readings at least
    14 days apart.
  - `pace_kg_week` is what the food goal (`profile.goal` on the targets) wants:
    - gain: +0.06–0.12% of the weight a week, which is 0.25–0.5% a month;
    - lose: −0.75 to −0.25%;
    - keep and perform: ±0.06%.
  - `verdict` is `below`, `on_track` or `above`, with 0.06% a week of slack either side for the scale's noise.
  - Any of these is `null` without the data. `latest` and `days_since` are null when there's no reading in the last
    year.
- **The targets.** `GET /v1/food/targets` carries the same `summary` as `weight`. Coach's proposal gets the
  trend and corrects the base from it when it has been off for about 3 weeks (for gain with the average falling,
  about +150–200 kcal).
- **Coach** has `log_weight`, `weight_trend` and `delete_weight` (queued). A starting watch, "Weigh-in" (Mondays at
  08:30), speaks up only when there's no reading in the last 7 days or the trend is off the goal.

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

The assistant gets a read-only `health` tool over the stored days: each day's scores (the same as
`/v1/health/scores`), sleep, resting heart rate, HRV, steps and workouts for a date range, with averages, the last
day's `line` and cardio load, so "how did I sleep this week?" or "when did I last work out?" works.
Its answers are plain text; there are no health attachments yet.

## Today

`GET /v1/today` (optional `?date=YYYY-MM-DD`, default today) →
```json
{
  "date": "2026-10-18",
  "events": [
    {"id": "df2c…@aide", "title": "Drive to Malpensa", "calendar": "Transport",
     "start": "2026-10-18T14:00:00+02:00", "end": "2026-10-18T19:00:00+02:00",
     "all_day": false, "location": "Malpensa Airport", "notes": "", "recurring": false, "color": "#1BADF8"}
  ],
  "reminders": [ /* Reminder objects due that day or overdue and not completed */ ]
}
```
All-day events have `"all_day": true`, and `start`/`end` are dates, with `end` **exclusive**. `notes` (since
2026-10-29) is the event's notes, `""` when it has none. `color` (since 2026-10-29) is its calendar's colour in
iCloud as `#RRGGBB`, `null` when iCloud gives none; the same on every event object (cards, `/v1/events`, a plan's
items).

### Events and plans

Since 2026-10-29 (#25): the chat's events card is a week view, and its events can be opened, moved and deleted.

`GET /v1/events?from=YYYY-MM-DD&days=7` (`from` defaults to today, `days` 1 to 42) → `{"from", "days", "events":
[event]}`, every calendar's events in those days, in time order: what the week card shows around its own.
`502` when iCloud doesn't answer, `503` with no calendar.

`PATCH /v1/events/{id}` with `{"start", "end"}` (local `YYYY-MM-DDTHH:MM`, or dates for an all-day event, `end` then
its last day) → the event, moved. `DELETE /v1/events/{id}` → `{"ok": true}`. These are the user's own taps on the
event's sheet, so they run at once (logged in Activity as `confirmed`). `409` for a recurring event (the Calendar app
does those), `404` for an unknown one, `400` for an end before the start.

**Plans.** An agent (Secretary, or Professor for review sessions) proposes several events at once with
`propose_events`. They come as `events` card items with `"change": "proposed"` and:
- `plan`: the plan's id, `ep_…`; the item's own `id` is `ep_…-1`, `ep_…-2` …;
- `status`: `"proposed"`, `"added"` or `"dropped"`; `/v1/history` gives it as it is now;
- `event`: the calendar event's id once added, else `null`;
- `error`: why the last Add of it failed, when it did (it stays `proposed`).

Nothing is in the calendar until the user taps Add, which is the confirmation (as with a mail draft's Send):
- `POST /v1/plans/{plan}/add` with `{"items": ["ep_…-1"]}` (or no body: every item still proposed) → `{"events":
  [the plan's items]}`. A review session's item (`Review: <course>`) goes in as a review session (see Quizzes and
  review sessions).
- `POST /v1/plans/{plan}/drop` with the same body → `{"events": [...]}`: those won't be added.
- The chat's agent is told what was added or removed. `404` for an unknown plan or item.

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
  or tomorrow if that's gone). Deleted once it fires or ends. Since 2026-10-27 a one-off asked for again (same stop,
  line and time) isn't added twice: the one waiting is kept, watching from now. `right_away` (true only on one-offs
  set with "start the live activity") starts the countdown at once for the next tram the user can make, instead of
  when it's time to leave.
- **One countdown per tram** (since 2026-10-27): an alert that fires while a tram countdown is already on for its
  line at its stop (two alerts for the same tram: a leave-now one and one set in chat) doesn't start another; it's
  done. Countdowns being followed survive a server restart.
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
  "right_away": false,
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

## Browser errands

Aide does things on websites for you in its own browser (since 2026-10-27, #22): "order me a USB-C cable on
Amazon", "what does the 8:05 to Milan cost", "fill my cart on Glovo". An **errand** runs in the background on the
server (Chromium, a phone-sized page, one profile per site so you log in once) and reports in the chat it was asked
from (Aide's). Aide starts one with `start_errand`; the specialists don't.

**What Aide may do on its own:** search, read, compare, fill a cart, go to the checkout. **What waits for your
Confirm:** anything that changes something (buying, booking, sending, signing up, cancelling, account changes). The
server refuses those clicks and Enters in code; the errand asks with a queued `errand_go` action carrying the order's
`detail` (items, total, address, a screenshot). After Confirm only the confirmed button is clicked, and only while
the page still shows the confirmed total: a different total means a new Confirm. It uses the site's saved card and
address and never types card numbers or passwords: logins, codes, CAPTCHAs, card forms and 3-D Secure are yours, in
the **live view** (below). The model never sees what you type there.

One errand runs at a time (others are `queued`). Each has at most 80 browser actions and 20 minutes of model time.
It runs on the Claude plan when the notes run there, else on OpenRouter; at the plan's limit it asks (`why`
`plan_limit`): "Wait for the reset" or "Finish on OpenRouter", as a reply.

Statuses: `queued`, `running`, `needs_you`, `waiting_confirm`, `done`, `failed`, `cancelled`, `interrupted` (the
server restarted while it ran: the profile keeps you logged in, the page is opened again; reply "go on" or tap "I'm
done" to carry on). An unanswered Confirm expires after 30 minutes and cancels the errand; so does Cancel.

Errand:
```json
{"id": 7, "title": "USB-C cable", "task": "A cheap 2 m USB-C cable, delivered by Friday", "site": "amazon.it",
 "url": "https://www.amazon.it/gp/buy/spc/handlers/display.html", "status": "waiting_confirm",
 "why": null, "reason": "Order the Anker USB-C cable", "options": null,
 "step": "Waiting for your Confirm", "steps": [{"ts": "2026-10-27T18:02:11+01:00", "text": "Opened amazon.it"}],
 "result": null, "action_id": 42, "conversation_id": "c_91f…", "purchase_id": null, "products": [],
 "created_at": "2026-10-27T18:01:50+01:00", "updated_at": "2026-10-27T18:03:20+01:00"}
```
- `why` (only on `needs_you`): `login`, `captcha`, `code`, `card` or `other` (take over in the live view, then "I'm
  done"), `question` (answer with a reply; `options` may list answers), `plan_limit` (reply with one of `options`).
- `reason`: on `needs_you`, what you're asked; on `waiting_confirm`, what waits for the Confirm. Else null.
- `step`: what it's doing now, in Aide's own words when it gave them ("Guardo le recensioni della Lodge", since
  2026-10-28), else a plain line ("Clicked [12] …"). `steps`: the last 10 (all of them, up to 60, on
  `GET /v1/errands/{id}`); each `{ts, text}` with `doing` (Aide's line) when it gave one.
- `action_id`: on `waiting_confirm`, the queued action to confirm (`POST /v1/confirm` with `{"ids": [42]}`).
- `result`: on `done` or `failed`, what it says. `purchase_id`: the order it placed, if any.
- `products` (since 2026-10-28): what it found, as Product cards, best first (up to 10); `[]` when there's nothing
  to show.

Product:
```json
{"title": "Lodge L8SK3, 26 cm", "url": "https://www.amazon.it/dp/B00006JSUA", "price": "49,15 €", "rating": 4.4,
 "reviews": 72015, "note": "Arriva domani", "image": "https://m.media-amazon.com/images/I/81q….jpg"}
```
`url` is always a full http(s) link (open it on tap). `price`, `rating` (out of 5), `reviews` (how many ratings),
`note` (one short line: delivery, a catch) and `image` may be null. `image` is a picture from the site itself,
taken from the page where the errand saw the product, else from the product's own page.

The Confirm's `detail` (on that action in `/v1/approvals` and `pending`):
```json
{"kind": "purchase", "errand_id": 7, "site": "amazon.it", "summary": "Order the Anker USB-C cable",
 "items": [{"title": "Anker USB-C cable 2 m", "quantity": 1, "price": "9,99 €", "image": "https://m.media-amazon.com/…"}],
 "total": "12,98 €", "delivery": "Tomorrow, 28 Oct", "address": "Via Roma 1, Torino",
 "screenshot": "p_3f2a…", "button": "Acquista ora"}
```
`total`, prices and `delivery` are as the site wrote them. `screenshot` is a photo id (`GET /v1/photos/{id}`) of
the checkout page; `image`, `delivery` and `address` may be null.

Purchase (an order placed):
```json
{"id": 3, "errand_id": 7, "site": "amazon.it", "title": "Anker USB-C cable", "items": [ /* as above */ ],
 "total": "12,98 €", "amount": 12.98, "currency": "EUR", "order_ref": "402-1234567-7654321",
 "delivery": "Tomorrow, 28 Oct", "receipt": "p_9c1e…", "placed_at": "2026-10-27T18:04:02+01:00"}
```
`amount` and `currency` are read from `total` (null when they can't be). `receipt`: a photo id of the confirmation
page. Finance reads these (`list_purchases`).

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/errands?open=true&limit=30` | | `{"errands": [Errand], "enabled": true}`, newest first; `open` leaves out finished ones. `enabled` false: no browser on the server |
| `GET /v1/errands/{id}` | | the Errand with all its `steps` |
| `POST /v1/errands/{id}/done` | | the Errand (`queued`): you finished in the live view. `409` unless it's `needs_you` or `interrupted` |
| `POST /v1/errands/{id}/reply` | `{"answer": "the 2 m one"}` | the Errand (`queued`). `409` unless it's `needs_you` or `interrupted`, or with an empty answer |
| `POST /v1/errands/{id}/cancel` | | the Errand (`cancelled`); also drops its queued Confirm. Nothing is ordered |
| `GET /v1/errands/{id}/frame` | | the page now, `image/jpeg`; `404` when it has no page open |
| `GET /v1/browser/sites` | | `{"sites": [{"site": "amazon.it", "used_at": "…", "open": false}], "enabled": true}`: the sites with a profile |
| `POST /v1/browser/sites` | `{"url": "amazon.it"}` | `{"site": "amazon.it", "url": "https://www.amazon.it/"}`: opens it to log in, then the live view with `?site=` |
| `DELETE /v1/browser/sites/{site}` | | `{"ok": true}`: its cookies and profile are deleted (logged out); `404` without one, `400` for a bad name |
| `GET /v1/purchases?days=30&site=amazon.it` | | `{"purchases": [Purchase], "totals": {"EUR": 12.98}}`, newest first |

Without the browser (Playwright's Chromium not installed) the errand endpoints answer `503`, the lists are empty with
`enabled` false, and Aide has no `start_errand`.

### Live view

`wss://…/v1/browser/live?errand=7` (an errand's page) or `?site=amazon.it` (logging in from Settings, after
`POST /v1/browser/sites`), with `Authorization: Bearer <token>`; without it the socket is closed with `1008`. Add
`&frames=false` (since 2026-10-28) for no frames until the app asks for them: the app draws the page itself from its
`scene`. JSON messages each way:

Server to app:
- `{"type": "frame", "data": "<base64 JPEG>", "width": 824, "height": 1830}`: the page, as often as it changes
  (the device pixels of a 412×915 page).
- `{"type": "status", "status": "needs_you", "step": "Log in to Amazon.", "control": true, "reason": "Log in to
  Amazon.", "url": "https://www.amazon.it/ap/signin…"}` when any of it changes. `control` false: Aide is working
  and the view is watch-only (your input is ignored). With `?site=`, `status` is `login` and `control` true.
- `{"type": "focus", "field": "password", "label": "Password"}` when the focused field changes: `field` is
  `password`, `username` (an email or user name), `code` (a one-time code), `phone`, `number`, `text`, or null (none:
  hide the keyboard bar). Show the matching native field, so the phone's AutoFill offers your password or code.
- `{"type": "action", "seq": 12, "kind": "click", "x": 0.5, "y": 0.38, "label": "Aggiungi al carrello"}` (since
  2026-10-28, errands only): what Aide just did, as it does it, for the app to show over the frames. `kind`: `open`
  (`label` the site and path), `click`, `type` (`label` what it types; null in a password field), `choose` (the
  option), `press` (the key), `scroll` (`up` or `down`), `back`. Since 2026-10-28 a button that only says "+" or "Add"
  carries its card's name after ` · ` ("Increase quantity · diavola"). `x`, `y`: the element's middle as fractions of the
  frame, or null. Only what it does after the socket opened; `seq` goes up by one or more each time. Since
  2026-10-28 also `read` (it reads the page), `find` (`label` what it looks for) and `look` (a screenshot), and
  `note`: Aide's own line for it ("Guardo le recensioni"), or null.
- `{"type": "scene", …}` (since 2026-10-28): what kind of page it is and the few real things on it, when it changes
  (after Aide's actions and your presses, on a new address, else checked every 2 s). The app draws its own screen
  for it; it never needs to draw the site.
  ```json
  {"kind": "results", "site": "amazon.it", "title": "Amazon.it : padella in ghisa", "url": "https://www.amazon.it/s?k=…",
   "icon": "https://www.amazon.it/favicon.ico", "query": "padella in ghisa",
   "items": [{"title": "VICTORIA Padella in Ghisa 30 cm", "price": "49,52 €", "image": "https://m.media-amazon.com/…", "ref": "41"}],
   "product": null, "cart": {"count": 0, "total": null}, "form": null, "captcha": null, "signin": "3"}
  ```
  - `kind`: `results` (a list of things: search results, a shop's or a restaurant's menu, a list of restaurants;
    `items`, up to 6, each with its picture or null, name, price or null, and `ref`: its link, or for a dish with its
    own "+" that button, which adds it), `rows` (since 2026-10-28: a timetable, trains, buses or flights with no
    pictures; `rows`, up to 8, each `{times: [leaves, arrives] ("05:20"), title (the train: "Regionale Veloce 2713",
    or null), places ([from, to], may be empty), detail ("1h 45min · 1 cambio", or null), price (or null), ref}`;
    `rows` is `[]` on every other kind), `product` (`product`: `{title, price, image, rating}`, any but `title` may be null), `cart`, `checkout`,
    `confirmation` (an order placed), `login`, `code` (a one-time code), `captcha`, or `page` (anything else: show
    `title`).
  - `query`: what was searched, or null. `icon`: the site's icon, or null. `cart`: `{count, total}` when the page shows
    a cart badge or a total (each may be null), else null.
  - `form` (on `login` and `code`): `{"fields": [{"ref": "7", "kind": "username", "label": "Indirizzo e-mail",
    "filled": false}], "submit": {"ref": "8", "text": "Continua"}, "choices": [{"ref": "9", "text": "SMS al
    ***12"}], "remember": "10", "remembered": false, "error": "Password errata"}`. Field `kind`: `username`,
    `password`, `code`, `phone`, `dial` or `text`; `filled`: it has a value (a password's is never read). `submit`, `remember`
    (a "stay logged in" box) and `error` may be null; `choices`: radio options (where to send a code), often empty.
    A `dial` field (since 2026-10-30) is a phone number's dialling code ("Prefisso"), often a box that opens a country
    list rather than one to type in: it carries `value` (the code on the page now, `"+34"`, or null) and `suggested`
    (the user's own, `"+39"`). The app puts `suggested` in for the user and sends a `fill` with the code (`"+39"`,
    `"39"`, `"0039"`) only when it differs from `value`; the server picks that country on the page.
  - `captcha` (on `captcha`): `{"kind": "text" | "grid" | "checkbox" | "other", "ref": "12", "input_ref": "13",
    "submit_ref": "14"}`: `text` is a picture of characters to type in `input_ref`, then press `submit_ref` (either may
    be null); the others are solved by tapping its picture (`crop`).
  - `signin`: on a page that isn't a login, the ref of its "Accedi" / "Log in" link or button, or null: `press` it to
    go to the login (the app's "Go to the login").
  - Refs are the same as the model's (`read_page`), and may change when the page does.
- `{"type": "crop", "data": "<base64 JPEG>", "box": {"x": 0.1, "y": 0.3, "width": 0.8, "height": 0.2}}` (since
  2026-10-28): the CAPTCHA's picture, with a scene of kind `captcha` (again whenever the picture changes). `box` is where it is on
  the page, as fractions of the frame: a tap at (u, v) on the picture is `tap` at (x + u·width, y + v·height).
The app shows the errand in its chat card while it's going (a socket per card on screen; a refused socket, `1008`
because the page isn't open yet, is tried again every few seconds).

App to server (only while `control` is true):
- `{"type": "tap", "x": 0.42, "y": 0.61}`: a tap, as fractions of the frame.
- `{"type": "scroll", "x": 0.5, "y": 0.5, "dy": 0.4}`: a scroll at that point, `dy` in screen heights (positive:
  down).
- `{"type": "text", "text": "…"}`: typed into the focused field (up to 500 characters a message). Never logged,
  stored or given to the model.
- `{"type": "key", "key": "Enter" | "Tab" | "Backspace" | "Escape" | "Back"}` (`Back`: the page's back).
- `{"type": "fill", "ref": "7", "text": "…"}` (since 2026-10-28): your text into one of the last scene's `form`
  fields or its CAPTCHA's `input_ref` (other refs are ignored). Never logged, stored or given to the model.
- `{"type": "press", "ref": "8"}` (since 2026-10-28): press the last scene's form `submit`, one of its `choices`,
  `remember`, its `signin`, or the CAPTCHA's `submit_ref`. Pressing `submit` ticks `remember` first when it isn't ticked.
- `{"type": "frames", "on": true}` (since 2026-10-28, any time): start or stop the frames ("Show the real page").
- `{"type": "done"}`: you're done. For an errand waiting on you, the same as `POST /v1/errands/{id}/done`; with
  `?site=`, the page is closed (the login stays). The server then closes the socket.

## Videos

Send Aide a YouTube video and get back what happens in it and what to know (since 2026-10-30). There are two ways in:
- paste a link in any chat with Aide or Professor (the model calls `summarize_video`);
- share it from YouTube or Safari through the app's share extension (`POST /v1/videos`, which opens a new Aide chat).

The server reads the video in the background, one at a time:
1. yt-dlp gets the details and captions: the video's own captions in its language, else YouTube's automatic ones.
   With no captions it transcribes the audio with Whisper.
2. Sonnet writes the brief in English, whatever the video's language.
3. A frame is taken a few seconds after each key moment, and Haiku keeps only the frames that show something (a
   slide, a diagram, code, a product), not a person talking.
4. It posts in the chat with its card, and sends a `message` push. The message's text is only what the card doesn't
   show: the answer to the user's question, else the TL;DR (the title, gist and the rest are on the card and its page).

It takes about 30 s for a 20-minute video with captions, and longer for Whisper. The agents read a video already
read with `read_video` (the brief, or the transcript's lines about something, with their times) and list them with
`list_videos`.

```jsonc
// VideoCard: on chat messages (`videos` attachment) and in the list
{
  "id": "v_3f9a1c2b7d",
  "youtube_id": "aircAruvnKk",
  "url": "https://www.youtube.com/watch?v=aircAruvnKk",   // the link as given
  "status": "queued",            // queued | working | ready | failed
  "step": "Writing the brief",   // while queued or working: what it's doing, else null
  "error": null,                 // failed: why, in words for the user ("It's a private video.")
  "title": "But what is a neural network?",   // null until it's been looked up
  "channel": "3Blue1Brown",
  "duration": 1120,              // seconds, or null
  "thumbnail": "https://i.ytimg.com/vi/aircAruvnKk/maxresdefault.jpg",
  "gist": "Two lines on what it is.",   // null until ready
  "moments": 9,                  // how many key moments
  "frames": 6,                   // how many of them have a frame
  "cover": "p_5afef32c44506e0e", // the first frame's photo id (GET /v1/photos/{id}), or null
  "created_at": "2026-10-30T13:46:00+01:00"
}
```

A **Video** (`GET /v1/videos/{id}`, `POST /v1/videos`) is a VideoCard plus the brief. Its `moments` is the list,
not the count:
```jsonc
{
  /* …VideoCard… */
  "question": "Is it hard?",     // what the user asked of it, or null
  "published": "2017-10-05",     // or null
  "language": "en",              // the spoken language
  "source": "captions",          // captions (the video's own) | auto (YouTube's) | whisper; null until read
  "conversation_id": "c_…",      // the chat it was asked from and posts in
  "chapters": [{"t": 0, "title": "Intro"}],   // the video's own chapters, seconds
  "tldr": "A paragraph.",
  "know": ["What you should know, a line each."],
  "takeaway": "The one thing to remember.",
  "answer": "The answer to `question` from the video, or that it doesn't say; null without a question.",
  "moments": [
    {"t": 163, "title": "Neurons and activations", "text": "Two or three lines.",
     "frame": "p_90b73538e54acca8",   // a photo id, or absent: no frame worth showing
     "url": "https://www.youtube.com/watch?v=aircAruvnKk&t=163s"}   // opens YouTube at that moment
  ]
}
```
Moments are in time order, 4 to 10 of them. Frames are 1280 px wide JPEGs, served by `GET /v1/photos/{id}`.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/videos` | `{"url": "https://youtu.be/…", "question": "what does he say about X?", "conversation_id": null}` | `{"video": Video, "conversation_id": "c_…"}`. `url` may be any text with a YouTube link in it. Without `conversation_id` it makes a new Aide chat, titled after the video once that's known. The chat gets the link (and the question) as your message and "Reading it now" with the card. `400`: no YouTube link; `404`: unknown `conversation_id` |
| `GET /v1/videos?q=neural&limit=100` | | `{"videos": [VideoCard], "enabled": true}`, newest first; `q` matches the title, channel and brief |
| `GET /v1/videos/{id}` | | the Video; `404` |
| `DELETE /v1/videos/{id}` | | `{"ok": true}`: the video, its brief, its frames and its vault page go; `404` |

Without the worker the endpoints answer `503` and the list is empty with `enabled` false.

What it can't read fails with the reason: private, members-only, age-restricted or removed videos, live streams,
and videos over 4 hours. A restart puts a video being read back in the queue.

Each ready video is also a page in the Obsidian vault, `Aide/Videos/<title>.md`: the link, channel and date, your
question and its answer, the TL;DR, what to know, the moments with their times (links to YouTube) and frames
(`Aide/Videos/Frames/`), the takeaway, and the transcript folded.

## Push

The server notifies the phone through APNs. It sends only when it has a key (`APNS_*` in `.env`) and at least one registered device; otherwise nothing is sent and everything is still in the app.

### Devices

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/devices` | `{"token": "a1b2…", "environment": "sandbox" \| "production", "name": "My iPhone"}` | `{"ok": true}`. Adds or updates the device (keyed by `token`). |
| `GET /v1/devices` | | `{"devices": [{"token": "a1b2…", "environment": "sandbox", "name": "…", "registered_at": "…", "last_push_at": "…" \| null}]}` |
| `DELETE /v1/devices/{token}` | | `{"ok": true}`, also for an unknown token. |
| `POST /v1/devices/test` | `{}` | `{"sent": 1, "failed": 0}`. Sends a visible test push to every device. |

- `token` is the APNs device token as lowercase hex. `environment` is `sandbox` for Debug builds from Xcode and
  `production` for TestFlight and App Store builds. The server must send each token to the matching APNs host.
- The app registers on every launch (the token can change), and when notifications are turned on in Settings.
  A `404` means an older server: the app ignores it.
- When APNs answers that a token is no longer valid (`410 Unregistered`), the server deletes the device. A `400
  BadDeviceToken` keeps it: that's also the answer for a good token sent to the other host (a Debug build installed
  over a TestFlight one), and the app's next registration puts the right `environment` back.

### Payloads

Every push carries an `aide` object saying what it is. The app ignores kinds it doesn't know.

| `aide.kind` | Type | When | Extra fields | On tap |
|---|---|---|---|---|
| `sync` | silent (`content-available: 1`, push type `background`, priority 5) | reminders changed on the server, a habit with `health` was counted, a meal or a Screen Time lock changed | | (not shown) the app runs a reminders sync, writes `health_logged` and meals to Health, and sets the locks |
| `reminder` | alert | due, but not on the phone (see the notification rule) | `reminder_id` | opens Today |
| `digest` | alert | a scheduled digest, or the wake-up briefing, is ready | `digest` (`daily`, `wake`, `evening`, `weekly`, `monthly`) | opens Today on the digest (since 2026-10-26; before: a new chat with it) |
| `message` | alert | an agent writes first: a routine or watch, lecture notes, a notebook proposal; or a chat reply finished after the app hung up on the stream (since 2026-10-29; title the agent's name, body the reply's first line; since 2026-10-30 also when a Live Activity was there, which the server ends first) | `conversation_id`, `routine` (a routine's or watch's post only) | with `routine`: opens Today on that note; else that conversation |
| `lecture` | alert | a lecture's notes are ready, or it failed (title "Professor · macroeconomics") | `lecture_id` | opens that lecture |
| `moodle` | alert | a Moodle sync brought new files (title "Moodle · 3 new files", a line per course naming them: "Macroeconomics: Lecture Notes: Monetary Policy, Lect: Monetary Policy"), or the login expired | `files` (the new files' ids, up to 20; since 2026-10-26), `login` (true: log in again) | lists the new files (`GET /v1/files/{id}`), each opening its PDF; the Moodle login with `login` |
| `transit` | alert, `interruption-level: time-sensitive` | a tram alert fires ("Tram 4 in 7 min: leave now") | `alert_id` | nothing special (opens the app) |
| `location` | silent (like `sync`) | a tram alert wants to know where the phone is | | (not shown) the app sends a fresh fix to `POST /v1/location` |
| `errand` | alert; `interruption-level: time-sensitive` when it needs you in the live view or waits for a Confirm | a browser errand needs you (a login, a code, a card step), asks something, waits for a Confirm (since 2026-10-30 only when its Live Activity didn't say it), is done or failed (since 2026-10-27). Not shown while the app is on that errand's chat or live view | `errand_id`, `conversation_id` | needing you in the live view: opens it (`aide://errand/<id>`); else the conversation |
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
- Since 2026-10-30, `message` and `errand` pushes carry `apns-collapse-id` (`message-<conversation id>`,
  `errand-<errand id>`): a newer one for the same chat or errand replaces the older one in Notification Center.
- A scheduled digest is pushed to every device.
- Silent `sync` pushes are coalesced: at most one per 10 seconds, so a burst of changes sends one.

## Live Activities

Three kinds on the Lock Screen and in the Dynamic Island, all drawn by the app's widget extension:

- **`tram`**: a tram alert's countdown. When an alert fires, the server starts it (APNs push-to-start) instead of
  the `transit` push, then keeps it live (the tram's expected time, its delay, the next one) until the tram has left,
  or, once the user is on it, until they get off.
- **`agent`**: an agent at work. The app starts one when it sends a chat or Team chat message; the server keeps it
  up to date (asking another agent, writing) and ends it at once when the reply is in, which then comes as a
  `message` push. Since 2026-10-27 the server also starts one for Professor writing notes (a notebook proposal being
  applied, a lecture's notes), and one for each browser errand.

One notification for each thing (since 2026-10-30): while an agent works, its activity is quiet; when it needs you
(a login, a question, a Confirm), the activity says so with an alert and no other push goes; when it's done or
failed, the activity goes at once and one normal push takes its place.
- **`event`** (since 2026-10-27): the next calendar event's countdown, started by the server 10 minutes before a
  timed event on the Work calendar ("Macroeconomics in 10 min · Aula 5"), unless leave-now has set a tram alert for it.

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
  stops pushing (and, for a tram, stops following it). Keys and tokens older than 12 hours are dropped. Since 2026-10-27, an activity the server started
  and ended before its token came (a short job) is ended as soon as the token comes, within an hour.
- `/v1/live/settings` (since 2026-10-27): `events` (default true) turns the `event` countdowns on or off.
- Tokens are hex, like device tokens; `environment` as for devices. A token APNs refuses (`410`, `BadDeviceToken`)
  is deleted.
- Since 2026-10-27 every `start` push carries `"input-push-token": 1`, so iOS gives the new activity an update token
  (without it a push-started activity got one only now and then, and stayed as it started). When a tram countdown's
  token still hasn't come, the server sends a silent `location` push (at most one a minute), and the app sends the
  update tokens of its activities that the server hasn't had yet (`activity.pushToken`), with the fix.

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
| `status` | `working`, `asking` (Aide asked another agent), `writing` (the reply is coming), `done`, `failed`; for an errand also `browsing` and `needs_you` (since 2026-10-27) |
| `detail` | a few words for `asking` ("Asking Coach") or `failed`; else empty |
| `text` | `done`: the reply's first line, cut to about 140 characters; else empty |
| `since` | when it started working |

- A chat turn: the app starts the activity (status `working`) and registers its key; the server sends `update`s as
  the turn goes (each ask; `writing` once, when the reply starts), at most one per 2 seconds, priority 5. About 3 s
  after the turn ends, if the key is still there, it sends an `end` with `done` (`text` the first line), dismissed at
  once and with no alert, then the `message` push with the reply (since 2026-10-30; before: an alert on the activity
  and an `end` dismissed after 30 minutes). A failed turn ends with `failed`, no alert, dismissed at once.
  A turn that started a browser errand hands over to the errand's activity: when the server has an `agent` start
  token, the turn's activity ends at once with no push, since the errand's is what comes next.
  An app that lost the stream leaves the activity to the server (no `failed` of its own, no delete) while the
  chat's history says `working`, so the `message` push still comes.
- Routines start none (since 2026-10-30; before, each scheduled run had one with a "Working on it" alert): the
  `message` push with the result is a routine's one notification.
- A notes job (since 2026-10-27): the server push-starts it under the key `notes:<proposal id>` (a notebook
  proposal being applied) or `notes:<lecture id>` (a lecture of a course), agent `professor`, `conversation` the chat
  the result goes to (the proposal's own, else the course's), `title` the course's name, with a quiet alert
  ("Professor · Macroeconomics", "Writing 5 topics"). Updates as it goes (status `writing`, `detail` the step:
  "Transcribing the lecture", "Writing the notes", "Writing The IS-LM model, Crowding out"), at most one per 2 s,
  then `end` with `done` (`text` the result) or `failed`, dismissed at once: the `message` or `lecture` push that
  follows is the notification. Its content state has two more fields, `done` (topics written so far, failed ones
  included) and `total` (the topics being written); both null on lecture notes and absent on every other agent
  activity.
- A browser errand (since 2026-10-27): the server push-starts it when the errand begins, under the key
  `errand:<errand id>`, agent `aide`, `conversation` the errand's chat, `title` the errand's, with a quiet alert
  ("Aide · USB-C cable"). Status `browsing` with `detail` the step ("Opened amazon.it", "Clicked Aggiungi al
  carrello"), at most one update per 2 s; `needs_you` with an `alert` when it waits for the user (`detail`: "Log in
  to Amazon", the question, "Confirm: Order the cable"; `stale-date` 30 minutes on). Since 2026-10-30 that alert is
  the one notification: the `errand` push for it goes only when the activity didn't take the update (no start token,
  no update token yet, APNs refused it). After 30 minutes waiting the activity ends at once, still `needs_you` (the
  errand goes on waiting in its chat and in Waiting for you), and a new one starts when the errand goes on. Back to
  `browsing` when it goes on (one activity across the whole errand); then `end` with `done` (`text` the result) or
  `failed`, dismissed at once. Its content state has one
  more field, `errand` (the errand's id), absent on every other agent activity; `done` and `total` are null.
  Tapping it opens the live view while it needs you (`aide://errand/<id>`), else the conversation.
- Tapping the activity opens the conversation (`aide://conversation/<id>`; the Team chat: `aide://team`).
- When the server starts (since 2026-10-30), it ends at once, as `failed` with `detail` "Interrupted", every chat,
  errand and notes activity whose key it still has: the restart cut their jobs off. Tram and event countdowns are
  followed again instead.
- Opening a chat in the app ends its `agent:<conversation id>` activity and clears that chat's delivered
  notifications.

**`event`** (`EventActivityAttributes`). Attributes: `key` (`event:<12 hex of the uid's hash>:<start, Unix>`),
`title`, `calendar`. Content state: `start` and `end` (Unix seconds; `end` null when there's none), `place` (the
event's location, or null) and `started` (it has begun: the last update). Since 2026-10-27 also `since` (Unix
seconds: when the countdown began, for a bar filling up to `start`), `notes` (the event's notes' first line, at most
80 characters, or null) and `then` (`{"title", "start"}`: the next timed event the same day, or null); the app
treats them as optional.

- Started 10 minutes before a timed (not all-day) event on the Work calendar, with a quiet alert ("Macroeconomics in
  10 min", body the place, else "At 09:00"); `stale-date` 10 minutes after the start. (30 minutes and any calendar
  until 2026-10-27.) `then` can be an event on any calendar. An event moved off Work ends its countdown at once.
- Not for an event leave-now has set a tram alert for (the tram's activity takes you there); a tram alert set while
  it's on ends it at once.
- An `update` when the event moves or its place changes; `end` with `started` true at the start, dismissed 10
  minutes later; `end` dismissed at once when the event is deleted or moved to another calendar.
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
