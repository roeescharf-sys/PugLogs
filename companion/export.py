"""Builds the one-line text you paste into WoW (format: see PugLogs/Live.lua) and copies it."""
import threading

import clipboard
import lookup
from lookup import spec_mismatch


def _clean(text):
    # The format uses ";" between players and "," between fields.
    return str(text).replace(";", " ").replace(",", " ")


def _num(value, digits=0):
    if value is None:
        return ""
    return str(round(value, digits)) if digits else str(int(round(value)))


def build(listing, members, results, result_key, request=None, copy_until=0):
    """members: payload.Member list; results: state.results; returns the paste text or None.
    request: ID of the paste-box request these results answer (the addon checks it).
    copy_until: Unix time until which the app copies again as lookups finish (the paste box
    stays open for another paste until then)."""
    if not listing or not listing.get("encounterId"):
        return None
    records = []
    pending = 0
    not_yet = []  # "who:waiting" (hourly API limit) / "who:error" (lookup failed)
    for m in members:
        result = results.get(result_key(m, listing["encounterId"], listing.get("key")))
        who = _clean(f"{m.name}-{m.realm_slug}")
        if not result or result.get("status") not in ("done", "nodata", "hidden"):
            if not result or result.get("status") in ("pending", "loading"):
                pending += 1
            elif result["status"] in ("waiting", "error"):
                not_yet.append(f"{who}:{result['status']}")
            continue
        if result["status"] == "hidden":
            records.append(f"{who},0,hidden")  # older addons read this as "no logs"
            continue
        if result["status"] == "nodata":
            records.append(f"{who},0")
            continue
        run = result["featured"]
        if run.get("raid"):  # raids: kills, bosses, median and best average percentile in the same places
            run = dict(run, key=run["kills"], timed=True, duration=run["bosses"] * 1000,
                       dps=run.get("median"), percent=run.get("best"))
        fields = [
            who, str(run.get("key") or 0), "1" if run.get("timed") else "0",
            _num((run.get("duration") or 0) / 1000), _num(run.get("dps")), _num(run.get("percent"), 1),
            "", "", "", "",  # interrupts, dispels, deaths, damage taken: not fetched
            _clean(result.get("reason", "").replace(", ", " - ")),  # "best timed +19 - 3 Oct 2026"
            _clean(run.get("spec") or ""),
            str(spec_mismatch(m.spec, run.get("spec"))),
            "hps" if run.get("metric") == "hps" else "",  # older addons ignore this field
            str(int(result.get("lookedUpAt") or 0)),  # when it was fetched from Warcraft Logs
        ]
        for also in (run.get("also") or [])[:1]:  # a second number, e.g. a tank's HPS
            fields += [also["metric"], _num(also.get("amount")), _num(also.get("percent"), 1)]
        records.append(",".join(fields))
    if pending or not_yet:
        # Still being looked up; older addons read only the count.
        records.append(",".join(["!pending", str(pending), str(int(copy_until or 0))] + not_yet))
    if request:
        records.append(f"!req,{_clean(request)}")  # which paste request this answers
    records.append(f"!keep,{lookup.PLAYER_TTL // 86400}")  # days the addon keeps these results
    head = ["PLR1", str(listing["encounterId"]), str(listing.get("key") or 0), _clean(listing.get("dungeon", ""))]
    return ";".join(head + records)


RESTORE_AFTER = 60  # seconds before your own clipboard text is put back


def copy(text):
    clipboard.copy(text)


def _paste():
    return clipboard.paste()


_restore_lock = threading.Lock()
_restore = {"previous": None, "ours": None, "timer": None}


def copy_then_restore(text, recopy=False):
    """Copies text for WoW, then puts your own clipboard text back after RESTORE_AFTER seconds -
    unless you copied something else in the meantime. Copying again before then keeps the
    original text to restore (it isn't replaced by our previous copy).
    recopy: an update of our last copy - skipped (returns False) if you copied something since."""
    with _restore_lock:
        try:
            current = _paste()
        except Exception:
            current = ""
        if _restore["timer"] is None:  # no copy of ours pending: remember what was there
            _restore["previous"] = current
        elif current != _restore["ours"] and not current.startswith("PLR1;"):
            if recopy:
                return False  # you copied something: leave it alone
            _restore["previous"] = current  # put back what you copied last, not the older text
        if _restore["previous"].startswith("PLR1;"):
            _restore["previous"] = ""  # older PugLogs results: never put those back
        if _restore["timer"] is not None:
            _restore["timer"].cancel()
        copy(text)
        _restore["ours"] = text

        def restore():
            with _restore_lock:
                previous, ours = _restore["previous"], _restore["ours"]
                _restore.update(previous=None, ours=None, timer=None)
            try:
                if previous and _paste() == ours:
                    copy(previous)
            except Exception:
                pass

        _restore["timer"] = threading.Timer(RESTORE_AFTER, restore)
        _restore["timer"].daemon = True
        _restore["timer"].start()
    return True
