# Aide

Personal assistant over Discord DMs, backed by Claude. See [SPEC.md](SPEC.md) for the full plan.
Done so far: milestone 1 (agent loop, SQLite history, Discord bot with an owner allowlist, systemd service) and milestone 2 (iCloud Calendar).

## Layout

```
src/aide/
  __main__.py            entry point: wires settings, db, agent, bot
  config.py              settings from the environment
  db.py                  SQLite (WAL): conversations, messages, audit_log
  agent.py               Claude tool-use loop and conversation history
  tools/                 tool registry: clock, calendar, reminders, memory, mail
  gmail.py, gmail_auth.py  Gmail API client; one-time OAuth sign-in script
  channels/discord_bot.py  Discord adapter (owner DMs only)
deploy/aide.service      systemd unit
```

## Setup

1. **Discord bot.** In the [Developer Portal](https://discord.com/developers/applications), create an application, add a bot and copy its token. No privileged intents are needed. Invite the bot to any server you're in (OAuth2 → URL Generator → scope `bot`), so Discord lets you DM it.
2. **Your user ID.** Discord settings → Advanced → Developer Mode, then right-click your name → Copy User ID.
3. **Env file.** `cp .env.example .env` and fill in your OpenRouter (or Anthropic) key, bot token and owner ID.
4. **iCloud Calendar (optional).** Create an app-specific password at account.apple.com → Sign-In and Security, and set `ICLOUD_EMAIL` and `ICLOUD_APP_PASSWORD`. Without them the calendar tools are off.
5. **Gmail (optional).** See [Gmail](#gmail) below. Without it the mail tools are off.
6. **Run.** `uv sync && uv run aide`. The bot DMs you "Aide is up." once it's connected.

Aide can list, search and create events on your iCloud calendars right away. Moving or deleting an event is queued: the bot shows exactly what will change, and nothing happens until you reply `!yes` (or `yes`). `!no` cancels, and queued actions expire after 30 minutes. Recurring events are listed but can't be changed yet.

In the DM, type anything to talk to it. `!new` starts a fresh conversation. `!think` (alone or before a message) switches the rest of the conversation from Haiku to Sonnet for harder requests. A new conversation also starts after `AIDE_IDLE_HOURS` (default 6) of silence. That keeps each request small and cheap without editing history.

## Gmail

Aide reads and searches your mail, and sends or replies only after your `!yes`. It uses the Gmail API with
two scopes: `gmail.readonly` (read) and `gmail.send` (send as you). It can't delete, archive or label anything.

One-time setup in Google Cloud, by hand:

1. [console.cloud.google.com](https://console.cloud.google.com): create a project, e.g. "Aide".
2. **APIs & Services → Library → Gmail API → Enable.**
3. **Google Auth Platform → Branding:** app name "Aide", your address as support and developer contact.
   **Audience:** External, and add your Gmail address under *Test users*.
4. **Data Access → Add or remove scopes:** add `.../auth/gmail.readonly` and `.../auth/gmail.send`.
5. **Clients → Create client:** type **Desktop app**, name "Aide server". Copy the client ID and secret into
   `.env` as `GMAIL_CLIENT_ID` and `GMAIL_CLIENT_SECRET`.
6. **Audience → Publish app** ("In production"). Skip this and the refresh token dies after 7 days, which is
   Google's limit for apps in Testing. You don't need verification for an app only you use. Google warns
   "Google hasn't verified this app" when you sign in: click *Advanced → Go to Aide*.

Then sign in once, on the server:

```
uv run python -m aide.gmail_auth        # opens the consent page, writes GMAIL_REFRESH_TOKEN to .env
systemctl --user restart aide
```

The browser has to reach `http://127.0.0.1:8765` on the server. From another computer, either forward the
port first (`ssh -L 8765:127.0.0.1:8765 cappa`, then open the printed link locally), or run with `--paste`
and paste back the address the browser fails to load. The token is never printed. If Aide later says Gmail
access expired, run the script again.

## Tests

```
uv run pytest
```

## Running as a service

Aide runs as a systemd **user** service straight from this checkout, reading `.env` here. It starts at boot and restarts on crashes.

```bash
mkdir -p ~/.config/systemd/user
ln -sf "$PWD/deploy/aide-user.service" ~/.config/systemd/user/aide.service
systemctl --user daemon-reload
systemctl --user enable --now aide
sudo loginctl enable-linger "$USER"   # keep running while logged out, and start at boot
```

Day to day:

```bash
systemctl --user status aide          # is it running?
systemctl --user restart aide         # after a git pull or editing .env
journalctl --user -u aide -f          # live logs
```

The database is `data/aide.db` in this folder. `deploy/aide.service` is a hardened system-wide alternative (dedicated `aide` user, `/opt/aide`) if you ever want that instead.

## Notes

- LLM: OpenRouter (`OPENROUTER_API_KEY`) or the Anthropic API directly (`ANTHROPIC_API_KEY`). Haiku 5.5 by default, Sonnet 5.5 after `!think`; override with `AIDE_MODEL` / `AIDE_SMART_MODEL`. Prompt caching is on for both; server-side refusal fallback only works direct, and not on Haiku.
- Each turn is saved to SQLite only after it completes. A crash mid-turn loses that turn but never corrupts history.
- Every tool call is written to `audit_log`.
