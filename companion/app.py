"""PugLogs companion: reads applicants from the addon's QR screenshots, looks them up on
Warcraft Logs and shows them in the PugLogs window.

Run with ./run.sh or run.bat (they set up everything on first run), or as the packaged
PugLogs app. On first start it installs the addon and shows a setup page for the API key.
"""
import collections
import itertools
import json
import os
import queue
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import export
import inbox
import installer
import lookup
import updates
import wcl
import window

PORT = int(os.environ.get("PUGLOGS_PORT", "47615"))


def find_wow_dir():
    """The WoW _retail_ folder: from PUGLOGS_WOW_DIR or WOW_DIR in the settings file,
    the Battle.net install entry in the Windows registry, or the usual install locations."""
    configured = os.environ.get("PUGLOGS_WOW_DIR") or wcl.read_config().get("WOW_DIR")
    if configured:
        return configured
    candidates = []
    if sys.platform == "win32":
        try:
            import winreg
            for root in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
                for key in (r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                            r"SOFTWARE\Blizzard Entertainment\World of Warcraft"):
                    try:
                        with winreg.OpenKey(root, key) as k:
                            candidates.append(winreg.QueryValueEx(k, "InstallPath")[0])
                    except OSError:
                        pass
        except ImportError:
            pass
        for drive in ("C:", "D:", "E:"):
            for folder in ("Program Files (x86)", "Program Files", "Games", ""):
                candidates.append(os.path.join(drive + "\\", folder, "World of Warcraft", "_retail_"))
    else:
        candidates.append("/Applications/World of Warcraft/_retail_")
    for path in candidates:
        path = path.rstrip("\\/")
        if not path.endswith("_retail_") and os.path.isdir(os.path.join(path, "_retail_")):
            path = os.path.join(path, "_retail_")
        if os.path.isdir(os.path.join(path, "Interface")):
            return path
    sys.exit("Couldn't find your World of Warcraft folder. Add a line like\n"
             "  WOW_DIR=C:\\Program Files (x86)\\World of Warcraft\\_retail_\n"
             f"to {wcl.ENV_FILE} and start PugLogs again.")
# Inside the packaged app, data files live in sys._MEIPASS.
RESOURCE_DIR = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(RESOURCE_DIR, "web")
SEASON_ZONE_ID = 55


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.listing = None          # {"dungeon", "key", "encounterId", "region", "filtered"}
        self.members = []            # applicant members in Group Finder order
        self.results = {}            # "player:encounter" -> {"status", "runs", "error"}
        self.updated_at = None
        self.messages = collections.deque(maxlen=8)
        self.rate = {}
        self.setup_needed = False    # no API key yet: the window shows the setup page
        self.setup_requested = False # /pl wcl in WoW: show the page to change the key
        self.update = None           # {"version", "url"} when a newer PugLogs is released
        self.min_rating = int(window.get_setting("minRating", 0) or 0)  # set in the window
        self._pages = {}             # batch -> {page number: Page}
        self.auto_copy = False       # off: only copy when the paste box in WoW asks
        self.copied_text = None
        self.copied_at = None
        self.waiting = {}            # rkey -> lookup job, retried when the hourly limit resets

    def log(self, text):
        print(text, flush=True)
        with self.lock:
            self.messages.appendleft({"at": time.time(), "text": text})

    def add_page(self, page):
        """Collects the pages of one batch; returns the members once all pages are in."""
        pages = self._pages.setdefault(page.batch, {})
        pages[page.page] = page
        if len(pages) < max(page.pages, 1):
            return None
        self._pages = {}
        members = [m for n in sorted(pages) for m in pages[n].members]
        return page, members

    def snapshot(self):
        with self.lock:
            applications = collections.OrderedDict()
            below = 0
            for m in self.members:
                lst = self.listing or {}
                rkey = result_key(m, lst.get("encounterId"), lst.get("key"))
                result = self.results.get(rkey) or {"status": "pending"}
                if result["status"] == "belowRating":
                    below += 1
                    continue
                applications.setdefault(m.application_id, []).append({
                    "name": m.name, "realm": m.realm_slug, "class": m.class_file, "spec": m.spec,
                    "role": m.role, "itemLevel": m.item_level, "score": m.score, "resultKey": rkey,
                    "profileUrl": lookup.character_url(lst.get("region", "eu"), m.realm_slug, m.name,
                                                       SEASON_ZONE_ID, lst.get("encounterId")),
                    **result,
                })
            return {
                "listing": self.listing,
                "updatedAt": self.updated_at,
                "applications": [{"id": k, "members": v} for k, v in applications.items()],
                "rate": _lookup.estimated_rate() if _lookup else self.rate,
                "minRating": self.min_rating,
                "belowRating": below,
                "messages": list(self.messages),
                "setupNeeded": self.setup_needed,
                "setupRequested": self.setup_requested,
                "version": updates.current_version(),
                "update": self.update,
                "inWindow": window.available() and not HEADLESS,
                "onTop": window.is_on_top(),
                "settingsFile": wcl.ENV_FILE,
                "autoCopy": self.auto_copy,
                "copiedAt": self.copied_at,
            }


def result_key(member, encounter_id, key_level):
    # The featured run depends on your key level, so it is part of the key.
    return f"{member.key}:{encounter_id}:{key_level}"


state = State()
# (priority, order, job), processed in order.
work = queue.PriorityQueue()
_order = itertools.count()


def queue_job(priority, job):
    work.put((priority, next(_order), job))


def on_page(page):
    if "S" in page.flags:
        # /pl wcl in WoW: show the API key page.
        with state.lock:
            state.setup_requested = True
        window.bring_to_front()
        state.log("Showing the Warcraft Logs API key page")
        return
    if "R" in page.flags:
        # The paste box in WoW was opened: copy the results we already have, right away.
        if copy_for_wow(force=True, restore=True):
            state.log("Results copied for WoW - press Cmd+V in the paste box")
        else:
            state.log("Paste box opened, but there are no results to copy yet")
        return
    done = state.add_page(page)
    if not done:
        return
    page, members = done
    with state.lock:
        state.listing = {"dungeon": page.dungeon, "key": page.key_level,
                         "encounterId": page.encounter_id, "region": page.region,
                         "filtered": page.filtered}
        state.members = members
        state.updated_at = time.time()
        new = [m for m in members if result_key(m, page.encounter_id, page.key_level) not in state.results]
    state.log(f"{len(members)} applicant(s) for {page.dungeon or 'no listing'}"
              + (f" +{page.key_level}" if page.key_level else "")
              + (f" ({page.filtered} filtered out)" if page.filtered else ""))
    for m in new:
        rkey = result_key(m, page.encounter_id, page.key_level)
        with state.lock:
            if state.min_rating and m.score < state.min_rating:
                state.results[rkey] = {"status": "belowRating"}  # hidden, never looked up
                continue
            state.results[rkey] = {"status": "pending"}
        queue_job(1, ("lookup", rkey, m, page.region, page.encounter_id, page.key_level))
    if not new and work.empty():
        copy_for_wow()


def copy_for_wow(force=False, restore=False):
    """Puts the paste text for WoW on the clipboard when results changed (or when forced).
    With restore, your previous clipboard text is put back a little later."""
    with state.lock:
        if not (state.auto_copy or force):
            return False
        text = export.build(state.listing, state.members, state.results, result_key)
        if not text or (text == state.copied_text and not force):
            return False
    try:
        (export.copy_then_restore if restore else export.copy)(text)
    except Exception as e:
        state.log(f"Could not copy to clipboard: {e}")
        return False
    with state.lock:
        state.copied_text, state.copied_at = text, time.time()
    return True


def set_min_rating(value):
    """From the window: hide (and don't look up) applicants below this M+ rating."""
    value = max(0, int(value))
    window.set_setting("minRating", value)
    jobs = []
    with state.lock:
        state.min_rating = value
        lst = state.listing or {}
        for m in state.members:
            rkey = result_key(m, lst.get("encounterId"), lst.get("key"))
            status = (state.results.get(rkey) or {}).get("status")
            if value and m.score < value and status in (None, "pending", "waiting"):
                state.results[rkey] = {"status": "belowRating"}
                state.waiting.pop(rkey, None)
            elif status == "belowRating" and not (value and m.score < value):
                state.results[rkey] = {"status": "pending"}
                jobs.append(("lookup", rkey, m, lst.get("region"), lst.get("encounterId"), lst.get("key")))
    for job in jobs:
        queue_job(1, job)
    return value


def describe_error(e):
    if isinstance(e, lookup.BudgetError):
        return "Hourly API limit nearly used up - try again later"
    if isinstance(e, wcl.WCLError):
        return str(e)[:200]
    return f"{type(e).__name__}: {e}"[:200]






def do_lookup(lk, rkey, member, region, encounter_id, key_level):
    with state.lock:
        if (state.results.get(rkey) or {}).get("status") == "belowRating":
            return  # filtered out while it was waiting in the queue
        state.results[rkey] = {"status": "loading"}
    try:
        found = lk.look_up(member, region, encounter_id, key_level)
        result = {"status": "nodata"} if not found else {"status": "done", "playerName": member.name, **found}
    except (lookup.BudgetError, wcl.RateLimited) as e:
        # Out of API points (or briefly refused): wait, then look them up automatically.
        wait = 60 if isinstance(e, wcl.RateLimited) else (lk.estimated_rate().get("pointsResetIn") or 300) + 5
        retry_at = time.time() + wait
        result = {"status": "waiting", "retryAt": retry_at}
        with state.lock:
            state.waiting[rkey] = (retry_at, ("lookup", rkey, member, region, encounter_id, key_level))
    except Exception as e:
        result = {"status": "error", "error": describe_error(e)}
    with state.lock:
        state.results[rkey] = result


def retry_waiting():
    """Re-queues lookups that were paused by the hourly API limit once it has reset."""
    while True:
        time.sleep(5)
        now = time.time()
        with state.lock:
            due = [(k, job) for k, (at, job) in state.waiting.items() if at <= now]
            current = {result_key(m, (state.listing or {}).get("encounterId"), (state.listing or {}).get("key"))
                       for m in state.members}
            for k, _ in due:
                del state.waiting[k]
                if k in current:
                    state.results[k] = {"status": "pending"}
        for k, job in due:
            if k in current:  # skip applicants who are gone
                queue_job(1, job)




def worker(lk):
    while True:
        _, _, job = work.get()
        kind, args = job[0], job[1:]
        if kind == "lookup":
            if not args[3]:  # no dungeon (listing ended)
                continue
            do_lookup(lk, *args)
        # Copy once the queue is empty, so the clipboard isn't rewritten for every player.
        if work.empty():
            copy_for_wow()
        try:
            state.rate = lk.refresh_rate()
            lk.cache.save()
        except Exception as e:
            state.log(f"Could not save cache: {e}")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if self.path == "/api/copy":
                reply = {"copied": copy_for_wow(force=True)}
            elif self.path == "/api/setup":
                ok, error = set_up_api_client(str(body.get("clientId", "")).strip(),
                                              str(body.get("secret", "")).strip())
                reply = {"ok": ok, "error": error}
            elif self.path == "/api/setup/close":
                with state.lock:
                    state.setup_requested = False
                reply = {"ok": True}
            elif self.path == "/api/minrating":
                reply = {"minRating": set_min_rating(body.get("value") or 0)}
            elif self.path == "/api/ontop":
                window.set_on_top(bool(body["on"]))
                reply = {"onTop": window.is_on_top()}
            elif self.path == "/api/autocopy":
                with state.lock:
                    state.auto_copy = bool(body["on"])
                if state.auto_copy:
                    copy_for_wow(force=True)
                reply = {"autoCopy": state.auto_copy}
            else:
                self.send_error(404)
                return
        except (ValueError, KeyError):
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(reply).encode())

    def do_GET(self):
        if self.path == "/api/state":
            body = json.dumps(state.snapshot()).encode()
            ctype = "application/json"
        elif self.path in ("/", "/index.html"):
            with open(os.path.join(WEB_DIR, "index.html"), "rb") as f:
                body = f.read()
            ctype = "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


_services_started = False
_screenshots = None
_lookup = None


def start_services():
    """Logs in to Warcraft Logs and starts looking applicants up. Raises MissingCredentials
    if no API client is set up yet."""
    global _services_started, _lookup
    if _services_started:
        return
    lk = _lookup = lookup.Lookup(log=state.log)
    state.rate = lk.refresh_rate()
    _services_started = True
    with state.lock:
        state.setup_needed = False
    threading.Thread(target=worker, args=(lk,), daemon=True).start()
    threading.Thread(target=retry_waiting, daemon=True).start()
    inbox.Inbox(_screenshots, on_page, state.log).start()
    state.log(f"Watching {_screenshots}")


def on_update_available(version, url):
    with state.lock:
        state.update = {"version": version, "url": url}
    state.log(f"PugLogs {version} is available")


def set_up_api_client(client_id, secret):
    """From the setup page: checks the API client works, saves it and starts PugLogs."""
    if not client_id or not secret:
        return False, "Fill in both the Client ID and the Client Secret."
    try:
        wcl.Client(client_id, secret).rate_limit()
    except wcl.WCLError as e:
        return False, f"Warcraft Logs didn't accept these: {e}"
    except OSError as e:
        return False, f"Couldn't reach Warcraft Logs: {e}"
    wcl.save_credentials(client_id, secret)
    try:
        if _services_started:
            _lookup.client = wcl.Client(client_id, secret)  # a changed key, used from now on
            state.rate = _lookup.refresh_rate(force=True)
        else:
            start_services()
    except wcl.WCLError as e:
        return False, str(e)
    with state.lock:
        state.setup_requested = False
    state.log("API client saved - PugLogs is ready")
    return True, None


HEADLESS = "--no-window" in sys.argv or "--no-browser" in sys.argv  # server only (tests)
LOG_FILE = os.path.expanduser("~/.config/puglogs/puglogs.log")


def main():
    global _screenshots
    wow_dir = find_wow_dir()
    _screenshots = os.path.join(wow_dir, "Screenshots")
    installer.install(wow_dir, log=state.log)
    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError:
        sys.exit("PugLogs is already running - look for its window.\n\n"
                 f"(If it isn't, another program is using port {PORT}; "
                 "set PUGLOGS_PORT to another number.)")
    try:
        start_services()
    except wcl.MissingCredentials:
        with state.lock:
            state.setup_needed = True
        state.log("Set up your Warcraft Logs API client in the PugLogs window")
    except wcl.WCLError as e:
        with state.lock:
            state.setup_needed = True
        state.log(f"Warcraft Logs login failed ({e}) - check your API client in the PugLogs window")
    url = f"http://127.0.0.1:{PORT}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    updates.start(on_update_available)
    print("PugLogs is running. Close its window to stop it.", flush=True)
    if not HEADLESS and window.show(url, log=state.log):
        return  # the window was closed: quit
    if not HEADLESS:
        state.log("PugLogs is running in your web browser. To stop it, close this program "
                  "(Windows: Task Manager > PugLogs).")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


def run():
    if getattr(sys, "frozen", False):
        # The packaged app has no console: keep a log file for troubleshooting.
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        try:
            log = open(LOG_FILE, "w", encoding="utf-8", buffering=1)
        except OSError:  # Windows: another PugLogs may hold the file open
            log = open(LOG_FILE + f".{os.getpid()}", "w", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr = log
    if "--selftest" in sys.argv:
        print("window engine OK:", window.self_test(), flush=True)
        return
    try:
        main()
    except SystemExit as e:
        if isinstance(e.code, str) and not HEADLESS and window.show_error(e.code):
            sys.exit(1)
        raise


if __name__ == "__main__":
    run()
