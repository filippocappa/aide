"""Settings, read once from the environment (systemd EnvironmentFile or a local .env)."""

import os
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv


OPENROUTER_BASE_URL = "https://openrouter.ai/api"


@dataclass(frozen=True)
class Settings:
    # Exactly one of these is set: OpenRouter takes priority if both are.
    openrouter_api_key: str | None
    anthropic_api_key: str | None
    discord_token: str
    discord_owner_id: int
    timezone: ZoneInfo
    db_path: Path
    model: str
    effort: str
    idle_hours: float


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing required environment variable {name}")
    return value


def load_settings() -> Settings:
    load_dotenv()  # no-op under systemd, where the env file is already loaded
    openrouter_key = os.environ.get("OPENROUTER_API_KEY", "").strip() or None
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "").strip() or None
    if not (openrouter_key or anthropic_key):
        raise SystemExit("set OPENROUTER_API_KEY or ANTHROPIC_API_KEY")
    default_model = "anthropic/claude-sonnet-5.5" if openrouter_key else "claude-sonnet-5-5"
    return Settings(
        openrouter_api_key=openrouter_key,
        anthropic_api_key=None if openrouter_key else anthropic_key,
        discord_token=_required("DISCORD_TOKEN"),
        discord_owner_id=int(_required("DISCORD_OWNER_ID")),
        timezone=ZoneInfo(os.environ.get("AIDE_TIMEZONE", "UTC")),
        db_path=Path(os.environ.get("AIDE_DB_PATH", "./data/aide.db")),
        model=os.environ.get("AIDE_MODEL") or default_model,
        effort=os.environ.get("AIDE_EFFORT", "medium"),
        idle_hours=float(os.environ.get("AIDE_IDLE_HOURS", "6")),
    )
