"""Builds the one-line text you paste into WoW (format: see PugLogs/Live.lua) and copies it."""
import threading

import clipboard
from lookup import spec_mismatch


def _clean(text):
    # The format uses ";" between players and "," between fields.
    return str(text).replace(";", " ").replace(",", " ")


def _num(value, digits=0):
    if value is None:
        return ""
    return str(round(value, digits)) if digits else str(int(round(value)))


def build(listing, members, results, result_key):
    """members: payload.Member list; results: state.results; returns the paste text or None."""
    if not listing or not listing.get("encounterId"):
        return None
    records = []
    pending = 0
    for m in members:
        result = results.get(result_key(m, listing["encounterId"], listing.get("key")))
        who = _clean(f"{m.name}-{m.realm_slug}")
        if not result or result.get("status") not in ("done", "nodata", "hidden"):
            if not result or result.get("status") in ("pending", "loading"):
                pending += 1
            continue
        if result["status"] == "hidden":
            records.append(f"{who},0,hidden")  # older addons read this as "no logs"
            continue
        if result["status"] == "nodata":
            records.append(f"{who},0")
            continue
        run = result["featured"]
        fields = [
            who, str(run.get("key") or 0), "1" if run.get("timed") else "0",
            _num((run.get("duration") or 0) / 1000), _num(run.get("dps")), _num(run.get("percent"), 1),
            "", "", "", "",  # interrupts, dispels, deaths, damage taken: not fetched
            _clean(result.get("reason", "")),
            _clean(run.get("spec") or ""),
            str(spec_mismatch(m.spec, run.get("spec"))),
        ]
        records.append(",".join(fields))
    if pending:
        records.append(f"!pending,{pending}")  # still being looked up
    head = ["PLR1", str(listing["encounterId"]), str(listing.get("key") or 0), _clean(listing.get("dungeon", ""))]
    return ";".join(head + records)


RESTORE_AFTER = 20  # seconds before your own clipboard text is put back


def copy(text):
    clipboard.copy(text)


def _paste():
    return clipboard.paste()


_restore_lock = threading.Lock()
_restore = {"previous": None, "ours": None, "timer": None}


def copy_then_restore(text):
    """Copies text for WoW, then puts your own clipboard text back after RESTORE_AFTER seconds -
    unless you copied something else in the meantime. Copying again before then keeps the
    original text to restore (it isn't replaced by our previous copy)."""
    with _restore_lock:
        if _restore["timer"] is None:  # no copy of ours pending: remember what was there
            try:
                _restore["previous"] = _paste()
            except Exception:
                _restore["previous"] = ""
        else:
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
