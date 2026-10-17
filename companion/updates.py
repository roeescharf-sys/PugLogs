"""Checks GitHub for a newer PugLogs release (once at start, then every few hours)."""
import json
import threading
import time
import urllib.request

import installer

LATEST_URL = "https://api.github.com/repos/roeescharf-sys/PugLogs/releases/latest"
DOWNLOAD_PAGE = "https://github.com/roeescharf-sys/PugLogs/releases/latest"
CHECK_EVERY = 6 * 60 * 60


def current_version():
    return installer.bundled_version()


def latest_version():
    request = urllib.request.Request(LATEST_URL, headers={"Accept": "application/vnd.github+json",
                                                          "User-Agent": "PugLogs"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response).get("tag_name", "").lstrip("v")


def start(on_update):
    """Calls on_update(new_version, download_page) when a newer release exists."""
    def loop():
        while True:
            try:
                current, latest = current_version(), latest_version()
                if current and latest and installer.version_tuple(latest) > installer.version_tuple(current):
                    on_update(latest, DOWNLOAD_PAGE)
            except Exception:
                pass  # offline or GitHub unavailable: try again later
            time.sleep(CHECK_EVERY)

    threading.Thread(target=loop, daemon=True).start()
