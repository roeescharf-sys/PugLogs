"""Minimal Warcraft Logs API v2 client (standard library only).

Reads credentials from ~/.config/puglogs/wcl.env (WCL_CLIENT_ID / WCL_CLIENT_SECRET);
on Windows that is C:\\Users\\<you>\\.config\\puglogs\\wcl.env.
"""
import base64
import json
import os
import time
import urllib.error
import urllib.request

ENV_FILE = os.path.expanduser("~/.config/puglogs/wcl.env")
TOKEN_URL = "https://www.warcraftlogs.com/oauth/token"
API_URL = "https://www.warcraftlogs.com/api/v2/client"

RATE_LIMIT_QUERY = "{ rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } }"


TEMPLATE = """# PugLogs settings. Keep this file private.
# Warcraft Logs API client, from https://www.warcraftlogs.com/api/clients/
WCL_CLIENT_ID=
WCL_CLIENT_SECRET=
# Optional: your WoW _retail_ folder, if PugLogs can't find it by itself, e.g.
# WOW_DIR=D:\\Games\\World of Warcraft\\_retail_
"""


def read_config():
    """Reads KEY=value lines from the settings file, creating it the first time."""
    if not os.path.exists(ENV_FILE):
        os.makedirs(os.path.dirname(ENV_FILE), exist_ok=True)
        with open(ENV_FILE, "w", encoding="utf-8") as f:
            f.write(TEMPLATE)
        try:
            os.chmod(ENV_FILE, 0o600)
        except OSError:
            pass
    values = {}
    with open(ENV_FILE, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    return values


class WCLError(Exception):
    pass


class MissingCredentials(WCLError):
    """No Warcraft Logs API client has been set up yet."""


def load_credentials():
    values = read_config()
    client_id = values.get("WCL_CLIENT_ID")
    secret = values.get("WCL_CLIENT_SECRET")
    if not client_id or not secret:
        raise MissingCredentials(f"No Warcraft Logs API client in {ENV_FILE}")
    return client_id, secret


def save_credentials(client_id, secret):
    """Writes the API client into the settings file, keeping its other lines."""
    read_config()  # creates the file if needed
    with open(ENV_FILE, encoding="utf-8-sig") as f:
        lines = f.read().splitlines()
    wanted = {"WCL_CLIENT_ID": client_id, "WCL_CLIENT_SECRET": secret}
    for i, line in enumerate(lines):
        key = line.split("=", 1)[0].strip()
        if key in wanted and "=" in line and not line.lstrip().startswith("#"):
            lines[i] = f"{key}={wanted.pop(key)}"
    lines += [f"{k}={v}" for k, v in wanted.items()]
    with open(ENV_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    try:
        os.chmod(ENV_FILE, 0o600)
    except OSError:
        pass


class RateLimited(WCLError):
    """Warcraft Logs refused the request because too many were sent (HTTP 429)."""


class Client:
    def __init__(self, client_id=None, secret=None):
        if client_id and secret:
            self._client_id, self._secret = client_id, secret
        else:
            self._client_id, self._secret = load_credentials()
        self._token = None
        self._token_expires = 0

    def _get_token(self):
        if self._token and time.time() < self._token_expires - 60:
            return self._token
        basic = base64.b64encode(f"{self._client_id}:{self._secret}".encode()).decode()
        req = urllib.request.Request(
            TOKEN_URL,
            data=b"grant_type=client_credentials",
            headers={"Authorization": f"Basic {basic}",
                     "Content-Type": "application/x-www-form-urlencoded"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.load(resp)
        except urllib.error.HTTPError as e:
            raise WCLError(f"Login failed (HTTP {e.code}). Check the client ID and secret.") from None
        self._token = data["access_token"]
        self._token_expires = time.time() + data.get("expires_in", 3600)
        return self._token

    def query(self, query, variables=None, retries=4):
        body = json.dumps({"query": query, "variables": variables or {}}).encode()
        for attempt in range(retries + 1):
            req = urllib.request.Request(
                API_URL, data=body,
                headers={"Authorization": f"Bearer {self._get_token()}",
                         "Content-Type": "application/json"},
            )
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    data = json.load(resp)
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    # Retrying right away only spends more; let the caller wait instead.
                    raise RateLimited("Too many requests - waiting before trying again") from None
                if e.code >= 500:
                    if attempt < retries:
                        time.sleep(2 ** (attempt + 1))
                        continue
                if e.code == 401:
                    self._token = None
                    if attempt < retries:
                        continue
                raise WCLError(f"HTTP {e.code}: {e.read()[:300]!r}") from None
            if data.get("errors"):
                raise WCLError(json.dumps(data["errors"])[:500])
            return data["data"]
        raise WCLError("Gave up after retries")

    def rate_limit(self):
        return self.query(RATE_LIMIT_QUERY)["rateLimitData"]

    def measured(self, query, variables=None):
        """Runs a query and returns (data, points it cost)."""
        before = self.rate_limit()["pointsSpentThisHour"]
        data = self.query(query, variables)
        after = self.rate_limit()["pointsSpentThisHour"]
        return data, after - before
