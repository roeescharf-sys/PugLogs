"""Looks up applicants on Warcraft Logs: their best run in the listed dungeon.

Each new player costs one request: ~1.3 API points per number fetched (DPS, HPS). Which numbers
each role gets is a setting (by default healers HPS, everyone else DPS). Nothing else is fetched.
Checking the remaining points also costs 1 point, so that is done rarely and spending is
counted locally in between.
"""
import json
import os
import re
import threading
import time

import wcl

CACHE_FILE = os.path.expanduser("~/.config/puglogs/cache.json")
PLAYER_TTL = 24 * 60 * 60  # re-fetch a player's run list after this long ("Keep lookups for" setting)


def set_keep_days(days):
    global PLAYER_TTL
    PLAYER_TTL = max(1, int(days)) * 24 * 60 * 60
RATE_CHECK_EVERY = 600    # seconds between checks of the remaining points (each check costs 1)
POINTS_RESERVE = 15       # leave this much of the hourly limit unused
LOOKUP_COST = 1.1         # measured: ~1 point per player lookup
RAID_COST = 5.0           # measured: ~5 points per player and number for a whole raid
TIMED_MEDALS = {"gold", "silver", "bronze"}
CACHE_VERSION = 3         # bump when the stored run data changes meaning


def percent(run):
    """DPS percentile within the run's key level, as the Warcraft Logs site shows it."""
    value = run.get("todayPercent")
    return value if value is not None else run.get("rankPercent")

def raid_target(encounter_id):
    """Raid listings come with a negative ID holding the Warcraft Logs zone and difficulty:
    -(zone * 10 + difficulty), e.g. -534 = zone 53 Heroic. Returns (zone, difficulty) or None."""
    if encounter_id >= 0:
        return None
    return -encounter_id // 10, -encounter_id % 10


def ranks_query(metrics, encounter_id=0):
    """One request for all the numbers wanted, e.g. ["dps", "hps"] (each costs about the same)."""
    raid = raid_target(encounter_id)
    if raid:
        fields = "\n    ".join(f"{m}: zoneRankings(zoneID: {raid[0]}, difficulty: {raid[1]}, metric: {m})"
                                for m in metrics)
        enc = ""  # a raid needs no encounter variable (an unused one is an error)
    else:
        fields = "\n    ".join(f"{m}: encounterRankings(encounterID: $enc, metric: {m}, byBracket: true)"
                                for m in metrics)
        enc = ", $enc: Int"
    return f"""query($name: String, $realm: String, $region: String{enc}) {{
  characterData {{ character(name: $name, serverSlug: $realm, serverRegion: $region) {{
    hidden
    {fields}
  }} }}
}}"""


def character_url(region, realm_slug, name, zone_id=None, encounter_id=None):
    url = f"https://www.warcraftlogs.com/character/{region}/{realm_slug}/{name}"
    if zone_id and encounter_id:
        url += f"?zone={zone_id}&boss={encounter_id}"
    return url


def report_url(code, fight_id, metric="dps"):
    kind = "healing" if metric == "hps" else "damage-done"
    return f"https://www.warcraftlogs.com/reports/{code}#fight={fight_id}&type={kind}"


# Which numbers to fetch per role (the window's "Look up DPS/HPS for" setting).
METRICS = {"TANK": ["dps"], "HEALER": ["hps"], "DAMAGER": ["dps"]}


def set_metrics(by_role):
    for role in METRICS:
        wanted = [m for m in ("dps", "hps") if m in (by_role.get(role) or [])]
        METRICS[role] = wanted or (["hps"] if role == "HEALER" else ["dps"])  # never nothing


def metrics_for(member):
    """The numbers to fetch for this member, the main one first: healing for healers when
    it's wanted, damage for everyone else."""
    wanted = METRICS.get(member.role) or ["dps"]
    if member.role == "HEALER":
        return sorted(wanted, key=lambda m: m != "hps")
    return sorted(wanted, key=lambda m: m != "dps")


def cache_key(member, region, encounter_id, metric="dps"):
    # Healing rankings are stored apart from damage rankings (DPS keys keep the old form).
    suffix = "-hps" if metric == "hps" else ""
    return f"{member.key}-{region}-{encounter_id}{suffix}"


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

    def _budget_ok(self, cost=LOOKUP_COST):
        rate = self.estimated_rate()
        reset_in = rate.get("pointsResetIn")
        if rate and (reset_in is None or reset_in <= 0):
            rate = self.refresh_rate(force=True)  # the hour has reset: ask for the new numbers
        spent, limit = rate.get("pointsSpentThisHour") or 0, rate.get("limitPerHour") or 720
        if spent + cost > limit - POINTS_RESERVE and time.time() - self._rate_checked > 60:
            # Our count says we're near the limit; ask (at most once a minute) to be sure.
            rate = self.refresh_rate(force=True)
            spent, limit = rate.get("pointsSpentThisHour") or 0, rate.get("limitPerHour") or 720
        return spent + cost <= limit - POINTS_RESERVE

    def player_runs(self, member, region, encounter_id):
        """{metric: ranks} for the numbers wanted for this member; saved ones are free, the
        missing ones are fetched together in one request."""
        runs, missing = {}, []
        for metric in metrics_for(member):
            cached = self.cache.players.get(cache_key(member, region, encounter_id, metric))
            if cached and time.time() - cached["at"] < PLAYER_TTL:
                runs[metric] = cached["ranks"]
            else:
                missing.append(metric)
        if not missing:
            return runs
        cost = (RAID_COST if raid_target(encounter_id) else LOOKUP_COST) * len(missing)
        if not self._budget_ok(cost):
            raise BudgetError()
        variables = {"name": member.name, "realm": member.realm_slug, "region": region}
        if not raid_target(encounter_id):
            variables["enc"] = encounter_id
        data = self.client.query(ranks_query(missing, encounter_id), variables)
        self._spent_since_check += cost
        character = data["characterData"]["character"]
        for metric in missing:
            if raid_target(encounter_id):  # a raid: the whole summary is kept
                ranks = ((character or {}).get(metric) or None) if character else None
            else:
                ranks = ((character or {}).get(metric) or {}).get("ranks", []) if character else None
            self.cache.players[cache_key(member, region, encounter_id, metric)] = {
                "at": time.time(), "ranks": ranks, "hidden": bool(character and character.get("hidden"))}
            runs[metric] = ranks
        return runs

    def forget(self, member, region, encounter_id):
        """Drops a player's saved lookup, so the next one asks Warcraft Logs again."""
        for metric in ("dps", "hps"):
            self.cache.players.pop(cache_key(member, region, encounter_id, metric), None)

    def looked_up_at(self, member, region, encounter_id):
        """When this player's runs were fetched from Warcraft Logs (the oldest of their numbers)."""
        times = [(self.cache.players.get(cache_key(member, region, encounter_id, m)) or {}).get("at")
                 for m in metrics_for(member)]
        return min((t for t in times if t), default=None)

    def is_hidden(self, member, region, encounter_id):
        """True if the player hid their rankings on Warcraft Logs (from the last lookup)."""
        main = metrics_for(member)[0]
        return bool((self.cache.players.get(cache_key(member, region, encounter_id, main)) or {}).get("hidden"))

    def look_up(self, member, region, encounter_id):
        """Returns {"featured", "reason"}: the member's one run to show for this dungeon.
        None if they have no logs in this dungeon, {"hidden": True} if they hid their logs.
        Only this dungeon (encounter_id) is ever requested."""
        runs = self.player_runs(member, region, encounter_id)
        if self.is_hidden(member, region, encounter_id):
            return {"hidden": True}
        metrics = metrics_for(member)
        if raid_target(encounter_id):
            return raid_summary(member, runs, metrics, region, encounter_id)
        metric = metrics[0]
        ranks = usable(runs.get(metric))
        if not ranks:
            return None
        r, reason = pick_featured(ranks, member.role)
        start = r.get("startTime")
        if start:
            t = time.localtime(start / 1000)
            reason += ", %d %s %d" % (t.tm_mday, time.strftime("%b", t), t.tm_year)
        also = []
        for other in metrics[1:]:
            # The other number of the same run when it's there, else their best one by itself.
            other_ranks = usable(runs.get(other))
            same = [o for o in other_ranks if same_fight(o, r)]
            o = same[0] if same else (pick_featured(other_ranks, member.role)[0] if other_ranks else None)
            if o:
                also.append({"metric": other, "amount": o.get("amount"), "percent": percent(o)})
        return {
            "featured": {
                "key": r.get("bracketData"),
                "duration": r.get("duration"),
                "timed": r.get("medal") in TIMED_MEDALS,
                "dps": r.get("amount"),  # healing per second when metric is "hps"
                "metric": metric,
                "percent": percent(r),
                "spec": spec_display(r.get("spec")),
                "date": r.get("startTime"),
                "url": report_url(r["report"]["code"], r["report"]["fightID"], metric),
                "also": also,  # the other numbers asked for, e.g. HPS of a tank's run
            },
            "reason": reason,
        }


def raid_numbers(zone):
    """(bosses killed, bosses, best average percentile, median average, main spec) from a
    zoneRankings answer, or None when they killed nothing at that difficulty."""
    rankings = (zone or {}).get("rankings") or []
    killed = [r for r in rankings if r.get("totalKills")]
    if not killed:
        return None
    specs = [r.get("spec") for r in killed if r.get("spec")]
    spec = max(set(specs), key=specs.count) if specs else ""
    return (len(killed), len(rankings), zone.get("bestPerformanceAverage"),
            zone.get("medianPerformanceAverage"), spec_display(spec))


def raid_summary(member, runs, metrics, region, encounter_id):
    zone_id, difficulty = raid_target(encounter_id)
    main = raid_numbers(runs.get(metrics[0]))
    if not main:
        return None
    kills, bosses, best, median, spec = main
    also = []
    for other in metrics[1:]:
        numbers = raid_numbers(runs.get(other))
        if numbers:
            also.append({"metric": other, "amount": numbers[3], "percent": numbers[2]})
    return {
        "featured": {
            "raid": True, "kills": kills, "bosses": bosses, "best": best, "median": median,
            "spec": spec, "metric": metrics[0], "also": also,
            "url": character_url(region, member.realm_slug, member.name) + f"?zone={zone_id}&difficulty={difficulty}",
        },
        "reason": f"{kills}/{bosses} bosses killed",
    }


def usable(ranks):
    return [r for r in ranks or [] if r.get("report", {}).get("fightID") is not None]


def same_fight(a, b):
    return (a.get("report", {}).get("code"), a.get("report", {}).get("fightID")) == \
        (b.get("report", {}).get("code"), b.get("report", {}).get("fightID"))


# Spec names that aren't damage dealers (names are unique per role across classes).
SPEC_ROLES = {
    "Restoration": "HEALER", "Holy": "HEALER", "Discipline": "HEALER", "Mistweaver": "HEALER",
    "Preservation": "HEALER",
    "Protection": "TANK", "Blood": "TANK", "Brewmaster": "TANK", "Guardian": "TANK", "Vengeance": "TANK",
}
ROLE_NAMES = {"TANK": "tank", "HEALER": "healer", "DAMAGER": "DPS"}


def spec_display(spec):
    """Warcraft Logs writes multi-word specs without spaces ("BeastMastery"); WoW writes
    "Beast Mastery". Use WoW's spelling."""
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", spec or "")


def _same_spec(a, b):
    return (a or "").replace(" ", "").lower() == (b or "").replace(" ", "").lower()


def spec_role(spec):
    return SPEC_ROLES.get(spec or "", "DAMAGER")


def spec_mismatch(applied_spec, run_spec):
    """0 = same spec (or unknown), 1 = other spec in the same role, 2 = a different role
    (e.g. a healing run for someone who applied as DPS)."""
    if not applied_spec or not run_spec or _same_spec(applied_spec, run_spec):
        return 0
    return 2 if spec_role(applied_spec) != spec_role(run_spec) else 1


def level(run):
    """A run's key level. Warcraft Logs sometimes sends it as null, so treat that as 0."""
    return run.get("bracketData") or 0


def pick_featured(ranks, applied_role=""):
    """The run to show: their highest timed run, played in the role they applied as when they have
    one (a healing run says little about their DPS)."""
    run, reason = _pick(_in_role(ranks, applied_role) or ranks)
    if applied_role and spec_role(run.get("spec")) != applied_role:
        reason = f"no logs as {ROLE_NAMES.get(applied_role, applied_role)} - {reason}"
    return run, reason


def _in_role(ranks, role):
    return [r for r in ranks if spec_role(r.get("spec")) == role] if role else []


def _pick(ranks):
    # Runs without a key level can't be compared with your key; use them only if nothing else.
    ranks = [r for r in ranks if level(r)] or ranks
    if not any(level(r) for r in ranks):
        timed = [r for r in ranks if r.get("medal") in TIMED_MEDALS]
        return max(timed or ranks, key=lambda r: percent(r) or 0), "key level unknown"
    timed = [r for r in ranks if r.get("medal") in TIMED_MEDALS]
    best = lambda runs: max(runs, key=lambda r: (level(r), percent(r) or 0))
    if not timed:
        return best(ranks), "no timed runs"
    return best(timed), "highest timed"


class BudgetError(Exception):
    """Not enough of the hourly API limit left."""
