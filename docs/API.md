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
  "pending": [{"id": 42, "summary": "Move 'Dentist' from Tue 20 Oct 15:00–16:00 to Fri 23 Oct 10:00–11:00"}]
}
```
A reply can take 5–30 s (the model plus tools). Use a request timeout of at least 90 s and show a typing indicator.

`pending` lists the actions waiting for confirmation, written by code, not the model. When it isn't empty, show the summaries with **Confirm** and **Cancel** buttons.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/confirm` | `{}` | `{"result": "✓ Moved: …", "pending": []}`. Runs every pending action. |
| `POST /v1/cancel` | `{}` | `{"result": "Cancelled. Nothing was changed.", "pending": []}` |
| `POST /v1/new` | `{}` | `{"ok": true}`. Starts a fresh conversation (like `!new`). |
| `POST /v1/think` | `{}` | `{"ok": true}`. Smarter model for the rest of the conversation (like `!think`). |

`GET /v1/history?limit=50` → `{"messages": [{"role": "user" | "assistant", "text": "…", "ts": "…"}]}`. The current conversation's visible text, oldest first, so the chat screen can show what was said on Discord too. Tool calls and internal notes are left out.

## Conversations

The app keeps many chats; Discord stays on the one shared conversation. Every chat endpoint takes an optional `conversation_id`. **Omitted means the shared conversation, exactly as before**, so old clients keep working. Reminders, the confirmation queue and `POST /v1/confirm` / `/v1/cancel` stay global.

| Endpoint | Body / query | Response |
|---|---|---|
| `GET /v1/conversations` | | `{"conversations": [{"id": "c_91f…", "title": "Dentist on Friday" \| null, "preview": "last message text…", "updated_at": "2026-10-18T11:20:00+02:00"}]}` newest first. Includes the shared (Discord) conversation, titled "Discord" or similar. |
| `POST /v1/conversations` | `{}` | The new conversation (same shape as a list row, `title: null`). |
| `DELETE /v1/conversations/{id}` | | `{"ok": true}`. The shared conversation can't be deleted (400). |
| `POST /v1/chat` | `{"text": "…", "conversation_id": "c_91f…"}` | Same as before, plus `"conversation_id"`. The server sets `title` from the first exchange. |
| `GET /v1/history` | `?limit=50&conversation_id=c_91f…` | As before, for that conversation. |
| `POST /v1/think` | `{"conversation_id": "c_91f…"}` (optional) | `{"ok": true}`. Smarter model for that conversation. |

The app creates a conversation with `POST /v1/conversations` before the first message of each new chat. If that returns 404 or 405 (older server), it falls back to the shared conversation.

## Memory

Short facts Aide keeps between chats (preferences, names, routines). The server puts all items into the model's context at the start of every conversation and gives the model a `remember` tool to add one (adding is harmless, so it isn't queued; the model deleting one is, like other destructive actions).

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/memory` | | `{"items": [{"id": 7, "text": "Vegetarian", "created_at": "2026-10-18T11:20:00+02:00"}]}` newest first |
| `POST /v1/memory` | `{"text": "Vegetarian"}` | The new item |
| `DELETE /v1/memory/{id}` | | `{"ok": true}` |

## Digest

A summary the server builds on a schedule: daily, weekly or monthly. The app shows the latest one on the empty new-chat screen ("Hello, today…"), and the server also sends it as a Discord DM (push notification later). Sections are structured, so the app draws cards instead of parsing text.

`GET /v1/digest?kind=daily` (`daily` default, `evening`, `weekly`, `monthly`) →
```json
{
  "kind": "daily",
  "generated_at": "2026-10-19T08:00:03+02:00",
  "greeting": "Good morning. Two meetings today and three mails that need you.",
  "sections": [
    {"type": "calendar", "title": "Today", "events": [ /* same objects as a calendar event: id, title, calendar, start, end, all_day, location, recurring */ ]},
    {"type": "mail", "title": "Mail", "items": [{"id": "…", "from": "Dr. Rossi", "subject": "Appointment", "preview": "…", "received_at": "…", "unread": true}]},
    {"type": "reminders", "title": "Due today", "reminders": [ /* Reminder objects */ ]},
    {"type": "habits", "title": "Habits", "habits": [ /* Habit objects, see below */ ]},
    {"type": "text", "title": "Looking ahead", "text": "free-form markdown"}
  ]
}
```
The app skips section types it doesn't know. `404` if none has been generated yet; `400` for an unknown `kind`.

- **Morning and evening:** `daily` is the morning digest (the app calls it
  "Morning"). `evening` is new, for before bed: tomorrow's calendar ("Tomorrow"), reminders due tomorrow or overdue,
  habits not yet done today (`habits` section, only the undone ones), unread mail from today, and a short `text`
  wrap-up (titled "Wrap-up"). It always looks at tomorrow, whatever the clock says. Default time 22:00.
- **What it covers:** daily = one day, weekly = 7 days, monthly = to the end of the month. The period starts today,
  or tomorrow if the digest is made after 17:00 (so the Sunday 18:00 weekly covers Monday to Sunday). Section
  titles say which ("Today", "Tomorrow", "Next 7 days", "October"; reminders "Due today", "Due in October", …).
  Reminders include overdue ones.
- **Only the greeting and the `text` section come from the model.** Everything else is data from code. If the
  model fails, the greeting is a plain one from code and there's no `text` section.
- **Sections can be missing:** `mail`, `reminders` and `habits` are left out when empty; `calendar` and `mail`
  when the source isn't set up or is down. `calendar` is kept when empty (nothing scheduled).
- **Schedule:** each enabled kind runs at its time. If the server was off then, it catches up within 6 hours,
  otherwise skips that one. A scheduled digest is also sent as a Discord DM when `discord` is true; `POST
  /v1/digest/run` isn't (you're looking at it). `day` 29–31 means the last day in shorter months.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/digest/run` | `{"kind": "daily"}` | The freshly generated digest (can take 5–30 s). |
| `GET /v1/digest/settings` | | `{"daily": {"enabled": true, "time": "08:00"}, "evening": {"enabled": true, "time": "22:00"}, "weekly": {"enabled": true, "weekday": 7, "time": "18:00"}, "monthly": {"enabled": true, "day": 1, "time": "09:00"}, "discord": true}` (times in the server zone, `weekday` 1 = Monday) |
| `PUT /v1/digest/settings` | the same object (all of it; `evening` may be missing from older clients: keep its current value) | the saved settings; `400` if a time isn't `HH:MM` or a field is missing or out of range |

## Habits

Habit object: `{"id": 3, "name": "Gym", "cadence": {"type": "daily"} | {"type": "weekly", "per_week": 3}, "streak": 4, "done_today": false, "last_done": "2026-10-18" | null}`.

| Endpoint | Body | Response |
|---|---|---|
| `GET /v1/habits` | | `{"habits": [Habit]}` |
| `POST /v1/habits` | `{"name": "Gym", "cadence": {"type": "weekly", "per_week": 3}}` | the new Habit |
| `POST /v1/habits/{id}/check` | `{"date": "2026-10-18"}` (optional, default today; send `"done": false` to undo) | the updated Habit |
| `DELETE /v1/habits/{id}` | | `{"ok": true}` |

`streak` counts consecutive scheduled periods done: days for a daily habit, Monday-to-Sunday weeks with at least
`per_week` checks for a weekly one. Today (or this week) adds to the streak once it's done, and doesn't break it
while it's still in progress. Names are unique, ignoring case (a duplicate is `400`); checking a future date is
`400`; an unknown id is `404`.

The assistant also gets tools to add, check and list habits (deleting is queued for confirmation).

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

**Notification rule (server side):** at `due_at`, if a reminder is still not completed and has no `apple_id` (it never reached the phone), the server sends it as a Discord DM. Otherwise Apple Reminders notifies, and the server stays quiet.
