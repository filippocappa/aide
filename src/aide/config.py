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
    smart_model: str
    effort: str
    idle_hours: float
    icloud_email: str | None
    icloud_app_password: str | None
    default_calendar: str | None
    api_token: str | None
    api_port: int
    gmail_client_id: str | None
    gmail_client_secret: str | None
    gmail_refresh_token: str | None
    tavily_api_key: str | None
    google_maps_api_key: str | None
    home_address: str | None
    apns_key_path: str | None
    apns_key_id: str | None
    apns_team_id: str | None
    apns_bundle_id: str


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
    prefix = "anthropic/" if openrouter_key else ""
    haiku = prefix + ("claude-haiku-5.5" if openrouter_key else "claude-haiku-5-5")
    sonnet = prefix + ("claude-sonnet-5.5" if openrouter_key else "claude-sonnet-5-5")
    return Settings(
        openrouter_api_key=openrouter_key,
        anthropic_api_key=None if openrouter_key else anthropic_key,
        discord_token=_required("DISCORD_TOKEN"),
        discord_owner_id=int(_required("DISCORD_OWNER_ID")),
        timezone=ZoneInfo(os.environ.get("AIDE_TIMEZONE", "UTC")),
        db_path=Path(os.environ.get("AIDE_DB_PATH", "./data/aide.db")),
        model=os.environ.get("AIDE_MODEL") or haiku,
        smart_model=os.environ.get("AIDE_SMART_MODEL") or sonnet,
        effort=os.environ.get("AIDE_EFFORT", "medium"),
        idle_hours=float(os.environ.get("AIDE_IDLE_HOURS", "6")),
        icloud_email=os.environ.get("ICLOUD_EMAIL", "").strip() or None,
        icloud_app_password=os.environ.get("ICLOUD_APP_PASSWORD", "").strip() or None,
        default_calendar=os.environ.get("AIDE_DEFAULT_CALENDAR", "").strip() or None,
        api_token=os.environ.get("AIDE_API_TOKEN", "").strip() or None,
        api_port=int(os.environ.get("AIDE_API_PORT", "8787")),
        gmail_client_id=os.environ.get("GMAIL_CLIENT_ID", "").strip() or None,
        gmail_client_secret=os.environ.get("GMAIL_CLIENT_SECRET", "").strip() or None,
        gmail_refresh_token=os.environ.get("GMAIL_REFRESH_TOKEN", "").strip() or None,
        tavily_api_key=os.environ.get("TAVILY_API_KEY", "").strip() or None,
        google_maps_api_key=os.environ.get("GOOGLE_MAPS_API_KEY", "").strip() or None,
        home_address=os.environ.get("AIDE_HOME_ADDRESS", "").strip() or None,
        apns_key_path=os.environ.get("APNS_KEY_PATH", "").strip() or None,
        apns_key_id=os.environ.get("APNS_KEY_ID", "").strip() or None,
        apns_team_id=os.environ.get("APNS_TEAM_ID", "").strip() or None,
        apns_bundle_id=os.environ.get("APNS_BUNDLE_ID", "").strip() or "com.filippocappa.aide",
    )
