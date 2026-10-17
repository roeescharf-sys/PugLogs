"""Finds the World of Warcraft _retail_ folder on Windows and macOS."""
import os
import re
import string
import sys


def normalize(path):
    """Turns a WoW install folder (or its _retail_ folder) into the _retail_ folder, or None."""
    if not path:
        return None
    path = os.path.expandvars(os.path.expanduser(str(path).strip().strip('"'))).rstrip("\\/")
    # A real retail install has the game itself (or, on macOS, the app) in it. The Interface
    # folder only exists once an addon has been installed, so it can't be required.
    markers = ("Wow.exe", "WowT.exe", "WowB.exe", "World of Warcraft.app", "WTF", "Interface", "Data")
    candidates = [path] if os.path.basename(path).lower() == "_retail_" else [os.path.join(path, "_retail_"), path]
    for candidate in candidates:
        if os.path.isdir(candidate) and any(os.path.exists(os.path.join(candidate, m)) for m in markers):
            return candidate
    return None


def _registry_paths():
    paths = []
    try:
        import winreg
    except ImportError:
        return paths
    keys = (r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
            r"SOFTWARE\Blizzard Entertainment\World of Warcraft",
            r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft",
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft")
    for root in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
        for key in keys:
            for value in ("InstallPath", "InstallLocation"):
                try:
                    with winreg.OpenKey(root, key) as k:
                        paths.append(winreg.QueryValueEx(k, value)[0])
                except OSError:
                    pass
    return paths


def _battlenet_paths():
    """Battle.net's own list of installed games (a binary file, but the paths are readable)."""
    found = []
    db = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "Battle.net", "Agent", "product.db")
    try:
        with open(db, "rb") as f:
            data = f.read().decode("utf-8", "ignore")
    except OSError:
        return found
    for match in re.finditer(r"[A-Za-z]:[\\/][^\x00-\x1f\"*?<>|]{0,200}?World of Warcraft", data):
        found.append(match.group(0))
    return found


def _common_paths():
    if sys.platform != "win32":
        return [os.path.expanduser("~/Applications/World of Warcraft"), "/Applications/World of Warcraft",
                "/Applications/Games/World of Warcraft"]
    drives = [d + ":\\" for d in string.ascii_uppercase if os.path.exists(d + ":\\")]
    folders = ("Program Files (x86)", "Program Files", "Games", "Program Files (x86)\\Battle.net",
               "Battle.net", "Blizzard", "Blizzard Games", "Games\\Battle.net", "")
    return [os.path.join(d, f, "World of Warcraft") for d in drives for f in folders]


def find(configured=None):
    """The _retail_ folder, or None if it can't be found."""
    candidates = [configured] + _registry_paths() + _battlenet_paths() + _common_paths()
    for path in candidates:
        retail = normalize(path)
        if retail:
            return retail
    return None
