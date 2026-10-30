# Digest v2: proposal (for the Ubuntu session)

Status: **server part built** (2026-10-19, Ubuntu; contract in `docs/API.md`, "Digest" and "Conversations").
**App part built** (2026-10-19, Mac): see "App changes" below. Written on the Mac on 2026-10-19 from the user's feedback.

Built as proposed, plus the details the app may care about: the `reminders` window ends at the end of the
period (so tonight's later reminders show in the evening digest too); `mail` is capped at 25; `POST
/v1/conversations` with `digest` reuses the stored greeting only if it still covers the same days, otherwise it
makes a fresh digest first (can take 5–30 s, so show the typing indicator); the `text` section ("Looking ahead" /
"Wrap-up") is still there, stored like the greeting.
`docs/API.md` stays the contract: change it in the same commit as the server code, as usual.

## What's wrong now

- **Stale reminders.** The morning digest is a snapshot taken at 08:00 and the app shows that stored copy all day,
  so reminders you've done since (or that have passed) are still listed.
- **Overdue clutter.** `ReminderStore.due_before` includes every open reminder ever due. Many are one-off alerts
  ("call X at 10") that are just past, not real to-dos.
- **Mail is "unread in inbox"** (for the evening: unread from today). The user wants "what mail came in today".
- **It reads like a calendar dump.** In practice it's mostly the 7-day calendar list. The user wants something closer to
  "Hi, here's your schedule for tomorrow and the things you have to do."
- The app no longer shows the digest on the empty new-chat screen (only behind the sun button), because a full
  card page there felt heavy.

## The idea: the digest is Pebble's first message

A new chat opens with Pebble saying a short, spoken-style note, which you can answer straight away
("move the dentist to Friday"). The cards stay available behind the sun button for the details.

Example (evening):
> Tomorrow is light: the dentist at 15:00 and gym at 19:00. Still to do: pay the electricity bill and call Marco.
> 6 emails today; the one from Giulia about Saturday looks like it wants an answer.

## Server changes

1. **Live data at read time.** `GET /v1/digest` recomputes the data sections (calendar, reminders, mail, habits)
   when it's called. Only the greeting comes from the stored, scheduled generation. Completed or deleted reminders
   never appear.
2. **Reminders:** open ones due in the period, plus overdue ones from the **last 48 h** only (an `overdue` flag
   on each, so the app can mark them). Older overdue ones are left to the chat ("you have 5 old reminders").
3. **Mail: what came in today** (inbox, since local midnight; for the morning digest, since the previous evening's),
   read or unread, newest first, with `unread` kept per item.
4. **Greeting:** 2 or 3 sentences, like the example: what's coming, what to do, mail worth answering. No lists,
   no repeating every event.
5. **Digest as a chat message:** `POST /v1/conversations` accepts optional `{"digest": "evening"}` (or `daily`).
   The new conversation then starts with the greeting as its first assistant message, so it shows in history and
   the model knows what it said when you reply. Without the field nothing changes (old app keeps working).
   Pick the kind by local time: `daily` before 17:00, `evening` after.

## App changes (Mac, after the server ships)

- A new chat calls `POST /v1/conversations` with the digest kind and shows Pebble's message like any reply, with a
  small "Details" link under it that opens the existing digest sheet.
- Overdue reminders get a subtle "overdue" label in the cards.
- Digest settings already got simpler (one list, schedule rows only for the digests that are on).
