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
CACHE_VERSION = 2         # bump when the stored run data changes meaning


def percent(run):
    """DPS percentile within the run's key level, as the Warcraft Logs site shows it."""
    value = run.get("todayPercent")
    return value if value is not None else run.get("rankPercent")

RANKS_QUERY = """query($name: String, $realm: String, $region: String, $enc: Int) {
  characterData { character(name: $name, serverSlug: $realm, serverRegion: $region) {
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
            left = rate.get("pointsResetIn", 0) - (time.time() - self._rate_checked)
            if left > 0:
                rate["pointsSpentThisHour"] = rate.get("pointsSpentThisHour", 0) + self._spent_since_check
                rate["pointsResetIn"] = left
            else:  # the hour has reset since the last check: only what we spent since counts
                rate["pointsSpentThisHour"] = self._spent_since_check
                rate["pointsResetIn"] = None  # unknown until the next check
        return rate

    def _budget_ok(self):
        rate = self.estimated_rate()
        if rate.get("pointsResetIn", 1) <= 0:
            rate = self.refresh_rate(force=True)  # the hour has reset
        spent, limit = rate.get("pointsSpentThisHour", 0), rate.get("limitPerHour", 720)
        if spent + LOOKUP_COST > limit - POINTS_RESERVE and time.time() - self._rate_checked > 60:
            # Our count says we're near the limit; ask (at most once a minute) to be sure.
            rate = self.refresh_rate(force=True)
            spent, limit = rate.get("pointsSpentThisHour", 0), rate.get("limitPerHour", 720)
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
        self.cache.players[key] = {"at": time.time(), "ranks": ranks}
        return ranks

    def look_up(self, member, region, encounter_id, key_level=0):
        """Returns {"featured", "reason"}: the member's one run to show for this dungeon and key level.
        None if they have no logs in this dungeon. Only this dungeon (encounter_id) is ever requested."""
        ranks = self.player_runs(member, region, encounter_id)
        ranks = [r for r in ranks or [] if r.get("report", {}).get("fightID") is not None]
        if not ranks:
            return None
        r, reason = pick_featured(ranks, key_level)
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


def pick_featured(ranks, key_level):
    """The run to show: their best timed run one key below yours (or the closest to it)."""
    timed = [r for r in ranks if r.get("medal") in TIMED_MEDALS]
    best = lambda runs: max(runs, key=lambda r: (r.get("bracketData", 0), percent(r) or 0))
    if not timed:
        return best(ranks), "no timed runs"
    if not key_level:
        return best(timed), "highest timed"
    target = key_level - 1
    below = [r for r in timed if r.get("bracketData", 0) <= target]
    if below:
        run = best(below)
        return run, ("best timed +%d" % run["bracketData"])
    above = [r for r in timed if r.get("bracketData", 0) > target]
    lowest = min(r.get("bracketData", 0) for r in above)
    run = best([r for r in above if r.get("bracketData") == lowest])
    return run, "closest timed (above your key)"


class BudgetError(Exception):
    """Not enough of the hourly API limit left."""
