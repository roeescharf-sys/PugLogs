-- Shows the companion's results in the Group Finder applicant tooltip.
--
-- Addons can't receive data from other programs while the game runs, but they can accept
-- text you paste. The companion keeps its results on the clipboard; open the paste box
-- (button on the applicant list, or a key binding) and press Cmd+V / Ctrl+V.
-- Format (one line, from companion/export.py):
--   PLR1;encounterID;keyLevel;dungeonName;record;record;...
--   record = name-realmslug,key,timed,seconds,dps,percent,interrupts,dispels,deaths,damageTaken,reason,
--            runSpec,specMismatch,metric,lookedUpAt   (specMismatch: 0 = same spec, 1 = other spec
--            same role, 2 = different role; metric: "hps" = healing per second, "bossdps" = damage
--            to bosses, else damage;
--            lookedUpAt: when the app fetched it from Warcraft Logs, Unix time)
--            [,metric2,amount2,percent2]   (a second number, e.g. a tank's HPS)
--            [,topKey,topSeconds,topReason]   (their highest timed run has no log; the fields
--            before it are their best logged run, key 0 if nothing has a log)
--            [,metric3,amount3,percent3]   (fields 22-24: a third number, e.g. Boss DPS)
--            [,overKey,overSeconds,overAmount,overPercent,overReason]   (fields 25-29: their highest
--            run was over time, above the run shown; amount/percent empty when it has no log)
--   "!keep,7" = keep these results for 7 days (the app's "Keep lookups for" setting)
-- Pasted results are kept per dungeon (PugLogsDB.liveSaved), so a player who applies again
-- still shows their run without a new paste.
--   (stats fields are empty when not loaded; "name-realmslug,0" = no logs in this dungeon,
--    "name-realmslug,0,hidden" = they hid their rankings on Warcraft Logs)
--   "!pending,N[,copyUntil,who:waiting,who:error,...]" = N applicants still being looked up; the app
--   copies again as they finish until copyUntil (Unix time); players not looked up yet because of
--   Warcraft Logs' hourly limit ("waiting") or a failed lookup ("error"). Older addons read only N.
--   "retry:<unix time>" among them = when the app looks up the waiting ones; "off:who" = not looked
--   up (nothing ticked for their role in the app's Settings).
local _, ns = ...

local MAGIC = "PLR1"

local pasteFrame

-- Parsing ------------------------------------------------------------------------

local function Num(text)
	return tonumber(text)
end

local function Parse(text)
	local parts = { strsplit(";", text) }
	if parts[1] ~= MAGIC then
		return nil
	end
	local data = {
		encounterID = Num(parts[2]) or 0,
		keyLevel = Num(parts[3]) or 0,
		dungeon = parts[4] or "",
		players = {},
		count = 0,
		at = time(),
	}
	for i = 5, #parts do
		local f = { strsplit(",", parts[i]) }
		local who = f[1]
		if who == "!pending" then
			data.pending = Num(f[2]) or 0 -- applicants the companion was still looking up
			data.copyUntil = Num(f[3]) -- older apps don't send it (they don't keep copying)
			local retryAt
			for i = 4, #f do
				retryAt = retryAt or Num(f[i]:match("^retry:(%d+)$"))
			end
			for i = 4, #f do
				local name, status = f[i]:match("^(.+):(%a+)$")
				local off = f[i]:match("^off:(.+)$")
				if off then
					data.players[off:lower()] = { none = true, off = true }
				elseif name then
					data.players[name:lower()] = { none = true, waiting = status == "waiting" or nil, failed = status == "error" or nil,
						retryAt = status == "waiting" and retryAt or nil }
				end
			end
		elseif who == "!req" then
			data.request = f[2] -- the paste request these results answer
		elseif who == "!keep" then
			data.keepDays = Num(f[2])
		elseif who and who ~= "" then
			local key = Num(f[2]) or 0
			local topKey = Num(f[19])
			local player = key == 0 and not topKey and { none = true, hidden = f[3] == "hidden" } or {
				key = key,
				timed = f[3] == "1",
				seconds = Num(f[4]),
				dps = Num(f[5]),
				percent = Num(f[6]),
				interrupts = Num(f[7]),
				dispels = Num(f[8]),
				deaths = Num(f[9]),
				damageTaken = Num(f[10]),
				reason = f[11],
				runSpec = f[12],
				specMismatch = Num(f[13]) or 0,
				hps = f[14] == "hps", -- the amount is healing per second (healers)
				boss = f[14] == "bossdps", -- the amount is damage to bosses per second
				lookedUpAt = Num(f[15]),
				also = f[16] and f[16] ~= "" and { hps = f[16] == "hps", boss = f[16] == "bossdps", amount = Num(f[17]), percent = Num(f[18]) } or nil,
				also2 = f[22] and f[22] ~= "" and { hps = f[22] == "hps", boss = f[22] == "bossdps", amount = Num(f[23]), percent = Num(f[24]) } or nil,
			}
			if topKey then -- key/seconds/timed become the highest run, log* the best logged one
				player.noLog = true
				player.logKey = key > 0 and key or nil
				player.logSeconds, player.logTimed = player.seconds, player.timed
				player.key, player.seconds, player.timed = topKey, Num(f[20]), true
				player.reason = f[21]
			end
			if Num(f[25]) and not player.none then
				player.over = { key = Num(f[25]), seconds = Num(f[26]), amount = Num(f[27]), percent = Num(f[28]), reason = f[29] }
			end
			data.players[who:lower()] = player
			data.count = data.count + 1
		end
	end
	return data
end

ns.ParseLiveData = Parse -- used by tests

-- Paste box ------------------------------------------------------------------------

local PASTE_KEY = IsMacClient() and "Cmd+V" or "Ctrl+V"
local COPY_TIME = 1.2 -- seconds the companion needs after the request's screenshot is saved
local GIVE_UP_AFTER = 15 -- seconds without the request getting through
local readyTimer
local ready = false
local requestCodes = 1 -- QR codes in the current request (more codes take the companion longer)
local retries = 0
local MAX_RETRIES = 10
local openedAt -- GetTime() when the paste box was opened
local readyAt -- GetTime() when the box last said "Ready"
-- A wrong paste soon after "Ready" is usually the app still copying: asking again (new codes
-- on screen) only delays it further, pasting once more works.
local RESEND_AFTER = 8
-- Results with players still being looked up: the box stays open while the app copies again as
-- their lookups finish (it says until when), and says Ready for the rest after MORE_TIME.
local MORE_TIME = 2
local loadedRequest -- the request whose answer last closed the box

local function SetWarning(text)
	pasteFrame.warning:SetText(text or "")
	pasteFrame:SetHeight(text and 96 + (pasteFrame.warning:GetStringHeight() or 12) + 4 or 96)
end

local function SetHint(text, r, g, b)
	pasteFrame.hint:SetText(text)
	pasteFrame.hint:SetTextColor(r or 1, g or 1, b or 1)
end

-- After "Ready", a paste that isn't the answer to this box's request (your own clipboard,
-- a screenshot, older results) asks the companion again, so pressing Cmd+V once more works.
local function StartFallback()
	if readyTimer then
		readyTimer:Cancel()
	end
	-- "Ready" comes from ns.OnPasteRequestDone once the request really went out; this is a fallback.
	readyTimer = C_Timer.NewTimer(GIVE_UP_AFTER, function()
		readyTimer = nil
		ready = true
		readyAt = GetTime()
		SetHint(("Taking long - press %s to try, or click Copy for WoW in the PugLogs window."):format(PASTE_KEY), 1, 0.7, 0.3)
	end)
end

local function AskAgain(why)
	if retries >= MAX_RETRIES then
		SetWarning(("No answer from the PugLogs app - is it running? Start it, then press %s again."):format(PASTE_KEY))
		SetHint(why .. (" Click Copy for WoW in the PugLogs window, then press %s."):format(PASTE_KEY), 1, 0.4, 0.3)
		return
	end
	retries = retries + 1
	ready = false
	SetHint(why .. (" Trying again... press %s when it says Ready."):format(PASTE_KEY), 1, 0.7, 0.3)
	StartFallback()
	ns.RequestCopy()
end

-- The paste wasn't the answer to this box. Ask the app again only when it has had plenty of
-- time to answer; otherwise the next Cmd+V usually works.
local function WrongPaste(why)
	if readyAt and GetTime() - readyAt >= RESEND_AFTER then
		AskAgain(why)
		return
	end
	SetHint(why .. (" Press %s again."):format(PASTE_KEY), 1, 0.7, 0.3)
end

local function OnPasted(editBox)
	local text = strtrim(editBox:GetText() or "")
	if text == "" then
		return
	end
	editBox:SetText("")
	local data = Parse(text)
	ns.TracePaste(("pasted %s, request %s, waiting for %s"):format(data and "results" or "other text",
		tostring(data and data.request), tostring(ns.lastPasteRequest)))
	if not data then
		if ready then
			WrongPaste("That wasn't PugLogs results.")
		else
			SetHint(("Not ready yet - wait for \"Ready\", then press %s."):format(PASTE_KEY), 1, 0.7, 0.3)
		end
		return
	end
	-- Accept the answer to any request this box made (an earlier one is only seconds old).
	-- Anything else on the clipboard is older results (e.g. from a previous paste) and would
	-- hide newer applicants.
	local requested = data.request and ns.pasteRequests[data.request]
	local fromThisBox = requested and openedAt and requested >= openedAt
	if data.request and not fromThisBox then
		if ready then
			WrongPaste("Those were older results.")
		else
			SetHint(("Not ready yet - wait for \"Ready\", then press %s."):format(PASTE_KEY), 1, 0.7, 0.3)
		end
		return
	end
	if not ready and not fromThisBox then
		SetHint(("Not ready yet - wait for \"Ready\", then press %s."):format(PASTE_KEY), 1, 0.7, 0.3)
		return
	end
	if data.encounterID == 0 and data.count == 0 then
		if fromThisBox and data.request:find("^req%-") then
			-- The request carried no dungeon and the app has none either: asking again can't help.
			if readyTimer then
				readyTimer:Cancel()
				readyTimer = nil
			end
			ready = true
			SetHint("Nothing to load yet - list a key (or join a group) first.", 1, 0.7, 0.3)
			return
		end
		AskAgain("The PugLogs app is still loading.")
		return
	end
	SetWarning(nil)
	PugLogsDB.liveData = data -- also kept through /reload
	ns.RememberResults(data)
	if ns.OnPanelChanged then
		ns.OnPanelChanged()
	end
	if ns.OnLiveResultsPasted then
		ns.OnLiveResultsPasted()
	end
	local pending = data.pending or 0
	if pending > 0 and fromThisBox and data.copyUntil and time() < data.copyUntil then
		-- Players who just applied are still being looked up: the app copies again when they're
		-- done, so keep the box open for one more Cmd+V instead of making them reopen it.
		ready = false
		if readyTimer then
			readyTimer:Cancel()
		end
		SetHint(("Loaded %d - %d still being looked up..."):format(data.count, pending), 0.7, 0.7, 0.7)
		readyTimer = C_Timer.NewTimer(MORE_TIME, function()
			readyTimer = nil
			ready = true
			readyAt = GetTime()
			SetHint(("Ready - press %s for the other %d"):format(PASTE_KEY, pending), 0.3, 1, 0.4)
			pasteFrame.editBox:SetFocus()
		end)
		return
	end
	loadedRequest = data.request
	pasteFrame:Hide()
	ns.Print(("Loaded %d player(s) for %s%s. Hover over applicants to see their run."):format(
		data.count, data.dungeon ~= "" and data.dungeon or "?", data.keyLevel > 0 and (" +" .. data.keyLevel) or ""))
	if (data.pending or 0) > 0 then
		ns.Print(("%d more still loading - paste again in a moment."):format(data.pending))
	end
end

local function CreatePasteFrame()
	local frame = CreateFrame("Frame", "PugLogsPasteFrame", UIParent, "BackdropTemplate")
	frame:SetSize(340, 96)
	frame:SetPoint("CENTER", 0, 200)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:SetScript("OnMouseDown", function(self) self.editBox:SetFocus() end) -- Cmd+V needs the box focused
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	tinsert(UISpecialFrames, "PugLogsPasteFrame")
	-- A "Ready" timer left running would give the hidden edit box the keyboard.
	frame:SetScript("OnHide", function()
		if readyTimer then
			readyTimer:Cancel()
			readyTimer = nil
		end
	end)

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOP", 0, -18)
	title:SetText("PugLogs: paste results")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local editBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	editBox:SetSize(280, 24)
	editBox:SetPoint("TOP", 0, -40)
	editBox:SetAutoFocus(true)
	editBox:SetMaxLetters(0)
	editBox:SetMaxBytes(0)
	editBox:SetScript("OnEscapePressed", function() frame:Hide() end)
	editBox:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			OnPasted(self)
		end
	end)
	frame.editBox = editBox

	local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	hint:SetPoint("TOP", editBox, "BOTTOM", 0, -6)
	frame.hint = hint

	-- A warning that stays visible while the request steps go on in the line above.
	local warning = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	warning:SetPoint("TOP", hint, "BOTTOM", 0, -4)
	warning:SetWidth(310)
	warning:SetTextColor(1, 0.4, 0.3)
	frame.warning = warning
	return frame
end

function ns.OpenPasteBox()
	if not ns.LiveEnabled() then
		ns.Print("Live lookups with the PugLogs app are off - turn them on in /pl opt.")
		return
	end
	-- The companion only touches the clipboard when you ask, and puts your own text back afterwards.
	pasteFrame = pasteFrame or CreatePasteFrame()
	pasteFrame.editBox:SetText("")
	ready = false
	retries = 0
	-- Reopened while its last request is still on its way: that answer still counts.
	local last = ns.lastPasteRequest and ns.pasteRequests[ns.lastPasteRequest]
	openedAt = (last and GetTime() - last < 10 and ns.lastPasteRequest ~= loadedRequest) and last or GetTime()
	readyAt = nil
	SetWarning(nil)
	SetHint("Getting the latest results...", 0.7, 0.7, 0.7)
	StartFallback()
	pasteFrame:Show()
	pasteFrame.editBox:SetFocus()
	ns.RequestCopy()
end

-- Progress of the paste box's request, from Transport.lua, so you can see where it is.
function ns.OnPasteRequestStatus(stage, codes)
	if not (pasteFrame and pasteFrame:IsShown()) then
		return
	end
	if stage == "sending" then
		-- A newer request is going out (e.g. the box was reopened): "Ready" follows this one.
		ready = false
		StartFallback()
	elseif ready then
		return
	end
	if stage == "queued" then
		SetHint("Waiting for the current update to finish...", 0.7, 0.7, 0.7)
	elseif stage == "sending" then
		requestCodes = codes or 1
		SetHint(("Sending the request%s..."):format(codes and codes > 1 and (" (" .. codes .. " codes)") or ""), 0.7, 0.7, 0.7)
	end
end

-- Called by Transport.lua when the paste box's request was saved as a screenshot (delivered)
-- or couldn't be sent. The companion reads it and copies within about a second.
function ns.OnPasteRequestDone(delivered)
	if not (pasteFrame and pasteFrame:IsShown()) or ready then
		return
	end
	if readyTimer then
		readyTimer:Cancel()
		readyTimer = nil
	end
	if not delivered then
		ready = true
		SetHint(("Couldn't send the request (no screenshot, or in combat or a key). Try again with %s."):format(PASTE_KEY), 1, 0.4, 0.3)
		return
	end
	SetHint("Waiting for the PugLogs window...", 0.7, 0.7, 0.7)
	-- The companion reads each code in turn before copying.
	readyTimer = C_Timer.NewTimer(COPY_TIME + 0.6 * (requestCodes - 1), function()
		readyTimer = nil
		ready = true
		readyAt = GetTime()
		SetHint(("Ready - press %s"):format(PASTE_KEY), 0.3, 1, 0.4)
		pasteFrame.editBox:SetFocus() -- clicking the Group Finder meanwhile takes it away
	end)
end

-- Key binding (Options > Keybindings > AddOns > PugLogs)
BINDING_HEADER_PUGLOGS = "PugLogs"
BINDING_NAME_PUGLOGS_PASTE = "Paste results from the PugLogs window"
function PugLogs_OpenPasteBox()
	ns.OpenPasteBox()
end

-- Button on the applicant list
local function AddViewerButton()
	local viewer = LFGListFrame and LFGListFrame.ApplicationViewer
	if not viewer or viewer.PugLogsButton then
		return
	end
	local button = CreateFrame("Button", nil, viewer, "UIPanelButtonTemplate")
	button:SetSize(90, 20)
	button:SetText("Paste logs")
	-- Just above your group's role icons, in the top-right of the listing info.
	if viewer.DataDisplay then
		button:SetPoint("BOTTOMRIGHT", viewer.DataDisplay, "TOPRIGHT", 0, 2)
	else
		button:SetPoint("TOPRIGHT", viewer, "TOPRIGHT", -40, -30)
	end
	button:SetScript("OnClick", ns.OpenPasteBox)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("PugLogs")
		GameTooltip:AddLine("Loads the latest PugLogs results into applicant tooltips. Click, then press Cmd+V.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	viewer.PugLogsButton = button
	button:SetShown(ns.LiveEnabled())
	ns.OnLiveChanged(function(on) button:SetShown(on) end)

	-- On/off switch for live lookups, always visible (the Paste logs button hides when off).
	local toggle = CreateFrame("CheckButton", nil, viewer, "UICheckButtonTemplate")
	toggle:SetSize(20, 20)
	toggle:SetPoint("RIGHT", button, "LEFT", -46, 0)
	local label = toggle:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	label:SetPoint("LEFT", toggle, "RIGHT", 0, 1)
	label:SetText("PugLogs")
	toggle:SetChecked(ns.LiveEnabled())
	toggle:SetScript("OnClick", function(self) ns.SetLive(self:GetChecked()) end)
	toggle:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("PugLogs live lookups")
		GameTooltip:AddLine("On: your applicants are looked up in the PugLogs app. Off: no screenshots are taken.", 1, 1, 1, true)
		if PugLogsDB.liveLeaderOnly ~= false then
			GameTooltip:AddLine("Only while you can invite (leader or assistant) - change it in /pl opt.", 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	toggle:SetScript("OnLeave", GameTooltip_Hide)
	ns.OnLiveChanged(function(on) toggle:SetChecked(on) end)
	viewer.PugLogsToggle = toggle
end

-- Tooltip --------------------------------------------------------------------------

local function FormatNumber(n)
	if not n then return "-" end
	if n >= 1e9 then return ("%.2fB"):format(n / 1e9) end
	if n >= 1e6 then return ("%.2fM"):format(n / 1e6) end
	if n >= 1e3 then return ("%.0fK"):format(n / 1e3) end
	return tostring(math.floor(n))
end

local function PercentColor(p)
	if not p then return "ffffff" end
	if p >= 100 then return "e5cc80" end
	if p >= 99 then return "e268a8" end
	if p >= 95 then return "ff8000" end
	if p >= 75 then return "a335ee" end
	if p >= 50 then return "0070ff" end
	if p >= 25 then return "1eff00" end
	return "9d9d9d"
end

local function Clean(value)
	if value == nil or ns.IsSecret(value) then
		return nil
	end
	return value
end

-- The spec they applied as, in the game's language.
local function AppliedSpecName(applicantID, memberIdx)
	local specID = Clean(select(16, C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)))
	if specID and specID > 0 then
		return select(2, GetSpecializationInfoByID(specID))
	end
end

-- Which spec the run was played as, standing out when it isn't how they applied.
local function RunLeftText(key, seconds, timed)
	local timeText = seconds and ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60) or "-"
	return ("+%d  %s %s"):format(key, timeText, timed and "|cff4ec36atimed|r" or "|cffe0624fover|r")
end

-- The run's key and time with its numbers. A run without a log says so, and the numbers go on a
-- "best log" line under it.
local function AddRunLines(tooltip, entry)
	local over = entry.over -- their highest run, over time: a red line above the run shown
	if over and over.key then
		tooltip:AddDoubleLine(RunLeftText(over.key, over.seconds, false), over.amount
			and ("|cff%s%s %s (%d)|r"):format(PercentColor(over.percent), FormatNumber(over.amount), ns.MetricName(entry),
				math.floor(over.percent or 0)) or "|cff888888no log|r", 1, 1, 1, 1, 1, 1)
	end
	local left = RunLeftText(entry.key, entry.seconds, entry.timed)
	if entry.noLog then
		tooltip:AddDoubleLine(left, "|cff888888no log|r", 1, 1, 1, 1, 1, 1)
		if not entry.logKey then
			return
		end
		left = "best log: " .. RunLeftText(entry.logKey, entry.logSeconds, entry.logTimed)
	end
	tooltip:AddDoubleLine(left, ("|cff%s%s %s (%d)|r"):format(PercentColor(entry.percent), FormatNumber(entry.dps),
		ns.MetricName(entry), math.floor(entry.percent or 0)), 1, 1, 1, 1, 1, 1)
	for _, also in ipairs({ entry.also or false, entry.also2 or false }) do
		if also and also.amount then
			tooltip:AddDoubleLine(" ", ("|cff%s%s %s (%d)|r"):format(PercentColor(also.percent),
				FormatNumber(also.amount), ns.MetricName(also), math.floor(also.percent or 0)), 1, 1, 1, 1, 1, 1)
		end
	end
end

local function AddSpecLine(entry, applicantID, memberIdx)
	if not entry.runSpec or entry.runSpec == "" then
		return
	end
	local applied = AppliedSpecName(applicantID, memberIdx)
	if entry.specMismatch == 2 then
		GameTooltip:AddLine(("Run was as %s - a different role than they applied as%s!"):format(
			entry.runSpec, applied and (" (" .. applied .. ")") or ""), 1, 0.42, 0.36, true)
	elseif entry.specMismatch == 1 then
		GameTooltip:AddLine(("Run was as %s%s"):format(entry.runSpec,
			applied and (" - they applied as " .. applied) or " (another spec)"), 1, 0.7, 0.28, true)
	else
		GameTooltip:AddLine("as " .. entry.runSpec, 0.6, 0.6, 0.6)
	end
end

-- Saved results ---------------------------------------------------------------------

local DAY = 24 * 60 * 60

local function KeepSeconds()
	return (PugLogsDB.liveKeepDays or 1) * DAY
end

-- Adds a paste to the saved results of its dungeon and drops results older than the
-- app's "Keep lookups for" setting.
function ns.RememberResults(data)
	PugLogsDB.liveKeepDays = data.keepDays or PugLogsDB.liveKeepDays or 1
	local saved = PugLogsDB.liveSaved or {}
	PugLogsDB.liveSaved = saved
	local bucket = saved[data.encounterID] or {}
	saved[data.encounterID] = bucket
	for who, entry in pairs(data.players) do
		entry.lookedUpAt = entry.lookedUpAt or data.at -- older apps don't send the date
		entry.raid = data.encounterID < 0 or nil -- raid results (see RaidText)
		local old = bucket[who]
		-- "Not looked up yet" never replaces a run we already have.
		if not ((entry.waiting or entry.failed or entry.off) and old and not (old.waiting or old.failed or old.off)) then
			bucket[who] = entry
		end
	end
	local oldest = time() - KeepSeconds()
	for _, players in pairs(saved) do
		for who, entry in pairs(players) do
			if (entry.lookedUpAt or 0) < oldest then
				players[who] = nil
			end
		end
	end
end

-- The saved run for a player ("Name-Realm") in the dungeon you're listing now (or the given
-- one). Also used by the applicant panel (Panel.lua) and the filters.
function ns.LiveEntry(fullName, dungeon)
	if not ns.LiveEnabled() then
		return nil
	end
	if not PugLogsDB.liveSaved and PugLogsDB.liveData then
		ns.RememberResults(PugLogsDB.liveData) -- results pasted before saving existed
	end
	dungeon = dungeon or ns.GetListingTarget()
	local bucket = dungeon and PugLogsDB.liveSaved and PugLogsDB.liveSaved[dungeon.wclEncounterID]
	if not (bucket and fullName) then
		return nil
	end
	local name, realm = ns.SplitNameRealm(fullName)
	local entry = bucket[(name .. "-" .. ns.GetRealmSlug(realm)):lower()]
	if entry and (entry.lookedUpAt or 0) < time() - KeepSeconds() then
		return nil -- older than the app's "Keep lookups for"
	end
	if entry and entry.waiting and entry.retryAt then
		if time() > entry.retryAt + 120 then
			return nil -- looked up by now: paste again for the result
		end
	elseif entry and (entry.waiting or entry.failed) and (entry.lookedUpAt or 0) < time() - 600 then
		return nil -- "not looked up yet" is only news for a few minutes
	end
	return entry
end

-- Why a player has no run yet, when the app couldn't look them up (nil otherwise).
function ns.UnavailableText(entry)
	if entry.off then
		return "Not looked up - their role is turned off in the PugLogs app's Settings."
	elseif entry.waiting then
		local at = entry.retryAt and date("%H:%M", entry.retryAt)
		return at and ("Warcraft Logs' hourly limit is used up - the PugLogs app looks them up at %s. Paste logs again then."):format(at)
			or "Warcraft Logs' hourly limit is used up - the PugLogs app looks them up after the reset. Paste logs again then."
	elseif entry.failed then
		return "The PugLogs app couldn't look them up - it tries again in a minute. Paste logs again then."
	end
end

-- "DPS", "HPS" or "Boss DPS": which number an entry (or one of its extra numbers) holds.
function ns.MetricName(t)
	return t.hps and "HPS" or (t.boss and "Boss DPS" or "DPS")
end

-- The damage per second of a player's run, whichever of the numbers it is (nil if only HPS);
-- damage to bosses only when there's no overall damage.
function ns.EntryDamage(entry)
	if not entry or entry.raid then
		return nil -- raid results are percentiles, not damage
	end
	local boss
	for _, t in ipairs({ { hps = entry.hps, boss = entry.boss, amount = entry.dps }, entry.also or {}, entry.also2 or {} }) do
		if t.amount and not t.hps then
			if not t.boss then
				return t.amount
			end
			boss = boss or t.amount
		end
	end
	return boss
end

-- "Look up again" (right-click menu): forget the saved result and ask the app for a fresh one.
function ns.LookUpAgain(fullName, dungeon)
	dungeon = dungeon or ns.GetListingTarget() or ns.GetGroupDungeon()
	if not (dungeon and ns.LiveEnabled()) then
		ns.Print("Nothing to look up again: no listing or group dungeon (or live lookups are off).")
		return
	end
	if ns.SendRefresh(fullName, dungeon) then
		local bucket = PugLogsDB.liveSaved and PugLogsDB.liveSaved[dungeon.wclEncounterID]
		if bucket then
			local name, realm = ns.SplitNameRealm(fullName)
			bucket[(name .. "-" .. ns.GetRealmSlug(realm)):lower()] = nil
		end
		if ns.OnPanelChanged then
			ns.OnPanelChanged()
		end
		ns.Print(("Looking %s up again - Paste logs in a few seconds."):format(ns.SplitNameRealm(fullName)))
	end
end

local function LookedUpText(at)
	local days = at and math.floor((time() - at) / DAY)
	if not days then
		return nil
	end
	return "Looked up " .. (days <= 0 and "today" or days == 1 and "yesterday" or (days .. " days ago"))
end

local function AddApplicantLines(applicantID, memberIdx)
	local dungeon = ns.GetListingTarget()
	if not dungeon then
		return
	end
	local fullName = Clean(C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx))
	if not fullName then
		return
	end
	if ns.AddSavedPlayerLines then
		ns.AddSavedPlayerLines(GameTooltip, fullName)
	end
	local reason = ns.ApplicantFilterReason(applicantID, memberIdx)
	if reason then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("PugLogs: filtered out (" .. reason .. ")", 0.6, 0.6, 0.6)
		GameTooltip:Show()
		return
	end
	-- Only results for the dungeon you're listing now (and only with live lookups on).
	if not ns.LiveEnabled() then
		return
	end
	local entry = ns.LiveEntry(fullName)

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("PugLogs - " .. dungeon.name, 0, 0.8, 1)
	if not entry then
		GameTooltip:AddLine("Not loaded yet - paste again from the PugLogs window.", 0.6, 0.6, 0.6)
	elseif ns.UnavailableText(entry) then
		GameTooltip:AddLine(ns.UnavailableText(entry), 1, 0.7, 0.28, true)
	elseif entry.hidden then
		GameTooltip:AddLine("Logs hidden - they hid their rankings on Warcraft Logs.", 1, 0.7, 0.28, true)
	elseif entry.none then
		GameTooltip:AddLine(entry.raid and "No kills at this difficulty yet." or "No logs in this dungeon this season.", 0.6, 0.6, 0.6)
	elseif entry.raid then
		-- Raid: bosses killed at this difficulty, and their average percentile (best and median).
		local function Line(left, best, median, t)
			GameTooltip:AddDoubleLine(left, ("|cff%s%s %d|r (median %d)"):format(PercentColor(best), ns.MetricName(t),
				math.floor(best or 0), math.floor(median or 0)), 1, 1, 1, 1, 1, 1)
		end
		Line(("%d/%d bosses killed"):format(entry.key or 0, entry.seconds or 0), entry.percent, entry.dps, entry)
		for _, also in ipairs({ entry.also or false, entry.also2 or false }) do
			if also and also.percent then
				Line(" ", also.percent, also.amount, also)
			end
		end
		if entry.runSpec and entry.runSpec ~= "" then
			GameTooltip:AddLine("mostly as " .. entry.runSpec, 0.6, 0.6, 0.6)
		end
	else
		AddRunLines(GameTooltip, entry)
		AddSpecLine(entry, applicantID, memberIdx)
		if entry.reason and entry.reason ~= "" then
			GameTooltip:AddLine(entry.reason, 0.6, 0.6, 0.6)
		end
	end
	if entry and not ns.UnavailableText(entry) and LookedUpText(entry.lookedUpAt) then
		GameTooltip:AddLine(LookedUpText(entry.lookedUpAt), 0.5, 0.5, 0.5)
	end
	GameTooltip:Show()
end

-- Players in your group: their run in the mouse-over window (from the same pasted results).
-- Only lines are added; nothing of Blizzard's is changed. Names WoW keeps secret (e.g. in
-- combat) are skipped.
local function AddUnitLines(tooltip)
	if tooltip ~= GameTooltip or not ns.GroupLookupsActive() then
		return
	end
	local _, unit = tooltip:GetUnit()
	unit = Clean(unit)
	if not unit or not Clean(UnitIsPlayer(unit)) or Clean(UnitIsUnit(unit, "player"))
		or not Clean(UnitInParty(unit)) then
		return
	end
	local name, realm = UnitName(unit)
	name, realm = Clean(name), Clean(realm)
	local dungeon = ns.GetGroupDungeon()
	if not (name and dungeon) then
		return
	end
	local entry = ns.LiveEntry((realm and realm ~= "") and (name .. "-" .. realm) or name, dungeon)
	tooltip:AddLine(" ")
	tooltip:AddLine("PugLogs - " .. dungeon.name, 0, 0.8, 1)
	if not entry then
		tooltip:AddLine("Not loaded yet - Paste logs (or /pl paste) after the PugLogs app looked them up.", 0.6, 0.6, 0.6, true)
	elseif ns.UnavailableText(entry) then
		tooltip:AddLine(ns.UnavailableText(entry), 1, 0.7, 0.28, true)
	elseif entry.hidden then
		tooltip:AddLine("Logs hidden - they hid their rankings on Warcraft Logs.", 1, 0.7, 0.28, true)
	elseif entry.none then
		tooltip:AddLine("No logs in this dungeon this season.", 0.6, 0.6, 0.6)
	else
		AddRunLines(tooltip, entry)
		if entry.runSpec and entry.runSpec ~= "" then
			tooltip:AddLine("as " .. entry.runSpec .. (entry.reason and entry.reason ~= "" and (" - " .. entry.reason) or ""), 0.6, 0.6, 0.6)
		end
	end
	if entry and not ns.UnavailableText(entry) and LookedUpText(entry.lookedUpAt) then
		tooltip:AddLine(LookedUpText(entry.lookedUpAt), 0.5, 0.5, 0.5)
	end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
		pcall(AddUnitLines, tooltip) -- a problem here must never break the mouse-over window
	end)
end

-- Shared with the applicant panel (Panel.lua).
ns.AddApplicantTooltip = AddApplicantLines
ns.PercentColor = PercentColor

local function OnApplicantEnter(self)
	local parent = self:GetParent()
	local applicantID = parent and parent.applicantID
	if applicantID and self.memberIdx and not ns.IsSecret(applicantID) then
		AddApplicantLines(applicantID, self.memberIdx)
	end
end

-- The Group Finder UI normally loads before addons; hook it once it exists.
local hooked = false
local function HookGroupFinder()
	if not hooked and LFGListApplicantMember_OnEnter then
		hooksecurefunc("LFGListApplicantMember_OnEnter", OnApplicantEnter)
		hooked = true
	end
	AddViewerButton()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, name)
	if event == "PLAYER_LOGIN" or name == "Blizzard_GroupFinder" then
		HookGroupFinder()
	end
end)
