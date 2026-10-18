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
- `db.py`: SQLite (WAL) at `data/aide.db`.
- `tools/`: everything that touches the outside world (`calendar.py` uses `icloud.py`, CalDAV).
- `channels/discord_bot.py` and `channels/api.py` (FastAPI, the app's API): two adapters over one agent and one shared conversation.
- `reminders.py`: reminders store and the sync rules. `scheduler.py`: background jobs (the Discord fallback).

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
- **Push notifications are possible** (APNs). v1 doesn't use them yet; they're the next step after v1
  (the server notifies the phone directly, and silent pushes trigger reminder sync).
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

Done: 1 core (Discord bot, agent loop, service), 2 iCloud Calendar, **server HTTP API v1** (all of `docs/API.md`,
live on the Ubuntu box; reminders store and sync; Discord fallback for reminders not yet on the phone).
Now: **iOS app v1** (Mac), per `docs/API.md`.
Next: push notifications (APNs) and silent-push sync, after which Discord becomes optional.
Later: habits, weekly digest, mail, nightly backups.
