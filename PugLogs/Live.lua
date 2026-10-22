-- Shows the companion's results in the Group Finder applicant tooltip.
--
-- Addons can't receive data from other programs while the game runs, but they can accept
-- text you paste. The companion keeps its results on the clipboard; open the paste box
-- (button on the applicant list, a key binding, or /pl paste) and press Cmd+V / Ctrl+V.
-- Format (one line, from companion/export.py):
--   PLR1;encounterID;keyLevel;dungeonName;record;record;...
--   record = name-realmslug,key,timed,seconds,dps,percent,interrupts,dispels,deaths,damageTaken,reason,
--            runSpec,specMismatch   (0 = same spec, 1 = other spec same role, 2 = different role)
--   (stats fields are empty when not loaded; "name-realmslug,0" = no logs in this dungeon,
--    "name-realmslug,0,hidden" = they hid their rankings on Warcraft Logs)
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
		elseif who == "!req" then
			data.request = f[2] -- the paste request these results answer
		elseif who and who ~= "" then
			local key = Num(f[2]) or 0
			data.players[who:lower()] = key == 0 and { none = true, hidden = f[3] == "hidden" } or {
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
			}
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
local MAX_RETRIES = 3

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
		SetHint(("Taking long - press %s to try, or click Copy for WoW in the PugLogs window."):format(PASTE_KEY), 1, 0.7, 0.3)
	end)
end

local function AskAgain(why)
	-- Once is usually something you copied; twice in a row means the companion isn't answering.
	if retries >= 1 then
		SetWarning(("No answer from the PugLogs app - is it running? Start it, then press %s again."):format(PASTE_KEY))
	end
	if retries >= MAX_RETRIES then
		SetHint(why .. (" Click Copy for WoW in the PugLogs window, then press %s."):format(PASTE_KEY), 1, 0.4, 0.3)
		return
	end
	retries = retries + 1
	ready = false
	SetHint(why .. " Getting the results again...", 1, 0.7, 0.3)
	StartFallback()
	ns.RequestCopy()
end

local function OnPasted(editBox)
	local text = strtrim(editBox:GetText() or "")
	if text == "" then
		return
	end
	editBox:SetText("")
	local data = Parse(text)
	if not data then
		-- Not PugLogs data. Show what arrived (start and length) so a report can say why.
		local preview = text:sub(1, 40):gsub("|", "||")
		ns.Print(("Paste box got %d characters that aren't PugLogs results, starting: %s"):format(#text, preview))
		if ready then
			AskAgain("That wasn't PugLogs results.")
		else
			SetHint(("Not ready yet - wait for \"Ready\", then press %s."):format(PASTE_KEY), 1, 0.7, 0.3)
		end
		return
	end
	-- Only accept the answer to this box's own request: anything else on the clipboard is
	-- older results (e.g. from a previous paste) and would hide newer applicants.
	local stale = data.request and ns.lastPasteRequest and data.request ~= ns.lastPasteRequest
	if not ready then
		SetHint(("Not ready yet - wait for \"Ready\", then press %s."):format(PASTE_KEY), 1, 0.7, 0.3)
		return
	end
	if stale then
		AskAgain("Those were older results.")
		return
	end
	SetWarning(nil)
	PugLogsDB.liveData = data -- also kept through /reload
	if ns.OnPanelChanged then
		ns.OnPanelChanged()
	end
	if ns.OnLiveResultsPasted then
		ns.OnLiveResultsPasted()
	end
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
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	tinsert(UISpecialFrames, "PugLogsPasteFrame")

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
	SetWarning(nil)
	SetHint("Getting the latest results...", 0.7, 0.7, 0.7)
	StartFallback()
	pasteFrame:Show()
	pasteFrame.editBox:SetFocus()
	ns.RequestCopy()
end

-- Progress of the paste box's request, from Transport.lua, so you can see where it is.
function ns.OnPasteRequestStatus(stage, codes)
	if not (pasteFrame and pasteFrame:IsShown()) or ready then
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
		SetHint("Couldn't send the request - is the PugLogs window running? Try again.", 1, 0.4, 0.3)
		return
	end
	SetHint("Waiting for the PugLogs window...", 0.7, 0.7, 0.7)
	-- The companion reads each code in turn before copying.
	readyTimer = C_Timer.NewTimer(COPY_TIME + 0.6 * (requestCodes - 1), function()
		readyTimer = nil
		ready = true
		SetHint(("Ready - press %s"):format(PASTE_KEY), 0.3, 1, 0.4)
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

-- The pasted run for a player ("Name-Realm"), if the pasted results are for the dungeon you're
-- listing now. Also used by the applicant panel (Panel.lua).
function ns.LiveEntry(fullName)
	local data = ns.LiveEnabled() and PugLogsDB.liveData
	local dungeon = ns.GetListingDungeon()
	if not (data and fullName and dungeon and dungeon.wclEncounterID == data.encounterID) then
		return nil
	end
	local name, realm = ns.SplitNameRealm(fullName)
	return data.players[(name .. "-" .. ns.GetRealmSlug(realm)):lower()]
end

local function AddApplicantLines(applicantID, memberIdx)
	local dungeon = ns.GetListingDungeon()
	if not dungeon then
		return
	end
	local fullName = Clean(C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx))
	if not fullName then
		return
	end
	local reason = ns.ApplicantFilterReason(applicantID, memberIdx)
	if reason then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("PugLogs: filtered out (" .. reason .. ")", 0.6, 0.6, 0.6)
		GameTooltip:Show()
		return
	end
	-- Only show results for the dungeon you're listing now (and only with live lookups on).
	local data = ns.LiveEnabled() and PugLogsDB.liveData
	if not data or dungeon.wclEncounterID ~= data.encounterID then
		return
	end
	local name, realm = ns.SplitNameRealm(fullName)
	local entry = data.players[(name .. "-" .. ns.GetRealmSlug(realm)):lower()]

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("PugLogs - " .. data.dungeon, 0, 0.8, 1)
	if not entry then
		GameTooltip:AddLine("Not loaded yet - paste again from the PugLogs window.", 0.6, 0.6, 0.6)
	elseif entry.hidden then
		GameTooltip:AddLine("Logs hidden - they hid their rankings on Warcraft Logs.", 1, 0.7, 0.28, true)
	elseif entry.none then
		GameTooltip:AddLine("No logs in this dungeon this season.", 0.6, 0.6, 0.6)
	else
		local timeText = entry.seconds and ("%d:%02d"):format(math.floor(entry.seconds / 60), entry.seconds % 60) or "-"
		GameTooltip:AddDoubleLine(
			("+%d  %s %s"):format(entry.key, timeText, entry.timed and "|cff4ec36atimed|r" or "|cffe0624fover|r"),
			("|cff%s%s DPS (%d)|r"):format(PercentColor(entry.percent), FormatNumber(entry.dps), math.floor(entry.percent or 0)),
			1, 1, 1, 1, 1, 1)
		AddSpecLine(entry, applicantID, memberIdx)
		if entry.reason and entry.reason ~= "" then
			GameTooltip:AddLine(entry.reason, 0.6, 0.6, 0.6)
		end
	end
	GameTooltip:Show()
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
