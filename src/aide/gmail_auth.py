"""One-time Gmail sign-in: `uv run python -m aide.gmail_auth`.

Reads GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET from .env, opens Google's consent page, and writes
GMAIL_REFRESH_TOKEN back into .env. The token is never printed.

The browser must reach http://127.0.0.1:<port> on this machine. From another computer, forward the port
first (`ssh -L 8765:127.0.0.1:8765 <this machine>`), or use --paste and copy the address the browser
fails to load back into this terminal.
"""

import argparse
import base64
import hashlib
import os
import re
import secrets
import sys
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import httpx
from dotenv import load_dotenv

from .gmail import API, SCOPES, TOKEN_URL

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"


def _wait_for_redirect(port: int) -> str:
    """Serve one request on 127.0.0.1:port and return its full URL."""
    got: dict[str, str] = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if "code=" not in self.path and "error=" not in self.path:
                self.send_response(404)
                self.end_headers()
                return
            got["url"] = f"http://127.0.0.1:{port}{self.path}"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write("Aide: done. You can close this tab and go back to the terminal.".encode())

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        while "url" not in got:
            thread.join(0.2)
    finally:
        server.shutdown()
    return got["url"]


def _save(env_path: Path, key: str, value: str) -> None:
    """Set key=value in the env file, replacing an existing line, keeping everything else."""
    text = env_path.read_text() if env_path.exists() else ""
    line = f"{key}={value}"
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.M)
    text = pattern.sub(lambda _: line, text) if pattern.search(text) else text.rstrip("\n") + f"\n{line}\n"
    env_path.write_text(text)
    env_path.chmod(0o600)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", type=Path, default=Path(".env"), help="env file to read and update (default .env)")
    parser.add_argument("--port", type=int, default=8765, help="local port Google redirects to (default 8765)")
    parser.add_argument("--paste", action="store_true", help="don't listen; paste the redirect address instead")
    args = parser.parse_args()

    load_dotenv(args.env)
    client_id = os.environ.get("GMAIL_CLIENT_ID", "").strip()
    client_secret = os.environ.get("GMAIL_CLIENT_SECRET", "").strip()
    if not (client_id and client_secret):
        sys.exit(f"Set GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET in {args.env} first (see README.md, \"Gmail\").")

    redirect_uri = f"http://127.0.0.1:{args.port}"
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    url = AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": client_id, "redirect_uri": redirect_uri, "response_type": "code",
        "scope": " ".join(SCOPES), "access_type": "offline", "prompt": "consent",  # always return a refresh token
        "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
    })

    print("Open this address and allow access:\n\n" + url + "\n")
    if args.paste:
        redirected = input("Paste the address the browser ended on (it starts with http://127.0.0.1): ").strip()
    else:
        webbrowser.open(url)
        print(f"Waiting for Google to redirect to {redirect_uri} …")
        redirected = _wait_for_redirect(args.port)

    query = urllib.parse.parse_qs(urllib.parse.urlparse(redirected).query)
    if "error" in query:
        sys.exit(f"Google said: {query['error'][0]}")
    if query.get("state", [""])[0] != state:
        sys.exit("The redirect doesn't belong to this sign-in (state mismatch). Run the script again.")

    r = httpx.post(TOKEN_URL, data={
        "client_id": client_id, "client_secret": client_secret, "code": query["code"][0],
        "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect_uri,
    })
    if r.status_code != 200:
        sys.exit(f"Token exchange failed: {r.json().get('error_description') or r.json().get('error')}")
    tokens = r.json()
    granted = set(tokens.get("scope", "").split())
    if missing := [s for s in SCOPES if s not in granted]:
        sys.exit("Access was granted without " + ", ".join(missing) + ". Run again and tick every box.")
    if "refresh_token" not in tokens:
        sys.exit("Google returned no refresh token. Remove Aide at myaccount.google.com/permissions and run again.")

    profile = httpx.get(API + "/profile", headers={"Authorization": f"Bearer {tokens['access_token']}"})
    profile.raise_for_status()
    _save(args.env, "GMAIL_REFRESH_TOKEN", tokens["refresh_token"])
    print(f"Signed in as {profile.json()['emailAddress']}. Saved GMAIL_REFRESH_TOKEN to {args.env}.")
    print("Restart Aide to pick it up: systemctl --user restart aide")


if __name__ == "__main__":
    main()
