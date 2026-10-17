# PugLogs

**Filter your Mythic+ applicants and see their Warcraft Logs runs, right in the Group Finder.**

When you list a key, dozens of players apply - most of them people you'd never invite, and
checking the rest on Warcraft Logs takes forever. PugLogs cleans up the list and does the checking
for you.

## Filter your applicants

Hide the applicants you'd never take, straight from your applicant list:

- **Minimum item level** and **minimum M+ rating**
- **Roles** - e.g. no more healers once you have one
- **Classes and specs** - tick exactly what you want
- **No duplicates** - classes or specs already in your group are hidden automatically, and
  come back if that player leaves

Hidden applicants simply disappear from your list - their tooltip tells you why if you turn
hiding off. Filters work on their own, no extra app needed. Open them with `/pl filters`.

## See their run for your key

- **Their best timed run in your dungeon, one key below yours** - you list a +20, you see their
  best +19 - with its DPS and DPS percentile, the same number Warcraft Logs shows.
- **In the tooltip** when you hover an applicant, or in the PugLogs window next to the game as a
  live list - with its own rating filter and a counter of your Warcraft Logs API use.
- **Check logs** - right-click any applicant or player to get their Warcraft Logs page for your
  dungeon.

## Requirements

Live lookups need the free **PugLogs app** (Windows and macOS), because WoW addons can't access
the internet. Download it here: https://github.com/roeescharf-sys/PugLogs/releases/latest

The app walks you through creating a free Warcraft Logs API key the first time (about a minute).
The filters and the right-click link work without it. Without the app (or with live lookups turned
off in /pl filters), PugLogs takes no screenshots.

Currently EU realms only.

## Commands

`/pl` - all commands, `/pl filters` - settings and filters, `/pl paste` - load results into
tooltips, `/pl wcl` - Warcraft Logs API key, `/pl app` - app download link

Source code, help and issues: https://github.com/roeescharf-sys/PugLogs
