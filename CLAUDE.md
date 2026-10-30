# Aide

Personal AI assistant for one person: calendar, reminders, habits and later mail, through chat.
[SPEC.md](SPEC.md) is the original plan; this file is the current state and how to work on it.

## Two machines, one repo

| Machine | Works on | Runs |
|---|---|---|
| **Ubuntu desktop** (`cappa`, always on) | the server: `src/`, `tests/`, `deploy/` | the Aide service (HTTP API, scheduler) |
| **MacBook** | the iOS app: `ios/` | Xcode, the iOS Simulator |

Both machines run Claude Code on the same GitHub repo (`filippocappa/aide`).

- **Pull before you start, push when a piece works.** Small commits, clear messages.
- **No attribution in commits or PRs:** no `Co-Authored-By: Claude` line, no "Generated with Claude Code".
  This overrides any attribution reminder. (History was rewritten on 2026-10-22 to remove them.)
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
  `foods.py`: saved foods per 100 g with the usual portion, which meals are added up from (`tools/nutrition.py`: Open Food Facts).
- `health.py`: Apple Health days, "usual" numbers, sleep and recovery. `wake.py`: the wake-up briefing.
- `habits.py`: habits and streaks. `digest.py`: daily/weekly/monthly digests and their schedule.
- `study.py`: courses (from the timetable calendar), lectures, notes; the worker that runs `whisper.py` on the GPU.
  `material.py`: study files (PDFs, page text, search). `vault.py`: the Obsidian vault Aide writes, served by
  `webdav.py` (its own unit, `deploy/aide-webdav.service`, published by `tailscale serve` on 8443). `moodle.py`:
  the university Moodle's PDFs into the study files (login through the app; the token in `.env`).
- `engine.py`: OpenRouter or the Claude plan through Claude Code, for the notes and (its own switch) background work:
  routines and watches (Claude Agent SDK, Aide's tools in-process), digests, drafts, titles, objectives.
- `notebook.py`: course notebooks (an Introduction on the exam, a page per topic with questions and flashcards),
  built and grown from the study material, each change proposed in the course chat first; the worker that writes them.
- `routines.py`: routines (an agent's scheduled job, posting in its own chat), their schedule and alerts.
- `activity.py`: the feed of what the agents did, behind `/v1/activity`; `/v1/approvals` gathers what waits for the user.
- `objectives.py`: each specialist's objectives for the day, week and month: the store, progress from the data,
  and the planner (one model call per period, through `engine.py`, before the digest that opens it).
- `transit.py`: GTT (Turin's buses and trams): the GTFS timetable (rebuilt nightly into `data/gtt.db`), the live
  feed, the phone's location, and tram alerts with their watcher. `tools/transit.py`: the agents' transit tools.
  `leave.py`: leave-now for calendar events (the event's GTT ride from Maps becomes a one-off tram alert).
- `plans.py`: events an agent proposes together (`propose_events`), added when the user taps Add on the week card.
- `upcoming.py`: the next calendar event's Live Activity (a countdown from 30 min before; `live.py` sends it).
- `locks.py`: Screen Time locks (one-offs and weekly schedules, unlocking early with a reason); `tools/locks.py`: Coach's.
- `browser.py`: Aide's own Chromium (Playwright, headless, a phone-sized page, a profile per site in `data/browser/`),
  the page listing the model reads, the live view's screencast and input. `errands.py`: browser errands (the store,
  the runner and its phases, the commit guard, the purchases log); `tools/browser.py`: Aide's and the errand's tools.
- `videos.py`: YouTube videos (yt-dlp, captions or Whisper, the brief, frames), posted back in the chat it came from.
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
2026-10-20; team ID in `Signing.local.xcconfig`), so:
- Sign with the paid team, not "Personal Team". Installs last a year, and TestFlight is available.
- **Push notifications** (APNs): live since 2026-10-20 (the key on `cappa`, in `~/.config/aide/`, its ID in `.env`). `PushService` registers the
  device token, silent `sync` pushes run the reminders sync, taps route through `AppEnvironment.open(_:)`.
- Push is opt-in per Mac: `AIDE_ENTITLEMENTS = Aide/Aide.entitlements` in `ios/Aide/Config/Signing.local.xcconfig`
  (see the `.example`). This MacBook has it on. A Personal Team can't sign it.
- The team ID goes in `Signing.local.xcconfig`, not in Xcode's Signing tab: `xcodegen generate` rewrites the project.
- Develop against the **Simulator** (no signing needed). Install on the phone only to try it for real.

```bash
cd ios/Aide
xcodebuild -scheme Aide -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build   # compile check
xcodebuild -scheme Aide -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test    # unit tests
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
boxes in chat from `attachments`, the habit grid from `history` (552f523).

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
Settings → Notifications with a test button. The test push reached the phone. App unit tests pass on the Simulator (53, 2026-10-22).

**Done, both sides, not yet tried live:** Apple Health (#2), contract in `docs/API.md` ("Apple Health"). App:
daily health summaries with a 60-day backfill, HealthKit background delivery, the "I'm up" App Intent for a
Shortcuts Sleep → Waking Up automation, the `wake` digest with sleep and recovery cards, Watch workouts ticking
habits. The app's Health tab (redesigned 2026-10-30, Bevel-style) is one page for a day (arrows to earlier ones):
Strain, Recovery and Sleep as gradient rings with the server's line of the day (tap: Coach's chat), each ring opening
its page (what it's made of, flags, sleep need, zones, workouts' strain, cardio load, 30 days); last night's numbers
on gauges against the usual range, the day's heart rate, workouts with their strain, activity tiles and weight, then
Food (`Views/ScoreViews.swift`; the metric charts in `Views/BodyViews.swift`). Scores come from the server
(`scores.py`, contract "Scores"); the app sends heart rate as `hr_minutes`, `hr_hourly` and `max_hr`. Second pass
(2026-10-30, after the first look on the phone): sleep need learnt from his own nights (trimmed mean of up to 90, plus
the day before's strain and half the 3 nights' net shortfall, at most 45 min), deep and REM scored apart, stricter
efficiency, bed and wake consistency; recovery adds the 7-day HRV trend and the training load; max HR is the middle of
the 3 highest workout peaks, zones shown in bpm (`zone_bpm`). Recovery's heart part is the heart rate asleep (`sleep_hr`,
the phone's average over the night's sleep stages; `sleep_hr_low` the lowest ~15 min), not Apple's resting HR, which is
mostly a daytime number and often missing in the morning (that one stays for strain's rest HR and as the fallback). Each score's page asks Coach for its take
(`POST /v1/health/insight`, contract "Coach's take"). Food is its own tab (`Views/FoodView.swift`; Team · Study ·
Health · Food · Settings; `aide://food`, the meal buttons and the Food widget open it). Habits moved to Today (#21). Health is on by default (`Aide/Health.entitlements`); `Aide.entitlements` has push plus Health. Server
(live): `health_days` and `/v1/health/days`, habit `workouts` and `PATCH /v1/habits/{id}`, `POST /v1/wake` and the
implicit wake from an upload (once a day, 03:00–15:00, waits up to 10 min for sleep), the `wake` digest with a
time-aware greeting and leave-by times (Maps: walk and transit, arriving 10 min early, home and per-place mode from memory, else `AIDE_HOME_ADDRESS`), `sleep` and `recovery`
sections in `wake` and `daily`, the read-only `health` tool. Live from the phone: 63 days uploaded (backfill from 2026-08-21), wake briefings from uploads since 2026-10-20.

**In progress:** agents (contract in `docs/API.md`, "Agents"): Aide as the orchestrator that asks Secretary,
Professor, Coach and Finance (`ask_agent`), each with its own chats, tools, memory and Pebble colour. App side built
(agent row in the chat list, tinted Pebble, starters, "Asked Coach" above replies, memory per agent). Server
(live): definitions and prompts in `agents.py`, `GET /v1/agents`, `agent` on conversations and memory, each chat
answered by its agent with its own tools and memory (shared plus its own; Aide sees all, marked), `ask_agent` for
Aide (one stateless turn, max 3 per turn, `consulted` in chat and history). Team talk: every ask and answer is
stored (`team` in chat and history, `GET /v1/team`), and `"stream": true` on `/v1/chat` sends them live as
server-sent events (checked through `tailscale serve`, not buffered). Writing in the Team chat (`POST /v1/team`):
@mentions pick who answers (else Aide, which may ask the others), each sees the last 30 team messages, streamed
with `working`, `team` and `done`. App (dfbca79): the "Your team" home grid, a drawn
figure per agent (`Support/Figure.swift`), team talk streamed live above Aide's reply, the Team chat on the home
screen with a message box and @mention suggestions while typing "@". Being tried on the phone (#11).

**Done, both sides, not yet tried live:** routines (contract in `docs/API.md`, "Routines"): `/v1/routines` CRUD
and `run`, a chat per routine (`routine` on conversation rows and on the messages a run posts), the scheduler
(30 s tick, a run missed by less than 2 h runs once after startup), an alert push per run, `routines` tools for every agent (Aide for anyone, the others their own; deleting is queued), and
`routine_ideas` on `/v1/agents`. App (dfbca79, `Views/RoutinesView.swift`): routines per agent from a card's
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
Saved foods (2026-10-29, server only, contract "Food"): Coach looks each item up (`find_food`: saved foods, then Open
Food Facts by name or barcode; else `web_search`, a label, or its estimate, saved with `save_food`) and logs the meal
from `items` with grams; the server adds them up and remembers the usual portion. Barcodes (2026-10-29,
both sides): the app reads them in meal photos (Vision, `BarcodeReader` in `Support/Photos.swift`). A lone packet's
photo opens `Views/ScanViews.swift`: the product and how much (empty: the usual portion, else a serving), logged by
the server with no model call, or "Ask Coach instead"; an unknown barcode asks for a photo of its nutrition facts,
read once (`POST /v1/food/label`) and saved. More photos go to Coach with their `barcodes`. "Type a barcode" in the
Log a meal menu. Fixes from the first day (2026-10-29): Coach's chats read barcodes too (the meal's card is posted in
that chat); `log_meal` takes only items (new foods saved as they're logged), so every meal builds the saved foods;
OFF's placeholder "100 g" serving is ignored; the message box makes a new text field on send (the keyboard wrote the
sent text back).
Targets and the day score (2026-10-29, both sides, contract "Food", "Targets and the day score"; `nutrition.py`): a
rest-day base plus the day's Watch workout kcal (× `share`, `carbs_pct` as carbs, the rest fat), or before it a run in
the calendar at the user's usual kcal a minute; `goals` on `GET /v1/food` is now the day's targets. Each food's
Nutri-Score (2023 rules; Open Food Facts' grade when it has one, else from sugars, saturated fat, fibre, salt, fruit
and veg share and kind, which Coach gives as it logs a new food) and NOVA. A 0–100 day score: 60% numbers, 40% the
calorie-weighted grades (counted from half the day's kcal graded). `POST /v1/food/targets/propose`: Coach's proposal
from the profile, 60 days of Health and 14 of food. App (`Views/NutritionViews.swift`): the score card on top of Health
→ Food and the day's page (targets, A–E bars, 4 weeks of scores), Settings → Nutrition targets (also Targets on the
Food page; profile from Apple Health once, "Ask Coach to propose"); HealthKit now also reads weight, height, age,
sex, VO2 max and workout distance (`weight_kg`, `vo2max`, `workouts[].km`). Not yet tried on the phone.
Quality beyond Nutri-Score (2026-10-29, contract "Targets and the day score"): the 40% is three `parts`, the day's
nutrients 50% (fibre, fruit and veg, saturated fat and free sugars as % of kcal, salt, against WHO-style lines; fibre
and fruit/veg only on a finished day), processing 25% (the NOVA 4 share of kcal; Coach gives `nova` for new foods)
and the kcal-weighted grades 25%. Coach's day line names the weakest. App: Nutrients, Processing and Food grades
sections on the day's page, the weakest as a hint on the card.
From the first try (2026-10-29): Health's Resting Energy is uploaded (`resting_kcal`) and Coach's proposal works from the
measured burn, not a formula; it may ask up to two `questions`, answered on the page and sent back for a new proposal.
Meals list newest first, each with an `emoji` (Coach's, else guessed from the name); the photo only on the meal's page.
Second try (2026-10-29): targets are optional (without them the score is quality alone, and the card says so). Each
meal carries its `items` (Nutri-Score, NOVA, a 0–100 quality each) and a `quality` (the day's recipe on the meal, its
nutrients per 2000 kcal): a pill on the meal row, "What's in it" on the meal's page. The targets page: the goals as
rows (Fuel my training = `perform`, Stay as I am, Lose weight, Build muscle), "Anything else for Coach" (`note`), the
Ask Coach pill, "Edit" folded, "What Coach gets" (the model from `coach` on the targets, and every piece of data sent);
the profile comes from Apple Health with no page of its own. The 25 meals logged before items were broken into foods
once by Sonnet (2026-10-29, totals unchanged).
Third try (2026-10-29): Coach keeps its last proposal and every answer (with the targets) and starts `why` with what the
answers changed; the app shows "was 2,450" on each number that moved. "What Coach gets" is gone from the page.
Control Center (iOS 18): "Snap a meal" and "Describe a meal" (`LogMealIntent`, `Shared/MealIntents.swift`, also a
Shortcut) open Health → Food with the camera or the describe box (`aide://meal/photo`). The barcode's grams take sums
(`Support/Arithmetic.swift`: 400/3, 2×30; + − × ÷ keys over the number pad).
The meal camera (2026-10-29, `Views/MealCameraView.swift`): Aide's own camera for Health → Food and the Control Center
button (now a fork and knife, not a camera): up to 4 shots then Next, Library and Describe. A food barcode held still
in view (0.35 s) opens the packet's page over the camera by itself (Cancel goes back; that code then waits for a tap on
its pill until it leaves the picture). The packet page (`ScanSheet`, redesigned 2026-10-29): name, brand, Nutri-Score
tile, Ultra-processed, a big grams field prefilled with the usual portion or a serving, portion chips, the kcal and
macros, "Log 240 kcal". Chat photos keep the system camera. Since 2026-10-30: the phone's virtual back camera (triple,
dual wide…) with lens buttons as in the Camera app (0.5, 1, 2, the telephoto), pinch to zoom, tap to focus, macro
switched on by the phone up close (a Macro badge), the preview kept upright by following the rotation coordinator.
Barcodes are read by Vision on the live frames (~8 a second, 10–20 ms each), not `AVCaptureMetadataOutput`: asking it
for any barcode type held the camera's start up exactly 9 s on the 15 Pro Max; now it runs in ~0.15 s.
Weight (2026-10-29, both sides, contract "Apple Health", Weight; `weight.py`, `tools/weight.py`): readings logged in
chat (`log_weight`) or the app plus Health's, the 7-day average, the change over 3 weeks and the rate a week (28 days)
against the goal's pace (gain +0.25–0.5% a month), with a verdict. The phone writes Aide's readings to Health as Body
Mass (`HealthService.writeWeights`). Coach's proposal corrects the base from a trend off for ~3 weeks. A Weigh-in watch
(Mondays 08:30). App: a Weight card on Health → Body, `Views/WeightViews.swift` (chart, trend, days, Log weight), a row
on the targets page. Not yet tried on the phone.

**Done, both sides (2026-10-21):** study material and course notebooks (#3, contract in `docs/API.md`, "Study
files", "Moodle", "Obsidian vault" and "Notebook"). Moodle's PDFs come in every 4 hours (login in the app), and
the Obsidian vault is served over WebDAV. A notebook per course: an Introduction on the exam, a page per topic
(explanation, key terms, formulas, worked examples, slide figures, exam-style MCQs with checked keys) and Spaced
Repetition cards. Every write is proposed in the course's Professor chat first; new material is triaged against
the outline and merged into the user's latest version, edits in Obsidian included. Sonnet writes, Haiku triages
and checks the answer keys. App: Moodle and Obsidian setup in Settings, a progress card in the chat while notes
are written. Live on macroeconomics (11 topics, 25 figures).
Formula sheet and exercises (2026-10-29, contract "Notebook" and "Exercises"): `Formulas.md` gathers every topic's
Formulas (no model call, never behind the topics). A set of solved exercises per topic (`exercise_sets`, the `exercises`
job): only the course's own (exercise sheets and their solutions, review questions, past exams), matched to the topics
by Haiku, copied and solved (following the course's solution where there is one), nothing invented; the other final
answers checked by a blind solver; topics no sheet practises get none; `Exercises/` in the vault, Professor's `write_exercises` and
`read_exercises`. App: a Practice section on the course page (Formulas, Exercises, Quiz me, Practice exam).
Mock exams (2026-10-29, contract "Mock exams"): a paper like the real exam (`mock_exams`, the `mock` job, Sonnet in one
go from the Introduction, every topic's notes and the past exams; MCQ keys checked blind), open questions included,
taken in the app as a `kind: "mock"` quiz with its own time and scoring; open answers typed or photographed, marked by
the `grade` job against the model answer and marking, then posted in the course chat. `Mock exams/` in the vault (the
paper, then the answers), Professor's `write_mock_exam`, objectives count them. Past exams (`past=true`, the `papers`
job): the course's own papers (past exams, the mocks it gave out) copied as they are, one Sonnet call each, keys checked
blind with only the key changeable; a mock with `source` and the paper's `title`, in `Past exams/` in the vault. App: Mock exams in Practice.
Practice exams (#4, `quiz.py`, contract "Practice exams"): from the notebook's checked MCQs, no model call, missed
questions first, scored like the exam; the app's "Practice exam" in a course chat's ••• menu; Professor posts the
result in the chat.
Quizzes and review sessions (2026-10-27, closes #4; `reviews.py`, `tools/quiz.py`, contract "Quizzes and review
sessions"): Professor quizzes in the course chat, one question at a time from the notebook's MCQs and flashcards (missed
first, answers recorded as they come, shared with practice exams; `kind: "chat"` quizzes don't count for objectives).
By voice: `voice` on `/v1/chat` makes replies speakable, and "Quiz me" (course page, course chat's ••• menu) opens the
chat in voice mode with "Quiz me" said for you (`VoiceController.start(saying:)`). Review sessions: planned with the
user from `free_time`, `study_progress` and the exam date, put in the timetable calendar as "Review: <course>" (never
a lecture), followed when moved or deleted there; when one starts Professor offers the quiz in the chat, with a push.
The course page lists them (swipe to cancel). Not yet tried on the phone.
Since 2026-10-22 (`engine.py`, contract "Who writes the notes"): lecture notes and notebook jobs can run on the
user's Claude plan through Claude Code on `cappa` (`claude -p`, Sonnet writes, Haiku reads; set in Settings → Claude
plan; on now). At the plan's limit a job pauses and Professor asks: wait, or finish on OpenRouter.
Figures come from a Haiku scan of every slide (`page_looks`); "Find figures in the slides" re-picks them.
Study tab (both sides): courses with their notebook in brief, a course page with proposals (Apply / Not now), the
writing progress, Ask Professor, Practice exam, the Introduction and topic pages (notes with figures from
`GET /v1/files/{id}/pages/{n}`, folded answers, flashcards; `plain=true` reads), lectures, PDFs, and adding a PDF or
a recording from Files.
Notes in the app (2026-10-29): formulas and the maths in sentences drawn as LaTeX with SwiftMath (`MathFormula`,
`MathText`; `plain`, `latex` and `inline` on the note endpoints), and Contents (the list button) on long pages to jump to a heading.

**Done, both sides (2026-10-22), live on the server:** objectives (contract in `docs/API.md`, "Objectives";
covers the Goals idea in #14). Every specialist proposes objectives for the day, the week and the month (before the
morning, weekly and monthly digests, month first), each tied to a measure where one fits (habit check-ins, practice
exams, food log, sleep, steps, a reminder) so it ticks itself; the rest are ticked by hand. They wait for the
user's OK. `objectives` tools for every agent, an `objectives` digest section. App: an Objectives tab (badge: proposals
waiting for the OK; Today / Week / Month, accept, drop, tick, add, propose now), objectives in the
digest. First plan made live 2026-10-22; on the phone, the first proposals accepted 2026-10-22.
Steps (2026-10-26): any objective can carry a checklist (`steps`); a hand-ticked one with steps is done when they all
are. Only hand-ticked and reminder-linked objectives have a tick box; measured ones show a dashed ring and "Ticks
itself". Tapping an objective opens its page (how it's ticked, steps, title).
Since #19 (2026-10-22): a `notes` measure (notebook topics written or revised, logged in `topic_changes`), and
`StudyReplanner` plans Professor's week and day again 10 min after a course's notes or dates change (not when
they're all taken with none waiting); the planner sees each course's new notes and most-missed topics.
Course dates (2026-10-22): a model reads each course's Moodle page and the files' exam pages into dated items
(exams, mid-terms, sign-up deadlines; `course_dates`, the `dates` notebook job), again when Moodle changes. The
planner, Professor's `list_courses` and the Introduction's Dates section use them.

**Done, both sides (2026-10-22), not yet tried on the phone:** Activity and approvals (#12, contract in
`docs/API.md`, "Activity and approvals"). Server: `activity.py` keeps a 90-day feed of what each agent did (changes,
queued actions and how they were answered, routine and watch runs, asks, unasked posts, objectives proposed,
digests), `GET /v1/activity` (paged, per agent) and `GET /v1/approvals` (queued actions with who and from where,
proposed objectives, notebook proposals, a paused notes job, the next routines). `/v1/confirm` and `/v1/cancel`
take `ids` to answer one action at a time. App (`Views/ActivityView.swift`): a bell with a badge on the home
screen, a sheet with "Waiting for you" (each answered there), "Coming up" and the feed by day; an agent card's
"Activity" shows that agent's alone.

**Done, both sides (2026-10-22), live on the phone:** GTT tram alerts (contract in `docs/API.md`, "Transit
(GTT)"). Server (live): GTT's timetable and live feed (GTT takes ~20 s to answer, so it refreshes in the background;
the metro has no live data), transit tools for Aide and Secretary (stops, arrivals near the phone or at a stop,
alerts: a weekday commute or a one-off), a watcher that pushes a time-sensitive "Tram 4 in 7 min: leave now" when
the tram is the walk from the phone plus 2 min away (or N min before). App: `LocationService` (significant moves,
Always, a fix on a silent `location` push), Settings → Location and trams (location, Tram alerts list and editor).
Departure cards (`departures` attachment, `GET /v1/transit/departures`): per stop, each line's badge, direction,
minutes, live delay or timetable, the next ones, the walk and when to leave; with a destination (a stop, or any place
through Maps: its stops within 400 m) only direct lines, with the time there. The app's `DeparturesCard` counts down
and fetches the board again every 30 s while on screen (cards under 3 h old).
Leave-now for events (2026-10-26, contract "Leaving for an event"; closes the tram half of #5): for a timed event with
a place (or one from memory: lectures are at the uni), Maps' transit ways from the phone, the latest on the line memory
prefers (the 10 to uni), else on a frequent GTT line; ~45 min before leaving, its first ride becomes a one-off tram alert
(`event` on the alert), so the usual "Tram 4 in 7 min: leave now" comes. On/off in Settings → Location and trams →
Tram alerts (`/v1/transit/settings`). Not yet tried on the phone.
Following the ride (2026-10-27): while a tram Live Activity is on, the app sends a fix every ~20 s (background location);
the server re-picks the tram from where the user is (an earlier one once at the stop), sees them on board when the phone
moves along the line, counts the stops to where they get off (`to_stop` from Maps) and says when it's next.
Tram alerts (2026-10-27): leave-now 3 min before it's time to leave, at the stop 2 min early; the push and the Live
Activity say where the tram is (stops to go, the stop it's near, or when it leaves its first stop, drawn as a track)
and "GTT live down" when GTT's feed isn't answering (it was down 07:32–07:58 on 2026-10-27).
Fixes from the first ride (2026-10-27): push-started activities ask iOS for their update token (`input-push-token`),
and when one's missing the server wakes the app (a `location` push) to send it again; the trams being followed survive
a restart (`tram_follows`); one countdown per tram (a second alert for the same stop and line, or a one-off asked again,
doesn't start another); "follow my tram" is a one-off with `right_away`. Driving and transit times come as a `routes`
card (`Views/RouteCard.swift`). The event activity has a bar to the start, the notes and what comes after.

**Done, both sides (2026-10-22), not yet tried on the phone:** mail drafts (#7, contract in `docs/API.md`, "Mail
drafts"). Server (live, `drafts.py`): before the evening digest Secretary reads the last 3 days' inbox (each message
once) and drafts replies to mail that asks something of the user, with memory and the calendar; `draft_reply`,
`list_drafts`, `discard_draft` in chat; drafts in `/v1/approvals` and the evening digest's `replies` section.
`POST /v1/mail/drafts/{id}/send` (the app's tap) is the confirmation. App (`Views/DraftViews.swift`): drafts in
Activity's "Waiting for you" (Send, Edit, Dismiss), an editor sheet, and "Replies to send" in the digest Details.

**Done, both sides (2026-10-24), not yet tried on the phone:** Live Activities and widgets (contract in
`docs/API.md`, "Live Activities" and "Widgets"). Server (live, `live.py`): push-to-start and update tokens
(`/v1/live/tokens`, `/v1/live/activities`), the `liveactivity` sender; a tram alert starts a countdown instead of
the plain push when there's a start token, updated as the live feed moves; chat and team turns update the agent's
activity (asking, writing, then done with an alert ~3 s after, unless the app ended it); scheduled routines start one
quietly. `POST /v1/reminders/{id}/complete` and `GET /v1/transit/nearby` for the widgets. App: `AideWidgets`
extension (App Group `group.<bundle id>` shares the keychain items and a cache of the last answers): Today, Food and
habits, Objectives, Your team (and "Talk to Aide" on the Lock Screen), Departures; tick boxes through App Intents;
`TramLiveActivity` and `AgentLiveActivity` on the Lock Screen and in the Dynamic Island
(`Shared/LiveActivityAttributes.swift`); `Support/LiveActivities.swift` starts the chat ones and registers tokens;
`aide://` links (`PushRoute(url:)`). The first phone install needs the App Group and the `.widgets` bundle ID on the
team (Xcode's automatic signing adds them).

**Done, both sides (2026-10-27), not yet tried on the phone:** more in the Dynamic Island (#24, two of its ideas;
contract in `docs/API.md`, "Live Activities"). The next event: 10 min before a timed event on the Work calendar the server
(`upcoming.py`) push-starts an `event` countdown with its place, follows a move, ends at the start; none when leave-now
set a tram alert for it; off in Settings → Notifications (`/v1/live/settings`). Notes jobs: Professor's agent activity
while a notebook proposal is applied (topics done of total, a bar and "2/5" in the island) or a lecture's notes are
written (`NotesRun` in `live.py`). An activity ended before the app sent its token is ended when the token comes.

**Done, both sides (2026-10-27), not yet tried on the phone:** Screen Time locks (#23, contract in `docs/API.md`,
"Screen Time"). Server (`locks.py`): one-offs (15 min to 24 h) and weekly schedules (overnight ones run into the next
morning), `/v1/locks`, a sync push on every change; Coach's tools (`lock_now`, `add_lock_schedule`, `update_lock`;
`end_lock` and `delete_lock` queued, ending early needs the user's reason, and Coach sees the week's unlocks). App:
Settings → Screen Time (allow it, what stays open through `FamilyActivityPicker`, lock now, the locks and an editor,
End early with a reason and a 10 s wait); `ScreenTimeService` sets one DeviceActivity schedule per lock; two
extensions read the locks from the App Group (`ScreenTime/LockBook.swift`): `LockMonitor` shields and opens on time
with the app closed, `LockShield` is the locked app's screen ("Locked until 07:00"). Needs the Family Controls
entitlement (`Aide.entitlements` and both extensions): fine for development builds, TestFlight needs Apple's approval
(a request form). Each lock picks its own apps on the phone (everything but some, or only some). Strict locks
(2026-10-27): once on, only an emergency pass ends one early (3 a calendar month, `passes` on `/v1/locks`), not a
reason or Coach, and the app's Screen Time page is locked until it's over. Usage thresholds and a countdown in the
Dynamic Island are not done.

**Done, both sides (2026-10-27), tried on the server, not yet on the phone:** browser errands (#22, contract in
`docs/API.md`, "Browser errands"). Aide starts an errand (`start_errand`) for anything a shop or booking site shows now
or does for you; it runs in the background in Aide's Chromium on `cappa` and reports in Aide's chat. It searches,
reads, compares and fills carts on its own; anything that changes something (buying, booking, sending, signing up,
cancelling) is refused in code and asked as a queued `errand_go` with the order's `detail`, and after Confirm only the
confirmed button is clicked while the page shows the confirmed total. Logins, codes, CAPTCHAs and card steps are the
user's, in the live view (a WebSocket; typed text is never logged or shown to the model). It uses the site's saved
card and address. Placed orders go into `purchases`, which Finance reads (`list_purchases`). Tried headless on
Amazon.it (prices, product links). App (`Views/ErrandViews.swift`): the errand card in chat (Take over, answers, Review
and confirm, Watch, Cancel), the live view (`BrowserSheet`: taps, drags, a native field that follows the page's focus
so AutoFill offers passwords and codes), the order's Confirm sheet, errands and orders in Waiting for you, purchase
cards, Settings → Browser (sites, logging in, Purchases), `aide://errand/<id>` and the `errand` push. Since 2026-10-28:
the app draws the errand (scenes: results, menus, timetables as `rows`, product, cart), logins open on their own;
Glovo (menu, "+", the address dialog) and Trenitalia (stations, search, timetable) tried headless. Next: a login and
a small real order from the phone.

**Done, both sides (2026-10-26), installed on the phone 2026-10-26:** Today and limit habits (#21, contract in
`docs/API.md`, "Today" and "Habits"). The app's first tab, `Views/TodayView.swift`: the latest digest as a card
(`GET /v1/digest?kind=latest`; Details, Reply), "Waiting for you" (`WaitingSection`, also in an agent's Activity),
habits and objectives with Today / Week / Month, "From the team" (`/v1/activity?kind=routine,watch`) and all
activity. It replaced the digest as a chat message, the sun button, the bell and the Objectives tab. Since 2026-10-26 the
agents come first: tabs Team · Study · Health · Settings. The Team tab has the briefing behind a sun button in the
corner (the digest sheet: Wake-up, Evening, Week, Month, and Refresh to write it again) and a small strip ("3 of 5 habits
done today", what's waiting) above the team; Today opens from it as a page (`env.showToday`). The Morning digest is off
(2026-10-26): the wake-up briefing is the morning one. Notifications open Today on their item (a routine's push carries `routine`), or the
chat. Routine chats are left out of Chats. Limit habits (`{"type": "limit", "max": 5}`, `POST /v1/habits/{id}/count`,
the `count_habit` tool, "had another coffee") show "2/5" with − and +. Food habits tick from the food log. The planner
leaves habits out of a day's objectives, and Coach sees each limit habit's last 7 days. One tap: the "Log one" App
Intent (Shortcuts, Action Button), the Health widget's +, a Control Center control (iOS 18,
`AideWidgets/HabitControl.swift`). A limit habit can count from Apple Health (`health: "inhaler_usage"`: the user logs
the habit as Inhaler Usage; the day's count is the larger of Health's and the app's). One habit is set up
that way. Counts logged through Aide (an agent, the app, a widget) go back to Health (2026-10-27): the server keeps each
day's `health_logged` and the app makes its own Inhaler Usage samples match, never touching the user's.

**Done, both sides (2026-10-29), not yet tried on the phone:** the events card as a week (#25, contract "Events and
plans"): a turn's events in one card in time order, marked found, created or proposed; `propose_events` (Secretary,
Professor) puts a plan on it that goes in the calendar only on Add; the app's `Views/EventWeekView.swift` (week strip,
the chosen day, the event's sheet with Move, Delete, Open in Calendar). Also a reply survives the app going to the
background (pings, `working` on history, a `message` push when no Live Activity is left).

**Done, server (2026-10-30), app in progress:** YouTube videos (contract in `docs/API.md`, "Videos"; `videos.py`,
`tools/videos.py`). A link pasted in Aide's or Professor's chat (`summarize_video`) or shared through the app
(`POST /v1/videos`, a new Aide chat) is read in the background: yt-dlp's details and captions (the video's own, else
YouTube's automatic ones; no captions: Whisper on the audio), a brief in English by Sonnet (gist, TL;DR, what to know,
4–10 key moments with times, the takeaway, the answer to the user's question), a frame after each moment from the
stream (ffmpeg, no download) and Haiku keeping only the ones that show something; posted in the chat with a `videos`
card and a push. `read_video` and `list_videos` for follow-ups. Each one is a page in the vault (`Aide/Videos/`).
Tried on cappa: 3Blue1Brown (captions, 27–43 s), Geopop in Italian (brief in English), Whisper on 10 min (42 s).
yt-dlp must be kept current (README, "YouTube videos").

**Next** (filed as GitHub issues, #11 first):
1. Try it all on the phone (#11): voice (works on the phone since the mic restarts after iOS's audio setup change; `SpeechDetector` tuned from
   `voice.log`, pulled with `devicectl` as in `Support/VoiceLog.swift`; talking over Aide not yet tried), streamed
   replies, reminder lists, the team grid, Team chat, routines, photos and the food log.
2. Ideas from the agent-app research, not yet chosen: (#15, digests in a feed, is mostly covered by Today; #14,
   Goals, by objectives.)
3. New, filed 2026-10-27, not yet chosen: the rest of #24 (buttons in the expanded view, voice chat in the background).
4. Recording a lecture in the app. Notebooks for the other courses. Finance still has no data source (memory
   only).

Later: Later for health: bedtime nudge in the evening digest,
weekly health recap, the getting-sick hint (resting HR, HRV and wrist temperature off baseline together).
