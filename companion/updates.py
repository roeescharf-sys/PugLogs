"""Checks GitHub for a newer PugLogs release, and installs it in place when possible.

- Windows (installed with PugLogs-Setup.exe): downloads the new installer and runs it silently;
  it closes PugLogs, updates it and starts it again.
- macOS (PugLogs.app): downloads the new disk image, swaps the app and starts it again.
- Anything else (the portable zip, running from source): opens the download page instead.
The addon is updated by the new app on its next start (or by CurseForge/Wago).
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

import installer

LATEST_URL = "https://api.github.com/repos/roeescharf-sys/PugLogs/releases/latest"
DOWNLOAD_PAGE = "https://github.com/roeescharf-sys/PugLogs/releases/latest"
CHECK_EVERY = 6 * 60 * 60
ASSET = {"win32": "PugLogs-Setup.exe", "darwin": "PugLogs-macOS.dmg"}.get(sys.platform)


def current_version():
    return installer.bundled_version()


def latest_release():
    request = urllib.request.Request(LATEST_URL, headers={"Accept": "application/vnd.github+json",
                                                          "User-Agent": "PugLogs"})
    with urllib.request.urlopen(request, timeout=15) as response:
        release = json.load(response)
    assets = {a.get("name"): a.get("browser_download_url") for a in release.get("assets", [])}
    return release.get("tag_name", "").lstrip("v"), assets.get(ASSET)


def latest_version():
    return latest_release()[0]


def start(on_update):
    """Calls on_update(new_version, download_page, installer_url) when a newer release exists."""
    def loop():
        while True:
            try:
                current, (latest, url) = current_version(), latest_release()
                if current and latest and installer.version_tuple(latest) > installer.version_tuple(current):
                    on_update(latest, DOWNLOAD_PAGE, url)
            except Exception:
                pass  # offline or GitHub unavailable: try again later
            time.sleep(CHECK_EVERY)

    threading.Thread(target=loop, daemon=True).start()


# Installing --------------------------------------------------------------------------------

def _mac_app_bundle():
    """The running PugLogs.app, if it can be replaced (not run from the disk image itself)."""
    exe = os.path.realpath(sys.executable)
    marker = ".app/Contents/MacOS/"
    if marker not in exe:
        return None
    bundle = exe.split(marker)[0] + ".app"
    if bundle.startswith("/Volumes/") or not os.access(os.path.dirname(bundle), os.W_OK):
        return None
    return bundle


def _windows_installed():
    """True when this copy was installed with PugLogs-Setup.exe (it has an uninstaller)."""
    folder = os.path.dirname(sys.executable)
    return any(name.lower().startswith("unins") and name.lower().endswith(".exe") for name in os.listdir(folder))


def can_update_in_place():
    if not getattr(sys, "frozen", False):
        return False  # running from source: update with git instead
    if sys.platform == "win32":
        return _windows_installed()
    if sys.platform == "darwin":
        return _mac_app_bundle() is not None
    return False


def _download(url, progress):
    path = os.path.join(tempfile.mkdtemp(prefix="puglogs-update-"), url.rsplit("/", 1)[-1])
    request = urllib.request.Request(url, headers={"User-Agent": "PugLogs"})
    with urllib.request.urlopen(request, timeout=60) as response, open(path, "wb") as f:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = response.read(1 << 16)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            if total:
                progress(f"Downloading... {done * 100 // total}%")
    return path


def install(url, progress, quit_app):
    """Downloads and installs the update, then quits so the new version can start.
    Runs in a background thread; reports with progress(text); raises on failure."""
    path = _download(url, progress)
    progress("Installing...")
    if sys.platform == "win32":
        # The installer closes this app, updates it and starts it again (/UPDATE=1).
        subprocess.Popen([path, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/UPDATE=1"],
                         close_fds=True, creationflags=0x00000008 | 0x00000200)  # detached, new group
    elif sys.platform == "darwin":
        bundle = _mac_app_bundle()
        script = os.path.join(os.path.dirname(path), "update.sh")
        with open(script, "w") as f:
            f.write(f"""#!/bin/bash
# Waits for PugLogs to quit, swaps in the new app and starts it again.
while kill -0 {os.getpid()} 2>/dev/null; do sleep 0.3; done
mount=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$mount" {json.dumps(path)} >/dev/null || exit 1
rm -rf {json.dumps(bundle)}.old
mv {json.dumps(bundle)} {json.dumps(bundle)}.old
if ditto "$mount/PugLogs.app" {json.dumps(bundle)}; then rm -rf {json.dumps(bundle)}.old
else rm -rf {json.dumps(bundle)}; mv {json.dumps(bundle)}.old {json.dumps(bundle)}; fi
hdiutil detach "$mount" -quiet
open {json.dumps(bundle)}
""")
        os.chmod(script, 0o755)
        subprocess.Popen(["/bin/bash", script], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        raise RuntimeError("Updating in place isn't supported here")
    progress("Restarting PugLogs...")
    time.sleep(1)
    quit_app()
