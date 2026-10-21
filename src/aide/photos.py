"""Photos the app uploads for chat and the food log (docs/API.md, "Photos").

Each photo is one file in data/photos, named by its id. Photos never change once saved, so the nightly
backup copies only the new ones (backup.py).
"""

import re
import secrets
from pathlib import Path

MAX_BYTES = 3_500_000  # Claude reads up to about 5 MB of base64, so about 3.7 MB raw
TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
ID = re.compile(r"^p_[0-9a-f]{16}$")


class PhotoStore:
    def __init__(self, folder: Path):
        self.folder = folder
        self.folder.mkdir(parents=True, exist_ok=True)

    def save(self, data: bytes, content_type: str) -> str:
        if not data:
            raise ValueError("the photo is empty")
        if content_type not in TYPES:
            raise ValueError(f"photos must be one of {', '.join(TYPES)}")
        if len(data) > MAX_BYTES:
            raise ValueError(f"the photo is over {MAX_BYTES / 1_000_000:.1f} MB")
        photo_id = "p_" + secrets.token_hex(8)
        tmp = self.folder / f".{photo_id}.tmp"
        tmp.write_bytes(data)
        tmp.rename(self.folder / (photo_id + TYPES[content_type]))
        return photo_id

    def _path(self, photo_id: str) -> Path | None:
        if not ID.match(photo_id):  # also keeps an id from naming a path outside the folder
            return None
        return next((p for ext in TYPES.values() if (p := self.folder / (photo_id + ext)).exists()), None)

    def exists(self, photo_id: str) -> bool:
        return self._path(photo_id) is not None

    def load(self, photo_id: str) -> tuple[bytes, str] | None:
        """The photo's bytes and content type, or None for an unknown id."""
        if (path := self._path(photo_id)) is None:
            return None
        return path.read_bytes(), next(t for t, ext in TYPES.items() if ext == path.suffix)
