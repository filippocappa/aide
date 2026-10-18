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
  tools/                 tool registry; clock.py is the only tool so far
  channels/discord_bot.py  Discord adapter (owner DMs only)
deploy/aide.service      systemd unit
```

## Setup

1. **Discord bot.** In the [Developer Portal](https://discord.com/developers/applications), create an application, add a bot and copy its token. No privileged intents are needed. Invite the bot to any server you're in (OAuth2 → URL Generator → scope `bot`), so Discord lets you DM it.
2. **Your user ID.** Discord settings → Advanced → Developer Mode, then right-click your name → Copy User ID.
3. **Env file.** `cp .env.example .env` and fill in your OpenRouter (or Anthropic) key, bot token and owner ID.
4. **iCloud Calendar (optional).** Create an app-specific password at account.apple.com → Sign-In and Security, and set `ICLOUD_EMAIL` and `ICLOUD_APP_PASSWORD`. Without them the calendar tools are off.
5. **Run.** `uv sync && uv run aide`. The bot DMs you "Aide is up." once it's connected.

Aide can list, search and create events on your iCloud calendars right away. Moving or deleting an event is queued: the bot shows exactly what will change, and nothing happens until you reply `!yes` (or `yes`). `!no` cancels, and queued actions expire after 30 minutes. Recurring events are listed but can't be changed yet.

In the DM, type anything to talk to it. `!new` starts a fresh conversation. `!think` (alone or before a message) switches the rest of the conversation from Haiku to Sonnet for harder requests. A new conversation also starts after `AIDE_IDLE_HOURS` (default 6) of silence. That keeps each request small and cheap without editing history.

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
