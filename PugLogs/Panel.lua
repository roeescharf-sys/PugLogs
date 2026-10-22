-- PugLogs applicant panel: your applicants, filtered and sorted, next to the Group Finder.
--
-- Blizzard's own applicant list can't be re-sorted or filtered by an addon without making the
-- Group Finder error since Midnight ("attempt to compare a secret number value"). This panel is
-- PugLogs' own frame: it only reads the applicants and never touches Blizzard's list.
-- Invite/Decline buttons are an experiment (off by default): /pl panel invite on.
local _, ns = ...

local MAX_ROWS = 18
local ROW_HEIGHT = 20
local SORTS = {
	{ key = "log", label = "Log" },
	{ key = "dps", label = "DPS" },
	{ key = "rating", label = "Rating" },
	{ key = "ilvl", label = "iLvl" },
	{ key = "role", label = "Role" },
	{ key = "applied", label = "Applied" },
}
local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }
local ROLE_ICONS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }

local panel, rows, sortButtons, footer
local refreshPending = false

local function Settings()
	PugLogsDB = PugLogsDB or {}
	if PugLogsDB.panel == nil then
		PugLogsDB.panel = true
	end
	PugLogsDB.panelSort = PugLogsDB.panelSort or "log"
	return PugLogsDB
end

local function Clean(value)
	if value == nil or ns.IsSecret(value) then
		return nil
	end
	return value
end

-- Applicants -------------------------------------------------------------------------------

-- Returns the applications to show (filtered ones left out) and how many were filtered.
local function CollectApplications()
	local list, filtered = {}, 0
	local ok, ids = pcall(C_LFGList.GetApplicants)
	for order, id in ipairs(ok and ids or {}) do
		local info = not ns.IsSecret(id) and C_LFGList.GetApplicantInfo(id)
		local status = info and Clean(info.applicationStatus)
		if status == "applied" or status == "invited" then
			if ns.ApplicationFiltered and ns.ApplicationFiltered(id) then
				filtered = filtered + 1
			else
				local app = { id = id, order = order, status = status, members = {} }
				for memberIdx = 1, (Clean(info.numMembers) or 0) do
					local name, classFile, _, _, itemLevel, _, _, _, _, role, _, score =
						C_LFGList.GetApplicantMemberInfo(id, memberIdx)
					name = Clean(name)
					if name then
						local member = {
							idx = memberIdx, name = name, class = Clean(classFile), role = Clean(role),
							ilvl = math.floor(Clean(itemLevel) or 0), score = math.floor(Clean(score) or 0),
						}
						member.entry = ns.LiveEntry and ns.LiveEntry(name)
						app.members[#app.members + 1] = member
					end
				end
				if #app.members > 0 then
					list[#list + 1] = app
				end
			end
		end
	end
	return list, filtered
end

-- Sort value for one application (higher first); a group counts as its best member.
local function SortValue(app, by)
	local best
	for _, m in ipairs(app.members) do
		local v
		if by == "log" then
			v = m.entry and m.entry.percent or -1
		elseif by == "dps" then
			v = m.entry and m.entry.dps or -1
		elseif by == "rating" then
			v = m.score
		elseif by == "ilvl" then
			v = m.ilvl
		elseif by == "role" then
			v = -(ROLE_ORDER[m.role or ""] or 4)
		else
			v = -app.order
		end
		best = best and math.max(best, v) or v
	end
	return best or -math.huge
end

local function Sort(list, by)
	for _, app in ipairs(list) do
		app.sortValue = SortValue(app, by)
	end
	table.sort(list, function(a, b)
		if a.sortValue ~= b.sortValue then
			return a.sortValue > b.sortValue
		end
		return a.order < b.order
	end)
end

-- Display ------------------------------------------------------------------------------------

local function ClassColor(classFile)
	local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	return c and c.colorStr or "ffffffff"
end

local function RoleText(role)
	local atlas = ROLE_ICONS[role or ""]
	if atlas and CreateAtlasMarkup then
		return CreateAtlasMarkup(atlas, 14, 14)
	end
	return role and role:sub(1, 1) or "?"
end

-- "+19 87" in the colour of the percentile ("+19 350K" when sorting by DPS), or why there's no run.
local function RunText(m, showDps)
	local e = m.entry
	if not e then
		return "|cff888888not loaded|r"
	elseif e.hidden then
		return "|cffffb347logs hidden|r"
	elseif e.none then
		return "|cff888888no logs|r"
	end
	local key = ("%s+%d|r"):format(e.timed and "|cff4ec36a" or "|cffe0624f", e.key or 0)
	local pct = e.percent and ("|cff%s%d|r"):format(ns.PercentColor(e.percent), math.floor(e.percent)) or "-"
	if showDps then
		pct = e.dps and ("|cff%s%dK|r"):format(ns.PercentColor(e.percent), math.floor(e.dps / 1000)) or "-"
	end
	local mark = e.specMismatch == 2 and " |cffff6b5b!|r" or (e.specMismatch == 1 and " |cffffb347*|r" or "")
	return key .. " " .. pct .. mark
end

local function CreateRow(index)
	local row = CreateFrame("Button", nil, panel)
	row:SetSize(330, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -54 - (index - 1) * ROW_HEIGHT)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.role = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.role:SetPoint("LEFT", 2, 0)
	row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 22, 0)
	row.name:SetWidth(108)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.ilvl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.ilvl:SetPoint("LEFT", 132, 0)
	row.score = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.score:SetPoint("LEFT", 162, 0)
	row.run = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.run:SetPoint("LEFT", 200, 0)

	-- Experimental: invite / decline from the panel (/pl panel invite on).
	row.invite = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.invite:SetSize(22, 18)
	row.invite:SetPoint("RIGHT", row, "RIGHT", -24, 0)
	row.invite:SetText("+")
	row.invite:SetScript("OnClick", function(self)
		local ok, err = pcall(C_LFGList.InviteApplicant, self.applicantID)
		if not ok then
			ns.Print("Inviting from the panel isn't allowed: " .. tostring(err))
		end
	end)
	row.decline = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.decline:SetSize(22, 18)
	row.decline:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	row.decline:SetText("x")
	row.decline:SetScript("OnClick", function(self)
		local ok, err = pcall(C_LFGList.DeclineApplicant, self.applicantID)
		if not ok then
			ns.Print("Declining from the panel isn't allowed: " .. tostring(err))
		end
	end)

	row:SetScript("OnEnter", function(self)
		if not self.applicantID then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self.fullName or "")
		if ns.AddApplicantTooltip then
			ns.AddApplicantTooltip(self.applicantID, self.memberIdx)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	return row
end

local function Refresh()
	refreshPending = false
	if not panel or not panel:IsShown() then
		return
	end
	local settings = Settings()
	for _, b in ipairs(sortButtons) do
		b:SetEnabled(b.key ~= settings.panelSort)
	end
	local list, filtered = CollectApplications()
	Sort(list, settings.panelSort)

	local index, shownApps = 0, 0
	for _, app in ipairs(list) do
		if index + #app.members > MAX_ROWS then
			break
		end
		shownApps = shownApps + 1
		for n, m in ipairs(app.members) do
			index = index + 1
			local row = rows[index] or CreateRow(index)
			rows[index] = row
			row.applicantID, row.memberIdx, row.fullName = app.id, m.idx, m.name
			row.role:SetText(RoleText(m.role))
			local shortName = m.name:match("^[^-]+") or m.name
			row.name:SetText(("%s|c%s%s|r"):format(n > 1 and "  " or "", ClassColor(m.class), shortName))
			row.ilvl:SetText(m.ilvl > 0 and m.ilvl or "-")
			row.score:SetText(m.score > 0 and m.score or "-")
			row.run:SetText(RunText(m, settings.panelSort == "dps"))
			local buttons = settings.panelInvite and n == 1 and app.status == "applied"
			row.invite.applicantID, row.decline.applicantID = app.id, app.id
			row.invite:SetShown(buttons)
			row.decline:SetShown(buttons)
			row:Show()
		end
	end
	for i = index + 1, #rows do
		rows[i]:Hide()
		rows[i].applicantID = nil
	end

	local notes = {}
	if #list == 0 then
		notes[#notes + 1] = "No applicants yet."
	end
	if shownApps < #list then
		notes[#notes + 1] = ("%d more not shown"):format(#list - shownApps)
	end
	if filtered > 0 then
		notes[#notes + 1] = ("%d filtered out"):format(filtered)
	end
	footer:SetText(table.concat(notes, " - "))
end

function ns.OnPanelChanged()
	if refreshPending then
		return
	end
	refreshPending = true
	C_Timer.After(0.1, Refresh)
end

-- Frame ---------------------------------------------------------------------------------------

-- Where the panel goes: where you dragged it, or else beside Raider.IO's profile window (which
-- sits on the right of the Group Finder too), or else right of the Group Finder.
local function Position()
	if not panel then
		return
	end
	panel:ClearAllPoints()
	local saved = PugLogsDB and PugLogsDB.panelPos
	if saved and type(saved[1]) == "number" then
		panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved[1], saved[2])
		return
	end
	local rio = _G.RaiderIO_ProfileTooltip
	if rio and rio:IsShown() then
		panel:SetPoint("TOPLEFT", rio, "TOPRIGHT", 4, 0)
	else
		panel:SetPoint("TOPLEFT", PVEFrame, "TOPRIGHT", 4, 0)
	end
end

local rioHooked = false
local function FollowRaiderIO()
	local rio = _G.RaiderIO_ProfileTooltip
	if rio and not rioHooked then
		rioHooked = true
		rio:HookScript("OnShow", Position)
		rio:HookScript("OnHide", Position)
	end
end

local function UpdateShown()
	local viewer = LFGListFrame and LFGListFrame.ApplicationViewer
	local show = Settings().panel and viewer and viewer:IsVisible() and ns.GetListingDungeon() ~= nil
	if panel then
		panel:SetShown(show and true or false)
		if show then
			FollowRaiderIO()
			Position()
			ns.OnPanelChanged()
		end
	end
end

local function CreatePanel()
	local viewer = LFGListFrame and LFGListFrame.ApplicationViewer
	if panel or not viewer or not PVEFrame then
		return
	end
	panel = CreateFrame("Frame", "PugLogsApplicantPanel", PVEFrame, "BackdropTemplate")
	panel:SetSize(350, 54 + MAX_ROWS * ROW_HEIGHT + 30)
	panel:SetPoint("TOPLEFT", PVEFrame, "TOPRIGHT", 4, 0)
	panel:SetFrameStrata("HIGH")
	panel:SetClampedToScreen(true)
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self:SetUserPlaced(false) -- PugLogs remembers the position itself
		-- GetLeft/GetTop and SetPoint offsets both use the panel's own scale, measured from the
		-- screen's bottom-left corner, so this works however the Group Finder is scaled.
		local left, top = self:GetLeft(), self:GetTop()
		if left and top then
			PugLogsDB.panelPos = { left, top }
			Position()
		end
	end)
	panel:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:Hide()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("PugLogs applicants  |cff888888(drag to move)|r")

	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function()
		Settings().panel = false
		UpdateShown()
		ns.Print("Applicant panel hidden - /pl panel on brings it back.")
	end)

	sortButtons = {}
	local prev
	for _, s in ipairs(SORTS) do
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(52, 18)
		b:SetText(s.label)
		b.key = s.key
		b:SetPoint("TOPLEFT", prev or panel, prev and "TOPRIGHT" or "TOPLEFT", prev and 4 or 10, prev and 0 or -28)
		b:SetScript("OnClick", function()
			Settings().panelSort = s.key
			ns.OnPanelChanged()
		end)
		sortButtons[#sortButtons + 1] = b
		prev = b
	end

	footer = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMLEFT", 12, 10)
	footer:SetWidth(326)
	footer:SetJustifyH("LEFT")

	rows = {}
	viewer:HookScript("OnShow", UpdateShown)
	viewer:HookScript("OnHide", UpdateShown)
	UpdateShown()
end

-- Slash command (/pl panel ...), called from Core.lua.
function ns.HandlePanelSlash(msg)
	local settings = Settings()
	if msg == "panel" or msg == "panel on" or msg == "panel off" then
		settings.panel = msg ~= "panel off"
		ns.Print("Applicant panel " .. (settings.panel and "on" or "off") .. ".")
	elseif msg == "panel reset" then
		settings.panelPos = nil
		ns.Print("Applicant panel back to its automatic place (next to the Group Finder / Raider.IO).")
		Position()
	elseif msg == "panel invite on" or msg == "panel invite off" then
		settings.panelInvite = msg == "panel invite on"
		ns.Print("Invite/Decline buttons in the panel " .. (settings.panelInvite and "on (experimental)." or "off."))
	else
		return false
	end
	UpdateShown()
	return true
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("LFG_LIST_APPLICANT_LIST_UPDATED")
events:RegisterEvent("LFG_LIST_APPLICANT_UPDATED")
events:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:SetScript("OnEvent", function(_, event, name)
	if event == "PLAYER_LOGIN" or (event == "ADDON_LOADED" and name == "Blizzard_GroupFinder") then
		CreatePanel()
	elseif event ~= "ADDON_LOADED" then
		if event == "LFG_LIST_ACTIVE_ENTRY_UPDATE" then
			UpdateShown()
		end
		ns.OnPanelChanged()
	end
end)
