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
-- "subtle" (default): dark grey on near-black. "classic": black on white. /pl qr subtle|classic
-- module = screen pixels per QR square (2 survives JPG screenshots).
local STYLES = {
	subtle = { background = 0.05, squares = 0.11, module = 2 },
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

-- specID -> its position within the class (1-4), the order the companion knows spec names in.
local specPosition
local function SpecPosition(specID)
	if not specPosition then
		specPosition = {}
		for classID = 1, 13 do
			local count = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
				and C_SpecializationInfo.GetNumSpecializationsForClassID(classID) or 0
			for index = 1, count do
				local id = GetSpecializationInfoForClassID(classID, index)
				if id then
					specPosition[id] = index
				end
			end
		end
	end
	return specID and specPosition[specID] or 0
end

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
		local numMembers = Clean(info and info.numMembers) or 0
		-- A group with any filtered player is left out as a whole, like the Group Finder list
		-- hides it (Filters.lua); otherwise its other players would show up in the window alone.
		local groupFiltered = false
		for memberIdx = 1, numMembers do
			if ns.ApplicantFilterReason(applicantID, memberIdx) then
				groupFiltered = true
				break
			end
		end
		if (status == "applied" or status == "invited") and groupFiltered then
			filtered = filtered + numMembers -- not sent, so never looked up
		elseif status == "applied" or status == "invited" then
			for memberIdx = 1, numMembers do
				local fullName, classFile, _, _, itemLevel, _, _, _, _, assignedRole, _, score, _, _, _, specID =
					C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
				fullName, classFile = Clean(fullName), Clean(classFile)
				itemLevel, score = math.floor(Clean(itemLevel) or 0), math.floor(Clean(score) or 0)
				assignedRole = Clean(assignedRole)
				if fullName and classFile then
					local name, realm = ns.SplitNameRealm(fullName)
					lines[#lines + 1] = table.concat({
						index, name, ns.GetRealmSlug(realm), CLASS_IDS[classFile] or 0,
						ROLE_CODES[assignedRole or ""] or "", itemLevel, score, SpecPosition(Clean(specID)),
					}, "\t")
				end
			end
		end
	end
	return dungeon, lines, filtered
end

local function BuildPages(dungeon, lines, filtered, flags)
	batchCounter = batchCounter + 1
	local batch = GetServerTime() .. "-" .. batchCounter
	if flags == "R" then
		ns.lastPasteRequest = batch -- the companion sends it back with the results
	end
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
		local header = table.concat({ "PL2", batch, i, #chunks, ns.REGION, encounterID, keyLevel, dungeonName, flags or "", filtered or 0 }, "\t")
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

-- Paste-request tracing in chat, for bug reports: /pl debug on|off (off by default).
local function Trace(text)
	if PugLogsDB and PugLogsDB.debugPaste then
		ns.Print("|cff888888[paste] " .. text .. "|r")
	end
end
local lastProgressAt -- GetTime() when the running capture last drew a code
local pagesFlag -- request flag carried by the running capture ("R" = paste box), if any
local STALE_AFTER = FAILSAFE + 3

-- delivered: every screenshot of this capture was saved (so the companion can read it now).
local function FinishCapture(delivered)
	local flag = pagesFlag
	pagesFlag = nil
	if flag == "R" then
		Trace(delivered and "request screenshot(s) saved" or "request capture ended WITHOUT saving")
	end
	pages, pageIndex = nil, 0
	if flag == "R" and ns.OnPasteRequestDone then
		-- Tell the paste box whether its request reached the screenshot folder.
		C_Timer.After(0, function() pcall(ns.OnPasteRequestDone, delivered) end)
	end
	if queuedRequest then
		local flag = queuedRequest
		queuedRequest = nil
		if flag == "R" then
			Trace("update finished - sending the waiting request")
		end
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

-- Screenshot settings for a capture; restored by FinishCapture. Ordinary JPG screenshots at
-- the highest quality: the faint 2-pixel code survives them, and they are small (lossless TGA
-- screenshots are ~40 MB at 5K and made the game stutter).
local function BeginCapture()
	lastProgressAt = GetTime() -- a capture that stalls even before drawing is still cleared
	savedQuality = GetCVar("screenshotQuality")
	SetCVar("screenshotQuality", "10")
	style = (PugLogsDB.qrStyle == "classic") and STYLES.classic or STYLES.subtle
end

-- Takes the screenshot after the code has been drawn for a couple of frames, then hides the
-- code on the very next frame (WoW captures the frame on screen when Screenshot() is called;
-- saving the file afterwards can take a while, and the code needn't stay up for that).
local awaitingShot = false
-- WoW names screenshots by the second (WoWScrnShot_MMDDYY_HHMMSS), so a second screenshot in
-- the same second overwrites the first - and that QR code is lost. One screenshot per second.
local lastShotSecond
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
	if time() == lastShotSecond then
		return -- wait for the next second, so this screenshot gets its own file name
	end
	lastShotSecond = time()
	-- Mark that we're waiting before asking: WoW can report the screenshot during the call.
	awaitingShot = true
	self.shotTaken = true
	local shotOK, err = pcall(Screenshot)
	if not shotOK then
		awaitingShot = false
		self:Hide()
		ns.Print("Screenshot failed: " .. tostring(err))
		return
	end
	if verbose then
		ns.Print("Screenshot requested.")
	end
end)

local function CaptureNextPage()
	pageIndex = pageIndex + 1
	local text = pages and pages[pageIndex]
	if not text then
		FinishCapture(true)
		return
	end
	local ok, matrix = ns.qrcode(text, EC_LEVEL)
	if not ok then
		ns.Print("Could not build QR code: " .. tostring(matrix))
		FinishCapture()
		return
	end
	lastProgressAt = GetTime()
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

-- A capture that hasn't moved for a while (e.g. WoW never reported its screenshot) is
-- abandoned, so it can't block later updates and paste requests forever.
-- dropQueued: the caller is a request about to be sent itself, so a waiting one isn't needed.
local function ClearStaleCapture(dropQueued)
	if pages and lastProgressAt and GetTime() - lastProgressAt > STALE_AFTER then
		if qrFrame then
			qrFrame:Hide()
		end
		frameWaiter:Hide()
		awaitingShot = false
		if dropQueued then
			queuedRequest = nil
		end
		FinishCapture() -- sends a still-waiting request right after
	end
end

function SendNow(force)
	pendingTimer = nil
	ClearStaleCapture()
	if pages then
		return -- a capture is already running; the next change will trigger another
	end
	if not ns.LiveActive() then
		return -- live lookups off, or you can't invite: never take screenshots
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
events:RegisterEvent("PARTY_LEADER_CHANGED") -- becoming leader or assistant starts the updates
events:RegisterEvent("GROUP_ROSTER_UPDATE")
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

-- Sends a request to the companion:
--   "R" = put the results on the clipboard (the paste box). It carries the current applicant
--         list, so players who applied a moment ago are looked up before the copy.
--   "S" = show the API key page (one tiny code, no players).
function ns.SendRequest(flag)
	if flag == "R" then
		Trace(("request: pages=%s waiting=%s live=%s"):format(tostring(pages and #pages), tostring(queuedRequest),
			tostring(ns.LiveEnabled())))
	end
	ClearStaleCapture(true)
	if not ns.LiveEnabled() then
		ns.Print("Live lookups with the PugLogs app are off - turn them on in /pl opt.")
		return
	end
	if pages then
		queuedRequest = flag -- sent right after the running capture
		if flag == "R" then
			Trace("busy with an update - request waits for it")
		end
		if flag == "R" and ns.OnPasteRequestStatus then
			pcall(ns.OnPasteRequestStatus, "queued")
		end
		return
	end
	if not CanCapture() then
		ns.Print("Can't reach the PugLogs window in combat or during a key - try again after.")
		Trace("not sent: in combat or a key")
		if flag == "R" and ns.OnPasteRequestDone then
			pcall(ns.OnPasteRequestDone, false)
		end
		return
	end
	local dungeon, lines, filtered
	if flag == "R" then
		dungeon, lines, filtered = CollectApplicants()
	end
	if dungeon then
		lastSignature = (dungeon.name or "-") .. "\n" .. filtered .. "\n" .. table.concat(lines, "\n")
		pages = BuildPages(dungeon, lines, filtered, flag)
	else
		batchCounter = batchCounter + 1
		local batch = "req-" .. GetServerTime() .. "-" .. batchCounter
		if flag == "R" then
			ns.lastPasteRequest = batch
		end
		pages = { table.concat({ "PL2", batch, 1, 1, ns.REGION, 0, 0, "", flag }, "\t") }
	end
	pagesFlag = flag
	pageIndex = 0
	if flag == "R" then
		Trace(("sending %d code(s), id %s, %d player(s)"):format(#pages, tostring(ns.lastPasteRequest), #(lines or {})))
		if ns.OnPasteRequestStatus then
			pcall(ns.OnPasteRequestStatus, "sending", #pages)
		end
	end
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
	elseif msg == "debug on" or msg == "debug off" then
		PugLogsDB.debugPaste = (msg == "debug on")
		ns.Print("Paste debug lines " .. (PugLogsDB.debugPaste and "on." or "off."))
		return true
	elseif msg == "test" then
		ClearStaleCapture(true)
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
