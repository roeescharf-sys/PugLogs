# PugLogs

**Filter your Mythic+ applicants and see their Warcraft Logs runs, without leaving the Group Finder.**

When you list a key, dozens of players apply - most of them people you'd never invite, and
checking the rest on Warcraft Logs means finding each character page, picking the right dungeon
and digging for a relevant run. PugLogs does both for you:

- **Filters** hide applicants you'd never invite - minimum item level, minimum M+ rating, roles,
  classes and specs - straight from your applicant list. Specs (or classes) already in your group
  are hidden too, and come back when that player leaves. Filters work without the app.
- For every remaining applicant, it finds **their best timed run in the dungeon you listed, one key
  level below yours** (you list a +20 Murder Row, you see their best timed +19 Murder Row), with its
  **DPS and DPS percentile** - the same number Warcraft Logs shows on the log.
- Results appear in a **live window** next to the game within seconds (with its own rating filter
  and a meter of your Warcraft Logs API use), and in the **Group Finder tooltip**.
- **Right-click → "Check logs"** opens a player's Warcraft Logs page for that dungeon.

> Status: personal project, tested on macOS with WoW Retail 12.1.5 (Midnight Season 2), EU realms.
> Windows support is written but not yet tested.

---

## What you see

**In the PugLogs window** (an app window next to WoW; tick "keep on top" to float it over the game):

```
Murder Row +20 · 4 filtered out · 2 below your rating     API 41/720 ▓▓░░░░ resets in 22:58
Ceannor   silvermoon · DPS · 330 ilvl · 3700 score
  +19   31:03 timed   364K DPS (57)    Balance · 20 days ago        <- click +19 to open the log
  best timed +19
```

**In the Group Finder tooltip**, under Raider.IO's lines:

```
PugLogs - Murder Row
+19  31:03 timed        364K DPS (57)
best timed +19
```

Filtered players say why, e.g. `PugLogs: filtered out (item level 325 < 330)` or
`a Frost Mage is already in your group (Anna)`.

---

## How it works

World of Warcraft addons can't access the internet or talk to other programs. So PugLogs has
two parts that pass data through the only channels the game allows:

```
 ┌──────────── WoW ────────────┐        ┌──────── Your computer ────────┐        ┌─ Warcraft Logs ─┐
 │ PugLogs addon               │        │ PugLogs companion (Python)     │        │                 │
 │ - reads your applicants     │ QR in  │ - reads the QR, deletes it     │  API   │ run history     │
 │ - applies your filters      │ ─────► │ - looks players up             │ ─────► │ per player and  │
 │ - draws a tiny QR code and  │ screen │ - shows the live window        │ ◄───── │ dungeon         │
 │   takes a screenshot        │ shot   │ - copies results on request    │        │                 │
 │ - shows results in tooltips │ ◄───── │                                │        └─────────────────┘
 └─────────────────────────────┘ paste  └────────────────────────────────┘
```

1. **Game → companion:** when your applicant list changes, the addon shows a small, faint QR
   code (dark grey on black, about 150 px) in the top-left corner for a couple of frames and takes
   a lossless WoW screenshot (your own screenshot settings are restored right after). The companion watches the Screenshots folder, decodes the code and deletes the
   screenshot. Your own screenshots are never touched.
2. **Companion → Warcraft Logs:** it asks the Warcraft Logs API for each new applicant's runs in
   that dungeon and picks the run to show.
3. **Companion → game:** addons can't receive data while the game runs, but they can accept text
   you paste. Click **Paste logs** in the Group Finder; the companion puts the results on your
   clipboard, you press Cmd+V / Ctrl+V, and the tooltips fill in. Your previous clipboard text is
   put back about 20 seconds later.

The addon never automates gameplay, never sends chat messages and never reads game memory.

---

## Why you need a Warcraft Logs API key

The run data comes from the **Warcraft Logs API**, and Warcraft Logs requires every program that
uses it to identify itself with an API client (a "key"). It is **free** and takes a minute to make.

- **Each person needs their own key.** Every key has an hourly budget (720 points per hour on a
  free key). Sharing one key means sharing one budget, and Warcraft Logs' terms don't allow it.
- **How far it goes:** looking up one applicant costs about **1 point**, and players are
  remembered for **24 hours**, so a free key covers roughly **650 new applicants per hour**.
  Filtered-out applicants cost nothing. If the hour runs out, lookups pause and continue
  automatically when it resets.
- **Your key stays on your computer**, in a settings file outside this project. Never commit it
  or send it to anyone.

### Creating the key

1. Log in at [warcraftlogs.com](https://www.warcraftlogs.com) and open
   [API Clients](https://www.warcraftlogs.com/api/clients/) → **Create Client**.
2. Name: anything (e.g. `PugLogs`). Redirect URL: type `http://localhost` (the form requires
   one; PugLogs doesn't use it). Leave "Public Client" unchecked.
3. Paste the **Client ID** and **Client Secret** into the PugLogs setup page.

---

## Requirements

| | |
|---|---|
| Game | World of Warcraft Retail 12.x (Midnight), current Mythic+ season |
| Region | **EU** realms (other regions need a realm table - see Limitations) |
| Computer | macOS or Windows |
| Warcraft Logs | A free account and API client (see above) |
| Display | WoW in **windowed** mode if you want the live window next to the game (macOS can't place windows over fullscreen games) |

Nothing else to install: the download includes everything it needs (only running from source needs Python).

---

## Install

1. **The PugLogs app** - from [Releases](https://github.com/roeescharf-sys/PugLogs/releases/latest):
   - **Windows:** run **PugLogs-Setup.exe** (Next → Install; no administrator rights needed).
     If Windows says "Windows protected your PC", click **More info → Run anyway**.
   - **macOS:** open **PugLogs-macOS.dmg** and drag PugLogs into Applications. If macOS says it
     can't be opened: **System Settings → Privacy & Security → Open Anyway**. The first start
     can take up to half a minute.

   These warnings appear because PugLogs isn't signed with a paid developer certificate.
2. **Start PugLogs.** It **installs the WoW addon for you** (or keeps the one you have from
   CurseForge/Wago if it's up to date) and opens its window, which walks you through creating
   your free Warcraft Logs API client and pasting it in.
3. In WoW, type `/reload`.

Next time, just start PugLogs before you list a key. It tells you in its window when a new
version is out. PugLogs finds WoW by itself (including custom install folders known to
Battle.net); if it can't, its window asks you to choose the World of Warcraft folder. In game, `/pl wcl` reopens the API key page and
`/pl app` shows the download link.

### Running from source (developers)
Requires Python 3.12+. Clone the repository, then start `companion/run.sh` (macOS) or
`companion\run.bat` (Windows); the first run creates a private Python environment. Build the
downloads with `python companion/build.py`, or push a `v*` tag to have GitHub build both.
On macOS you can symlink the addon into WoW to edit it in place
(`ln -s "$PWD/PugLogs" "/Applications/World of Warcraft/_retail_/Interface/AddOns/PugLogs"`).

---

## Using it

1. **List a Mythic+ key** in the Group Finder. Applicants appear in the PugLogs window within a few
   seconds of applying.
2. **Hover** over an applicant to see their run in the tooltip: click **Paste logs** (above your
   group's role icons), wait for "Ready", press **Cmd+V / Ctrl+V**.
3. **Click a key level** in the window to open that exact log on Warcraft Logs (Damage Done tab).
4. **Right-click** any applicant or player → **Check logs** for their Warcraft Logs page.

### Which run is shown
For a +20 listing: their best timed **+19** (highest DPS percentile among their +19s). If they
have no timed +19, the closest lower key; if all their timed runs are higher, the closest higher
one; if nothing is timed, their highest run, marked "over". If PugLogs can't tell your key level
(e.g. you listed someone else's key), it shows their highest timed run.

The percentile is the one Warcraft Logs shows on the log: DPS compared with the same spec at
the same key level.

### Settings (`/pl opt`, or Options → AddOns → PugLogs)
- **Live Warcraft Logs lookups with the PugLogs app** - turn off if you only want "Check logs"
  and the filters; then no screenshots are taken. On by default only when the PugLogs app is
  installed (it adds a tiny "PugLogs (app)" addon so the addon can tell).

### Filters
- **Minimum item level** and **minimum M+ rating**
- **Roles** they applied as, **classes** and **specs**
- **Hide filtered applicants** from the Group Finder list (on by default). A group that applied
  together is hidden if any member doesn't match.
- **Hide specs already in your group** (or whole classes) - you included. Updates as players join
  or leave; someone who declines your invite never counts. Other players' specs come from what they
  applied with, or from a quick background inspect.

"Spec" is the spec a player is in when they apply, which can differ from the one they'd play.

### Commands
| Command | |
|---|---|
| `/pl` | List the commands |
| `/pl opt` | Open the settings (live lookups and filters) |
| `/pl wcl` | Open the Warcraft Logs API key page in the PugLogs app (to enter or change your key) |
| `/pl paste` | Open the paste box (also: key binding in Options → Keybindings → AddOns) |
| `/pl Name-Realm [dungeon]` | Link to a player's logs, e.g. `/pl Anna-Kazzak voidscar` |
| `/pl send` | Send your current applicants to the companion again |
| `/pl live on\|off` | Turn the QR screenshots on or off |
| `/pl qr subtle\|classic` | Faint dark code (default) or the black-and-white one if the faint one isn't read |
| `/pl test` | Take one test screenshot and report each step in chat |
| `/pl debug` | Show which dungeon PugLogs detects |

---

## Troubleshooting

- **The window says "Waiting for the addon..."**: make sure the companion is running, then
  `/pl test` in game. If files pile up in `_retail_/Screenshots`, the companion isn't reading them
  (check it's watching the right folder - it prints the path when it starts).
- **"Hourly API limit reached"**: lookups resume automatically when the hour resets.
- **"PugLogs is already running"**: it's already open - look for its window (or quit it first).
- **Something else went wrong**: the log is in `~/.config/puglogs/puglogs.log`
  (Windows: `C:\Users\<you>\.config\puglogs\puglogs.log`).
- **"That was your own clipboard"** in the paste box: you pasted before the results arrived; press
  Cmd+V / Ctrl+V again.

---

## Privacy

- Your API key and the lookup cache live only in `~/.config/puglogs/` on your computer.
- The companion talks only to Warcraft Logs (the names and realms it looks up). Its window talks
  to it over a connection that only works on your own computer. Nothing else is sent anywhere.
- PugLogs screenshots are deleted as soon as they are read. Old ones left from times the companion
  wasn't running are deleted (not used) on the next start.

---

## Limitations

- **EU only for now.** WoW gives realm names without spaces ("TwistingNether"); Warcraft Logs
  needs "twisting-nether". The EU table is in `PugLogs/Data/RealmsEU.lua`
  (regenerate with `tools/gen_realms.py`); other regions need their own table and `ns.REGION`.
- **Each season** the dungeon list changes: update `PugLogs/Data/Season.lua` and
  `SEASON_ZONE_ID` in `companion/app.py`.
- Only damage is shown. Interrupts, dispels and other stats were tried but cost several API
  points per run, so they were removed.
- Tooltips update when you paste (one keystroke); the live window updates by itself.
- Windows support is untested.

---

## Project layout

```
PugLogs/              the WoW addon
  Core.lua            links, realm names, /pl command
  Menu.lua            right-click "Check logs"
  Filters.lua         filters, hiding applicants, options panel
  Transport.lua       QR screenshots to the companion
  Live.lua            paste box and tooltips
  Data/               season dungeons, EU realm names
  Libs/qrencode.lua   QR code library
companion/            the program (Python)
  app.py              main program and live window server
  lookup.py           Warcraft Logs lookups and run choice
  inbox.py            reads QR screenshots
  wcl.py              Warcraft Logs API client
  clipboard.py        clipboard on macOS and Windows
  installer.py        installs/updates the addon in WoW
  build.py            builds the downloads (PyInstaller)
  run.sh / run.bat    start scripts (running from source)
docs/api-costs.md     measured API costs
tools/gen_realms.py   regenerates the EU realm table
```

## License

MIT - see [LICENSE](LICENSE). The bundled QR library keeps its BSD 3-clause license.

## Credits

- QR codes: [luaqrcode](https://github.com/speedata/luaqrcode) by Patrick Gundlach, BSD 3-clause
  (license in `PugLogs/Libs/qrencode.lua`).
- EU realm list generated from [LibRealmInfo](https://github.com/phanx-wow/LibRealmInfo) by Phanx (zlib).
- The QR-screenshot idea was inspired by [ApplicantScout](https://github.com/Antrakt92/ApplicantScout-Addon);
  PugLogs is an independent implementation.
- Run data from the [Warcraft Logs API](https://www.warcraftlogs.com/v2-api-docs/warcraft/).
