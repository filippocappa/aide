"""Settings, read once from the environment (systemd EnvironmentFile or a local .env)."""

import os
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv


@dataclass(frozen=True)
class Settings:
    anthropic_api_key: str
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
    return Settings(
        anthropic_api_key=_required("ANTHROPIC_API_KEY"),
        discord_token=_required("DISCORD_TOKEN"),
        discord_owner_id=int(_required("DISCORD_OWNER_ID")),
        timezone=ZoneInfo(os.environ.get("AIDE_TIMEZONE", "UTC")),
        db_path=Path(os.environ.get("AIDE_DB_PATH", "./data/aide.db")),
        model=os.environ.get("AIDE_MODEL", "claude-sonnet-5-5"),
        effort=os.environ.get("AIDE_EFFORT", "medium"),
        idle_hours=float(os.environ.get("AIDE_IDLE_HOURS", "6")),
    )
