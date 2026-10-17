-- Settings panel (Options > AddOns > PugLogs, or /pl filters): live lookups on/off and applicant filters.
-- Applicants who don't match are never sent to the companion, so they are never looked
-- up and cost no API points. Their tooltip says why they were filtered out.
local _, ns = ...

local NUM_CLASSES = 13
local ROLE_NAMES = { TANK = "Tank", HEALER = "Healer", DAMAGER = "Damage" }
local ROLE_ORDER = { "TANK", "HEALER", "DAMAGER" }

local function Filters()
	PugLogsDB = PugLogsDB or {}
	PugLogsDB.filters = PugLogsDB.filters or {}
	local f = PugLogsDB.filters
	f.minItemLevel = f.minItemLevel or 0
	f.minRating = f.minRating or 0
	f.excludedRoles = f.excludedRoles or {}     -- role -> true
	f.excludedClasses = f.excludedClasses or {} -- classFile -> true
	f.excludedSpecs = f.excludedSpecs or {}     -- specID -> true
	if f.hideFiltered == nil then
		f.hideFiltered = true -- hide filtered applications from the Group Finder list
	end
	if f.inviteHidesSpec == nil then
		f.inviteHidesSpec = true -- after an invite, hide others with that spec (this listing only)
	end
	f.inviteHidesClass = f.inviteHidesClass or false
	return f
end

-- Returns nil if the applicant passes, or a short reason if filtered out.
-- applicant = { classFile, specID, role, itemLevel, rating }
function ns.FilterReason(applicant)
	local f = Filters()
	if f.minItemLevel > 0 and (applicant.itemLevel or 0) < f.minItemLevel then
		return ("item level %d < %d"):format(applicant.itemLevel or 0, f.minItemLevel)
	end
	if f.minRating > 0 and (applicant.rating or 0) < f.minRating then
		return ("rating %d < %d"):format(applicant.rating or 0, f.minRating)
	end
	if applicant.role and f.excludedRoles[applicant.role] then
		return (ROLE_NAMES[applicant.role] or applicant.role) .. " not wanted"
	end
	if applicant.classFile and f.excludedClasses[applicant.classFile] then
		return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[applicant.classFile] or applicant.classFile) .. " not wanted"
	end
	if applicant.specID and f.excludedSpecs[applicant.specID] then
		local _, specName = GetSpecializationInfoByID(applicant.specID)
		return (specName or "spec") .. " not wanted"
	end
	-- Rules from people you invited for this listing (never applied to the invitees themselves).
	if not applicant.invited and PugLogsDB.session then
		for _, inv in pairs(PugLogsDB.session.invited) do
			if f.inviteHidesSpec and inv.specID and inv.specID == applicant.specID then
				return ("you already invited a %s (%s)"):format(inv.label, inv.name)
			end
			if f.inviteHidesClass and inv.classFile and inv.classFile == applicant.classFile then
				return ("you already invited a %s (%s)"):format(inv.className, inv.name)
			end
		end
	end
	return nil
end

local function Clean(value)
	if value == nil or ns.IsSecret(value) then
		return nil
	end
	return value
end

-- Filter reason for one member of a Group Finder application (nil = passes).
local INVITED = { invited = true, inviteaccepted = true }

local function ApplicationStatus(applicantID)
	local info = C_LFGList.GetApplicantInfo(applicantID)
	return info and Clean(info.applicationStatus)
end

function ns.ApplicantFilterReason(applicantID, memberIdx)
	local _, classFile, _, _, itemLevel, _, _, _, _, assignedRole, _, score, _, _, _, specID =
		C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
	return ns.FilterReason({
		classFile = Clean(classFile), specID = Clean(specID), role = Clean(assignedRole),
		itemLevel = math.floor(Clean(itemLevel) or 0), rating = math.floor(Clean(score) or 0),
		invited = INVITED[ApplicationStatus(applicantID)] or false,
	})
end

-- True if any member of the application is filtered out (you'd have to invite them all).
local function ApplicationFiltered(applicantID)
	local info = C_LFGList.GetApplicantInfo(applicantID)
	local numMembers = info and Clean(info.numMembers)
	for memberIdx = 1, numMembers or 0 do
		if ns.ApplicantFilterReason(applicantID, memberIdx) then
			return true
		end
	end
	return false
end

-- Hide filtered applications from the Group Finder list. Blizzard sorts the list right
-- after fetching it; we remove filtered entries from that same table afterwards.
local function HideFiltered(applicants)
	if type(applicants) ~= "table" or not Filters().hideFiltered or not ns.GetListingDungeon() then
		return
	end
	for i = #applicants, 1, -1 do
		local id = applicants[i]
		if not ns.IsSecret(id) and ApplicationFiltered(id) then
			table.remove(applicants, i)
		end
	end
end

local hooked = false
local function HookApplicantList()
	if not hooked and LFGListUtil_SortApplicants then
		hooksecurefunc("LFGListUtil_SortApplicants", HideFiltered)
		hooked = true
	end
end

-- Redraws the applicant list after the filters change.
local function RefreshApplicantList()
	local viewer = LFGListFrame and LFGListFrame.ApplicationViewer
	if viewer and viewer:IsVisible() and LFGListApplicationViewer_UpdateResultList then
		LFGListApplicationViewer_UpdateResultList(viewer)
		LFGListApplicationViewer_UpdateResults(viewer)
	end
end

-- A string that changes whenever the filters change (so applicants are re-sent).
function ns.FilterSignature()
	local f = Filters()
	local parts = { f.minItemLevel, f.minRating }
	for _, set in ipairs({ f.excludedRoles, f.excludedClasses, f.excludedSpecs }) do
		local keys = {}
		for k, v in pairs(set) do
			if v then keys[#keys + 1] = tostring(k) end
		end
		table.sort(keys)
		parts[#parts + 1] = table.concat(keys, ",")
	end
	return table.concat(parts, "|")
end

local function Changed()
	if ns.OnFiltersChanged then
		ns.OnFiltersChanged()
	end
	RefreshApplicantList()
end

-- Invites for this listing ---------------------------------------------------------
-- PugLogsDB.session.invited: "applicantID:memberIdx" -> { classFile, specID, name, label, className, accepted }

local function Session()
	PugLogsDB.session = PugLogsDB.session or { invited = {} }
	return PugLogsDB.session
end

local GONE = { declined = true, declined_full = true, declined_delisted = true, timedout = true,
	cancelled = true, invitedeclined = true, failed = true }

local function OnApplicantUpdated(applicantID)
	if applicantID == nil or ns.IsSecret(applicantID) or not ns.GetListingDungeon() then
		return
	end
	local f, session = Filters(), Session()
	local status = ApplicationStatus(applicantID)
	local info = C_LFGList.GetApplicantInfo(applicantID)
	local changed = false
	for memberIdx = 1, (info and Clean(info.numMembers)) or 0 do
		local key = tostring(applicantID) .. ":" .. memberIdx
		local entry = session.invited[key]
		if INVITED[status] then
			if not entry then
				local fullName, classFile, className, _, _, _, _, _, _, _, _, _, _, _, _, specID =
					C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
				fullName, classFile, specID = Clean(fullName), Clean(classFile), Clean(specID)
				if fullName and classFile then
					local specName
					if specID then
						specName = select(2, GetSpecializationInfoByID(specID))
					end
					className = Clean(className) or classFile
					entry = { classFile = classFile, specID = specID, className = className,
						name = (strsplit("-", fullName)), label = specName and (specName .. " " .. className) or className }
					session.invited[key] = entry
					changed = true
					local hiding = (f.inviteHidesClass and className) or (f.inviteHidesSpec and entry.label)
					if hiding then
						ns.Print(("Invited %s - hiding other %s applicants until you delist."):format(entry.name, hiding))
					end
				end
			end
			if entry and status == "inviteaccepted" then
				entry.accepted = true
			end
		elseif entry and not entry.accepted and GONE[status] then
			session.invited[key] = nil -- they declined or the invite expired
			changed = true
			ns.Print(("%s didn't join - showing %s applicants again."):format(entry.name, entry.label))
		end
	end
	if changed then
		Changed()
	end
end

local function OnListingChanged()
	if C_LFGList.GetActiveEntryInfo() then
		return
	end
	local session = PugLogsDB and PugLogsDB.session
	if session and next(session.invited) then
		ns.Print("Listing ended - spec/class hiding from invites is cleared.")
	end
	if PugLogsDB then
		PugLogsDB.session = nil
	end
	Changed()
end

-- Options panel ----------------------------------------------------------------------

local function NumSpecs(classID)
	if C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID then
		return C_SpecializationInfo.GetNumSpecializationsForClassID(classID) or 0
	end
	return GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID) or 0
end

local function CreateCheckbox(parent, label, checked, onClick)
	local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	box:SetSize(24, 24)
	box.text = box.text or box.Text or box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	box.text:ClearAllPoints()
	box.text:SetPoint("LEFT", box, "RIGHT", 2, 1)
	box.text:SetText(label)
	box:SetChecked(checked)
	box:SetScript("OnClick", function(self) onClick(self:GetChecked()) end)
	return box
end

local function CreateNumberBox(parent, label, value, onChange)
	local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetText(label)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(60, 20)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(5)
	box:SetPoint("LEFT", text, "RIGHT", 10, 0)
	box:SetText(value > 0 and tostring(value) or "")
	local function Save(self)
		onChange(tonumber(self:GetText()) or 0)
		self:ClearFocus()
	end
	box:SetScript("OnEnterPressed", Save)
	box:SetScript("OnEditFocusLost", function(self) onChange(tonumber(self:GetText()) or 0) end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	local hint = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("LEFT", box, "RIGHT", 8, 0)
	hint:SetText("(empty = any)")
	return text
end

local function BuildPanel(panel)
	local f = Filters()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("PugLogs")

	local live = CreateCheckbox(panel, "Live Warcraft Logs lookups with the PugLogs app", ns.LiveEnabled(), function(on)
		ns.SetLive(on)
	end)
	live:SetPoint("TOPLEFT", title, "BOTTOMLEFT", -4, -10)
	ns.OnLiveChanged(function(on) live:SetChecked(on) end)
	local liveNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	liveNote:SetPoint("TOPLEFT", live, "BOTTOMLEFT", 28, 0)
	liveNote:SetWidth(580)
	liveNote:SetJustifyH("LEFT")
	liveNote:SetText((ns.AppInstalled() and "The PugLogs app is installed. " or "The PugLogs app isn't installed (/pl app for the link). ")
		.. "Off: only \"Check logs\" and the filters below - no screenshots are taken.")

	local filtersTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	filtersTitle:SetPoint("TOPLEFT", liveNote, "BOTTOMLEFT", -24, -20)
	filtersTitle:SetText("Applicant filters")

	local intro = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	intro:SetPoint("TOPLEFT", filtersTitle, "BOTTOMLEFT", 0, -8)
	intro:SetWidth(600)
	intro:SetJustifyH("LEFT")
	intro:SetText("Applicants who don't match are hidden and never looked up on Warcraft Logs. "
		.. "Their tooltip says why they were filtered out.")

	local ilvl = CreateNumberBox(panel, "Minimum item level", f.minItemLevel, function(v)
		if v ~= f.minItemLevel then f.minItemLevel = v; Changed() end
	end)
	ilvl:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -20)

	local rating = CreateNumberBox(panel, "Minimum M+ rating", f.minRating, function(v)
		if v ~= f.minRating then f.minRating = v; Changed() end
	end)
	rating:SetPoint("TOPLEFT", ilvl, "BOTTOMLEFT", 0, -16)

	local hide = CreateCheckbox(panel, "Hide filtered applicants from the Group Finder list", f.hideFiltered, function(on)
		f.hideFiltered = on
		RefreshApplicantList()
	end)
	hide:SetPoint("TOPLEFT", rating, "BOTTOMLEFT", -4, -14)
	local hideNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hideNote:SetPoint("TOPLEFT", hide, "BOTTOMLEFT", 28, 0)
	hideNote:SetText("A group that applied together is hidden if any member doesn't match.")

	local inviteSpec = CreateCheckbox(panel, "When you invite someone, hide other applicants with the same spec",
		f.inviteHidesSpec, function(on) f.inviteHidesSpec = on; Changed() end)
	inviteSpec:SetPoint("TOPLEFT", hideNote, "BOTTOMLEFT", -28, -10)
	local inviteClass = CreateCheckbox(panel, "... or with the same class", f.inviteHidesClass,
		function(on) f.inviteHidesClass = on; Changed() end)
	inviteClass:SetPoint("TOPLEFT", inviteSpec, "BOTTOMLEFT", 0, -2)
	local inviteNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	inviteNote:SetPoint("TOPLEFT", inviteClass, "BOTTOMLEFT", 28, 0)
	inviteNote:SetText("Only for the current listing: undone if they decline, cleared when you delist.")

	local roleHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	roleHeader:SetPoint("TOPLEFT", inviteNote, "BOTTOMLEFT", -24, -16)
	roleHeader:SetText("Roles they applied as")
	local prev
	for i, role in ipairs(ROLE_ORDER) do
		local box = CreateCheckbox(panel, ROLE_NAMES[role], not f.excludedRoles[role], function(on)
			f.excludedRoles[role] = not on or nil
			Changed()
		end)
		if i == 1 then
			box:SetPoint("TOPLEFT", roleHeader, "BOTTOMLEFT", -4, -4)
		else
			box:SetPoint("LEFT", prev, "RIGHT", 90, 0)
		end
		prev = box
	end

	local classHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	classHeader:SetPoint("TOPLEFT", roleHeader, "BOTTOMLEFT", 0, -40)
	classHeader:SetText("Classes and specs")
	local classNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	classNote:SetPoint("LEFT", classHeader, "RIGHT", 10, 0)
	classNote:SetText("Spec = the spec they are in when applying, which can differ from what they'd play.")

	local anchor = classHeader
	for classID = 1, NUM_CLASSES do
		local className, classFile = GetClassInfo(classID)
		if classFile then
			local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
			local label = color and color:WrapTextInColorCode(className) or className
			local specBoxes = {}
			local classBox = CreateCheckbox(panel, label, not f.excludedClasses[classFile], function(on)
				f.excludedClasses[classFile] = not on or nil
				for _, b in ipairs(specBoxes) do
					b:SetEnabled(on)
				end
				Changed()
			end)
			classBox:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == classHeader and -4 or 0, -2)
			anchor = classBox

			local specPrev
			for index = 1, NumSpecs(classID) do
				local specID, specName = GetSpecializationInfoForClassID(classID, index)
				if specID then
					local box = CreateCheckbox(panel, specName, not f.excludedSpecs[specID], function(on)
						f.excludedSpecs[specID] = not on or nil
						Changed()
					end)
					box:SetPoint("LEFT", specPrev or classBox, "RIGHT", specPrev and 100 or 130, 0)
					box:SetEnabled(not f.excludedClasses[classFile])
					specBoxes[#specBoxes + 1] = box
					specPrev = box
				end
			end
		end
	end
end

local category
local panel = CreateFrame("Frame")
panel:Hide()
panel:SetScript("OnShow", function(self)
	if not self.built then
		BuildPanel(self)
		self.built = true
	end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("LFG_LIST_APPLICANT_UPDATED")
events:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "LFG_LIST_APPLICANT_UPDATED" then
		OnApplicantUpdated(arg1)
		return
	elseif event == "LFG_LIST_ACTIVE_ENTRY_UPDATE" then
		OnListingChanged()
		return
	end
	Filters()
	HookApplicantList()
	if not C_LFGList.GetActiveEntryInfo() then
		PugLogsDB.session = nil -- the listing ended while you were logged out
	end
	if Settings and Settings.RegisterCanvasLayoutCategory then
		category = Settings.RegisterCanvasLayoutCategory(panel, "PugLogs")
		Settings.RegisterAddOnCategory(category)
	end
end)

function ns.OpenFilters()
	if category and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	end
end
