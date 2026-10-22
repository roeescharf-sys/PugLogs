local _, ns = ...

ns.REGION = "eu"

-- Link templates. If Warcraft Logs changes its URL format, only these need updating.
local CHARACTER_URL = "https://www.warcraftlogs.com/character/%s/%s/%s"
local DUNGEON_QUERY = "?zone=%d&boss=%d"

local PREFIX = "|cff00ccffPugLogs:|r "
ns.APP_URL = "https://github.com/roeescharf-sys/PugLogs/releases/latest"

function ns.Print(msg)
	print(PREFIX .. msg)
end

-- Live lookups (QR screenshots to the PugLogs app). Off means only "Check logs" and the
-- filters: no screenshots at all. The default is on only if the app is installed - it adds
-- a tiny "PugLogs_App" addon that sets PugLogsAppInstalled.
local liveListeners = {}

function ns.AppInstalled()
	return PugLogsAppInstalled == true
end

function ns.LiveEnabled()
	return PugLogsDB ~= nil and PugLogsDB.live == true
end

function ns.SetLive(on)
	PugLogsDB.live = on and true or false
	for _, listener in ipairs(liveListeners) do
		listener(PugLogsDB.live)
	end
end

function ns.OnLiveChanged(listener)
	liveListeners[#liveListeners + 1] = listener
end

-- Whether you can invite applicants: group leader or assistant, or listing on your own.
function ns.CanInvite()
	if not IsInGroup() then
		return true
	end
	local leader, assistant = UnitIsGroupLeader("player"), UnitIsGroupAssistant("player")
	if ns.IsSecret(leader) or ns.IsSecret(assistant) then
		return true -- can't tell right now: don't block updates
	end
	return leader or assistant or false
end

-- Automatic updates to the PugLogs app: live lookups on and, unless that option is off, only
-- while you can invite (as a group member PugLogs stays quiet and takes no screenshots).
function ns.LiveActive()
	return ns.LiveEnabled() and (PugLogsDB.liveLeaderOnly == false or ns.CanInvite())
end

-- Since Midnight, some API values can be "secret" (unreadable by addons), e.g. in combat.
function ns.IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

-- Dungeon lookups ------------------------------------------------------------

local byActivityID, byChallengeMapID, byMapID = {}, {}, {}
for _, dungeon in ipairs(ns.Season.dungeons) do
	for _, activityID in ipairs(dungeon.activityIDs) do
		byActivityID[activityID] = dungeon
	end
	byChallengeMapID[dungeon.challengeMapID] = dungeon
	byMapID[dungeon.mapID] = dungeon
end

function ns.FindDungeonByName(text)
	text = text:lower()
	for _, dungeon in ipairs(ns.Season.dungeons) do
		if dungeon.name:lower():find(text, 1, true) then
			return dungeon
		end
	end
end

-- The dungeon of your own active Group Finder listing, if any.
function ns.GetListingDungeon()
	local entry = C_LFGList.GetActiveEntryInfo()
	local activityID = entry and entry.activityIDs and entry.activityIDs[1]
	if not activityID or ns.IsSecret(activityID) then
		return nil
	end
	if byActivityID[activityID] then
		return byActivityID[activityID]
	end
	local info = C_LFGList.GetActivityInfoTable(activityID)
	if info and not ns.IsSecret(info.mapID) and byMapID[info.mapID] then
		return byMapID[info.mapID]
	end
	if info and info.fullName and not ns.IsSecret(info.fullName) then
		for _, dungeon in ipairs(ns.Season.dungeons) do
			if info.fullName:find(dungeon.name, 1, true) then
				return dungeon
			end
		end
	end
end

-- The dungeon of the keystone in your bags, if any.
function ns.GetKeystoneDungeon()
	local ok, challengeMapID = pcall(C_MythicPlus.GetOwnedKeystoneChallengeMapID)
	if ok and challengeMapID and not ns.IsSecret(challengeMapID) then
		return byChallengeMapID[challengeMapID]
	end
end

-- Your listing's dungeon first, then your own key's.
function ns.GetContextDungeon()
	return ns.GetListingDungeon() or ns.GetKeystoneDungeon()
end

-- Names and realms -----------------------------------------------------------

-- Splits "Name-Realm" into name and realm. Players from your own realm come without "-Realm".
function ns.SplitNameRealm(fullName, realm)
	local name, nameRealm = strsplit("-", fullName, 2)
	realm = (realm and realm ~= "") and realm or nameRealm
	if not realm or realm == "" then
		realm = GetNormalizedRealmName() or GetRealmName()
	end
	return name, realm
end

local function AsciiLower(c)
	return string.char(c:byte() + 32)
end

-- WoW gives realms without spaces ("TwistingNether"); Warcraft Logs wants "twisting-nether".
function ns.GetRealmSlug(realm)
	-- ASCII-only character classes: %s, %u and lower() can depend on the system
	-- locale and break non-Latin (e.g. Cyrillic) realm names.
	local key = realm:gsub("[ %-']", ""):gsub("\226\128\153", ""):gsub("[A-Z]", AsciiLower)
	local slugs = ns.RealmSlugs[ns.REGION]
	if slugs and slugs[key] then
		return slugs[key]
	end
	-- Unknown realm: split CamelCase as a best guess.
	local guess = realm:gsub("'", ""):gsub("([a-z])([A-Z])", "%1-%2"):gsub(" +", "-")
	return (guess:gsub("[A-Z]", AsciiLower))
end

function ns.BuildLogsURL(name, realm, dungeon)
	local url = CHARACTER_URL:format(ns.REGION, ns.GetRealmSlug(realm), name)
	if dungeon then
		url = url .. DUNGEON_QUERY:format(ns.Season.wclZoneID, dungeon.wclEncounterID)
	end
	return url
end

-- Shows the copy popup for a player. fullName may be "Name" or "Name-Realm".
function ns.ShowLogsFor(fullName, realm, dungeon)
	if not fullName or ns.IsSecret(fullName) or fullName == "" then
		ns.Print("Can't read this player's name right now (try again out of combat).")
		return
	end
	local name, playerRealm = ns.SplitNameRealm(fullName, realm)
	dungeon = dungeon or ns.GetContextDungeon()
	local title = name .. " - " .. (dungeon and dungeon.name or "all dungeons")
	ns.ShowCopyPopup(title, ns.BuildLogsURL(name, playerRealm, dungeon))
end

-- Slash command ---------------------------------------------------------------

local function PrintHelp()
	ns.Print("Usage:")
	print("  /pl Name-Realm [dungeon]  - link to a player's logs")
	print("  /pl debug  - show which dungeon PugLogs detects")
	print("  /pl debug on|off  - show each step of a paste request in chat (for bug reports)")
	print("  /pl live on|off  - send applicants to the PugLogs window on your computer")
	print("  /pl send  - send the current applicants again")
	print("  /pl test  - take one test screenshot and report each step")
	print("  /pl paste  - paste results from the PugLogs window into applicant tooltips")
	print("  /pl opt  - settings: live lookups and applicant filters (item level, rating, role, class, spec)")
	print("  /pl wcl  - open the Warcraft Logs API key page in the PugLogs app")
	print("  /pl app  - download link for the PugLogs app (needed for live lookups)")
	print("  Or right-click an applicant or group member and choose \"Check logs\".")
end

SLASH_PUGLOGS1 = "/pl"
SLASH_PUGLOGS2 = "/puglogs"
SlashCmdList.PUGLOGS = function(msg)
	msg = strtrim(msg or "")
	if msg == "" then
		PrintHelp()
	elseif msg == "app" then
		ns.ShowCopyPopup("PugLogs app - free download", ns.APP_URL)
	elseif msg:match("^sort") then
		ns.SetSort() -- explains that the PugLogs window does the sorting now
	elseif msg == "opt" then
		ns.OpenFilters()
	elseif msg == "paste" then
		ns.OpenPasteBox()
	elseif ns.HandleLiveSlash and ns.HandleLiveSlash(msg) then
		return
	elseif msg == "debug" then
		local entry = C_LFGList.GetActiveEntryInfo()
		local activityID = entry and entry.activityIDs and entry.activityIDs[1]
		local info = activityID and C_LFGList.GetActivityInfoTable(activityID)
		ns.Print(("Listing activity: %s (%s, map %s)"):format(
			tostring(activityID), tostring(info and info.fullName), tostring(info and info.mapID)))
		local ok, keyMap = pcall(C_MythicPlus.GetOwnedKeystoneChallengeMapID)
		ns.Print("Keystone challenge map: " .. tostring(ok and keyMap))
		local dungeon = ns.GetContextDungeon()
		ns.Print("Detected dungeon: " .. (dungeon and dungeon.name or "none"))
	else
		local player, dungeonText = msg:match("^(%S+)%s*(.*)$")
		local dungeon
		if dungeonText ~= "" then
			dungeon = ns.FindDungeonByName(dungeonText)
			if not dungeon then
				ns.Print("Unknown dungeon: " .. dungeonText)
				return
			end
		end
		ns.ShowLogsFor(player, nil, dungeon)
	end
end

-- First login after installing: explain what needs the PugLogs app.
local welcome = CreateFrame("Frame")
welcome:RegisterEvent("PLAYER_LOGIN")
welcome:SetScript("OnEvent", function()
	PugLogsDB = PugLogsDB or {}
	if PugLogsDB.live == nil then
		ns.SetLive(ns.AppInstalled()) -- first run: on only if the app is installed
	end
	if PugLogsDB.welcomed then
		return
	end
	PugLogsDB.welcomed = true
	C_Timer.After(8, function()
		ns.Print("Thanks for installing PugLogs! Right-click \"Check logs\" and the filters (/pl opt) work right away.")
		if ns.AppInstalled() then
			ns.Print("The PugLogs app is installed - live Warcraft Logs runs are on (turn them off in /pl opt).")
		else
			ns.Print("For live Warcraft Logs runs of your applicants, install the free PugLogs app: type |cffffd100/pl app|r for the link.")
		end
	end)
end)
