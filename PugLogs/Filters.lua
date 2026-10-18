-- Settings panel (Options > AddOns > PugLogs, or /pl opt): live lookups on/off and applicant filters.
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
	if f.groupHidesSpec == nil then
		f.groupHidesSpec = true -- hide applicants whose spec is already in your group
	end
	f.groupHidesClass = f.groupHidesClass or false -- ... or whose class is
	f.sortBy = f.sortBy or "default" -- applicant list order: default, role, rating, log
	f.inviteHidesSpec, f.inviteHidesClass = nil, nil -- replaced by the group rules above
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
	-- Classes/specs already in your group (never applied to someone you've invited).
	if not applicant.invited then
		for _, member in ipairs(ns.groupMembers or {}) do
			if f.groupHidesClass and member.classFile == applicant.classFile then
				return ("a %s is already in your group (%s)"):format(member.className, member.name)
			end
			if f.groupHidesSpec and member.specID and member.specID == applicant.specID then
				return ("a %s is already in your group (%s)"):format(member.label, member.name)
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
local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }

-- Sort key for one application (lower sorts first); a group counts as its best member.
local function SortKey(applicantID, sortBy)
	local info = C_LFGList.GetApplicantInfo(applicantID)
	local data = PugLogsDB.liveData
	local dungeon = ns.GetListingDungeon()
	if data and not (dungeon and dungeon.wclEncounterID == data.encounterID) then
		data = nil -- results from another listing
	end
	local best
	for memberIdx = 1, (info and Clean(info.numMembers)) or 0 do
		local fullName, _, _, _, _, _, _, _, _, assignedRole, _, score = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
		local value
		if sortBy == "role" then
			value = ROLE_ORDER[Clean(assignedRole) or ""] or 4
		elseif sortBy == "rating" then
			value = -(Clean(score) or 0)
		else -- log: DPS percentile of their run, from the last paste
			value = 1
			fullName = Clean(fullName)
			if data and fullName then
				local name, realm = ns.SplitNameRealm(fullName)
				local entry = data.players[(name .. "-" .. ns.GetRealmSlug(realm)):lower()]
				if entry and entry.percent then
					value = -entry.percent
				end
			end
		end
		best = best and math.min(best, value) or value
	end
	return best or 99
end

-- Runs right after Blizzard sorts the applicant list: hide filtered applications, then
-- re-order the rest if a sort is chosen.
local function ProcessApplicants(applicants)
	if type(applicants) ~= "table" or not ns.GetListingDungeon() then
		return
	end
	local f = Filters()
	if f.hideFiltered then
		for i = #applicants, 1, -1 do
			local id = applicants[i]
			if not ns.IsSecret(id) and ApplicationFiltered(id) then
				table.remove(applicants, i)
			end
		end
	end
	if f.sortBy ~= "default" then
		local keys, order = {}, {}
		for i, id in ipairs(applicants) do
			if ns.IsSecret(id) then
				return -- can't read them right now: keep Blizzard's order
			end
			keys[id], order[id] = SortKey(id, f.sortBy), i
		end
		table.sort(applicants, function(a, b)
			if keys[a] ~= keys[b] then
				return keys[a] < keys[b]
			end
			return order[a] < order[b]
		end)
	end
end

local hooked = false
local function HookApplicantList()
	if not hooked and LFGListUtil_SortApplicants then
		hooksecurefunc("LFGListUtil_SortApplicants", ProcessApplicants)
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

-- Sets the applicant list order ("default", "role", "rating" or "log").
function ns.SetSort(value)
	Filters().sortBy = value
	if ns.OnSortChanged then
		ns.OnSortChanged(value)
	end
	RefreshApplicantList()
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

-- Your group ---------------------------------------------------------------------------
-- ns.groupMembers: who is in your group (you included), with class and - when known - spec.
-- Other players' specs come from what they applied with (remembered when you invite them)
-- or from inspecting them in the background (WoW only reveals specs after an inspect).

ns.groupMembers = {}
local knownSpecs = {} -- "name-realm" (lowercase) -> specID
local inspectQueue = {}
local inspectBusy = false

local function MemberKey(name, realm)
	return (name .. "-" .. ((realm and realm ~= "") and realm or (GetNormalizedRealmName() or ""))):lower()
end

local function SpecLabel(specID, className)
	local specName = specID and select(2, GetSpecializationInfoByID(specID))
	return specName and (specName .. " " .. className) or className
end

-- When you invite someone, remember the spec they applied with.
local INVITED_OR_JOINED = { invited = true, inviteaccepted = true }
local function OnApplicantUpdated(applicantID)
	if applicantID == nil or ns.IsSecret(applicantID) or not INVITED_OR_JOINED[ApplicationStatus(applicantID)] then
		return
	end
	local info = C_LFGList.GetApplicantInfo(applicantID)
	for memberIdx = 1, (info and Clean(info.numMembers)) or 0 do
		local fullName, _, _, _, _, _, _, _, _, _, _, _, _, _, _, specID = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
		fullName, specID = Clean(fullName), Clean(specID)
		if fullName and specID and specID > 0 then
			local name, realm = ns.SplitNameRealm(fullName)
			knownSpecs[MemberKey(name, realm)] = specID
		end
	end
end

local function UnitSpecID(unit, key)
	if UnitIsUnit(unit, "player") then
		local index = GetSpecialization and GetSpecialization()
		return index and (GetSpecializationInfo(index)) or nil
	end
	local inspected = GetInspectSpecialization and GetInspectSpecialization(unit)
	if inspected and not ns.IsSecret(inspected) and inspected > 0 then
		knownSpecs[key] = inspected
	end
	return knownSpecs[key]
end

local RebuildGroup

local function InspectNext()
	if inspectBusy or InCombatLockdown() then
		return
	end
	local unit = table.remove(inspectQueue, 1)
	if not unit then
		return
	end
	if UnitExists(unit) and CanInspect(unit) then
		inspectBusy = true
		NotifyInspect(unit)
		C_Timer.After(2, function() -- don't wait forever for INSPECT_READY
			if inspectBusy then
				inspectBusy = false
				InspectNext()
			end
		end)
	else
		InspectNext()
	end
end

function RebuildGroup()
	local members, before = {}, {}
	for _, m in ipairs(ns.groupMembers) do
		before[m.key] = m
	end
	local units = { "player" }
	if not IsInRaid() then
		for i = 1, GetNumSubgroupMembers() do
			units[#units + 1] = "party" .. i
		end
	end
	for _, unit in ipairs(units) do
		if UnitExists(unit) then
			local name, realm = UnitName(unit)
			local className, classFile = UnitClass(unit)
			name, realm, className, classFile = Clean(name), Clean(realm), Clean(className), Clean(classFile)
			if name and classFile then
				local key = MemberKey(name, realm)
				local specID = UnitSpecID(unit, key)
				members[#members + 1] = { key = key, name = name, classFile = classFile, className = className,
					specID = specID, label = SpecLabel(specID, className) }
				if not specID and unit ~= "player" then
					inspectQueue[#inspectQueue + 1] = unit
				end
			end
		end
	end
	ns.groupMembers = members

	-- Tell what changed (while listing a key), then refresh the applicant list.
	local f, changed, now = Filters(), false, {}
	local me = MemberKey(UnitName("player"))
	for _, m in ipairs(members) do
		now[m.key] = m
		local old = before[m.key]
		if not old or old.specID ~= m.specID then
			changed = true
			-- Announce once we know what gets hidden: their class, or their spec once it's known.
			local hiding = (f.groupHidesClass and (not old) and m.className)
				or (f.groupHidesSpec and not f.groupHidesClass and m.specID and m.label)
			if hiding and m.key ~= me and ns.GetListingDungeon() then
				ns.Print(("%s is in your group - hiding other %s applicants."):format(m.name, hiding))
			end
		end
	end
	for key, m in pairs(before) do
		if not now[key] then
			changed = true
			if ns.GetListingDungeon() and (f.groupHidesSpec or f.groupHidesClass) then
				ns.Print(("%s left - showing %s applicants again."):format(m.name, f.groupHidesClass and m.className or m.label))
			end
		end
	end
	if changed then
		Changed()
	end
	InspectNext()
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

	local leaderOnly = CreateCheckbox(panel, "Only while I can invite (group leader or assistant)",
		PugLogsDB.liveLeaderOnly ~= false, function(on) PugLogsDB.liveLeaderOnly = on end)
	leaderOnly:SetPoint("TOPLEFT", liveNote, "BOTTOMLEFT", -28, -8)
	local leaderNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	leaderNote:SetPoint("TOPLEFT", leaderOnly, "BOTTOMLEFT", 28, 0)
	leaderNote:SetText("As a group member PugLogs then stays quiet: no screenshots, no Warcraft Logs lookups.")

	local filtersTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	filtersTitle:SetPoint("TOPLEFT", leaderNote, "BOTTOMLEFT", -24, -20)
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

	local groupSpec = CreateCheckbox(panel, "Hide applicants whose spec is already in your group",
		f.groupHidesSpec, function(on) f.groupHidesSpec = on; Changed() end)
	groupSpec:SetPoint("TOPLEFT", hideNote, "BOTTOMLEFT", -28, -10)
	local groupClass = CreateCheckbox(panel, "... or whose class is already in your group", f.groupHidesClass,
		function(on) f.groupHidesClass = on; Changed() end)
	groupClass:SetPoint("TOPLEFT", groupSpec, "BOTTOMLEFT", 0, -2)
	local inviteNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	inviteNote:SetPoint("TOPLEFT", groupClass, "BOTTOMLEFT", 28, 0)
	inviteNote:SetText("Includes you. Updates as people join or leave - someone who declines your invite never counts.")

	local sortHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	sortHeader:SetPoint("TOPLEFT", inviteNote, "BOTTOMLEFT", -24, -16)
	sortHeader:SetText("Sort the applicant list by")
	local sortBoxes, sortPrev = {}, nil
	for _, option in ipairs({ { "default", "Blizzard's order" }, { "role", "Role" }, { "rating", "M+ rating" }, { "log", "Log (after Paste logs)" } }) do
		local value, label = option[1], option[2]
		local box = CreateCheckbox(panel, label, f.sortBy == value, function()
			ns.SetSort(value)
		end)
		if sortPrev then
			box:SetPoint("LEFT", sortPrev, "RIGHT", 130, 0)
		else
			box:SetPoint("TOPLEFT", sortHeader, "BOTTOMLEFT", -4, -4)
		end
		sortBoxes[value], sortPrev = box, box
	end
	ns.OnSortChanged = function(value)
		for v, box in pairs(sortBoxes) do
			box:SetChecked(v == value)
		end
	end

	local roleHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	roleHeader:SetPoint("TOPLEFT", sortHeader, "BOTTOMLEFT", 0, -40)
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

	-- Select all / Clear all for every class and spec at once.
	local rows = {} -- { box, classFile, specs = { { box, specID } } }
	local function SetAll(on)
		for _, row in ipairs(rows) do
			f.excludedClasses[row.classFile] = not on or nil
			row.box:SetChecked(on)
			for _, spec in ipairs(row.specs) do
				f.excludedSpecs[spec.specID] = not on or nil
				spec.box:SetChecked(on)
				spec.box:SetEnabled(on)
			end
		end
		Changed()
	end
	local selectAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	selectAll:SetSize(100, 22)
	selectAll:SetText("Select all")
	selectAll:SetPoint("TOPLEFT", classHeader, "BOTTOMLEFT", 0, -6)
	selectAll:SetScript("OnClick", function() SetAll(true) end)
	local clearAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	clearAll:SetSize(100, 22)
	clearAll:SetText("Clear all")
	clearAll:SetPoint("LEFT", selectAll, "RIGHT", 8, 0)
	clearAll:SetScript("OnClick", function() SetAll(false) end)

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
			classBox:SetPoint("TOPLEFT", anchor == classHeader and selectAll or anchor, "BOTTOMLEFT",
				anchor == classHeader and -4 or 0, anchor == classHeader and -6 or -2)
			anchor = classBox
			local row = { box = classBox, classFile = classFile, specs = {} }
			rows[#rows + 1] = row

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
					row.specs[#row.specs + 1] = { box = box, specID = specID }
					specPrev = box
				end
			end
		end
	end
	return anchor -- the lowest element, used to size the scrollable area
end

local category
local panel = CreateFrame("Frame")
panel:Hide()
panel:SetScript("OnShow", function(self)
	if self.built then
		return
	end
	self.built = true
	-- The page is taller than the Options window, so it scrolls inside it.
	local scroll = CreateFrame("ScrollFrame", nil, self, "ScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, -2)
	scroll:SetPoint("BOTTOMRIGHT", -24, 2)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(math.max(scroll:GetWidth(), 600), 1)
	scroll:SetScrollChild(content)
	local last = BuildPanel(content)
	-- Size the content to what was drawn once the layout is known.
	C_Timer.After(0, function()
		local top, bottom = content:GetTop(), last:GetBottom()
		content:SetHeight(top and bottom and (top - bottom + 20) or 1000)
	end)
	scroll:SetScript("OnSizeChanged", function(_, width)
		content:SetWidth(math.max(width, 600))
	end)
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("LFG_LIST_APPLICANT_UPDATED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
events:RegisterEvent("INSPECT_READY")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "LFG_LIST_APPLICANT_UPDATED" then
		OnApplicantUpdated(arg1)
		return
	elseif event == "INSPECT_READY" then
		inspectBusy = false
		RebuildGroup()
		return
	elseif event == "PLAYER_REGEN_ENABLED" then
		InspectNext() -- inspects wait until combat ends
		return
	elseif event ~= "PLAYER_LOGIN" then -- GROUP_ROSTER_UPDATE, PLAYER_SPECIALIZATION_CHANGED
		RebuildGroup()
		return
	end
	Filters()
	HookApplicantList()
	PugLogsDB.session = nil -- from older versions (invite-based hiding)
	RebuildGroup()
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
