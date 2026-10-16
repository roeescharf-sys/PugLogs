"""The PugLogs app window: the live page shown in a native window (no browser, no address bar).

Uses pywebview, which draws with the system's own web engine (Edge WebView2 on Windows,
WebKit on macOS). Falls back to the default browser if pywebview isn't available.
"""
import json
import os
import sys
import threading
import webbrowser

try:
    import webview
except ImportError:  # running from source without pywebview
    webview = None

SETTINGS_FILE = os.path.expanduser("~/.config/puglogs/settings.json")
_window = None


def _load():
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save(settings):
    os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(settings, f)


def self_test():
    """Loads this system's window engine without opening a window (for automated build checks)."""
    import importlib
    backend = {"win32": "webview.platforms.edgechromium", "darwin": "webview.platforms.cocoa"}.get(sys.platform)
    if webview is None:
        raise RuntimeError("pywebview is missing")
    if backend:
        importlib.import_module(backend)
    return backend


def available():
    return webview is not None


def is_on_top():
    return bool(_load().get("onTop"))


def set_on_top(on):
    settings = _load()
    settings["onTop"] = bool(on)
    _save(settings)
    if _window is not None:
        _window.on_top = bool(on)


# Windows: only the modern Edge WebView2 engine. pywebview would otherwise fall back to the
# old Internet Explorer engine, which can't run the PugLogs page (an empty window).
_GUI = "edgechromium" if sys.platform == "win32" else None


def show(url, log=print):
    """Opens the PugLogs window and returns True when the user closes it. If the window
    can't be shown, opens the page in the default web browser instead and returns False."""
    global _window
    if webview is None:
        webbrowser.open(url)
        return False
    shown = threading.Event()
    try:
        _window = webview.create_window(
            "PugLogs", url, width=980, height=760, min_size=(420, 320),
            on_top=is_on_top(), background_color="#111317", text_select=True,
        )
        _window.events.shown += shown.set
        webview.start(gui=_GUI)
    except Exception as e:
        log(f"The PugLogs window couldn't open ({type(e).__name__}: {e}) - "
            "opening it in your web browser instead.")
        _window = None
        webbrowser.open(url)
        return False
    if not shown.is_set():
        log("The PugLogs window never appeared - opening it in your web browser instead.")
        _window = None
        webbrowser.open(url)
        return False
    return True


def _native_message(title, message):
    """A plain system dialog, which works even when the window engine doesn't."""
    try:
        if sys.platform == "win32":
            import ctypes
            ctypes.windll.user32.MessageBoxW(None, message, title, 0x10)
            return True
        if sys.platform == "darwin":
            import subprocess
            script = 'display dialog (item 1 of argv) with title (item 2 of argv) buttons {"OK"} with icon stop'
            subprocess.run(["osascript", "-e", f"on run argv\n{script}\nend run", message, title], check=False)
            return True
    except Exception:
        pass
    return False


def show_error(message):
    """Shows a fatal startup problem (the packaged app has no console)."""
    return _native_message("PugLogs can't start", message)
