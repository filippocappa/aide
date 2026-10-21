"""WebDAV for the Obsidian vault (vault.py), in a process of its own (deploy/aide-webdav.service):

    python -m aide.webdav

Serves AIDE_VAULT_DIR (data/obsidian), which holds the vault folder (AIDE_VAULT_NAME, "Uni"): Remotely Save syncs a
vault with the folder of its name. Listens on 127.0.0.1:AIDE_WEBDAV_PORT (8789); `tailscale serve` publishes it on
the tailnet. Basic auth, user "aide" and AIDE_WEBDAV_PASSWORD from .env; without a password it doesn't start.
"""

import logging
import sys

from .config import load_settings

USER = "aide"
# Obsidian's origins on the Mac, the iPhone and Android, for its plugins' requests.
ORIGINS = ["app://obsidian.md", "capacitor://localhost", "http://localhost"]


def config(root: str, password: str, port: int) -> dict:
    from wsgidav.error_printer import ErrorPrinter
    from wsgidav.http_authenticator import HTTPAuthenticator
    from wsgidav.mw.cors import Cors
    from wsgidav.request_resolver import RequestResolver

    return {
        "host": "127.0.0.1",
        "port": port,
        "provider_mapping": {"/": root},
        "simple_dc": {"user_mapping": {"*": {USER: {"password": password}}}},
        "http_authenticator": {"accept_basic": True, "accept_digest": False, "default_to_digest": False},
        "cors": {"allow_origin": ORIGINS, "allow_credentials": True, "max_age": 600,
                 "allow_methods": ["GET", "HEAD", "PUT", "DELETE", "MKCOL", "COPY", "MOVE", "PROPFIND", "OPTIONS"],
                 "allow_headers": ["authorization", "content-type", "depth", "destination", "overwrite",
                                   "if-match", "if-none-match", "cache-control"],
                 "expose_headers": ["etag", "dav", "content-length", "last-modified"]},
        # No directory browser: it would also mount its own share, readable without a password.
        "middleware_stack": [Cors, ErrorPrinter, HTTPAuthenticator, RequestResolver],
        "lock_storage": True,
        "property_manager": True,
        "verbose": 2,
        "logging": {"enable_loggers": []},
    }


def main() -> None:
    from cheroot import wsgi
    from wsgidav.wsgidav_app import WsgiDAVApp

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    settings = load_settings()
    if not settings.webdav_password:
        sys.exit("AIDE_WEBDAV_PASSWORD isn't set in .env: not serving the vault")
    root = settings.vault_dir
    (root / settings.vault_name).mkdir(parents=True, exist_ok=True)
    app = WsgiDAVApp(config(str(root), settings.webdav_password, settings.webdav_port))
    server = wsgi.Server(("127.0.0.1", settings.webdav_port), app)
    logging.info("WebDAV for %s on http://127.0.0.1:%d", root, settings.webdav_port)
    try:
        server.start()
    except KeyboardInterrupt:
        server.stop()


if __name__ == "__main__":
    main()
