"""Installs or updates the PugLogs addon in WoW's AddOns folder."""
import os
import re
import shutil
import sys

ADDON = "PugLogs"


def bundled_addon_dir():
    """The addon shipped with this companion: inside the packaged app, or next to this folder."""
    base = getattr(sys, "_MEIPASS", None)
    if base:
        return os.path.join(base, ADDON)
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ADDON)


def _version(addon_dir):
    try:
        with open(os.path.join(addon_dir, ADDON + ".toc"), encoding="utf-8-sig") as f:
            match = re.search(r"^## Version:\s*(\S+)", f.read(), re.M)
        return match.group(1) if match else None
    except OSError:
        return None


def version_tuple(version):
    """'0.10.2' -> (0, 10, 2); anything unreadable sorts lowest."""
    try:
        return tuple(int(part) for part in str(version).lstrip("v").split("."))
    except ValueError:
        return ()


def bundled_version():
    return _version(bundled_addon_dir())


MARKER = "PugLogs_App"


def install_marker(wow_dir):
    """A tiny extra addon that tells the PugLogs addon the app is installed, so live lookups
    (QR screenshots) are on by default only for people who have the app."""
    try:
        with open(os.path.join(bundled_addon_dir(), ADDON + ".toc"), encoding="utf-8-sig") as f:
            interface = re.search(r"^## Interface:\s*(\S+)", f.read(), re.M).group(1)
    except (OSError, AttributeError):
        return
    folder = os.path.join(wow_dir, "Interface", "AddOns", MARKER)
    toc = (f"## Interface: {interface}\n"
           "## Title: PugLogs (app)\n"
           "## Notes: Added by the PugLogs app so the PugLogs addon knows the app is installed.\n"
           f"## Version: {bundled_version()}\n"
           "\nApp.lua\n")
    lua = "-- Added by the PugLogs app. Delete this folder if you uninstall the app.\nPugLogsAppInstalled = true\n"
    try:
        os.makedirs(folder, exist_ok=True)
        for name, text in ((MARKER + ".toc", toc), ("App.lua", lua)):
            path = os.path.join(folder, name)
            try:
                with open(path, encoding="utf-8") as f:
                    if f.read() == text:
                        continue
            except OSError:
                pass
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
    except OSError:
        pass


def install(wow_dir, log=print):
    """Copies the bundled addon into AddOns if it is missing or older than the bundled one.
    A newer addon (e.g. updated by CurseForge) and a symlinked addon folder (a developer
    setup) are left alone."""
    install_marker(wow_dir)
    source = bundled_addon_dir()
    new = _version(source)
    if not new:
        return  # running without a bundled addon
    target = os.path.join(wow_dir, "Interface", "AddOns", ADDON)
    if os.path.islink(target):
        return
    old = _version(target)
    if old and version_tuple(old) >= version_tuple(new):
        return
    try:
        if os.path.isdir(target):
            shutil.rmtree(target)
        shutil.copytree(source, target)
    except OSError as e:
        log(f"Could not install the PugLogs addon into {target}: {e}")
        return
    verb = "Updated" if old else "Installed"
    log(f"{verb} the PugLogs addon (version {new}). In WoW, type /reload (or restart the game).")
