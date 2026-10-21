# Aide

Personal AI assistant for one person (Filippo): calendar, reminders, habits and later mail, through chat.
[SPEC.md](SPEC.md) is the original plan; this file is the current state and how to work on it.

## Two machines, one repo

| Machine | Works on | Runs |
|---|---|---|
| **Ubuntu desktop** (`cappa`, always on) | the server: `src/`, `tests/`, `deploy/` | the Aide service (HTTP API, scheduler) |
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
- `channels/api.py` (FastAPI): the app's API, the only way in since the Discord bot was removed (2026-10-21).
- `reminders.py`: reminders store and the sync rules. `scheduler.py`: background jobs (a push for reminders not yet on the phone).
- `push.py`: APNs sender and the devices table (off without `APNS_*` in `.env`; then nothing is pushed).
- `photos.py`: photos for chat and food, files in `data/photos/` (backed up once each). `food.py`: meals and food goals.
- `health.py`: Apple Health days, "usual" numbers, sleep and recovery. `wake.py`: the wake-up briefing.
- `habits.py`: habits and streaks. `digest.py`: daily/weekly/monthly digests and their schedule.
- `study.py`: courses (from the timetable calendar), lectures, notes; the worker that runs `whisper.py` on the GPU.
  `material.py`: study files (PDFs, page text, search). `vault.py`: the Obsidian vault Aide writes, served by
  `webdav.py` (its own unit, `deploy/aide-webdav.service`, published by `tailscale serve` on 8443). `moodle.py`:
  the university Moodle's PDFs into the study files (login through the app; the token in `.env`).
- `notebook.py`: course notebooks (an Introduction on the exam, a page per topic with questions and flashcards),
  built and grown from the study material, each change proposed in the course chat first; the worker that writes them.
- `routines.py`: routines (an agent's scheduled job, posting in its own chat), their schedule and alerts.
- `backup.py`: nightly backup to `~/aide-backups` (`deploy/aide-backup.timer`; restore notes in README.md).

```bash
uv run pytest                       # tests; keep them green
uv sync --extra whisper             # after a pull that changed dependencies (the extra: Whisper on the GPU)
systemctl --user restart aide       # deploy after changes (it runs from this checkout)
journalctl --user -u aide -f        # logs
```

Rules that matter here:
- **Destructive or outward-facing actions are queued in code** and run only after the user's `POST /v1/confirm` (Confirm in the app). Never let the model execute them directly.
- Each user message is stamped with local time and the live queue. The model shouldn't rely on remembered times or queue state.
- Secrets live in `.env` only (git-ignored). Never commit or print them.
- Times: store UTC, talk to the user in `AIDE_TIMEZONE` (Europe/Rome).

## iOS app (MacBook)

SwiftUI, iOS 17+, Xcode project in `ios/Aide/`. Paid Apple Developer Program account (active since
2026-10-20; team `6HCM796G2T`), so:
- Sign with the paid team, not "Personal Team". Installs last a year, and TestFlight is available.
- **Push notifications** (APNs): live since 2026-10-20 (key `79B9MDBW26` on `cappa`, in `~/.config/aide/`). `PushService` registers the
  device token, silent `sync` pushes run the reminders sync, taps route through `AppEnvironment.open(_:)`.
- Push is opt-in per Mac: `AIDE_ENTITLEMENTS = Aide/Aide.entitlements` in `ios/Aide/Config/Signing.local.xcconfig`
  (see the `.example`). This MacBook has it on. A Personal Team can't sign it.
- The team ID goes in `Signing.local.xcconfig`, not in Xcode's Signing tab: `xcodegen generate` rewrites the project.
- Develop against the **Simulator** (no signing needed). Install on the phone only to try it for real.

```bash
cd ios/Aide
xcodebuild -scheme Aide -destination 'platform=iOS Simulator,name=iPhone 16' build   # compile check
xcodebuild -scheme Aide -destination 'platform=iOS Simulator,name=iPhone 16' test    # unit tests
```
(Check `xcrun simctl list devices available` if that simulator name doesn't exist.)

What the app does, v1:
1. **Chat** with Aide and the specialists, with photos.
2. **Today:** today's calendar events and reminders.
3. **Reminders sync** with Apple Reminders through EventKit. The app is the only part that can touch Apple Reminders. Each synced reminder gets an EventKit alarm at its due time, so **Apple** notifies the user even with the app closed. Reminders that haven't reached the phone are pushed.
4. **Settings:** server URL and API token, kept in the Keychain. Never hardcode them.

The app reaches the server over Tailscale (the phone needs the Tailscale app). Everything is in `docs/API.md`.

## Roadmap

Where things stand (2026-10-20):

**Done, server (Ubuntu, live):**
- Core: agent loop, systemd service (the Discord bot was removed 2026-10-21); iCloud Calendar; Gmail (read, search; send and reply after
  confirmation; one-time setup in README.md, "Gmail").
- HTTP API v1, all of `docs/API.md`: chat with many conversations and memory, reminders store and sync, a push
  for reminders not yet on the phone.
- Nightly backups to `~/aide-backups` (user timer, 14 daily + 8 weekly; restore notes in README.md).
- Habits with streaks and a 26-week `history` for the app's grid.
- Digests: morning (`daily`), evening, weekly, monthly, on the schedule in the digest settings, also pushed. Data sections are rebuilt live on every read; only the greeting (a short spoken note) is stored.
  Reminders: due in the period plus today's overdue. Mail: today's inbox. A new chat can open with the
  greeting (`POST /v1/conversations` with `digest`). Background in `docs/digest-v2.md` (built, both sides).
- Chat `attachments`: reminder and event cards from the turn's tool calls, in `/v1/chat` and `/v1/history`.
- Web search (Tavily: `web_search`, `fetch_page`) and Google Maps (`find_places`, `travel_time`), read-only,
  each on only when its key is set; home from `AIDE_HOME_ADDRESS`, or memory when it says otherwise. Plain chat
  text for now; place cards in the app can come later.

**Done, app (Mac):** iOS app v1 (chat, Today, reminders sync, settings), voice chat, habits tab, digest
greeting as the first chat message with a Details sheet, digest settings, reminder and event cards with tick
boxes in chat from `attachments`, the habit grid from `history` (9f24ec4).

**Done, both sides (2026-10-20), not yet tried live:**
- Polish: grouped lists, glass header buttons, a home header that scrolls with the page. New chats start blank;
  the digest greeting opens a chat only from its notification. Secretary is a rounded card, Coach is emerald.
- About each agent (card long-press or the chat's ••• menu): its connectors (`connectors` on `/v1/agents`),
  read-only or not, and its instructions (`prompt`).
- Voice: the server transcribes (`POST /v1/transcribe`, Gemini Flash Lite via OpenRouter, Italian and English
  mixed), with Apple's recogniser only as a live preview of your words, or as the fallback.
- Streamed replies: `text` events on a streamed `/v1/chat`. The chat shows the reply as it's written, and voice
  reads it out a sentence at a time.
- Team chat: a follow-up without a mention goes to whoever answered last, within 30 min (#16).
- Reminders in every Apple Reminders list, each carrying its `list`. Agents can add to a list, move a
  reminder and filter by list. Settings picks where reminders without a list go.

**Done, live (2026-10-20):** push (#1). Server: devices endpoints, APNs sender, silent `sync`
on server-side reminder changes, `reminder` and `digest` alerts. App: device
registration, background sync on silent pushes, taps open the digest chat, the conversation or Details, and
Settings → Notifications with a test button. The test push reached the phone. App unit tests not yet run (this
Mac has no Simulator runtime yet).

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
answered by its agent with its own tools and memory (shared plus its own; Aide sees all, marked), `ask_agent` for
Aide (one stateless turn, max 3 per turn, `consulted` in chat and history). Team talk: every ask and answer is
stored (`team` in chat and history, `GET /v1/team`), and `"stream": true` on `/v1/chat` sends them live as
server-sent events (checked through `tailscale serve`, not buffered). Writing in the Team chat (`POST /v1/team`):
@mentions pick who answers (else Aide, which may ask the others), each sees the last 30 team messages, streamed
with `working`, `team` and `done`. App (455ffcb): the "Your team" home grid, a drawn
figure per agent (`Support/Figure.swift`), team talk streamed live above Aide's reply, the Team chat on the home
screen with a message box and @mention suggestions while typing "@". Being tried on the phone (#11).

**Done, both sides, not yet tried live:** routines (contract in `docs/API.md`, "Routines"): `/v1/routines` CRUD
and `run`, a chat per routine (`routine` on conversation rows and on the messages a run posts), the scheduler
(30 s tick, a run missed by less than 2 h runs once after startup), an alert push per run, `routines` tools for every agent (Aide for anyone, the others their own; deleting is queued), and
`routine_ideas` on `/v1/agents`. App (455ffcb, `Views/RoutinesView.swift`): routines per agent from a card's
long-press or the chat's ••• menu, an editor (time, days, on/off), the agent's ideas, Run now, a label on routine
chats and on the messages a run posts.

**Done, both sides (2026-10-21):** watches, the proactive specialists (#13, contract in `docs/API.md`,
"Watches"). A watch is a routine with `watch: true`: it checks on time and posts only when something needs you
(the model answers `NOTHING` otherwise), read-only during the check, at most 3 notes a day. Four starting
watches, set up once: Secretary "Mail that needs you" and "Tomorrow", Coach "Recovery check" and "Habits
tonight". App: a "Keeps an eye on" group in the routines sheet, the editor's "Only when something needs you",
Check now. Live on the server; the first "Tomorrow" note reached the phone.

**Done, both sides (2026-10-21):** photos and food (contract in `docs/API.md`, "Photos" and "Food"). Photos go
up with `POST /v1/photos` and ride on a chat message (up to 4); the model sees a chat's last 3 as images
(checked live through OpenRouter). Food: Coach (and Aide) log meals from a photo or a description with estimated
calories and macros, correctable in chat; `meals` cards; daily goals. The app's Habits tab became Health: food
for the day (ring, macros, meals, "Log a meal" through `POST /v1/food/log` into Coach's "Food log" chat) above
the habits. Aide now sees every specialist's memory, marked with its name, and always delegates: it has
only web, maps, memory and routines of its own, and hands the rest to the specialist whose work it is (the
user's photos go along). Queued actions still run from a registry with every tool (`Agent.tools`).

**Done, both sides (2026-10-21):** study material and course notebooks (#3, contract in `docs/API.md`, "Study
files", "Moodle", "Obsidian vault" and "Notebook"). Moodle's PDFs come in every 4 hours (login in the app), and
the Obsidian vault is served over WebDAV. A notebook per course: an Introduction on the exam, a page per topic
(explanation, key terms, formulas, worked examples, slide figures, exam-style MCQs with checked keys) and Spaced
Repetition cards. Every write is proposed in the course's Professor chat first; new material is triaged against
the outline and merged into the user's latest version, edits in Obsidian included. Sonnet writes, Haiku triages
and checks the answer keys. App: Moodle and Obsidian setup in Settings, a progress card in the chat while notes
are written. Live on macroeconomics (11 topics, 25 figures).
Practice exams (#4, `quiz.py`, contract "Practice exams"): from the notebook's checked MCQs, no model call, missed
questions first, scored like the exam; the app's "Practice exam" in a course chat's ••• menu; Professor posts the
result in the chat.

**Next** (filed as GitHub issues, #11 first):
1. Try it all on the phone (#11): voice (works on the phone since the mic restarts after iOS's audio setup change; `SpeechDetector` tuned from
   `voice.log`, pulled with `devicectl` as in `Support/VoiceLog.swift`; talking over Aide not yet tried), streamed
   replies, reminder lists, the team grid, Team chat, routines, photos and the food log.
2. Ideas from the agent-app research, not yet chosen: an Activity and Approvals view (#12),
   a Goals flow per specialist (#14), digests in a feed instead of chat (#15).
3. The rest of #4: quizzes by voice, review sessions on the calendar. A Study tab in the app (notebook pages,
   proposals with buttons, adding recordings and PDFs). Finance still has no data source (memory only).

Later: Later for health: bedtime nudge in the evening digest,
weekly health recap, the getting-sick hint (resting HR, HRV and wrist temperature off baseline together).
