# Aide

Personal AI assistant for one person (Filippo): calendar, reminders, habits and later mail, through chat.
[SPEC.md](SPEC.md) is the original plan; this file is the current state and how to work on it.

## Two machines, one repo

| Machine | Works on | Runs |
|---|---|---|
| **Ubuntu desktop** (`cappa`, always on) | the server: `src/`, `tests/`, `deploy/` | the Aide service (Discord bot + HTTP API) |
| **MacBook** | the iOS app: `ios/` | Xcode, the iOS Simulator |

Both machines run Claude Code on the same GitHub repo (`filippocappa/aide`).

- **Pull before you start, push when a piece works.** Small commits, clear messages.
- **Stay in your area.** The Ubuntu session changes server code, the Mac session changes `ios/`. That keeps merge conflicts away.
- **`docs/API.md` is the contract between them.** Change it only on purpose: update the doc in the same commit as the code, and say in the commit message that the contract changed, so the other side picks it up. The server must keep old fields working until the app stops using them.
- `brand/` holds the logo (Pebble). Use `brand/logo/` assets for the app icon and UI. Don't redraw them.

## Server (Ubuntu)

Python 3.12, managed with `uv`. Entry point `src/aide/__main__.py`.

- `agent.py`: Claude tool-use loop (via OpenRouter, Anthropic SDK), conversation history, the confirmation queue.
- `agents.py`: the agents (Aide and the specialists): prompts, tool sets, colours, starters.
- `db.py`: SQLite (WAL) at `data/aide.db`.
- `tools/`: everything that touches the outside world (`calendar.py` uses `icloud.py`, CalDAV).
- `channels/discord_bot.py` and `channels/api.py` (FastAPI, the app's API): two adapters over one agent and one shared conversation.
- `reminders.py`: reminders store and the sync rules. `scheduler.py`: background jobs (the Discord fallback).
- `push.py`: APNs sender and the devices table (off without `APNS_*` in `.env`; then Discord only).
- `health.py`: Apple Health days, "usual" numbers, sleep and recovery. `wake.py`: the wake-up briefing.
- `habits.py`: habits and streaks. `digest.py`: daily/weekly/monthly digests and their schedule.
- `routines.py`: routines (an agent's scheduled job, posting in its own chat), their schedule and alerts.
- `backup.py`: nightly backup to `~/aide-backups` (`deploy/aide-backup.timer`; restore notes in README.md).

```bash
uv run pytest                       # tests; keep them green
systemctl --user restart aide       # deploy after changes (it runs from this checkout)
journalctl --user -u aide -f        # logs
```

Rules that matter here:
- **Destructive or outward-facing actions are queued in code** and run only after the user's `!yes` (Discord) or `POST /v1/confirm` (app). Never let the model execute them directly.
- Each user message is stamped with local time and the live queue. The model shouldn't rely on remembered times or queue state.
- Secrets live in `.env` only (git-ignored). Never commit or print them.
- Times: store UTC, talk to the user in `AIDE_TIMEZONE` (Europe/Rome).

## iOS app (MacBook)

SwiftUI, iOS 17+, Xcode project in `ios/Aide/`. Paid Apple Developer Program account (bought 2026-10-18;
enrolment may still be finishing), so:
- Sign with the paid team, not "Personal Team". Installs last a year, and TestFlight is available.
- **Push notifications** (APNs): built on both sides, live once the `.p8` key exists. `PushService` registers the
  device token, silent `sync` pushes run the reminders sync, taps route through `AppEnvironment.open(_:)`.
- Push is opt-in per Mac: `AIDE_ENTITLEMENTS = Aide/Aide.entitlements` in `ios/Aide/Config/Signing.local.xcconfig`
  (see the `.example`). A Personal Team can't sign it, so leave it out until the paid team is active.
- The team ID goes in `Signing.local.xcconfig`, not in Xcode's Signing tab: `xcodegen generate` rewrites the project.
- Develop against the **Simulator** (no signing needed). Install on the phone only to try it for real.

```bash
cd ios/Aide
xcodebuild -scheme Aide -destination 'platform=iOS Simulator,name=iPhone 16' build   # compile check
xcodebuild -scheme Aide -destination 'platform=iOS Simulator,name=iPhone 16' test    # unit tests
```
(Check `xcrun simctl list devices available` if that simulator name doesn't exist.)

What the app does, v1:
1. **Chat** with Aide. Same conversation as Discord, so you can start on one and continue on the other.
2. **Today:** today's calendar events and reminders.
3. **Reminders sync** with Apple Reminders through EventKit. The app is the only part that can touch Apple Reminders. Each synced reminder gets an EventKit alarm at its due time, so **Apple** notifies the user even with the app closed. Until push exists, reminders that haven't reached the phone are sent as Discord DMs.
4. **Settings:** server URL and API token, kept in the Keychain. Never hardcode them.

The app reaches the server over Tailscale (the phone needs the Tailscale app). Everything is in `docs/API.md`.

## Roadmap

Where things stand (2026-10-19):

**Done, server (Ubuntu, live):**
- Core: Discord bot, agent loop, systemd service; iCloud Calendar; Gmail (read, search; send and reply after
  confirmation; one-time setup in README.md, "Gmail").
- HTTP API v1, all of `docs/API.md`: chat with many conversations and memory, reminders store and sync, Discord
  fallback for reminders not yet on the phone.
- Nightly backups to `~/aide-backups` (user timer, 14 daily + 8 weekly; restore notes in README.md).
- Habits with streaks and a 26-week `history` for the app's grid.
- Digests: morning (`daily`), evening, weekly, monthly, on the schedule in the digest settings, also sent as
  Discord DMs. Data sections are rebuilt live on every read; only the greeting (a short spoken note) is stored.
  Reminders: due in the period plus today's overdue. Mail: today's inbox. A new chat can open with the
  greeting (`POST /v1/conversations` with `digest`). Background in `docs/digest-v2.md` (built, both sides).
- Chat `attachments`: reminder and event cards from the turn's tool calls, in `/v1/chat` and `/v1/history`.
- Web search (Tavily: `web_search`, `fetch_page`) and Google Maps (`find_places`, `travel_time`), read-only,
  each on only when its key is set; home from `AIDE_HOME_ADDRESS`, or memory when it says otherwise. Plain chat
  text for now; place cards in the app can come later.

**Done, app (Mac):** iOS app v1 (chat, Today, reminders sync, settings), voice chat, habits tab, digest
greeting as the first chat message with a Details sheet, digest settings, reminder and event cards with tick
boxes in chat from `attachments`, the habit grid from `history` (9f24ec4).

**Done, both sides, not yet tried live:** push (issue #1). Server: devices endpoints, APNs sender, silent `sync`
on server-side reminder changes, `reminder` and `digest` alerts with Discord as the fallback. App: device
registration, background sync on silent pushes, taps open the digest chat, the conversation or Details, and
Settings → Notifications with a test button. Needs the `.p8` key (README.md, "Push notifications") once the
developer enrolment finishes; then install on the phone and send a test. App unit tests not yet run (this Mac
had no Simulator runtime on 2026-10-19).

**Done, both sides, not yet tried live:** Apple Health (#2), contract in `docs/API.md` ("Apple Health"). App:
daily health summaries with a 60-day backfill, HealthKit background delivery, the "I'm up" App Intent for a
Shortcuts Sleep → Waking Up automation, the `wake` digest with sleep and recovery cards, Watch workouts ticking
habits. Health is on by default (`Aide/Health.entitlements`); `Aide.entitlements` has push plus Health. Server
(live): `health_days` and `/v1/health/days`, habit `workouts` and `PATCH /v1/habits/{id}`, `POST /v1/wake` and the
implicit wake from an upload (once a day, 03:00–15:00, waits up to 10 min for sleep), the `wake` digest with a
time-aware greeting and leave-by times (Maps: walk and transit, arriving 10 min early, home and per-place mode from memory, else `AIDE_HOME_ADDRESS`), `sleep` and `recovery`
sections in `wake` and `daily`, the read-only `health` tool. No real health data uploaded yet.

**In progress:** agents (contract in `docs/API.md`, "Agents"): Aide as the orchestrator that asks Secretary,
Professor, Coach and Finance (`ask_agent`), each with its own chats, tools, memory and Pebble colour. App side built
(agent row in the chat list, tinted Pebble, starters, "Asked Coach" above replies, memory per agent). Server
(live): definitions and prompts in `agents.py`, `GET /v1/agents`, `agent` on conversations and memory, each chat
answered by its agent with its own tools and memory (shared plus its own; Aide sees shared only), `ask_agent` for
Aide (one stateless turn, max 3 per turn, `consulted` in chat and history). Team talk: every ask and answer is
stored (`team` in chat and history, `GET /v1/team`), and `"stream": true` on `/v1/chat` sends them live as
server-sent events (checked through `tailscale serve`, not buffered). Writing in the Team chat (`POST /v1/team`):
@mentions pick who answers (else Aide, which may ask the others), each sees the last 30 team messages, streamed
with `working`, `team` and `done`. Discord stays on Aide. Not yet tried from the app.

**Done, server (live), app not yet built:** routines (contract in `docs/API.md`, "Routines"): `/v1/routines` CRUD
and `run`, a chat per routine (`routine` on conversation rows and on the messages a run posts), the scheduler
(30 s tick, a run missed by less than 2 h runs once after startup), an alert push per run with a Discord DM as the
fallback, `routines` tools for every agent (Aide for anyone, the others their own; deleting is queued), and
`routine_ideas` on `/v1/agents`.

**Next:** try push live, then Discord becomes optional. Later for health: bedtime nudge in the evening digest,
weekly health recap, the getting-sick hint (resting HR, HRV and wrist temperature off baseline together).
