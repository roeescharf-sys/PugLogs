"""The PugLogs app window: the live page shown in a native window (no browser, no address bar).

Uses pywebview, which draws with the system's own web engine (Edge WebView2 on Windows,
WebKit on macOS). Falls back to the default browser if pywebview isn't available.
"""
import html
import json
import os
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
    import sys
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


def show(url):
    """Opens the PugLogs window and returns when the user closes it."""
    global _window
    if webview is None:
        webbrowser.open(url)
        return False
    _window = webview.create_window(
        "PugLogs", url, width=980, height=760, min_size=(420, 320),
        on_top=is_on_top(), background_color="#111317", text_select=True,
    )
    webview.start()
    return True


def show_error(message):
    """Shows a fatal startup problem in a small window (the packaged app has no console)."""
    if webview is None:
        return False
    page = f"""<!doctype html><html><body style="background:#111317;color:#e6e6e6;
        font:14px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:20px">
        <h2 style="color:#e0624f;margin-top:0">PugLogs can't start</h2>
        <p style="white-space:pre-wrap;line-height:1.5">{html.escape(message)}</p></body></html>"""
    webview.create_window("PugLogs", html=page, width=560, height=260)
    webview.start()
    return True
