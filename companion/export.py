"""Builds the one-line text you paste into WoW (format: see PugLogs/Live.lua) and copies it."""
import threading

import clipboard


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
    for m in members:
        result = results.get(result_key(m, listing["encounterId"], listing.get("key")))
        who = _clean(f"{m.name}-{m.realm_slug}")
        if not result or result.get("status") not in ("done", "nodata"):
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
        ]
        records.append(",".join(fields))
    head = ["PLR1", str(listing["encounterId"]), str(listing.get("key") or 0), _clean(listing.get("dungeon", ""))]
    return ";".join(head + records)


RESTORE_AFTER = 20  # seconds before your own clipboard text is put back


def copy(text):
    clipboard.copy(text)


def _paste():
    return clipboard.paste()


def copy_then_restore(text):
    """Copies text for WoW, then puts the previous clipboard text back after RESTORE_AFTER
    seconds - unless you copied something else in the meantime."""
    try:
        previous = _paste()
    except Exception:
        previous = ""
    copy(text)

    def restore():
        try:
            if previous and _paste() == text:
                copy(previous)
        except Exception:
            pass

    threading.Timer(RESTORE_AFTER, restore).start()
