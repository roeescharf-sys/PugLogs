"""Looks up applicants on Warcraft Logs: their best run in the listed dungeon.

Each new player costs one request (~1 API point). Nothing else is fetched.
Checking the remaining points also costs 1 point, so that is done rarely and spending is
counted locally in between.
"""
import json
import os
import threading
import time

import wcl

CACHE_FILE = os.path.expanduser("~/.config/puglogs/cache.json")
PLAYER_TTL = 24 * 60 * 60  # re-fetch a player's run list after 24 hours
RATE_CHECK_EVERY = 600    # seconds between checks of the remaining points (each check costs 1)
POINTS_RESERVE = 15       # leave this much of the hourly limit unused
LOOKUP_COST = 1.1         # measured: ~1 point per player lookup
TIMED_MEDALS = {"gold", "silver", "bronze"}
CACHE_VERSION = 3         # bump when the stored run data changes meaning


def percent(run):
    """DPS percentile within the run's key level, as the Warcraft Logs site shows it."""
    value = run.get("todayPercent")
    return value if value is not None else run.get("rankPercent")

RANKS_QUERY = """query($name: String, $realm: String, $region: String, $enc: Int) {
  characterData { character(name: $name, serverSlug: $realm, serverRegion: $region) {
    hidden
    encounterRankings(encounterID: $enc, metric: dps, byBracket: true)
  } }
}"""


def character_url(region, realm_slug, name, zone_id=None, encounter_id=None):
    url = f"https://www.warcraftlogs.com/character/{region}/{realm_slug}/{name}"
    if zone_id and encounter_id:
        url += f"?zone={zone_id}&boss={encounter_id}"
    return url


def report_url(code, fight_id):
    return f"https://www.warcraftlogs.com/reports/{code}#fight={fight_id}&type=damage-done"


class Cache:
    def __init__(self):
        self.players = {}   # "name-realm-region-encounter" -> {"at": time, "ranks": [...]}
        self._lock = threading.Lock()
        try:
            with open(CACHE_FILE, encoding="utf-8") as f:
                data = json.load(f)
            if data.get("version") == CACHE_VERSION:  # older caches had percentiles across all keys
                self.players = data.get("players", {})
        except (FileNotFoundError, ValueError):
            pass

    def save(self):
        with self._lock:
            tmp = CACHE_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"version": CACHE_VERSION, "players": self.players}, f)
            os.replace(tmp, CACHE_FILE)


class Lookup:
    def __init__(self, log=print):
        self.client = wcl.Client()
        self.cache = Cache()
        self.log = log
        self.rate = {}
        self._rate_checked = 0
        self._spent_since_check = 0

    def refresh_rate(self, force=False):
        """Asks Warcraft Logs how many points are left (costs 1 point), at most every 10 minutes."""
        if force or time.time() - self._rate_checked >= RATE_CHECK_EVERY:
            self.rate = self.client.rate_limit()
            self._rate_checked = time.time()
            self._spent_since_check = 0
        return self.estimated_rate()

    def estimated_rate(self):
        """The last known numbers plus what we've spent since, without asking (free)."""
        rate = dict(self.rate)
        if rate:
            left = (rate.get("pointsResetIn") or 0) - (time.time() - self._rate_checked)
            if left > 0:
                rate["pointsSpentThisHour"] = (rate.get("pointsSpentThisHour") or 0) + self._spent_since_check
                rate["pointsResetIn"] = left
            else:  # the hour has reset since the last check: only what we spent since counts
                rate["pointsSpentThisHour"] = self._spent_since_check
                rate["pointsResetIn"] = None  # unknown until the next check
        return rate

    def _budget_ok(self):
        rate = self.estimated_rate()
        reset_in = rate.get("pointsResetIn")
        if rate and (reset_in is None or reset_in <= 0):
            rate = self.refresh_rate(force=True)  # the hour has reset: ask for the new numbers
        spent, limit = rate.get("pointsSpentThisHour") or 0, rate.get("limitPerHour") or 720
        if spent + LOOKUP_COST > limit - POINTS_RESERVE and time.time() - self._rate_checked > 60:
            # Our count says we're near the limit; ask (at most once a minute) to be sure.
            rate = self.refresh_rate(force=True)
            spent, limit = rate.get("pointsSpentThisHour") or 0, rate.get("limitPerHour") or 720
        return spent + LOOKUP_COST <= limit - POINTS_RESERVE

    def player_runs(self, member, region, encounter_id):
        key = f"{member.key}-{region}-{encounter_id}"
        cached = self.cache.players.get(key)
        if cached and time.time() - cached["at"] < PLAYER_TTL:
            return cached["ranks"]  # free
        if not self._budget_ok():
            raise BudgetError()
        data = self.client.query(RANKS_QUERY, {"name": member.name, "realm": member.realm_slug,
                                               "region": region, "enc": encounter_id})
        self._spent_since_check += LOOKUP_COST
        character = data["characterData"]["character"]
        ranks = (character or {}).get("encounterRankings", {}).get("ranks", []) if character else None
        self.cache.players[key] = {"at": time.time(), "ranks": ranks,
                                   "hidden": bool(character and character.get("hidden"))}
        return ranks

    def is_hidden(self, member, region, encounter_id):
        """True if the player hid their rankings on Warcraft Logs (from the last lookup)."""
        return bool((self.cache.players.get(f"{member.key}-{region}-{encounter_id}") or {}).get("hidden"))

    def look_up(self, member, region, encounter_id, key_level=0):
        """Returns {"featured", "reason"}: the member's one run to show for this dungeon and key level.
        None if they have no logs in this dungeon, {"hidden": True} if they hid their logs.
        Only this dungeon (encounter_id) is ever requested."""
        ranks = self.player_runs(member, region, encounter_id)
        if self.is_hidden(member, region, encounter_id):
            return {"hidden": True}
        ranks = [r for r in ranks or [] if r.get("report", {}).get("fightID") is not None]
        if not ranks:
            return None
        r, reason = pick_featured(ranks, key_level, member.role)
        return {
            "featured": {
                "key": r.get("bracketData"),
                "duration": r.get("duration"),
                "timed": r.get("medal") in TIMED_MEDALS,
                "dps": r.get("amount"),
                "percent": percent(r),
                "spec": r.get("spec"),
                "date": r.get("startTime"),
                "url": report_url(r["report"]["code"], r["report"]["fightID"]),
            },
            "reason": reason,
        }


# Spec names that aren't damage dealers (names are unique per role across classes).
SPEC_ROLES = {
    "Restoration": "HEALER", "Holy": "HEALER", "Discipline": "HEALER", "Mistweaver": "HEALER",
    "Preservation": "HEALER",
    "Protection": "TANK", "Blood": "TANK", "Brewmaster": "TANK", "Guardian": "TANK", "Vengeance": "TANK",
}
ROLE_NAMES = {"TANK": "tank", "HEALER": "healer", "DAMAGER": "DPS"}


def spec_role(spec):
    return SPEC_ROLES.get(spec or "", "DAMAGER")


def spec_mismatch(applied_spec, run_spec):
    """0 = same spec (or unknown), 1 = other spec in the same role, 2 = a different role
    (e.g. a healing run for someone who applied as DPS)."""
    if not applied_spec or not run_spec or applied_spec == run_spec:
        return 0
    return 2 if spec_role(applied_spec) != spec_role(run_spec) else 1


def level(run):
    """A run's key level. Warcraft Logs sometimes sends it as null, so treat that as 0."""
    return run.get("bracketData") or 0


def pick_featured(ranks, key_level, applied_role=""):
    """The run to show: their best timed run one key below yours (or the closest to it), played
    in the role they applied as when they have one (a healing run says little about their DPS)."""
    run, reason = _pick(_in_role(ranks, applied_role) or ranks, key_level)
    if applied_role and spec_role(run.get("spec")) != applied_role:
        reason = f"no logs as {ROLE_NAMES.get(applied_role, applied_role)} - {reason}"
    return run, reason


def _in_role(ranks, role):
    return [r for r in ranks if spec_role(r.get("spec")) == role] if role else []


def _pick(ranks, key_level):
    # Runs without a key level can't be compared with your key; use them only if nothing else.
    ranks = [r for r in ranks if level(r)] or ranks
    if not any(level(r) for r in ranks):
        timed = [r for r in ranks if r.get("medal") in TIMED_MEDALS]
        return max(timed or ranks, key=lambda r: percent(r) or 0), "key level unknown"
    timed = [r for r in ranks if r.get("medal") in TIMED_MEDALS]
    best = lambda runs: max(runs, key=lambda r: (level(r), percent(r) or 0))
    if not timed:
        return best(ranks), "no timed runs"
    if not key_level:
        return best(timed), "highest timed"
    target = key_level - 1
    below = [r for r in timed if level(r) <= target]
    if below:
        run = best(below)
        return run, ("best timed +%d" % level(run))
    above = [r for r in timed if level(r) > target]
    lowest = min(level(r) for r in above)
    run = best([r for r in above if level(r) == lowest])
    return run, "closest timed (above your key)"


class BudgetError(Exception):
    """Not enough of the hourly API limit left."""
