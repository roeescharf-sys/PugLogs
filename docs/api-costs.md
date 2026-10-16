# Warcraft Logs API: measured costs (2026-10-16, EU, Midnight Season 2)

Free API client limit: **720 points per hour**.

| Request | Points | Notes |
|---|---|---|
| Leaderboard page (`encounter.characterRankings`) | ~2 | 100 players, each with their best run: key level, time, medal, score, report code + fight ID |
| One player's runs in one dungeon (`character.encounterRankings`) | ~2 | All their ranked runs incl. DPS |
| One run's stats: Summary only | ~2 (2.4-5) | Damage done/taken, deaths, item level - for all 5 players |
| One run's stats: Summary + Interrupts + Dispels | ~4 | Same request; batching 10 runs per request saves little |
| Any single `table` request | min 2 | Combine stats into one request |

## API facts
- Season zone ID 55 ("Mythic+ Season 2"); encounter IDs match `PugLogs/Data/Season.lua`.
- Leaderboards stop at **page 20** (2,000 entries per filter combination).
  EU Voidscar Arena page 20 is still +20 keys, so deeper scans must split by filters.
- Filters: `className` + `specName` work. `bracket` = key level - 1 (bracket 15 returns +16).
- One key level (+16) alone has more than 2,000 entries for one dungeon in EU; combine with spec.
- Leaderboards list each character once (best run), ordered by score.
- `metric` options include `dps`, `hps`, `playerscore` (default ranks M+ by score).

## Rough throughput per hour (free key)
- ~36,000 leaderboard entries (step 1), or
- ~350 players' run lists, or
- ~180 runs with full stats / ~360 with Summary only.
