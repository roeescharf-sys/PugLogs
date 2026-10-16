# PugLogs

Warcraft Logs for Mythic+ applicants, in game and in a live window beside WoW.

- `PugLogs/` - the WoW addon.
- `companion/` - the program (macOS and Windows) that looks applicants up and shows the live window.
- `docs/api-costs.md` - measured Warcraft Logs API costs.
- `tools/gen_realms.py` - regenerates the EU realm table.

## Setup

You need Python 3 (macOS: included or via python.org; Windows: https://www.python.org/downloads/)
and a free Warcraft Logs API client (https://www.warcraftlogs.com/api/clients/).

1. **Install the addon**: put the `PugLogs` folder in WoW's `_retail_/Interface/AddOns` folder.
   - macOS: `/Applications/World of Warcraft/_retail_/Interface/AddOns/PugLogs`
     (a symlink to this folder lets you edit in place: `ln -s "$PWD/PugLogs" ".../AddOns/PugLogs"`)
   - Windows: usually `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\PugLogs`
2. **Start the companion**: macOS `companion/run.sh`, Windows double-click `companion\run.bat`.
   The first run installs what it needs and creates the settings file:
   - macOS: `~/.config/puglogs/wcl.env`
   - Windows: `C:\Users\<you>\.config\puglogs\wcl.env`
3. **Add your API client** to that settings file (`WCL_CLIENT_ID=` and `WCL_CLIENT_SECRET=`)
   and start the companion again. Never put the secret in this project folder.
   If WoW is installed somewhere unusual, also add `WOW_DIR=` with your `_retail_` folder.

## Live window

1. With the companion running, a browser window opens at http://localhost:47615.
   Play WoW in windowed mode and keep it beside the game.
2. List a Mythic+ key. Each time your applicants change, the addon flashes a small QR code in the
   top-left corner for a moment and takes a screenshot; the companion reads and deletes it.

In game: `/pl live on|off` turns the QR screenshots on or off, `/pl send` resends.

Each applicant shows their best timed run one key below yours, in the listed dungeon only, with
its damage. A new applicant costs ~1 API point; players are remembered for 24 hours.

## Filters
Options > AddOns > PugLogs (or `/pl filters`): minimum item level, minimum M+ rating,
roles, classes and specs. Applicants who don't match are never sent to the companion, so they
cost no API points; their tooltip says why they were filtered out. By default they are also hidden from
the Group Finder applicant list (a group is hidden if any member doesn't match); turn this off
with "Hide filtered applicants" if you prefer to see them.

When you invite someone, other applicants with the same spec (or, optionally, class) are hidden
for that listing only. The rule is undone if they decline or the invite expires, and everything
is cleared when you delist. Spec is the spec they are in
when applying, which can differ from the one they'd play.

## Results in game tooltips (paste)
In WoW, click "Paste logs" (above your group's role icons), use the key binding
(Options > Keybindings > AddOns > PugLogs) or `/pl paste`, then press Cmd+V a second later.
Opening the box asks the companion (through a QR screenshot) to put the results on the clipboard;
your own clipboard text is put back about 20 seconds later. Hovering over an applicant then shows
their run. The pasted data is kept through /reload. ("auto-copy" in the window is off by default.)

## Each new season
Update `PugLogs/Data/Season.lua` and `SEASON_ZONE_ID` in `companion/app.py`.
