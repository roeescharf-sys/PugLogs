"""Error reports: keeps recent errors with their details, and builds a text report (errors plus
the end of the log) that players can paste into a bug report. Personal details are removed."""
import collections
import json
import os
import platform
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request

import clipboard

CONFIG_DIR = os.path.expanduser("~/.config/puglogs")
LOG_FILE = os.path.join(CONFIG_DIR, "puglogs.log")
PREVIOUS_LOG = os.path.join(CONFIG_DIR, "puglogs.previous.log")
REPORT_FILE = os.path.join(CONFIG_DIR, "error-report.txt")
GITHUB_NEW_ISSUE = "https://github.com/roeescharf-sys/PugLogs/issues/new"
# The developer's report relay (relay/worker.js). Empty = no "Send to developer" button.
RELAY_URL = os.environ.get("PUGLOGS_REPORT_URL", "https://puglogs-reports.puglogs-reports.workers.dev/report")

_errors = collections.deque(maxlen=20)
_lock = threading.Lock()
on_new_error = None      # set by the app: called with each new error (for automatic reports)


def record(where, exc=None):
    """Saves an error with what PugLogs was doing. Call from an except block, or pass the error."""
    details = "".join(traceback.format_exception(exc)) if exc is not None else traceback.format_exc()
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{stamp} ERROR while {where}\n{details}", flush=True)
    error = {"at": stamp, "where": where, "details": details, "signature": _signature(details), "sent": None}
    with _lock:
        _errors.append(error)
    if on_new_error:
        on_new_error(error)


def _signature(details):
    """Identifies "the same error": its type and message plus the line it happened on."""
    lines = details.strip().splitlines()
    places = [l.strip() for l in lines if l.strip().startswith("File ")]
    return f"{lines[-1] if lines else ''} @ {places[-1] if places else ''}"


def last_error():
    with _lock:
        return dict(_errors[-1]) if _errors else None


def mark_sent(error, status):
    """status: "sent", "failed: <why>" or "skipped". Applies to every error with the same signature."""
    with _lock:
        for e in _errors:
            if e["signature"] == error["signature"]:
                e["sent"] = status


def already_sent(error):
    with _lock:
        return any(e["sent"] == "sent" for e in _errors if e["signature"] == error["signature"])


def message(error):
    """The error's last line, e.g. "TypeError: ...", with personal details removed."""
    lines = error["details"].strip().splitlines()
    return _redact(lines[-1] if lines else "unknown error")[:300]


def error_count():
    with _lock:
        return len(_errors)


def summary():
    """One line about this session's errors, e.g. '2 errors, last: TypeError: ...'."""
    with _lock:
        errors = list(_errors)
    if not errors:
        return "no errors recorded"
    last = errors[-1]["details"].strip().splitlines()[-1]
    return _redact(f"{len(errors)} error{'s' if len(errors) > 1 else ''}, last: {last}")[:300]


def system():
    return f"{platform.system()} {platform.release()} ({platform.machine()})"


def install_hooks():
    """Records crashes that nothing else caught, in the main program and in background threads."""
    sys.excepthook = lambda kind, exc, tb: record("running PugLogs", exc)
    threading.excepthook = lambda args: record(f"running {args.thread.name if args.thread else 'a task'}",
                                               args.exc_value)


def rotate_log():
    """Keeps the last session's log, so restarting PugLogs before reporting doesn't lose it."""
    try:
        if os.path.exists(LOG_FILE):
            os.replace(LOG_FILE, PREVIOUS_LOG)
    except OSError:
        pass  # Windows: another PugLogs still has it open


def _tail(path, lines):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.readlines()[-lines:]
    except OSError:
        return []


def _redact(text):
    """Removes the user's home folder (it contains their name) and their API client."""
    home = os.path.expanduser("~")
    for variant in {home, home.replace("\\", "/")}:
        text = text.replace(variant, "~")
    try:
        import wcl
        for secret in wcl.load_credentials():
            if secret and len(secret) > 6:
                text = text.replace(secret, "<hidden>")
    except BaseException:  # no API client saved yet
        pass
    return text


def build(version, context_lines, messages):
    """The full report text."""
    out = [
        "PugLogs error report",
        f"Version: {version}",
        f"System: {system()} - {platform.platform()} ({'app' if getattr(sys, 'frozen', False) else 'source'}, "
        f"Python {platform.python_version()})",
        f"Created: {time.strftime('%Y-%m-%d %H:%M:%S %z')}",
        *context_lines,
        "",
    ]
    with _lock:
        errors = list(_errors)
    out.append(f"== Errors this session ({len(errors)}) ==")
    for e in errors or []:
        out += [f"[{e['at']}] while {e['where']}", e["details"].rstrip(), ""]
    if not errors:
        out += ["(none)", ""]
    out.append("== Recent messages ==")
    out += messages or ["(none)"]
    for title, path, lines in (("This session's log", LOG_FILE, 200), ("Previous session's log", PREVIOUS_LOG, 80)):
        tail = _tail(path, lines)
        if tail:
            out += ["", f"== {title} (last {len(tail)} lines) ==", "".join(tail).rstrip()]
    return _redact("\n".join(out)) + "\n"


def build_single(version, context_lines, error):
    """A short report about one error, for automatic sending: no log and no other messages."""
    out = [
        "PugLogs error report (automatic, one error)",
        f"Version: {version}",
        f"System: {system()} - {platform.platform()} ({'app' if getattr(sys, 'frozen', False) else 'source'}, "
        f"Python {platform.python_version()})",
        *context_lines,
        "",
        f"[{error['at']}] while {error['where']}",
        error["details"].rstrip(),
    ]
    return _redact("\n".join(out)) + "\n"


def save_and_copy(text):
    """Saves the report next to the log and puts it on the clipboard. Returns (copied, path)."""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(REPORT_FILE, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        clipboard.copy(text)
        copied = True
    except Exception:
        copied = False
    return copied, _redact(REPORT_FILE)


def github_issue_url(version):
    """A new GitHub issue with the basics filled in. The report itself is too long for a link,
    so it goes on the clipboard and the issue asks for it to be pasted."""
    title = f"Bug: {summary()}"[:120] if error_count() else "Bug report"
    body = "\n".join([
        f"**PugLogs version:** {version}",
        f"**System:** {system()}",
        "",
        "**What happened?**",
        "",
        "",
        "**Error report**",
        "PugLogs copied the error report to your clipboard. Paste it between the lines below:",
        "",
        "```",
        "",
        "```",
    ])
    return f"{GITHUB_NEW_ISSUE}?{urllib.parse.urlencode({'title': title, 'body': body})}"


def send(text, version, note="", contact=""):
    """Sends the report to the developer's relay. Returns (ok, message)."""
    if not RELAY_URL:
        return False, "Sending reports isn't set up in this version."
    data = json.dumps({"version": version, "system": system(), "summary": summary(),
                       "note": note[:1000], "contact": contact[:100], "report": text}).encode()
    request = urllib.request.Request(RELAY_URL, data=data, headers={
        "Content-Type": "application/json", "User-Agent": f"PugLogs/{version}"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return True, json.load(response).get("message") or "Report sent - thank you!"
    except urllib.error.HTTPError as e:
        try:
            message = json.load(e).get("message")
        except ValueError:
            message = None
        return False, message or f"The report service answered {e.code}."
    except (urllib.error.URLError, OSError) as e:
        return False, f"Couldn't reach the report service ({getattr(e, 'reason', e)})."
