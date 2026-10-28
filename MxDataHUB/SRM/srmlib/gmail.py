"""Reading your own Gmail, read-only, for the loaders (the Gmail API; amazon-email reads Amazon's order e-mails).

Google lets a program read a personal mailbox only through an OAuth client of your own: a Google Cloud project with
the Gmail API turned on, its consent screen (External, you as a test user, then Publish app: "In production", left
unverified — in "Testing" Google cancels the sign-in after 7 days) and a Desktop app OAuth client. Its JSON
(client_secret_….json, from Credentials ▸ Download JSON) is read once by

    ./srm.py gmail-auth --client-file ~/Downloads/client_secret_….json

(or, without --client-file, in Terminal: it asks for the client's ID and secret, pasted from the client's page),
which opens Google's sign-in in your browser. You sign in there yourself and allow "Read your email messages and
settings" (gmail.readonly: it can't send, change or delete anything); Google hands the answer back to this program on
127.0.0.1. The client's id and secret and the refresh token are kept in the Keychain (service SRM-api, accounts
gmail-client and gmail; on Windows the Credential Manager's SRM-api:gmail-client and SRM-api:gmail), never in a file
or the repository. Delete the downloaded JSON afterwards. Take the access away at myaccount.google.com/permissions
(then run gmail-auth again to give it back).

Each run trades the refresh token for an access token good for an hour; nothing else is kept.
"""

import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from concurrent.futures import ThreadPoolExecutor

from .common import HTTPError, RateLimiter, debug, keychain, log
from .common import http as fetch_json

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
API = "https://gmail.googleapis.com/gmail/v1/users/me"
SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
SERVICE, CLIENT, TOKEN = "SRM-api", "gmail-client", "gmail"


class _Limiter(RateLimiter):
    """RateLimiter for the threads that read messages."""

    def __init__(self, calls, period):
        super().__init__(calls, period)
        self.lock = threading.Lock()

    def wait(self):
        with self.lock:
            super().wait()


# A message costs Gmail 5 quota units, and a project's per-minute allowance per user can be small (a new one's ran out
# after about 100 messages in 6 seconds): 4 a second, and a minute's wait whenever Google says it's used up.
LIMITER = _Limiter(4, 1)
QUOTA_WAIT, QUOTA_TRIES = 65, 6


class NotAuthorized(Exception):
    """No sign-in kept, or Google took it back: run ./srm.py gmail-auth."""


# ------------------------------------------------------------------------------------------------------------ secrets

def save_secret(service, account, value):
    """Keeps a secret in the login Keychain (on Windows the Credential Manager), replacing what was there. The value
    goes to `security` on its standard input, not its command line."""
    if any(c in value for c in '"\\\n\r'):
        raise ValueError(f"can't keep {account}: it has a quote, backslash or line break")
    if sys.platform == "win32":
        _windows_save(f"{service}:{account}", account, value)
    else:
        line = f'add-generic-password -U -s "{service}" -a "{account}" -w "{value}"\n'
        out = subprocess.run(["security", "-i"], input=line, capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            raise RuntimeError(f"security add-generic-password failed: {out.stderr.strip()[:200]}")
    if keychain(service, account) != value:
        raise RuntimeError(f"{service} / {account} wasn't kept in the {'Credential Manager' if sys.platform == 'win32' else 'Keychain'}")


def _windows_save(target, user, value):
    """A generic credential in the Credential Manager (CredWriteW), as `cmdkey /generic:target /user:user /pass`
    saves one: the value as UTF-16."""
    import ctypes
    from ctypes import wintypes

    class CREDENTIAL(ctypes.Structure):
        _fields_ = [("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR),
                    ("Comment", wintypes.LPWSTR), ("LastWritten", wintypes.FILETIME),
                    ("CredentialBlobSize", wintypes.DWORD), ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
                    ("Persist", wintypes.DWORD), ("AttributeCount", wintypes.DWORD), ("Attributes", ctypes.c_void_p),
                    ("TargetAlias", wintypes.LPWSTR), ("UserName", wintypes.LPWSTR)]

    blob = value.encode("utf-16-le")
    buf = (ctypes.c_ubyte * len(blob)).from_buffer_copy(blob)
    cred = CREDENTIAL(Type=1, TargetName=target, CredentialBlobSize=len(blob),     # 1: CRED_TYPE_GENERIC
                      CredentialBlob=ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte)), Persist=2, UserName=user)  # 2: LOCAL_MACHINE
    advapi32 = ctypes.WinDLL("advapi32")
    advapi32.CredWriteW.argtypes = [ctypes.POINTER(CREDENTIAL), wintypes.DWORD]
    advapi32.CredWriteW.restype = wintypes.BOOL
    if not advapi32.CredWriteW(ctypes.byref(cred), 0):
        raise OSError(ctypes.get_last_error(), f"CredWriteW {target} failed")


def connected():
    """A Gmail sign-in is kept (asked without reading it on a Mac)."""
    if sys.platform == "win32":
        return keychain(SERVICE, TOKEN) is not None
    try:
        return subprocess.run(["security", "find-generic-password", "-s", SERVICE, "-a", TOKEN],
                              capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _client():
    kept = keychain(SERVICE, CLIENT)
    if not kept or " " not in kept:
        raise NotAuthorized("no Gmail OAuth client kept: run ./srm.py gmail-auth --client-file <the client's JSON>")
    return kept.split(" ", 1)


# ------------------------------------------------------------------------------------------------------------ signing in

class _Answer(http.server.BaseHTTPRequestHandler):
    """Google's redirect after the sign-in: /?code=…&state=… (or ?error=…)."""
    got = None

    def do_GET(self):
        q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
        if "code" not in q and "error" not in q:
            self.send_response(404)
            self.end_headers()
            return
        type(self).got = q
        ok = "code" in q
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(("<html><body style='font-family:-apple-system,sans-serif;margin:3em'><h2>%s</h2>"
                          "<p>You can close this tab and go back to the terminal.</p></body></html>"
                          % ("Gmail is connected to the SRM loaders" if ok else "Not connected: " + q.get("error", ""))).encode())

    def log_message(self, *args):
        pass


def authorize(client_file=None, timeout=600):
    """The one-time sign-in: keeps the OAuth client (from its downloaded JSON, else the one kept before), opens
    Google's consent page, waits for the answer on 127.0.0.1 and keeps the refresh token. Returns the mailbox's
    address."""
    if client_file:
        with open(os.path.expanduser(client_file)) as f:
            data = json.load(f)
        c = data.get("installed") or data.get("web") or {}
        if not data.get("installed"):
            raise ValueError("that JSON isn't a Desktop app OAuth client (Credentials ▸ Create credentials ▸ OAuth "
                             "client ID ▸ Application type: Desktop app)")
        client_id, client_secret = c.get("client_id"), c.get("client_secret")
        if not client_id or not client_secret:
            raise ValueError("no client_id / client_secret in that JSON")
        save_secret(SERVICE, CLIENT, f"{client_id} {client_secret}")
        log(f"kept the OAuth client {client_id.split('-')[0]}-… in the {'Credential Manager' if sys.platform == 'win32' else 'Keychain'} "
            f"({SERVICE} / {CLIENT}); you can delete {os.path.basename(client_file)} now")
    elif not keychain(SERVICE, CLIENT):
        # No JSON downloaded: the client's id and secret pasted from its page (Clients ▸ the client), the secret unshown.
        if not sys.stdin.isatty():
            raise NotAuthorized("no Gmail OAuth client kept: run ./srm.py gmail-auth in Terminal (it asks for the "
                                "client's ID and secret), or pass --client-file <the client's JSON>")
        import getpass
        client_id = input("Client ID (….apps.googleusercontent.com): ").strip()
        client_secret = getpass.getpass("Client secret (not shown as you paste): ").strip()
        if not client_id.endswith(".apps.googleusercontent.com") or not client_secret:
            raise ValueError("that isn't a Desktop app client's ID (it ends in .apps.googleusercontent.com) and secret")
        save_secret(SERVICE, CLIENT, f"{client_id} {client_secret}")
        log(f"kept the OAuth client {client_id.split('-')[0]}-… in the "
            f"{'Credential Manager' if sys.platform == 'win32' else 'Keychain'} ({SERVICE} / {CLIENT})")
    client_id, client_secret = _client()

    verifier = secrets.token_urlsafe(64)[:96]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    _Answer.got = None
    server = http.server.HTTPServer(("127.0.0.1", 0), _Answer)
    redirect = f"http://127.0.0.1:{server.server_port}"
    url = AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": client_id, "redirect_uri": redirect, "response_type": "code", "scope": SCOPE,
        "access_type": "offline", "prompt": "consent", "state": state,
        "code_challenge": challenge, "code_challenge_method": "S256"})
    log("opening Google's sign-in in your browser; sign in there and allow reading your e-mail (read-only).")
    log(f"If no browser opens, open this address yourself:\n\n    {url}\n")
    webbrowser.open(url)
    server.timeout = 5
    waited = 0
    while _Answer.got is None and waited < timeout:
        server.handle_request()
        waited += server.timeout
    server.server_close()
    got = _Answer.got
    if got is None:
        raise TimeoutError(f"no answer from Google's sign-in in {timeout // 60} minutes")
    if got.get("error"):
        raise PermissionError(f"Google's sign-in answered: {got['error']}")
    if got.get("state") != state:
        raise PermissionError("the answer isn't from this sign-in (state differs)")
    out = _post_form(TOKEN_URL, {
        "code": got["code"], "client_id": client_id, "client_secret": client_secret, "redirect_uri": redirect,
        "grant_type": "authorization_code", "code_verifier": verifier})
    if SCOPE not in (out.get("scope") or "").split():
        raise PermissionError("Gmail read access wasn't allowed (tick “Read your email messages and settings”)")
    if not out.get("refresh_token"):
        raise PermissionError("Google gave no refresh token; take the access away at "
                              "myaccount.google.com/permissions and run gmail-auth again")
    save_secret(SERVICE, TOKEN, out["refresh_token"])
    mailbox = Gmail(access_token=out["access_token"]).profile()["emailAddress"]
    log(f"Gmail {mailbox} connected, read-only; the sign-in is kept in the "
        f"{'Credential Manager' if sys.platform == 'win32' else 'Keychain'} ({SERVICE} / {TOKEN})")
    return mailbox


def _post_form(url, fields):
    """POSTs a form to Google's token endpoint; its JSON answer (errors as PermissionError, without the secrets)."""
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded",
                                          "User-Agent": "MxDataHUB-SRM-loader/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read().decode("utf-8", "replace"))
        except ValueError:
            err = {}
        if err.get("error") == "invalid_grant":
            raise NotAuthorized("Google no longer accepts the kept Gmail sign-in (taken away, its password changed, "
                                "or the OAuth app still in Testing: 7 days): run ./srm.py gmail-auth again")
        raise PermissionError(f"Google's token endpoint answered {e.code}: {err.get('error')} "
                              f"{err.get('error_description') or ''}".strip())


# ------------------------------------------------------------------------------------------------------------ reading

class Gmail:
    """The signed-in mailbox, read-only."""

    def __init__(self, access_token=None):
        self.calls, self.paused_until = 0, 0.0
        if access_token is None:
            refresh = keychain(SERVICE, TOKEN)
            if not refresh:
                raise NotAuthorized("Gmail isn't connected: run ./srm.py gmail-auth --client-file <the OAuth "
                                    "client's JSON> (see srmlib/gmail.py)")
            client_id, client_secret = _client()
            out = _post_form(TOKEN_URL, {"refresh_token": refresh, "client_id": client_id,
                                         "client_secret": client_secret, "grant_type": "refresh_token"})
            access_token = out["access_token"]
            self.calls += 1
            debug(f"Gmail access token for {out.get('expires_in')}s")
        self.headers = {"Authorization": f"Bearer {access_token}"}

    def _get(self, path, **params):
        url = API + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
        for attempt in range(QUOTA_TRIES):
            with LIMITER.lock:
                self.calls += 1
            try:
                return fetch_json(url, headers=self.headers, limiter=LIMITER, retries=2)
            except HTTPError as e:
                if e.status == 401:
                    raise NotAuthorized("Gmail refused the access token: run ./srm.py gmail-auth again")
                if e.status == 403 and ("has not been used" in e.body or "is disabled" in e.body):
                    raise NotAuthorized("the Gmail API isn't turned on in the OAuth client's Google Cloud project "
                                        "(APIs & Services ▸ Library ▸ Gmail API ▸ Enable)")
                quota = e.status == 429 or (e.status == 403 and re.search(r"quota exceeded|rate ?limit", e.body, re.I))
                if not quota or attempt == QUOTA_TRIES - 1:
                    raise
                with LIMITER.lock:     # one wait for every reader thread
                    if time.monotonic() >= self.paused_until:
                        log(f"  Gmail's per-minute quota is used up; waiting {QUOTA_WAIT}s")
                        self.paused_until = time.monotonic() + QUOTA_WAIT
                    pause = self.paused_until - time.monotonic()
                time.sleep(max(1, pause))

    def profile(self):
        """{emailAddress, messagesTotal, threadsTotal, historyId}."""
        return self._get("/profile")

    def search(self, query, limit=None):
        """The ids of the messages a Gmail search finds (as in Gmail's search box), newest first."""
        ids, token = [], None
        while True:
            page = self._get("/messages", q=query, maxResults=500, **({"pageToken": token} if token else {}))
            ids += [m["id"] for m in page.get("messages") or []]
            token = page.get("nextPageToken")
            if not token or (limit and len(ids) >= limit):
                return ids[:limit] if limit else ids

    def raw(self, message_id):
        """(the message as sent: RFC 822 bytes, Gmail's internalDate in ms)."""
        m = self._get(f"/messages/{message_id}", format="raw")
        return base64.urlsafe_b64decode(m["raw"] + "=" * (-len(m["raw"]) % 4)), int(m.get("internalDate") or 0)

    def raws(self, message_ids, workers=3):
        """{id: (bytes, internalDate)} of these messages, a few at a time."""
        lock = threading.Lock()
        out = {}

        def one(mid):
            got = self.raw(mid)
            with lock:
                out[mid] = got

        with ThreadPoolExecutor(workers) as pool:
            for _ in pool.map(one, message_ids):
                pass
        return out
