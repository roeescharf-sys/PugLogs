-- My players: players you saved with a mark (Good / Okay / Avoid) and a note, e.g. a tank who
-- played well although his logs look bad. Saved for your whole account (PugLogsDB.players).
-- Shown in the panel's "My players" tab, in tooltips, and in chat when they apply or join.
local _, ns = ...

local MARKS = {
	good = { label = "Good", color = "ff4ec36a", icon = "Interface\\RaidFrame\\ReadyCheck-Ready" },
	okay = { label = "Okay", color = "ffffd100", icon = "Interface\\RaidFrame\\ReadyCheck-Waiting" },
	avoid = { label = "Avoid", color = "ffff5b5b", icon = "Interface\\RaidFrame\\ReadyCheck-NotReady" },
}
local MARK_ORDER = { "good", "okay", "avoid" }
ns.MARK_ORDER = MARK_ORDER
local ROLE_NAMES = { TANK = "tank", HEALER = "healer", DAMAGER = "DPS" }

local function Clean(value)
	if value == nil or ns.IsSecret(value) then
		return nil
	end
	return value
end

local function Players()
	PugLogsDB.players = PugLogsDB.players or {}
	return PugLogsDB.players
end

-- "name-realmslug", the same key the pasted results use.
function ns.PlayerKey(fullName, realm)
	local name, playerRealm = ns.SplitNameRealm(fullName, realm)
	return (name .. "-" .. ns.GetRealmSlug(playerRealm)):lower(), name, playerRealm
end

function ns.GetSavedPlayer(fullName, realm)
	if not fullName then
		return nil
	end
	return Players()[(ns.PlayerKey(fullName, realm))]
end

function ns.AllSavedPlayers()
	return Players()
end

function ns.MarkInfo(mark)
	return MARKS[mark or ""]
end

-- "|T...|t Good" in the mark's colour.
function ns.MarkText(mark, withLabel)
	local m = MARKS[mark or ""]
	if not m then
		return ""
	end
	local icon = ("|T%s:12|t"):format(m.icon)
	return withLabel and ("%s |c%s%s|r"):format(icon, m.color, m.label) or icon
end

-- Hide players marked Avoid (a setting): in the PugLogs panel and the app, never in Blizzard's list.
function ns.IsAvoided(fullName)
	local saved = PugLogsDB.hideAvoid and ns.GetSavedPlayer(fullName)
	return saved ~= nil and saved and saved.mark == "avoid"
end

function ns.ApplicationAvoided(applicantID)
	if not PugLogsDB.hideAvoid then
		return false
	end
	local info = C_LFGList.GetApplicantInfo(applicantID)
	for memberIdx = 1, (info and Clean(info.numMembers)) or 0 do
		if ns.IsAvoided(Clean(C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx))) then
			return true
		end
	end
	return false
end

local function Changed()
	if ns.OnPanelChanged then
		ns.OnPanelChanged()
	end
	if ns.OnFiltersChanged then
		ns.OnFiltersChanged() -- the app gets the new marks (and loses Avoid players when hidden)
	end
end

-- Add / edit dialog ---------------------------------------------------------------------

local dialog

local function SelectMark(mark)
	dialog.mark = mark
	for key, box in pairs(dialog.markBoxes) do
		box:SetChecked(key == mark)
	end
end

local function CreateDialog()
	local d = CreateFrame("Frame", "PugLogsPlayerDialog", UIParent, "BackdropTemplate")
	d:SetSize(320, 168)
	d:SetPoint("CENTER", 0, 120)
	d:SetFrameStrata("DIALOG")
	d:EnableMouse(true)
	d:SetMovable(true)
	d:RegisterForDrag("LeftButton")
	d:SetScript("OnDragStart", d.StartMoving)
	d:SetScript("OnDragStop", d.StopMovingOrSizing)
	d:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	d:Hide()
	tinsert(UISpecialFrames, "PugLogsPlayerDialog") -- Escape closes it

	d.title = d:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	d.title:SetPoint("TOPLEFT", 14, -12)
	d.title:SetPoint("TOPRIGHT", -14, -12)
	d.title:SetJustifyH("LEFT")

	d.markBoxes = {}
	local prev
	for _, key in ipairs(MARK_ORDER) do
		local box = CreateFrame("CheckButton", nil, d, "UIRadioButtonTemplate")
		box:SetPoint("TOPLEFT", prev or d, prev and "TOPRIGHT" or "TOPLEFT", prev and 74 or 14, prev and 0 or -40)
		local label = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetPoint("LEFT", box, "RIGHT", 2, 0)
		label:SetText(ns.MarkText(key, true))
		box:SetScript("OnClick", function() SelectMark(key) end)
		d.markBoxes[key] = box
		prev = box
	end

	local noteLabel = d:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	noteLabel:SetPoint("TOPLEFT", 16, -70)
	noteLabel:SetText("Note")
	d.note = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
	d.note:SetSize(286, 22)
	d.note:SetPoint("TOPLEFT", 20, -86)
	d.note:SetAutoFocus(false)
	d.note:SetMaxLetters(200)
	d.note:SetScript("OnEnterPressed", function() d.save:Click() end)
	d.note:SetScript("OnEscapePressed", function() d:Hide() end)

	d.save = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
	d.save:SetSize(80, 22)
	d.save:SetPoint("BOTTOMLEFT", 14, 14)
	d.save:SetText("Save")
	d.save:SetScript("OnClick", function()
		local players = Players()
		local old = players[d.key] or {}
		players[d.key] = {
			name = d.info.name, realm = d.info.realm, class = d.info.class or old.class,
			spec = d.info.spec or old.spec, role = d.info.role or old.role,
			mark = d.mark, note = strtrim(d.note:GetText() or ""),
			added = old.added or time(), updated = time(),
		}
		ns.Print(("%s saved as %s."):format(d.info.name, ns.MarkText(d.mark, true)))
		d:Hide()
		Changed()
	end)
	d.remove = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
	d.remove:SetSize(80, 22)
	d.remove:SetPoint("LEFT", d.save, "RIGHT", 8, 0)
	d.remove:SetText("Remove")
	d.remove:SetScript("OnClick", function()
		Players()[d.key] = nil
		ns.Print(d.info.name .. " removed from your players.")
		d:Hide()
		Changed()
	end)
	local cancel = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
	cancel:SetSize(80, 22)
	cancel:SetPoint("BOTTOMRIGHT", -14, 14)
	cancel:SetText("Cancel")
	cancel:SetScript("OnClick", function() d:Hide() end)
	return d
end

-- info: { class = "WARRIOR", spec = "Protection", role = "TANK" } when known.
function ns.OpenPlayerDialog(fullName, realm, info)
	if not fullName or ns.IsSecret(fullName) or fullName == "" then
		ns.Print("Can't read this player's name right now (try again out of combat).")
		return
	end
	dialog = dialog or CreateDialog()
	local key, name, playerRealm = ns.PlayerKey(fullName, realm)
	local saved = Players()[key]
	info = info or {}
	dialog.key = key
	dialog.info = { name = name, realm = playerRealm, class = info.class, spec = info.spec, role = info.role }
	local color = info.class or (saved and saved.class)
	color = color and RAID_CLASS_COLORS and RAID_CLASS_COLORS[color]
	dialog.title:SetText((saved and "Edit " or "Add ") .. (color and color:WrapTextInColorCode(name) or name)
		.. (saved and " in my players" or " to my players"))
	SelectMark(saved and saved.mark or "good")
	dialog.note:SetText(saved and saved.note or "")
	dialog.remove:SetShown(saved ~= nil)
	dialog:Show()
	dialog.note:SetFocus()
end

function ns.SavedPlayerMenuText(fullName, realm)
	return ns.GetSavedPlayer(fullName, realm) and "Edit in my players..." or "Add to my players..."
end

-- Spec and role of a spec ID, for saving.
function ns.SpecInfo(specID)
	specID = Clean(specID)
	if not specID or specID == 0 then
		return nil, nil
	end
	local _, specName, _, _, role = GetSpecializationInfoByID(specID)
	return specName, role
end

-- Tooltip lines ---------------------------------------------------------------------------

function ns.AddSavedPlayerLines(tooltip, fullName, realm)
	local saved = ns.GetSavedPlayer(fullName, realm)
	if not saved then
		return
	end
	tooltip:AddLine(" ")
	tooltip:AddLine("My players: " .. ns.MarkText(saved.mark, true), 1, 1, 1)
	if saved.note and saved.note ~= "" then
		tooltip:AddLine(saved.note, 1, 1, 1, true)
	end
end

-- Any player you hover in the world, a chat name's unit, your group...
if TooltipDataProcessor and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
		pcall(function()
			if tooltip ~= GameTooltip then
				return
			end
			local _, unit = tooltip:GetUnit()
			unit = Clean(unit)
			if not unit or not Clean(UnitIsPlayer(unit)) then
				return
			end
			local name, realm = UnitName(unit)
			name, realm = Clean(name), Clean(realm)
			if name then
				ns.AddSavedPlayerLines(tooltip, name, realm)
			end
		end)
	end)
end

-- Chat notice when a saved player applies or joins -------------------------------------------

local seenApplicants, seenGroup = {}, {}

local function Announce(saved, what)
	if PugLogsDB.announceSaved == false then
		return
	end
	local color = saved.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[saved.class]
	local name = color and color:WrapTextInColorCode(saved.name) or saved.name
	local role = ROLE_NAMES[saved.role or ""]
	ns.Print(("%s %s (%s%s)%s"):format(ns.MarkText(saved.mark), name, MARKS[saved.mark] and MARKS[saved.mark].label or "",
		role and (" " .. role) or "", what) .. ((saved.note and saved.note ~= "") and (": " .. saved.note) or ""))
end

local function ScanApplicants()
	if not C_LFGList.GetActiveEntryInfo() then
		wipe(seenApplicants)
		return
	end
	local ok, ids = pcall(C_LFGList.GetApplicants)
	for _, id in ipairs(ok and ids or {}) do
		if not ns.IsSecret(id) and not seenApplicants[id] then
			local info = C_LFGList.GetApplicantInfo(id)
			local status = info and Clean(info.applicationStatus)
			if status == "applied" then
				seenApplicants[id] = true
				for memberIdx = 1, (Clean(info.numMembers) or 0) do
					local saved = ns.GetSavedPlayer(Clean(C_LFGList.GetApplicantMemberInfo(id, memberIdx)))
					if saved then
						Announce(saved, " applied")
					end
				end
			end
		end
	end
end

local function ScanGroup()
	if not IsInGroup() then
		wipe(seenGroup)
		return
	end
	for i = 1, GetNumGroupMembers() do
		local unit = IsInRaid() and ("raid" .. i) or ("party" .. i)
		if UnitExists(unit) and not Clean(UnitIsUnit(unit, "player")) then
			local name, realm = UnitName(unit)
			name, realm = Clean(name), Clean(realm)
			local saved = name and ns.GetSavedPlayer(name, realm)
			local key = name and ns.PlayerKey(name, realm)
			if saved and not seenGroup[key] then
				seenGroup[key] = true
				Announce(saved, " is in your group")
			end
		end
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("LFG_LIST_APPLICANT_LIST_UPDATED")
events:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:SetScript("OnEvent", function(_, event)
	if not PugLogsDB then
		return
	end
	if event == "GROUP_ROSTER_UPDATE" then
		pcall(ScanGroup)
	else
		pcall(ScanApplicants)
	end
end)
