# Aide

Personal AI assistant for one person, through chat: calendar, reminders, mail, study, health, food, money and errands.
[docs/archive/SPEC.md](docs/archive/SPEC.md) was the original plan; this file is the current state and how to work on it,
[docs/HISTORY.md](docs/HISTORY.md) how each part came about.

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
- `brand/` is the brand kit (logo, family, colours, screenshots, promo images; its README). Use `brand/logo/` assets for
  the app icon and UI, and don't redraw them: change `brand/source/pebble.py` and run it and `render.py` again.

## Server (Ubuntu)

Python 3.12, managed with `uv`. Entry point `src/aide/__main__.py`.

- `agent.py`: Claude tool-use loop (via OpenRouter, Anthropic SDK), conversation history, the confirmation queue.
- `agents.py`: the agents (Aide and the specialists): prompts, tool sets, colours, starters.
- `router.py`: before Aide runs on a typed message (its chat, or the Team chat with no mention or follow-up), one
  call picks the specialist; at `p` ≥ 0.6 that specialist answers directly (#59; fails open in 1.5 s, each pick a row
  in `routes` to check the threshold; `AIDE_ROUTER=off`). The picker is TypeSafe's Jev (`typesafe/jev-1.13`, a decision
  model on OpenRouter's `/api/alpha/decisions`: ~0.2 s, a probability per agent; 20/20 against Haiku's 20/20 at ~0.8 s,
  2026-11-08), or a chat model asked for JSON (`AIDE_ROUTER_MODEL=anthropic/claude-haiku-5.5`).
- `decide.py`: decision models (Jev on OpenRouter's alpha `/api/alpha/decisions`): a choice with a probability per
  option. The router uses it, and so does `quiz.mark` for a typed study answer (Study page, lesson checks): Jev ≥ 0.8
  sure it's right is the mark at once, with no feedback; else Haiku's mark and feedback (thinking off: it ran past
  `max_tokens`), Jev's when Haiku fails (85/94 against Haiku's 82/94 with 6 failures, 2026-11-08). `AIDE_DECIDER_MODEL=off`.
- `db.py`: SQLite (WAL) at `data/aide.db`.
- Smaller pieces: `config.py` (settings from `.env`), `usage.py` (what every model and paid API call cost, by purpose),
  `shapes.py` (JSON the API and the digest both send), `fts.py` (full-text search with a question), `lang.py` (Italian
  or English), `transcribe.py` (voice-chat recordings to text on OpenRouter), `agenda.py` (today's and tomorrow's
  calendar in a spoken turn's stamp, #71), `reader.py` (the photo reader: Gemini Flash looks at photos once for Coach's
  food turns), `gmail.py` (`gmail_auth.py`: the one-time setup), `drafts.py` (Secretary's reply drafts before the
  evening digest), `scores.py` (Strain, Recovery, Sleep), `weight.py` (readings, the trend, the verdict), `reviews.py`
  (review sessions in the timetable calendar), `datereminders.py` (course dates that aren't exams, as reminders).
- `tools/`: everything that touches the outside world (`calendar.py` uses `icloud.py`, CalDAV).
- `channels/api.py` (FastAPI): the app's API, the only way in since the Discord bot was removed (2026-10-21).
- `reminders.py`: reminders store and the sync rules. `scheduler.py`: background jobs (a push for reminders not yet on the phone).
- `push.py`: APNs sender and the devices table (off without `APNS_*` in `.env`; then nothing is pushed).
- `photos.py`: photos for chat and food, files in `data/photos/` (backed up once each). `food.py`: meals and food goals.
  `foods.py`: saved foods per 100 g with the usual portion, which meals are added up from (`tools/nutrition.py`: Open Food Facts).
- `health.py`: Apple Health days, "usual" numbers, sleep and recovery. `wake.py`: the wake-up briefing.
  `bedtime.py`: the steady wake time (learnt or set) and tonight's bedtime worked back from it, the evening nudge
  (a `bedtime` Live Activity or a push), the optional wind-down lock, each night against its plan.
- `habits.py`: habits and streaks; never miss twice (#52): each evening Coach writes once about daily habits missed
  yesterday and not done today, offering the habit's two-minute version (`minimum`). `digest.py`: daily/weekly/monthly digests and their schedule.
- `study.py`: courses (from the timetable calendar), lectures, notes; the worker that runs `whisper.py` on the GPU
  (Parakeet for English, Whisper for the rest and to pick the language).
  `material.py`: study files (PDFs, page text, search). `vault.py`: the Obsidian vault Aide writes, served by
  `webdav.py` (its own unit, `deploy/aide-webdav.service`, published by `tailscale serve` on 8443). `moodle.py`:
  the university Moodle's PDFs into the study files (login through the app; the token in `.env`).
  `passwords.py`: saved logins (Settings → Passwords) for the server's own code, never the model's: AES-256-GCM in
  the database, the key a systemd credential (`deploy/aide-passwords.conf`, README "Passwords"), given out only by
  `use()` for an https address on the entry's sites; write-only API, every change pushed. `tools/` never imports it.
  `unito.py`: UniTo's single sign-on in plain HTTP with the saved login (wrong: never tried again until changed).
  `unitimetable.py`: the lecture timetable from UniTo's University Planner (Cineca's public API, no login; the year's
  calendar link in `AIDE_UNITO_TIMETABLE`): Secretary's and Professor's `uni_timetable`, reading a week and adding
  the missing lectures to the study calendar under the course's name (room and teachers in the notes, no location).
  A routed specialist that needs the browser hands the message back with `pass_to_aide` (`agent.py`).
  `esse3.py`: Esse3 read through it (exam sessions with their sign-up windows into the course dates as `by: "esse3"`,
  `official_dates` in `notebook.py`; bookings; the transcript), four times a day, the fast model when a page won't parse;
  signing up and cancelling only on the user's tap (now, or when the sign-up opens: `esse3_wants`), as an Esse3 errand
  (#75, `start_esse3` in `errands.py`): `unito.handoff` gives the browser the login as cookies (never the password), no
  typing, at most two committing clicks, each only on the tapped session (`esse3_mismatch`), never retried or resumed;
  then the bookings decide and the UniTo profile is forgotten (kept 30 min only while it waits for the user).
  From chat: Professor's `exam_signups`, `sign_up_for_exam` and `cancel_exam_signup` (`tools/esse3.py`), the two
  queued, so Confirm is the tap.
- `engine.py`: OpenRouter or the Claude plan through Claude Code, for the notes and (its own switch) background work:
  routines and watches (Claude Agent SDK, Aide's tools in-process), digests, drafts, titles, objectives.
  Professor's typed chat turns run on the plan too, with Sonnet, whenever the notes do (`PLAN_CHATS` in `agent.py`;
  voice turns and every other chat stay on OpenRouter's Haiku; if the plan fails before a tool ran, OpenRouter answers).
- `notebook.py`: course notebooks (an Introduction on the exam, a page per topic with questions and flashcards),
  built and grown from the study material, each change proposed in the course chat first; the worker that writes them.
  Prerequisites (#66): `builds_on` per topic (the cheap model, at most 3, no cycles), `in_order` (a topic after what it
  builds on: the Learn path's order); `quiz.weak_prerequisites` (retained below `WEAK`) under a missed answer, and weak
  bases first in practice exams and Due today.
- `charts.py`: Professor's and Aide's `draw_chart` (#67): the spec checked (formulas in x through a small evaluator,
  never `eval`), curves sampled, equilibria worked out; the app draws the card with Swift Charts.
- `feedback.py`: 👍/👎 on a reply with the whole turn as it ran (tools, results, agent, model, the router's pick).
  "Check the feedback" means `ssh cappa 'cd ~/Developer/aide && uv run --no-sync python -m aide.feedback'`.
- `srs.py`: spaced repetition (#63): FSRS-4.5 over each question's and flashcard's answers in `quiz_answers`
  (one review a day, its worst grade; no state of its own), used by `quiz.py` for picking, mastery and the Due today deck;
  the user grades flashcards (Again/Hard/Good/Easy), a slow right MCQ is Hard, and from 21 days before the course's next
  exam (`QuizStore.exam`: the exam plan's `targets`, else the course's dates) items come due at 95% instead of 90%.
- `examplan.py`: the exam plan (#68): the hours each course's next exam still needs (learn, practise, mocks, review,
  less what's known) against the free days before it, under a daily cap; no model call. Professor's `study_plan`.
- `lessons.py`: a lesson per notebook topic (hook, goals, steps with checks), written from the topic's notes through
  `engine.py`; marking, Ask and the explanation back.
- `routines.py`: routines (an agent's scheduled job, posting in its own chat), their schedule and alerts.
- `activity.py`: the feed of what the agents did, behind `/v1/activity`; `/v1/approvals` gathers what waits for the user.
- `objectives.py`: each specialist's objectives for the day, week and month: the store, progress from the data,
  and the planner (one model call per period, through `engine.py`, before the digest that opens it).
- `transit.py`: GTT (Turin's buses and trams): the GTFS timetable (rebuilt nightly into `data/gtt.db`), the live
  feed, the phone's location, and tram alerts with their watcher. `tools/transit.py`: the agents' transit tools.
  `leave.py`: leave-now for calendar events (the event's GTT ride from Maps becomes a one-off tram alert).
- `weather.py`: Open-Meteo forecasts (no key, 30 min cache): the `weather` tool, the one-day digests' section, rain
  in a leave-now tram alert.
- `plans.py`: events an agent proposes together (`propose_events`), added when the user taps Add on the week card.
- `upcoming.py`: the next calendar event's Live Activity (a countdown from 30 min before; `live.py` sends it).
- `lockwatch.py`: a Screen Time lock's Live Activity while it holds (a countdown to when it opens).
- `locks.py`: Screen Time locks (one-offs and weekly schedules, unlocking early with a reason); `tools/locks.py`: Coach's.
- `focus.py`: focus sessions (study rounds and breaks, each round a strict lock over all but the focus apps), the
  watcher (the Live Activity at each switch, the end), the check at the end and Professor's post in the course chat.
- `browser.py`: Aide's own Chrome (Playwright; Google Chrome, desktop, headed on Xvfb `:99` (`deploy/aide-xvfb.service`), only the window phone-sized (#76); a profile per site in `data/browser/`),
  the page listing the model reads, the live view's screencast and input. `read_whole`: a page as it shows, folded parts opened, every
  tab, the pages behind Next or Load more, for `fetch_page` (`tools/search.py`; its own profiles in `data/reading/`,
  closed after each read; Tavily when it fails; long pages in parts of 30k). `errands.py`: browser errands (the store,
  the runner and its phases, the commit guard, the purchases log; one on a unito.it page logs in with the saved UniTo
  login, `unito_login`, its profile deleted at the end); `tools/browser.py`: Aide's and the errand's tools.
  `browsing.py`: the page tools and their read-only guard, shared by errands and chat; in chat (#77) Aide's
  `look_at_page` (screenshots the model sees, the latest two in a turn, a line in the history) and `browse_page`
  (clicks through, refusing anything that buys, sends, signs up or logs in: that's `start_errand`), a page per
  conversation in the reading browser, its cookie banner refused, kept 5 min for a follow-up, 15 page calls a turn.
  `pricewatch.py`: price watches. `releases.py`: release trackers (research by an errand, the user's picks, a daily
  look by the fast model, and the timed drop, reminder or price watch each pick calls for).
- `livecall.py`: live voice calls (#34): a voice behind an adapter listens and speaks over `WS /v1/voice/call`: the
  local one (`localvoice.py`: Silero and the smart-turn model hear when you're done, Parakeet v3 writes it down,
  Chatterbox speaks in its own service (`deploy/chatterbox/`, voices cloned from `data/voices/en.wav` and `it.wav`,
  streamed, `deploy/aide-voice.service`; Kokoro on the CPU while it's down); `voicemodels.py` loads them in the service at start, ~25 s and
  ~5 GB of the GPU, and lets them go while Whisper has a recording) or OpenAI's GPT-Live (`gptlive.py`, `AIDE_LIVE`); each spoken request is a normal turn for the chat's agent (Aide on a call, or in the voice mode, uses every tool itself, with the specialists' rules in `AIDE_VOICE_PROMPT`, instead of asking: ~2.5–3 s against ~5 s; no thinking in spoken turns; the cache warmed when a call opens), a spoken yes or
  no to queued actions is decided in code (`consent.py`), the call kept in `calls`. Off with `AIDE_LIVE=off`, or with neither a GPU nor the key.
  `voicequiz.py`: a spoken multiple-choice answer in a course chat's quiz marked with no model call.
- `videos.py`: YouTube videos (yt-dlp, captions or Whisper, the brief, frames), posted back in the chat it came from.
- `finance.py`: payments, categories, the month, subscriptions, budget, accounts. `banks.py`: bank accounts through
  Enable Banking (PSD2, read-only): linking, the reads (4 a day and when Money opens), matching taps to the bank's records.
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
- Secrets live in `.env` only (git-ignored), saved logins in `passwords` (encrypted, the key outside the repo and backups). Never commit or print them.
- Times: store UTC, talk to the user in `AIDE_TIMEZONE` (Europe/Rome).
- Memory: cappa has 15 GB and is also the user's dev box (an Android emulator, Expo). Aide and its voice share
  `deploy/aide.slice` (8 GB, 1 GB of swap; killed inside it, never cappa frozen, 2026-11-07; 10 GB while no
  emulator, Expo or Gradle runs: `deploy/aide-budget.sh`); each restart reloads
  the voice models (~5 GB for a minute), so one restart per deploy. Tests on cappa go in a capped scope:
  `systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 uv run pytest`.

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

### The Mac app (same project, target `AideMac`)

The phone's views in a Mac window, the sections (Team, Today, Habits, Objectives, Activity, Study, Health, Food,
Screen, Settings) in a glass sidebar with their names floating on the left over the page (`MacSidebar`; no system sidebar),
folding to a rail of icons (its button, ⌃⌘S, View → Show Section Names; no glance there since 2026-11-01, only
the menu bar panel has it), macOS 14+, bundle
`$(AIDE_BUNDLE_ID).mac`, its own server URL and token in the Mac's keychain. Same server, same API, no contract of its
own except `app: "mac"` on `POST /v1/devices`. What only the phone has stays on the phone: Apple Health uploads, Live
Activities, location, the meal camera, the Apple Reminders sync, the silent pushes (the Mac reads what
the phone sent; a reminder ticked on the Mac goes through the server and the phone's next sync).

- `Mac/AideMacApp.swift`, `Mac/MacRootView.swift`: the app, one window (a second would share the one
  `AppEnvironment`), the rail, the menus (⌘N new chat, ⌘1–9 and ⌘0, Show in Menu Bar) and the Pebble in the menu bar (the
  small cut, `MenuBarPebble`, cropped to the Pebble, 15 pt tall, a template). The Pebble opens a panel, not a menu
  (`Mac/MacMenuBarPanel.swift`): Pebble breathing with the greeting, Ask Aide (a new chat in the window), the glance,
  a week strip with a dot per calendar and the chosen day's events (today: what's left and its reminders), what's
  waiting, the team to open a chat, the sections as icons. The window toolbar has no background of its own (no hard
  line). Closing the window leaves Aide running.
- Peek (`Mac/MacPeek.swift`, `Mac/MacPeekTiles.swift`, after peek.zone): hold fn ⌥ (`MacChordWatcher`, needs
  Accessibility) and a non-activating `.screenSaver` panel shows the board over every space; a tap keeps it (`keep()`).
  Tiles are `PeekTile`s in `PeekLayout` (UserDefaults `peekTiles`), packed by `PeekMasonry`; Arrange moves, resizes
  (span) and adds them; `PeekData` loads only the kinds on the board; web tiles keep their `WKWebView` in
  `PeekWebViews`. A question asked there goes through the shared `ChatViewModel` and its reply is drawn on the board.
- On the Mac, Return sends in a chat (`MessageBox`'s `onReturn`; Option-, Shift-, Cmd- or Cmd-Shift-Return is a new line), drops go through
  `dropZone` (`Support/Drops.swift`, #78): an overlay says what the drop will do (the agent's Pebble, or the course)
  or that it isn't taken; photos and PDFs on a chat go into the message, PDFs or recordings on a course page are
  uploaded, photos on Food log a meal, and on any other page they start a chat with Aide (`composerDrop`).
  `-previewDrop takes|refused` shows the overlay in a debug build.
- Push (`Mac/MacAppDelegate.swift`): alerts only, with the topic `<bundle id>.mac` (the server's `push.py`). Off unless
  `Signing.local.xcconfig` sets `AIDE_MAC_ENTITLEMENTS = Mac/AideMacPush.entitlements`, which needs the Mac registered
  on the team (`xcodebuild -scheme AideMac -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`
  once). Without it the app doesn't ask APNs (`UIApplication.canPush`).
- Screen Time on the Mac (#30, in progress): Apple's Screen Time API is iOS-only, so Aide enforces the phone's locks
  itself. `Mac/MacScreenTime.swift` reads `/v1/locks` (on open, after a chat turn, every minute, on wake) and works out
  when each holds with `ScreenTime/LockClock.swift` (shared with the phone and its extensions), waking at the next
  start or end; the menu bar panel's glance says "Locked until 07:00". Step 2 (2026-11-01): the Mac app is no longer sandboxed
  (it quits other apps, an Apple Event). What a lock covers is the Mac's own, "only these" apps by bundle ID, kept on
  this Mac (`MacLockApps`). `Mac/MacShield.swift` quits a covered app when it opens or comes forward (hides it if it
  won't quit) and Pebble pops up asleep over its Dock icon with Open anyway. Settings → This Mac → Screen Time
  (`Mac/MacScreenTimeView.swift`): Lock now, the usual apps, weekly locks with their own apps. Debug builds:
  `-shieldTest 2` adds a local 2-minute lock. During a strict lock Quit is refused (`applicationShouldTerminate`;
  logging out and shutting down still quit, Force Quit always works).
  Daily limits on the Mac (2026-11-01): the phone's limits, each with its own Mac apps (`MacLockApps.perLimit`),
  counted from this Mac's own time (`Mac/MacUsage.swift`) and held until midnight when used up (`MacHold` is a lock
  or a limit holding now, what the shield and the unlock sheet show); a hit goes to the server with `days: []`.
- The Screen section (`Mac/MacScreenPage.swift`): the phone's Screen tab for this Mac, Day · Week · Month, Lock now and
  a gear (Locks and limits, ⇧⌘,) in the corner, a line under the date only while a lock or limit holds, the report drawn by the phone's `Usage/UsageReportView.swift` (shared;
  on the Mac app icons come from the bundle ID). `MacUsage` records it while Aide runs (it opens at login,
  `Mac/MacLoginItem.swift`, Settings → This Mac): every 5 s one app gets the time, so it's never doubled: the app in
  front if touched in the last minute; else an app playing a video (it holds the display awake; `runningboardd` holds it
  for Safari's WebKit) up to 30 min, in front or on the other screen; else, still up to 5 min (reading), the app in
  front once you touch something again (dropped after 5 min). A video on the side also counts for the limits covering it
  (`limits` in the day's file), not for the total. A pickup after 5 min away, a JSON file a day in Application
  Support/Aide/usage (120 days), never sent to the server.
  Websites (2026-11-01, `Mac/MacBrowser.swift`): in Safari and the Chromium browsers (Chrome, Arc, Brave, Edge,
  Vivaldi, Opera) each tick asks the front tab (AppleScript, 1 s timeout; macOS asks once per browser, a "no" or
  Firefox is just the app) and keeps only the site (youtube.com), never the URL: `sites` in the day's file, part of the
  browser's time. The report shows a Websites card and a browser's sites when it's opened (`UsageSite`, Mac-only data
  in the shared view). Locks and limits take sites beside apps ("site:youtube.com" in the same sets, `MacSites.covers`
  matches subdomains), counted in any browser in front or playing on the side; when one holds `MacShield` closes the
  tab (not the browser) at the next tick and Open anyway opens it again.
- Course folders (#73, `Mac/MacCourseFolders.swift`, Settings → This Mac → Course folders): each subfolder of the
  chosen folder is a course (guessed by name, or chosen); its PDFs go up once (`POST /v1/files?from=folder`, by SHA-256),
  the course's Moodle files come down into `<course>/moodle/` (never sent back, never copied again once deleted).
  State in Application Support/Aide/course-folders.json, a log beside it; every 10 min and when the app comes forward.
- `Mac/MacServices.swift`: stand-ins with the same names as the phone-only services (`HealthService`,
  `LiveActivities`, …); `project.yml` leaves the real ones out of `AideMac`.
- The Mac look (2026-10-31): `Mac/MacList.swift` makes `List` a grouped `Form` (rounded inset sections, no heavy
  lines; buttons in rows are accent text), lighter dark colours in `Theme.swift` under `#if os(macOS)`, and
  `Mac/MacNavigationStack.swift` makes `NavigationStack` give a sheet a glass close button (Esc) in its top-left
  corner, since phone sheets often close only by swiping. Both shadow SwiftUI's types for `AideMac` only.
- Sheets: macOS opens a sheet at its *minimum* size (an ideal size is ignored), so `MacSheetSize` works the minimum
  out from the window (`MacRootView`'s own sheets: `.macSheet(windowSize)`, and no `.frame(minWidth:)` around a
  sheet's stack: a smaller outer minimum makes the sheet narrower than the stack, cut off on both sides) (`macWindowSize` in the environment, set by `MacRootView`): a sheet about two thirds of it, a
  cover (`fullScreenCover`, `.macCoverSize()`, a no-op on the phone: slides, a video's page) nearly all of it. A centred
  title by the close button is `.macSheetTitle(_:)`; then keep `navigationTitle` to iOS (the Mac shows it too). Sheets
  don't inherit the window's styles, so each gets `.toggleStyle(.phoneSwitch)` (the switch at the row's end) and the
  grouped form again. A Mac `Button` centres its label's lines: give multi-line rows `.multilineTextAlignment(.leading)`. `.pageColumn()` keeps a ScrollView page's column at 860 pt;
  `List` (a `Form`) is 820 pt wide in the middle. On the Mac, `Theme.toggle` is the accent (ivory), not green.
  `.toolbar(.hidden, for: .navigationBar)` hides the back chevron there (`MacPhoneBar`).
- A practice exam, a lesson, the Learn path and the Study page (quizzes) open as a card over the page inside Aide's
  one window (`macWindowCover`, `Mac/MacCoverLayer.swift`; `fullScreenCover` on the phone): not a sheet, since macOS
  won't take a window with a sheet into full screen, and not a window of their own (they piled up, 2026-11-03). The
  card is the sheet's size with a border, in full screen too (the window's green button); its ⤢ (⇧⌘F,
  `MacCoverExpandButton`, remembered) makes it fill Aide's window, the title and toolbar hidden meanwhile. One opened from a card goes on top. `dismiss` doesn't close a card: `coverClose` does (the views' Close), and so does the X its
  `NavigationStack` puts in the corner (`macCoverRoot`). Toolbar items in a card would land in Aide's window toolbar, so
  the cover views keep theirs to the phone (`coverClose == nil`, titles through `.macSheetTitle`).
- `Mac/iOSCompat.swift`: lets the shared views build unchanged: `UIColor`/`UIImage`/`UIPasteboard` as their AppKit
  twins, `navigationBarTitleDisplayMode`, `topBarTrailing`, `keyboardType`, `fullScreenCover` (a sheet) and the like.

Keeping both working:
- **Build both before pushing a change to `ios/Aide/Aide/`.** When the Mac build breaks on something new from iOS:
  add it to `Mac/iOSCompat.swift` if it has a Mac meaning (or none: a no-op), else wrap it in `#if os(iOS)`.
- A new file that only makes sense on the phone (HealthKit, ActivityKit, a camera…) goes in `AideMac`'s `excludes` in
  `project.yml`, with a stand-in in `Mac/MacServices.swift` if shared code calls it.
- `#available(iOS 26, *)` needs `macOS 26` too: `#available(iOS 26, macOS 26, *)`.

```bash
cd ios/Aide
xcodebuild -scheme AideMac -destination 'platform=macOS' build    # the Mac app
```

## Where things stand

Built on both sides and in use unless it says otherwise. Each area's contract is its section in `docs/API.md`; how it
came about, with dates and what was tried, is in [docs/HISTORY.md](docs/HISTORY.md) and the closed issues.

- **Chat and the team:** Aide and the specialists (Secretary, Professor, Coach, Finance), each with its chats, tools,
  memory and Pebble colour; `ask_agent`, the Team chat with @mentions, the router (#59), queued messages (#69),
  streamed replies, photos, cards under replies (`attachments`, `open` links into the app), the confirm queue,
  Activity and approvals (#12).
- **Calendar, reminders, mail:** iCloud Calendar, Apple Reminders sync (every list, EventKit alarms), Gmail (read,
  send after Confirm), Secretary's reply drafts (#7), the events card as a week with proposed plans (#25).
- **Digests, objectives, routines:** the wake-up briefing, evening, weekly and monthly digests (the morning one is
  off); each specialist's objectives as plans that start by themselves; routines and watches (#13); weather (#51).
- **Health:** Apple Health uploads and the scores, a page per metric, weight, bedtime (#53), habits (limit habits,
  some counted from Health); the Health tab is Body · Food · Screen.
- **Food:** meals from a photo, a description, a barcode or Recent; saved foods; targets and the day score.
- **Screen Time:** locks (strict ones end early only with a pass), daily limits, the usage report; the Mac holds the
  same locks and limits itself, apps and websites (#30).
- **Study:** Moodle files, lecture notes from recordings, notebooks, lessons, quizzes and the Study page, practice and
  mock exams, spaced repetition (#63), the exam plan and study week (#68), focus sessions (#54), Esse3 (#74: sessions,
  bookings, transcript; sign-up as an errand, #75). Recording on the phone and an Esse3 sign-up aren't tried for real yet.
- **Errands:** Aide's Chrome on cappa for shops and bookings (#22), the live view, price watches and timed drops
  (#57), release trackers, the bot-check fixes (#76).
- **Getting around:** GTT trams (alerts, Live Activities, following the ride), leave-now for events, Maps, web search.
- **Money:** Apple Pay taps through a Shortcut, categories, budget, subscriptions, bank accounts (#31).
- **Voice:** voice chat and live calls on cappa's own voice (#34); the faster answers (#71) are live, not yet tried on
  a call.
- **On the phone:** push, Live Activities (trams, the next event, agents at work, locks, focus, bedtime), widgets,
  Control Center controls, App Intents and Shortcuts, the share extension (YouTube videos).

Worth remembering:
- Family Controls works in development builds; TestFlight needs Apple's approval (a request form).
- The first install on a phone needs the App Group and the `.widgets` bundle ID on the team (automatic signing adds them).
- yt-dlp must be kept current (README, "YouTube videos").
- Debug launch arguments: `-previewMonth 2026-10`, `-previewRoute <aide:// link>`, `-shieldTest 2` (Mac).

**Next** (GitHub issues):
0. Try #71 on a few real calls (a calendar question, one with a tool, one that queues an action), then close it.
   No call has been made since it went live (2026-11-06 23:48); the checklist is on the issue.
1. Record a real lecture with the app. Notebooks for the other courses.
2. A real Esse3 sign-up from the app (#74 and #75 are closed and reading works; the two tries on 2026-11-07 stopped
   at need_user, before the #76 fixes).

Later, for health: a bedtime nudge in the evening digest,
weekly health recap, the getting-sick hint (resting HR, HRV and wrist temperature off baseline together).
