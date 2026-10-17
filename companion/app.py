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
import payload
import updates
import wcl
import window
import wowdir

PORT = int(os.environ.get("PUGLOGS_PORT", "47615"))


def find_wow_dir():
    """The WoW _retail_ folder (PUGLOGS_WOW_DIR, WOW_DIR in the settings file, or found on
    this computer), or None - then the window asks the user to choose it."""
    configured = os.environ.get("PUGLOGS_WOW_DIR") or wcl.read_config().get("WOW_DIR")
    return wowdir.find(configured)


# Inside the packaged app, data files live in sys._MEIPASS.
RESOURCE_DIR = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(RESOURCE_DIR, "web")
SEASON_ZONE_ID = 55


def load_filters(values=None):
    """The window's filters with defaults filled in (from the saved settings by default)."""
    values = values if values is not None else (window.get_setting("filters") or {})
    old_min = window.get_setting("minRating", 0) or 0  # from before there were more filters
    def ints(key, default=0):
        try:
            return max(0, int(values.get(key, default) or 0))
        except (TypeError, ValueError):
            return default
    def names(key):
        return sorted({str(v) for v in values.get(key) or []})
    return {"minItemLevel": ints("minItemLevel"), "minRating": ints("minRating", old_min),
            "excludedRoles": names("excludedRoles"), "excludedClasses": names("excludedClasses"),
            "excludedSpecs": names("excludedSpecs")}  # specs as "CLASS:position", e.g. "MAGE:3"


def filter_reason(member, f):
    """Why the window's filters hide this applicant, or None."""
    if f["minItemLevel"] and member.item_level < f["minItemLevel"]:
        return "item level"
    if f["minRating"] and member.score < f["minRating"]:
        return "rating"
    if member.role and member.role in f["excludedRoles"]:
        return "role"
    if member.class_file in f["excludedClasses"]:
        return "class"
    if member.spec_index and f"{member.class_file}:{member.spec_index}" in f["excludedSpecs"]:
        return "spec"
    return None


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
        self.wow_missing = False     # WoW folder not found: the window asks for it
        self.update = None           # {"version", "url"} when a newer PugLogs is released
        self.filters = load_filters()  # the window's own filters (see filter_reason)
        self.sort_by = window.get_setting("sortBy", "applied")  # window list order
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
                if filter_reason(m, self.filters):
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
                "filters": self.filters,
                "specs": [{"class": c, "name": payload.CLASS_NAMES[c], "specs": names}
                          for c, names in payload.SPECS.items()],
                "sortBy": self.sort_by,
                "belowRating": below,
                "messages": list(self.messages),
                "setupNeeded": self.setup_needed,
                "wowMissing": self.wow_missing,
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
    if "R" in page.flags and not page.encounter_id:
        # The paste box in WoW was opened (older addon, or no listing): copy what we have.
        copy_for_paste_box()
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
            if filter_reason(m, state.filters):
                state.results[rkey] = {"status": "skipped"}  # hidden, never looked up
                continue
            state.results[rkey] = {"status": "pending"}
        queue_job(1, ("lookup", rkey, m, page.region, page.encounter_id, page.key_level))
    if "R" in page.flags:
        # The paste box was opened with the current applicant list: give anyone who just
        # applied a few seconds to be looked up, then copy.
        threading.Thread(target=copy_for_paste_box, args=(PASTE_WAIT,), daemon=True).start()
    elif not new and work.empty():
        copy_for_wow()


PASTE_WAIT = 4  # seconds the paste box waits for new applicants' lookups


def lookups_in_progress():
    with state.lock:
        lst = state.listing or {}
        return sum(1 for m in state.members
                   if (state.results.get(result_key(m, lst.get("encounterId"), lst.get("key"))) or {})
                   .get("status") in ("pending", "loading"))


def copy_for_paste_box(wait=0):
    deadline = time.time() + wait
    while time.time() < deadline and lookups_in_progress():
        time.sleep(0.1)
    if copy_for_wow(force=True, restore=True):
        state.log("Results copied for WoW - press Cmd+V in the paste box")
    else:
        state.log("Paste box opened, but there are no results to copy yet")


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


def set_filters(new):
    """From the window: hide (and don't look up) applicants who don't match."""
    filters = load_filters(new)
    window.set_setting("filters", filters)
    jobs = []
    with state.lock:
        state.filters = filters
        lst = state.listing or {}
        for m in state.members:
            rkey = result_key(m, lst.get("encounterId"), lst.get("key"))
            status = (state.results.get(rkey) or {}).get("status")
            hidden = filter_reason(m, filters)
            if hidden and status in (None, "pending", "waiting"):
                state.results[rkey] = {"status": "skipped"}
                state.waiting.pop(rkey, None)
            elif status == "skipped" and not hidden:
                state.results[rkey] = {"status": "pending"}
                jobs.append(("lookup", rkey, m, lst.get("region"), lst.get("encounterId"), lst.get("key")))
    for job in jobs:
        queue_job(1, job)
    return filters


def describe_error(e):
    if isinstance(e, lookup.BudgetError):
        return "Hourly API limit nearly used up - try again later"
    if isinstance(e, wcl.WCLError):
        return str(e)[:200]
    return f"{type(e).__name__}: {e}"[:200]






def do_lookup(lk, rkey, member, region, encounter_id, key_level):
    with state.lock:
        if (state.results.get(rkey) or {}).get("status") == "skipped":
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
            elif self.path == "/api/wowdir":
                reply = choose_wow_dir(body.get("path"))
            elif self.path == "/api/update":
                reply = {"started": start_update()}
            elif self.path == "/api/sort":
                value = body.get("value") if body.get("value") in ("applied", "role", "rating", "log") else "applied"
                window.set_setting("sortBy", value)
                with state.lock:
                    state.sort_by = value
                reply = {"sortBy": value}
            elif self.path == "/api/filters":
                reply = {"filters": set_filters(body)}
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


def on_update_available(version, url, installer_url=None):
    with state.lock:
        state.update = {"version": version, "url": url, "status": None,
                        "canUpdate": bool(installer_url) and updates.can_update_in_place()}
        state.update_installer = installer_url
    state.log(f"PugLogs {version} is available")


def start_update():
    """From the window's "Update now" button: download and install, then restart."""
    with state.lock:
        update, url = state.update, getattr(state, "update_installer", None)
        if not update or not update.get("canUpdate") or not url or update.get("status"):
            return False
        update["status"] = "Starting..."

    def progress(text):
        with state.lock:
            state.update["status"] = text

    def run():
        try:
            updates.install(url, progress, quit_app=lambda: os._exit(0))
        except Exception as e:
            with state.lock:
                state.update["status"] = None
                state.update["error"] = f"Update failed ({e}). Download it from the page instead."
            state.log(f"Update failed: {e}")

    threading.Thread(target=run, daemon=True).start()
    return True


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
    if _screenshots is None:
        return True, None  # saved; PugLogs starts once the WoW folder is chosen
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


def use_wow_dir(wow_dir):
    """Everything that needs the WoW folder: install the addon, then start PugLogs or the
    API key setup."""
    global _screenshots
    _screenshots = os.path.join(wow_dir, "Screenshots")
    with state.lock:
        state.wow_missing = False
    installer.install(wow_dir, log=state.log)
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


def choose_wow_dir(typed_path=None):
    """From the window: the user picks (or types) their WoW folder."""
    path = typed_path or window.choose_folder()
    if not path:
        return {"ok": False, "error": None}  # cancelled
    retail = wowdir.normalize(path)
    if not retail:
        return {"ok": False, "error": f"That doesn't look like a World of Warcraft folder: {path}. "
                                      "Choose the folder that contains _retail_."}
    wcl.save_values({"WOW_DIR": retail})
    state.log(f"Using the World of Warcraft folder {retail}")
    use_wow_dir(retail)
    return {"ok": True, "path": retail}


def main():
    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError:
        sys.exit("PugLogs is already running - look for its window.\n\n"
                 f"(If it isn't, another program is using port {PORT}; "
                 "set PUGLOGS_PORT to another number.)")
    wow_dir = find_wow_dir()
    if wow_dir:
        use_wow_dir(wow_dir)
    else:
        with state.lock:
            state.wow_missing = True
        state.log("Couldn't find World of Warcraft - choose its folder in the PugLogs window")
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
