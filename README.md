# PugLogs

**See Warcraft Logs performance for your Mythic+ applicants, without leaving the Group Finder.**

When you list a key, dozens of players apply. Checking each one on Warcraft Logs means finding
their character page, picking the right dungeon, and digging for a relevant run - for every
applicant. PugLogs does that for you:

- For every applicant, it finds **their best timed run in the dungeon you listed, one key level
  below yours** (you list a +20 Murder Row, you see their best timed +19 Murder Row), with its
  **DPS and DPS percentile** - the same number Warcraft Logs shows on the log.
- Results appear in a **live window** next to the game within seconds, and in the
  **Group Finder tooltip** when you hover over an applicant.
- **Filters** hide players you'd never invite (item level, M+ rating, role, class, spec), so you
  only see - and only spend lookups on - the ones that matter.
- **Right-click → "Check logs"** opens a player's Warcraft Logs page for that dungeon.

> Status: personal project, tested on macOS with WoW Retail 12.1.5 (Midnight Season 2), EU realms.
> Windows support is written but not yet tested.

---

## What you see

**In the live window** (a browser page on your computer, next to WoW):

```
Murder Row +20 · 4 filtered out                          API: 41/720 points this hour
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
`you already invited a Frost Mage (Anna)`.

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

1. **Game → companion:** when your applicant list changes, the addon shows a small QR code
   (about 150 px) in the top-left corner for a fraction of a second and takes a normal WoW
   screenshot. The companion watches the Screenshots folder, decodes the code and deletes the
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
2. Name: anything (e.g. `PugLogs`). Redirect URL: `http://localhost`. Leave "Public Client" unchecked.
3. Copy the **Client ID** and **Client Secret** into your settings file (see Setup).

---

## Requirements

| | |
|---|---|
| Game | World of Warcraft Retail 12.x (Midnight), current Mythic+ season |
| Region | **EU** realms (other regions need a realm table - see Limitations) |
| Computer | macOS or Windows |
| Python | **3.12 or newer** - [python.org/downloads](https://www.python.org/downloads/) (Windows: tick "Add python.exe to PATH") |
| Warcraft Logs | A free account and API client (see above) |
| Display | WoW in **windowed** mode if you want the live window next to the game (macOS can't place windows over fullscreen games) |

The companion installs its own Python packages (OpenCV for reading QR codes, NumPy, Pillow) into
a private folder the first time it runs.

---

## Setup

### 1. Get the files
Download this repository (**Code → Download ZIP**) and unzip it, or `git clone` it.

### 2. Install the addon
Copy the inner **`PugLogs`** folder (the one containing `PugLogs.toc`) into WoW's AddOns folder:

- **macOS:** `/Applications/World of Warcraft/_retail_/Interface/AddOns/PugLogs`
- **Windows:** `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\PugLogs`

(On macOS you can symlink it instead, to edit in place:
`ln -s "$PWD/PugLogs" "/Applications/World of Warcraft/_retail_/Interface/AddOns/PugLogs"`.)

### 3. Start the companion once
- **macOS:** in Terminal, run `companion/run.sh`
- **Windows:** double-click `companion\run.bat`

The first run installs what it needs and creates your settings file, then stops and tells you to
add your key:
- macOS: `~/.config/puglogs/wcl.env`
- Windows: `C:\Users\<you>\.config\puglogs\wcl.env`

### 4. Add your API key
Open the settings file and fill in:
```
WCL_CLIENT_ID=your client id
WCL_CLIENT_SECRET=your client secret
```
If WoW is installed somewhere unusual, also add `WOW_DIR=` with the path to your `_retail_` folder.

### 5. Run it
Start the companion again (step 3). A browser window opens at http://localhost:47615 - keep it
next to WoW. In game, type `/reload` once.

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

### Filters (`/pl filters`, or Options → AddOns → PugLogs)
- **Minimum item level** and **minimum M+ rating**
- **Roles** they applied as, **classes** and **specs**
- **Hide filtered applicants** from the Group Finder list (on by default). A group that applied
  together is hidden if any member doesn't match.
- **After an invite, hide others with the same spec** (or class) - for the current listing only;
  undone if they decline, cleared when you delist.

"Spec" is the spec a player is in when they apply, which can differ from the one they'd play.

### Commands
| Command | |
|---|---|
| `/pl` | List the commands |
| `/pl filters` | Open the filter settings |
| `/pl paste` | Open the paste box (also: key binding in Options → Keybindings → AddOns) |
| `/pl Name-Realm [dungeon]` | Link to a player's logs, e.g. `/pl Anna-Kazzak voidscar` |
| `/pl send` | Send your current applicants to the companion again |
| `/pl live on\|off` | Turn the QR screenshots on or off |
| `/pl test` | Take one test screenshot and report each step in chat |
| `/pl debug` | Show which dungeon PugLogs detects |

---

## Troubleshooting

- **The window says "Waiting for the addon..."**: make sure the companion is running, then
  `/pl test` in game. If files pile up in `_retail_/Screenshots`, the companion isn't reading them
  (check it's watching the right folder - it prints the path when it starts).
- **"Hourly API limit reached"**: lookups resume automatically when the hour resets.
- **Port 47615 is in use**: PugLogs is probably already running in another terminal window.
- **"That was your own clipboard"** in the paste box: you pasted before the results arrived; press
  Cmd+V / Ctrl+V again.

---

## Privacy

- Your API key and the lookup cache live only in `~/.config/puglogs/` on your computer.
- The companion talks only to Warcraft Logs (the names and realms it looks up) and to your own
  browser on `localhost`. Nothing else is sent anywhere.
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
  run.sh / run.bat    start scripts
docs/api-costs.md     measured API costs
tools/gen_realms.py   regenerates the EU realm table
```

## Credits

- QR codes: [luaqrcode](https://github.com/speedata/luaqrcode) by Patrick Gundlach, BSD 3-clause
  (license in `PugLogs/Libs/qrencode.lua`).
- EU realm list generated from [LibRealmInfo](https://github.com/phanx-wow/LibRealmInfo) by Phanx (zlib).
- The QR-screenshot idea was inspired by [ApplicantScout](https://github.com/Antrakt92/ApplicantScout-Addon);
  PugLogs is an independent implementation.
- Run data from the [Warcraft Logs API](https://www.warcraftlogs.com/v2-api-docs/warcraft/).
