-- PugLogs applicant panel: your applicants, filtered and sorted, next to the Group Finder.
--
-- Blizzard's own applicant list can't be re-sorted or filtered by an addon without making the
-- Group Finder error since Midnight ("attempt to compare a secret number value"). This panel is
-- PugLogs' own frame: it only reads the applicants and never touches Blizzard's list.
-- Invite/Decline buttons (on by default; can be turned off in /pl opt).
-- A second tab lists "My players" (Players.lua); that tab can also be opened on its own.
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
local PLAYER_ROLES = { { key = "all", label = "All" }, { key = "TANK", label = "Tank" },
	{ key = "HEALER", label = "Heal" }, { key = "DAMAGER", label = "DPS" } }

local panel, rows, sortButtons, footer, tabs, playerButtons
local refreshPending = false
local standalone = false -- "My players" opened on its own (from /pl opt)
local playerRole, playerMark, playerOffset = "all", "all", 0
local applicantOffset = 0
local filteredList = {}

local function Settings()
	PugLogsDB = PugLogsDB or {}
	if PugLogsDB.panel == nil then
		PugLogsDB.panel = true
	end
	if PugLogsDB.panelInvite == nil then
		PugLogsDB.panelInvite = true
	end
	PugLogsDB.panelSort = PugLogsDB.panelSort or "log"
	PugLogsDB.panelTab = PugLogsDB.panelTab or "applicants"
	return PugLogsDB
end

local function Clean(value)
	if value == nil or ns.IsSecret(value) then
		return nil
	end
	return value
end

-- Applicants -------------------------------------------------------------------------------

-- Returns the applications to show (filtered and hidden Avoid ones left out), how many were
-- filtered and how many were hidden as Avoid.
local function CollectApplications()
	local list, filtered, avoided, filteredDetails = {}, 0, 0, {}
	local ok, ids = pcall(C_LFGList.GetApplicants)
	for order, id in ipairs(ok and ids or {}) do
		local info = not ns.IsSecret(id) and C_LFGList.GetApplicantInfo(id)
		local status = info and Clean(info.applicationStatus)
		if status == "applied" or status == "invited" then
			if ns.ApplicationFiltered and ns.ApplicationFiltered(id) then
				filtered = filtered + 1
				for memberIdx = 1, (Clean(info.numMembers) or 0) do
					local name, classFile = C_LFGList.GetApplicantMemberInfo(id, memberIdx)
					name = Clean(name)
					local reason = name and ns.ApplicantFilterReason and ns.ApplicantFilterReason(id, memberIdx)
					if name and reason then
						filteredDetails[#filteredDetails + 1] = {
							name = name:match("^[^-]+") or name, class = Clean(classFile), reason = reason,
						}
					end
				end
			elseif ns.ApplicationAvoided and ns.ApplicationAvoided(id) then
				avoided = avoided + 1
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
						member.saved = ns.GetSavedPlayer and ns.GetSavedPlayer(name)
						app.members[#app.members + 1] = member
					end
				end
				if #app.members > 0 then
					list[#list + 1] = app
				end
			end
		end
	end
	return list, filtered, avoided, filteredDetails
end

-- Sort value for one application (higher first); a group counts as its best member.
local function SortValue(app, by)
	local best
	for _, m in ipairs(app.members) do
		local v
		if by == "log" then
			v = m.entry and m.entry.percent or -1
		elseif by == "dps" then
			v = ns.EntryDamage(m.entry) or -1 -- HPS isn't damage
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
		local bestRole = 4
		for _, m in ipairs(app.members) do
			bestRole = math.min(bestRole, ROLE_ORDER[m.role or ""] or 4)
		end
		app.roleGroup = bestRole
		-- In a group, the member who puts it in its role group comes first (a tank leading the DPS).
		table.sort(app.members, function(a, b)
			local ra, rb = ROLE_ORDER[a.role or ""] or 4, ROLE_ORDER[b.role or ""] or 4
			if ra ~= rb then
				return ra < rb
			end
			return a.idx < b.idx
		end)
	end
	table.sort(list, function(a, b)
		if a.roleGroup ~= b.roleGroup then
			return a.roleGroup < b.roleGroup
		end
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

-- "+19 87 350K": key (green timed / red over), percentile in its colour, DPS (or HPS for healers);
-- or why there's no run.
local function RunText(m)
	local e = m.entry
	if not e then
		return "|cff888888not loaded|r"
	elseif e.hidden then
		return "|cffffb347logs hidden|r"
	elseif e.none then
		return e.raid and "|cff888888no kills|r" or "|cff888888no logs|r"
	end
	if e.raid then -- "7/10 89": bosses killed, best average percentile
		return ("|cffffffff%d/%d|r |cff%s%d|r"):format(e.key or 0, e.seconds or 0, ns.PercentColor(e.percent), math.floor(e.percent or 0))
	end
	local key = ("%s+%d|r"):format(e.timed and "|cff4ec36a" or "|cffe0624f", e.key or 0)
	local pct = e.percent and ("|cff%s%d|r"):format(ns.PercentColor(e.percent), math.floor(e.percent)) or "-"
	local dps = e.dps and (" |cffffffff%dK|r%s"):format(math.floor(e.dps / 1000), e.hps and " |cff888888HPS|r" or "") or ""
	local mark = e.specMismatch == 2 and " |cffff6b5b!|r" or (e.specMismatch == 1 and " |cffffb347*|r" or "")
	return key .. " " .. pct .. dps .. mark
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
	row.name:SetWidth(100)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.ilvl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.ilvl:SetPoint("LEFT", 124, 0)
	row.score = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.score:SetPoint("LEFT", 152, 0)
	row.run = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.run:SetPoint("LEFT", 186, 0)

	-- Invite / decline from the panel (unless turned off in /pl opt).
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

	row:SetScript("OnClick", function(self)
		if self.savedKey then -- My players: edit
			local saved = ns.AllSavedPlayers()[self.savedKey]
			if saved then
				ns.OpenPlayerDialog(saved.name, saved.realm, saved)
			end
		end
	end)
	row:SetScript("OnEnter", function(self)
		if self.savedKey then
			local saved = ns.AllSavedPlayers()[self.savedKey]
			if saved then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(saved.name .. "-" .. (saved.realm or ""))
				GameTooltip:AddLine(ns.MarkText(saved.mark, true) .. (saved.spec and ("  " .. saved.spec) or ""), 1, 1, 1)
				if saved.note and saved.note ~= "" then
					GameTooltip:AddLine(saved.note, 1, 1, 1, true)
				end
				GameTooltip:AddLine(("Saved %s - click to edit"):format(date("%d %b %Y", saved.added or time())), 0.6, 0.6, 0.6)
				GameTooltip:Show()
			end
			return
		end
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

-- "My players" tab: saved players, filtered by role and mark, best marks first.
local function RefreshPlayers()
	local list = {}
	if not ns.AllSavedPlayers then
		footer:SetText("My players needs a full restart of WoW after updating PugLogs.")
		return
	end
	for key, saved in pairs(ns.AllSavedPlayers()) do
		if (playerRole == "all" or saved.role == playerRole) and (playerMark == "all" or saved.mark == playerMark) then
			list[#list + 1] = { key = key, saved = saved }
		end
	end
	local order = { good = 1, okay = 2, avoid = 3 }
	table.sort(list, function(a, b)
		local ma, mb = order[a.saved.mark] or 4, order[b.saved.mark] or 4
		if ma ~= mb then
			return ma < mb
		end
		return a.saved.name < b.saved.name
	end)
	playerOffset = math.max(0, math.min(playerOffset, #list - MAX_ROWS))
	local index = 0
	for i = playerOffset + 1, math.min(#list, playerOffset + MAX_ROWS) do
		index = index + 1
		local saved, row = list[i].saved, rows[index] or CreateRow(index)
		rows[index] = row
		row.savedKey, row.applicantID = list[i].key, nil
		row.role:SetText(RoleText(saved.role))
		row.name:SetText(("%s |c%s%s|r"):format(ns.MarkText(saved.mark), ClassColor(saved.class), saved.name))
		row.ilvl:SetText(saved.spec or "")
		row.ilvl:SetWidth(58)
		row.ilvl:SetWordWrap(false)
		row.score:SetText("")
		row.run:SetText(saved.note or "")
		row.run:SetWidth(140)
		row.run:SetWordWrap(false)
		row.invite:Hide()
		row.decline:Hide()
		row:Show()
	end
	for i = index + 1, #rows do
		rows[i]:Hide()
		rows[i].savedKey = nil
	end
	local total = 0
	for _ in pairs(ns.AllSavedPlayers()) do
		total = total + 1
	end
	footer:SetText(total == 0 and "No saved players yet - right-click a player: \"Add to my players...\""
		or ("%d shown of %d%s - click a player to edit"):format(#list, total, #list > MAX_ROWS and ", scroll for more" or ""))
end

local function Refresh()
	refreshPending = false
	if not panel or not panel:IsShown() then
		return
	end
	local settings = Settings()
	local players = settings.panelTab == "players"
	tabs.applicants:SetEnabled(players)
	tabs.players:SetEnabled(not players)
	for _, b in ipairs(sortButtons) do
		b:SetShown(not players)
		b:SetEnabled(b.key ~= settings.panelSort)
	end
	for _, b in ipairs(playerButtons) do
		b:SetShown(players)
		b:SetEnabled(not ((b.role and b.role == playerRole) or (b.mark and b.mark == playerMark)))
	end
	if players then
		RefreshPlayers()
		return
	end
	local list, filtered, avoided, newFilteredList = CollectApplications()
	Sort(list, settings.panelSort)
	filteredList = newFilteredList

	local allMembers = {}
	for _, app in ipairs(list) do
		for n, m in ipairs(app.members) do
			allMembers[#allMembers + 1] = { app = app, member = m, num = n }
		end
	end
	applicantOffset = math.max(0, math.min(applicantOffset, math.max(0, #allMembers - MAX_ROWS)))

	local index = 0
	for i = applicantOffset + 1, math.min(#allMembers, applicantOffset + MAX_ROWS) do
		index = index + 1
		local item = allMembers[i]
		local app, m, n = item.app, item.member, item.num
		local row = rows[index] or CreateRow(index)
		rows[index] = row
		row.applicantID, row.memberIdx, row.fullName, row.savedKey = app.id, m.idx, m.name, nil
		row.role:SetText(RoleText(m.role))
		local shortName = m.name:match("^[^-]+") or m.name
		row.name:SetText(("%s%s|c%s%s|r"):format(n > 1 and "  " or "", m.saved and (ns.MarkText(m.saved.mark) .. " ") or "",
			ClassColor(m.class), shortName))
		row.ilvl:SetText(m.ilvl > 0 and m.ilvl or "-")
		row.ilvl:SetWidth(0)
		row.score:SetText(m.score > 0 and m.score or "-")
		row.run:SetText(RunText(m))
		row.run:SetWidth(0)
		local buttons = settings.panelInvite and n == 1 and app.status == "applied"
		row.invite.applicantID, row.decline.applicantID = app.id, app.id
		row.invite:SetShown(buttons)
		row.decline:SetShown(buttons)
		row:Show()
	end
	for i = index + 1, #rows do
		rows[i]:Hide()
		rows[i].applicantID = nil
	end

	local notes = {}
	if #allMembers == 0 then
		notes[#notes + 1] = "No applicants yet."
	elseif #allMembers > MAX_ROWS then
		notes[#notes + 1] = ("%d-%d of %d"):format(applicantOffset + 1, math.min(applicantOffset + MAX_ROWS, #allMembers), #allMembers)
	end
	if filtered > 0 then
		notes[#notes + 1] = ("%d filtered out"):format(filtered)
	end
	if avoided > 0 then
		notes[#notes + 1] = ("%d on your Avoid list"):format(avoided)
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
	if not PVEFrame:IsShown() then
		panel:SetPoint("CENTER", UIParent, "CENTER", 0, 60) -- My players on its own
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
	local show = standalone or (Settings().panel and viewer and viewer:IsVisible() and ns.GetListingTarget() ~= nil)
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
	-- On UIParent (not the Group Finder) so "My players" can be open on its own; UpdateShown
	-- hides it with the Group Finder otherwise.
	panel = CreateFrame("Frame", "PugLogsApplicantPanel", UIParent, "BackdropTemplate")
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

	-- Tabs: Applicants | My players (the selected one is greyed out, like the sort buttons).
	tabs = {}
	for i, t in ipairs({ { "applicants", "Applicants" }, { "players", "My players" } }) do
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(96, 20)
		b:SetText(t[2])
		b:SetPoint("TOPLEFT", panel, "TOPLEFT", 10 + (i - 1) * 100, -6)
		b:SetScript("OnClick", function()
			Settings().panelTab = t[1]
			applicantOffset, playerOffset = 0, 0
			ns.OnPanelChanged()
		end)
		tabs[t[1]] = b
	end
	local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("LEFT", tabs.players, "RIGHT", 8, 0)
	hint:SetText("(drag to move)")

	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function()
		if standalone then -- closing My players opened from /pl opt
			standalone = false
			UpdateShown()
			return
		end
		Settings().panel = false
		UpdateShown()
		ns.Print("Applicant panel hidden - turn it back on in /pl opt.")
		if ns.OnPanelSettingChanged then
			ns.OnPanelSettingChanged()
		end
	end)

	sortButtons = {}
	local prev
	for _, s in ipairs(SORTS) do
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetText(s.label)
		b:SetSize(b:GetFontString():GetStringWidth() + 16, 18)
		b.key = s.key
		b:SetPoint("TOPLEFT", prev or panel, prev and "TOPRIGHT" or "TOPLEFT", prev and 4 or 10, prev and 0 or -28)
		b:SetScript("OnClick", function()
			Settings().panelSort = s.key
			applicantOffset = 0
			ns.OnPanelChanged()
		end)
		sortButtons[#sortButtons + 1] = b
		prev = b
	end

	-- My players: role buttons, then mark buttons (icons).
	playerButtons, prev = {}, nil
	for _, r in ipairs(PLAYER_ROLES) do
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetText(r.label)
		b:SetSize(b:GetFontString():GetStringWidth() + 16, 18)
		b.role = r.key
		b:SetPoint("TOPLEFT", prev or panel, prev and "TOPRIGHT" or "TOPLEFT", prev and 4 or 10, prev and 0 or -28)
		b:SetScript("OnClick", function()
			playerRole, playerOffset = r.key, 0
			ns.OnPanelChanged()
		end)
		playerButtons[#playerButtons + 1] = b
		prev = b
	end
	for i, mark in ipairs({ "all", "good", "okay", "avoid" }) do
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetText(mark == "all" and "Marks" or (ns.MarkText and ns.MarkText(mark) or mark))
		b:SetSize(math.max(b:GetFontString():GetStringWidth() + 16, 26), 18)
		b.mark = mark
		b:SetPoint("TOPLEFT", prev, "TOPRIGHT", i == 1 and 12 or 4, 0)
		b:SetScript("OnClick", function()
			playerMark, playerOffset = mark, 0
			ns.OnPanelChanged()
		end)
		playerButtons[#playerButtons + 1] = b
		prev = b
	end
	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function(_, delta)
		if Settings().panelTab == "players" then
			playerOffset = math.max(0, playerOffset - delta * 3)
		else
			applicantOffset = math.max(0, applicantOffset - delta * 3)
		end
		ns.OnPanelChanged()
	end)

	footer = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMLEFT", 12, 10)
	footer:SetWidth(326)
	footer:SetJustifyH("LEFT")

	local footerHit = CreateFrame("Frame", nil, panel)
	footerHit:SetPoint("BOTTOMLEFT", 12, 6)
	footerHit:SetSize(326, 20)
	footerHit:EnableMouse(true)
	footerHit:SetScript("OnEnter", function(self)
		if Settings().panelTab ~= "applicants" or #filteredList == 0 then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Filtered out:")
		local shown = math.min(#filteredList, 15)
		for i = 1, shown do
			local f = filteredList[i]
			GameTooltip:AddLine("|c" .. ClassColor(f.class) .. f.name .. "|r  " .. f.reason, 1, 1, 1, true)
		end
		if #filteredList > 15 then
			GameTooltip:AddLine(("and %d more"):format(#filteredList - 15), 0.6, 0.6, 0.6)
		end
		GameTooltip:Show()
	end)
	footerHit:SetScript("OnLeave", GameTooltip_Hide)

	rows = {}
	viewer:HookScript("OnShow", UpdateShown)
	viewer:HookScript("OnHide", UpdateShown)
	UpdateShown()
end

-- Settings from the options page (/pl opt).
function ns.PanelSetting(key)
	return Settings()[key]
end

function ns.SetPanelSetting(key, value)
	Settings()[key] = value
	UpdateShown()
end

-- Opens the panel (/pl panel), also without the Group Finder, on the given tab or the last one.
function ns.OpenPanel(tab)
	if not panel then
		if C_AddOns and C_AddOns.LoadAddOn then
			pcall(C_AddOns.LoadAddOn, "Blizzard_GroupFinder")
		end
		CreatePanel()
	end
	if not panel then
		ns.Print("Open the Group Finder once, then try again.")
		return
	end
	local settings = Settings()
	settings.panel = true -- also brings it back after closing it with its X
	settings.panelTab = tab or settings.panelTab
	standalone = true
	UpdateShown()
	if ns.OnPanelSettingChanged then
		ns.OnPanelSettingChanged()
	end
end

-- Opens the panel on its "My players" tab, also without the Group Finder (/pl opt button).
function ns.OpenMyPlayers()
	ns.OpenPanel("players")
end

function ns.ResetPanelPosition()
	Settings().panelPos = nil
	Position()
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
