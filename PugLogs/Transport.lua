-- Sends your applicants to the PugLogs companion on your computer.
--
-- Addons can't talk to other programs, so when the applicant list changes we briefly
-- draw a QR code in the top-left corner and take a normal screenshot. The companion
-- watches the Screenshots folder, reads the code and deletes the screenshot.
-- Format: see companion/payload.py.
local _, ns = ...

local QUIET_ZONE = 4       -- white border, in squares
local MAX_PAGE_BYTES = 350 -- keeps each code small; big queues use several codes in a row
local DEBOUNCE = 1.5       -- seconds to wait for more applicant changes before capturing
local EC_LEVEL = 2         -- QR error correction level M
local SETTLE_FRAMES = 2    -- rendered frames the code is on screen before the screenshot
-- "subtle" (default): dark grey on near-black, needs lossless (TGA) screenshots while the code
-- is up. "classic": black on white, works with any screenshot format. /pl qr subtle|classic
-- module = screen pixels per QR square: 1 needs a lossless screenshot; 2 survives JPG.
local STYLES = {
	subtle = { background = 0.05, squares = 0.11, module = 1 },
	classic = { background = 1, squares = 0, module = 2 },
}
local FAILSAFE = 4         -- give up on a capture if WoW doesn't report the screenshot

local qrFrame
local texturePool = {}
local usedTextures = 0
local pages, pageIndex = nil, 0
local lastSignature
local savedQuality, savedFormat
local style = STYLES.classic
local pendingTimer
local batchCounter = 0
local failsafeTimer
local verbose = false       -- /pl test prints each step

-- QR drawing -------------------------------------------------------------------

local function CreateQRFrame()
	local frame = CreateFrame("Frame", "PugLogsQRFrame", UIParent)
	frame:SetFrameStrata("TOOLTIP")
	frame:SetFrameLevel(9999)
	frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	frame:Hide()
	frame.bg = frame:CreateTexture(nil, "BACKGROUND")
	frame.bg:SetAllPoints()
	return frame
end

local function GetTexture()
	usedTextures = usedTextures + 1
	local tex = texturePool[usedTextures]
	if not tex then
		tex = qrFrame:CreateTexture(nil, "ARTWORK")
		texturePool[usedTextures] = tex
	end
	tex:SetColorTexture(style.squares, style.squares, style.squares, 1)
	tex:Show()
	return tex
end

local function DrawMatrix(matrix)
	qrFrame = qrFrame or CreateQRFrame()
	for i = 1, usedTextures do
		texturePool[i]:Hide()
	end
	usedTextures = 0

	local n = #matrix
	local _, physicalHeight = GetPhysicalScreenSize()
	-- At a render scale below 100% the screenshot has fewer pixels than the screen, so make
	-- the squares bigger to keep style.module real pixels each.
	local renderScale = tonumber(GetCVar("renderScale")) or 1
	local pixels = math.ceil(style.module / math.min(1, math.max(renderScale, 0.25)))
	local unit = pixels * UIParent:GetHeight() / physicalHeight -- one square, in UI units
	qrFrame:SetSize((n + 2 * QUIET_ZONE) * unit, (n + 2 * QUIET_ZONE) * unit)

	-- One texture per horizontal run of black squares keeps the texture count low.
	for y = 1, n do
		local x = 1
		while x <= n do
			if matrix[x][y] > 0 then
				local start = x
				while x <= n and matrix[x][y] > 0 do
					x = x + 1
				end
				local tex = GetTexture()
				tex:ClearAllPoints()
				tex:SetPoint("TOPLEFT", qrFrame, "TOPLEFT", (QUIET_ZONE + start - 1) * unit, -(QUIET_ZONE + y - 1) * unit)
				tex:SetSize((x - start) * unit, unit)
			else
				x = x + 1
			end
		end
	end
end

-- Short codes keep the QR small; the companion turns them back into names.
local CLASS_IDS = {
	WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7,
	MAGE = 8, WARLOCK = 9, MONK = 10, DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}
local ROLE_CODES = { TANK = "T", HEALER = "H", DAMAGER = "D" }

-- Collecting applicants ----------------------------------------------------------

local function Clean(value)
	if value == nil or ns.IsSecret(value) then
		return nil
	end
	return value
end

local function GetListingKeyLevel(dungeon)
	if dungeon and ns.GetKeystoneDungeon() == dungeon then
		local ok, level = pcall(C_MythicPlus.GetOwnedKeystoneLevel)
		if ok and Clean(level) then
			return level
		end
	end
	return 0
end

-- Returns the listing's dungeon, one line per applicant member who passes your filters,
-- and how many were filtered out.
local function CollectApplicants()
	local dungeon = C_LFGList.GetActiveEntryInfo() and ns.GetListingDungeon()
	if not dungeon then
		return nil, {}, 0
	end
	local lines, filtered = {}, 0
	local applicants = C_LFGList.GetApplicants() or {}
	for index, applicantID in ipairs(applicants) do
		local info = C_LFGList.GetApplicantInfo(applicantID)
		local status = info and Clean(info.applicationStatus)
		if status == "applied" or status == "invited" then
			for memberIdx = 1, (Clean(info.numMembers) or 0) do
				local fullName, classFile, _, _, itemLevel, _, _, _, _, assignedRole, _, score =
					C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
				fullName, classFile = Clean(fullName), Clean(classFile)
				itemLevel, score = math.floor(Clean(itemLevel) or 0), math.floor(Clean(score) or 0)
				assignedRole = Clean(assignedRole)
				if fullName and classFile then
					local reason = ns.ApplicantFilterReason(applicantID, memberIdx)
					if reason then
						filtered = filtered + 1 -- not sent, so never looked up
					else
						local name, realm = ns.SplitNameRealm(fullName)
						lines[#lines + 1] = table.concat({
							index, name, ns.GetRealmSlug(realm), CLASS_IDS[classFile] or 0,
							ROLE_CODES[assignedRole or ""] or "", itemLevel, score,
						}, "\t")
					end
				end
			end
		end
	end
	return dungeon, lines, filtered
end

local function BuildPages(dungeon, lines, filtered)
	batchCounter = batchCounter + 1
	local batch = GetServerTime() .. "-" .. batchCounter
	local encounterID = dungeon and dungeon.wclEncounterID or 0
	local keyLevel = GetListingKeyLevel(dungeon)
	local dungeonName = dungeon and dungeon.name or ""

	local chunks, current, size = {}, {}, 0
	for _, line in ipairs(lines) do
		if size + #line + 1 > MAX_PAGE_BYTES - 60 and #current > 0 then
			chunks[#chunks + 1] = current
			current, size = {}, 0
		end
		current[#current + 1] = line
		size = size + #line + 1
	end
	chunks[#chunks + 1] = current

	local result = {}
	for i, chunk in ipairs(chunks) do
		-- 9th field: flags ("R" = copy request), 10th: how many applicants your filters hid
		local header = table.concat({ "PL2", batch, i, #chunks, ns.REGION, encounterID, keyLevel, dungeonName, "", filtered or 0 }, "\t")
		result[i] = header .. (#chunk > 0 and ("\n" .. table.concat(chunk, "\n")) or "")
	end
	return result
end

-- Capturing ------------------------------------------------------------------------

local function CanCapture()
	if InCombatLockdown() then
		return false
	end
	local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
	return not (ok and active)
end

local SendNow
local queuedRequest -- a request flag waiting for the running capture to finish

local function FinishCapture()
	pages, pageIndex = nil, 0
	if queuedRequest then
		local flag = queuedRequest
		queuedRequest = nil
		C_Timer.After(0.2, function() ns.SendRequest(flag) end)
	end
	verbose = false
	if failsafeTimer then
		failsafeTimer:Cancel()
		failsafeTimer = nil
	end
	if savedQuality then
		SetCVar("screenshotQuality", savedQuality)
		savedQuality = nil
	end
	if savedFormat then
		SetCVar("screenshotFormat", savedFormat)
		savedFormat = nil
	end
end

-- Screenshot settings for a capture; restored by FinishCapture. The subtle style needs a
-- lossless format - if WoW won't switch to TGA, use the classic black-and-white code.
local function BeginCapture()
	savedQuality = GetCVar("screenshotQuality")
	SetCVar("screenshotQuality", "10")
	style = STYLES.classic
	if (PugLogsDB.qrStyle or "subtle") == "subtle" then
		savedFormat = GetCVar("screenshotFormat")
		SetCVar("screenshotFormat", "tga")
		if GetCVar("screenshotFormat") == "tga" then
			style = STYLES.subtle
		end
	end
end

-- Takes the screenshot after the code has been drawn for a couple of frames, then hides the
-- code on the very next frame (WoW captures the frame on screen when Screenshot() is called;
-- saving the file afterwards can take a while, and the code needn't stay up for that).
local awaitingShot = false
local frameWaiter = CreateFrame("Frame")
frameWaiter:Hide()
frameWaiter:SetScript("OnUpdate", function(self)
	self.frames = self.frames + 1
	if self.shotTaken then
		self:Hide()
		qrFrame:Hide()
		return
	end
	if self.frames < SETTLE_FRAMES then
		return
	end
	local shotOK, err = pcall(Screenshot)
	if not shotOK then
		self:Hide()
		ns.Print("Screenshot failed: " .. tostring(err))
		return
	end
	self.shotTaken = true
	awaitingShot = true
	if verbose then
		ns.Print("Screenshot requested.")
	end
end)

local function CaptureNextPage()
	pageIndex = pageIndex + 1
	local text = pages and pages[pageIndex]
	if not text then
		FinishCapture()
		return
	end
	local ok, matrix = ns.qrcode(text, EC_LEVEL)
	if not ok then
		ns.Print("Could not build QR code: " .. tostring(matrix))
		FinishCapture()
		return
	end
	DrawMatrix(matrix)
	qrFrame.bg:SetColorTexture(style.background, style.background, style.background, 1)
	qrFrame:Show()
	if verbose then
		ns.Print(("Showing QR code %d/%d (%d squares)."):format(pageIndex, #pages, #matrix))
	end
	-- Wait until the code has actually been drawn before the screenshot is taken.
	frameWaiter.frames = 0
	frameWaiter.shotTaken = false
	frameWaiter:Show()
	-- Never leave a capture hanging if the screenshot doesn't report back.
	failsafeTimer = C_Timer.NewTimer(FAILSAFE, function()
		failsafeTimer = nil
		if qrFrame:IsShown() or awaitingShot then
			qrFrame:Hide()
			frameWaiter:Hide()
			awaitingShot = false
			ns.Print("No screenshot was taken, so the window wasn't updated. Try /pl test.")
			FinishCapture()
		end
	end)
end

function SendNow(force)
	pendingTimer = nil
	if pages then
		return -- a capture is already running; the next change will trigger another
	end
	if not ns.LiveEnabled() then
		return -- live lookups are off: never take screenshots
	end
	if not CanCapture() then
		return -- retried when combat ends
	end
	local dungeon, lines, filtered = CollectApplicants()
	local signature = (dungeon and dungeon.name or "-") .. "\n" .. filtered .. "\n" .. table.concat(lines, "\n")
	if signature == lastSignature and not force then
		return
	end
	if not dungeon and lastSignature == nil and not force then
		return -- nothing listed and nothing sent yet
	end
	lastSignature = signature
	pages = BuildPages(dungeon, lines, filtered)
	pageIndex = 0
	BeginCapture()
	CaptureNextPage()
end

local function ScheduleSend()
	if pendingTimer then
		pendingTimer:Cancel()
	end
	pendingTimer = C_Timer.NewTimer(DEBOUNCE, function() SendNow(false) end)
end

-- Events ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("LFG_LIST_APPLICANT_LIST_UPDATED")
events:RegisterEvent("LFG_LIST_APPLICANT_UPDATED")
events:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SCREENSHOT_SUCCEEDED")
events:RegisterEvent("SCREENSHOT_FAILED")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == "PugLogs" then
			PugLogsDB = PugLogsDB or {} -- the live default is decided at login (Core.lua)
		end
	elseif event == "SCREENSHOT_SUCCEEDED" or event == "SCREENSHOT_FAILED" then
		if pages and awaitingShot then
			awaitingShot = false
			if failsafeTimer then
				failsafeTimer:Cancel()
				failsafeTimer = nil
			end
			qrFrame:Hide()
			if verbose then
				ns.Print(event == "SCREENSHOT_SUCCEEDED" and "Screenshot saved." or "WoW reported that the screenshot failed.")
			end
			if event == "SCREENSHOT_SUCCEEDED" then
				-- Hide the "Screen captured" message for our own screenshots.
				C_Timer.After(0, function()
					if ActionStatus and ActionStatus:IsShown() then
						ActionStatus:Hide()
					end
				end)
			end
			C_Timer.After(0.2, CaptureNextPage)
		end
	else
		ScheduleSend()
	end
end)

-- Slash commands, called from Core.lua --------------------------------------------

-- Live lookups turned on: send the current applicants right away.
ns.OnLiveChanged(function(on)
	if on then
		ScheduleSend()
	end
end)

-- Filters changed in the options: send the new (filtered) applicant list.
function ns.OnFiltersChanged()
	ScheduleSend()
end

-- Sends a request to the companion as one tiny code with no players:
--   "R" = put the results on the clipboard (the paste box), "S" = show the API key page.
function ns.SendRequest(flag)
	if not ns.LiveEnabled() then
		ns.Print("Live lookups with the PugLogs app are off - turn them on in /pl filters.")
		return
	end
	if pages then
		queuedRequest = flag -- sent right after the running capture
		return
	end
	if not CanCapture() then
		ns.Print("Can't reach the PugLogs window in combat or during a key - try again after.")
		return
	end
	batchCounter = batchCounter + 1
	pages = { table.concat({ "PL2", "req-" .. GetServerTime() .. "-" .. batchCounter, 1, 1, ns.REGION, 0, 0, "", flag }, "\t") }
	pageIndex = 0
	BeginCapture()
	CaptureNextPage()
end

function ns.RequestCopy()
	ns.SendRequest("R")
end

function ns.HandleLiveSlash(msg)
	if msg == "live on" or msg == "live off" then
		ns.SetLive(msg == "live on")
		ns.Print("Live lookups with the PugLogs app " .. (ns.LiveEnabled() and "on." or "off."))
		return true
	elseif msg == "live" then
		ns.Print("Live lookups with the PugLogs app are " .. (ns.LiveEnabled() and "on" or "off") .. ". Use /pl live on|off.")
		return true
	elseif msg == "send" then
		SendNow(true)
		return true
	elseif msg == "qr subtle" or msg == "qr classic" then
		PugLogsDB.qrStyle = msg:sub(4)
		ns.Print("QR style: " .. PugLogsDB.qrStyle .. (PugLogsDB.qrStyle == "subtle" and " (faint dark code)." or " (black and white)."))
		return true
	elseif msg == "wcl" or msg == "key" or msg == "setup" then
		ns.SendRequest("S")
		ns.Print("Opening the Warcraft Logs API key page in PugLogs. If nothing opens, start the PugLogs app first.")
		return true
	elseif msg == "test" then
		if pages then
			ns.Print("A capture is already running.")
			return true
		end
		verbose = true
		lastSignature = nil
		pages = { table.concat({ "PL2", "test-" .. GetServerTime(), 1, 1, ns.REGION, 0, 0, "" }, "\t") }
		pageIndex = 0
		BeginCapture()
		CaptureNextPage()
		return true
	end
	return false
end
