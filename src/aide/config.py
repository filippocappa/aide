"""Settings, read once from the environment (systemd EnvironmentFile or a local .env)."""

import os
import re
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv


OPENROUTER_BASE_URL = "https://openrouter.ai/api"
# Voice chats' speech to text: about a second for a sentence, Italian and English alike.
TRANSCRIBE_MODEL = "google/gemini-3.5-flash-lite"
# Coach's photos: what's on the plate and how much, for Coach to log on the everyday model (reader.py).
PHOTO_READ_MODEL = "google/gemini-3.8-flash"


@dataclass(frozen=True)
class Settings:
    # Exactly one of these is set: OpenRouter takes priority if both are.
    openrouter_api_key: str | None
    anthropic_api_key: str | None
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
    transcribe_model: str = TRANSCRIBE_MODEL
    photo_read_model: str = PHOTO_READ_MODEL
    study_calendar: str = "Work"  # lectures: a course is an event title in it
    exam_calendar: str = "Exam"
    study_skip: tuple[str, ...] = ("study",)  # study-calendar titles that aren't courses (own study blocks)
    vault_dir: Path = Path("./data/obsidian")  # what WebDAV serves; the vault is the folder vault_name in it
    vault_name: str = "Uni"
    webdav_password: str | None = None  # no password: no vault
    webdav_port: int = 8789
    webdav_url: str | None = None  # how the phone reaches it, for the app's setup screen
    moodle_url: str | None = None  # https://elearning.unito.it/sme
    moodle_token: str | None = None  # from the app's Moodle login, written here by the server
    enable_banking_app_id: str | None = None  # bank sync (#31): Enable Banking's application ID
    enable_banking_key: Path | None = None  # its private key (PEM), copied to the server by the user
    enable_banking_redirect: str | None = None  # the callback URL registered with Enable Banking
    gtt: bool = True  # Turin's GTT: stops, live arrivals and tram alerts (AIDE_GTT=0 turns it off)
    # Live calls (#34): AIDE_LIVE=local (Parakeet, Kokoro on the GPU; the default where they're installed),
    # gpt-live (OpenAI's GPT-Live, needs the key) or off.
    live: str | None = None  # None: local if it can, else gpt-live with a key, else off
    live_voice_en: str = "af_heart"
    live_voice_it: str = "if_sara"
    live_speed: float = 1.1
    voice_url: str | None = None  # the Chatterbox voice service (deploy/aide-voice.service); Kokoro without it
    voice_thinking: bool = False
    voice_direct: bool = True
    router_model: str | None = None  # picks the specialist for a message to Aide (#59); AIDE_ROUTER=off: none
    openai_api_key: str | None = None
    live_model: str = "gpt-live-1"
    live_voice: str = "marin"
    live_idle_minutes: float = 5


def save_env(env_path: Path, key: str, value: str | None) -> None:
    """Set key=value in the env file, replacing an existing line and keeping everything else; None removes it.
    Owner-only, since it holds secrets."""
    text = env_path.read_text() if env_path.exists() else ""
    pattern = re.compile(rf"^{re.escape(key)}=.*(\n|$)", re.M)
    if value is None:
        text = pattern.sub("", text)
    else:
        line = f"{key}={value}\n"
        text = pattern.sub(lambda _: line, text) if pattern.search(text) else text.rstrip("\n") + f"\n{line}"
    tmp = env_path.with_name(env_path.name + ".tmp")
    tmp.write_text(text)
    tmp.chmod(0o600)
    os.replace(tmp, env_path)


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
        transcribe_model=os.environ.get("AIDE_TRANSCRIBE_MODEL", "").strip() or TRANSCRIBE_MODEL,
        photo_read_model=os.environ.get("AIDE_PHOTO_READ_MODEL", "").strip() or PHOTO_READ_MODEL,
        study_calendar=os.environ.get("AIDE_STUDY_CALENDAR", "").strip() or "Work",
        exam_calendar=os.environ.get("AIDE_EXAM_CALENDAR", "").strip() or "Exam",
        study_skip=tuple(s.strip() for s in os.environ.get("AIDE_STUDY_SKIP", "study").split(",") if s.strip()),
        vault_dir=Path(os.environ.get("AIDE_VAULT_DIR", "").strip() or "./data/obsidian"),
        vault_name=os.environ.get("AIDE_VAULT_NAME", "").strip() or "Uni",
        webdav_password=os.environ.get("AIDE_WEBDAV_PASSWORD", "").strip() or None,
        webdav_port=int(os.environ.get("AIDE_WEBDAV_PORT", "8789")),
        webdav_url=os.environ.get("AIDE_WEBDAV_URL", "").strip() or None,
        moodle_url=os.environ.get("AIDE_MOODLE_URL", "").strip().rstrip("/") or None,
        moodle_token=os.environ.get("MOODLE_TOKEN", "").strip() or None,
        enable_banking_app_id=os.environ.get("ENABLE_BANKING_APP_ID", "").strip() or None,
        enable_banking_key=Path(k).expanduser() if (k := os.environ.get("ENABLE_BANKING_KEY", "").strip()) else None,
        enable_banking_redirect=os.environ.get("ENABLE_BANKING_REDIRECT", "").strip() or None,
        gtt=os.environ.get("AIDE_GTT", "1").strip() not in ("0", "false", "no", "off"),
        live=os.environ.get("AIDE_LIVE", "").strip().lower() or None,
        live_voice_en=os.environ.get("AIDE_LIVE_VOICE_EN", "").strip() or "af_heart",
        live_voice_it=os.environ.get("AIDE_LIVE_VOICE_IT", "").strip() or "if_sara",
        live_speed=float(os.environ.get("AIDE_LIVE_SPEED", "").strip() or 1.1),
        voice_url=None if (u := os.environ.get("AIDE_VOICE_URL", "").strip()).lower() in ("off", "0", "no")
        else u or "http://127.0.0.1:8766",
        voice_thinking=os.environ.get("AIDE_VOICE_THINKING", "").strip().lower() in ("1", "true", "on", "yes"),
        voice_direct=os.environ.get("AIDE_VOICE_DIRECT", "").strip().lower() not in ("0", "false", "off", "no"),
        router_model=None if os.environ.get("AIDE_ROUTER", "").strip().lower() in ("0", "false", "off", "no")
        else os.environ.get("AIDE_ROUTER_MODEL", "").strip() or haiku,
        openai_api_key=os.environ.get("OPENAI_API_KEY", "").strip() or None,
        live_model=os.environ.get("AIDE_LIVE_MODEL", "").strip() or "gpt-live-1",
        live_voice=os.environ.get("AIDE_LIVE_VOICE", "").strip() or "marin",
        live_idle_minutes=float(os.environ.get("AIDE_LIVE_IDLE_MIN", "").strip() or 5),
    )
