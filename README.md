# Aide

Personal assistant over Discord DMs, backed by Claude. See [SPEC.md](SPEC.md) for the full plan.
This is milestone 1: the agent loop, SQLite history, the Discord bot with an owner allowlist, and a systemd unit.

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
4. **Run.** `uv sync && uv run aide`. The bot DMs you "Aide is up." once it's connected.

In the DM, type anything to talk to it, or `!new` to start a fresh conversation. A new conversation also starts after `AIDE_IDLE_HOURS` (default 6) of silence. That keeps each request small and cheap without editing history.

## Tests

```
uv run pytest
```

## Running as a service

```bash
sudo useradd --system --home /opt/aide --shell /usr/sbin/nologin aide
sudo mkdir -p /opt/aide /etc/aide
sudo rsync -a --exclude .venv --exclude data --exclude .env ./ /opt/aide/
sudo chown -R aide:aide /opt/aide
sudo -u aide env UV_PYTHON_INSTALL_DIR=/opt/aide/.python uv sync --project /opt/aide --no-dev
sudo install -m 600 -o aide -g aide .env /etc/aide/aide.env
sudo cp deploy/aide.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now aide
journalctl -u aide -f
```

The database lives at `/var/lib/aide/aide.db` (systemd creates the directory). `AIDE_DB_PATH` in the env file is overridden by the unit.

## Notes

- LLM: OpenRouter (`OPENROUTER_API_KEY`, model `anthropic/claude-sonnet-5.5`) or the Anthropic API directly (`ANTHROPIC_API_KEY`, model `claude-sonnet-5-5`). Prompt caching is on for both; server-side refusal fallback only works direct. Override the model with `AIDE_MODEL`.
- Each turn is saved to SQLite only after it completes. A crash mid-turn loses that turn but never corrupts history.
- Every tool call is written to `audit_log`.
