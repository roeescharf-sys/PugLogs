-- Adds "Check logs" to right-click menus.
local _, ns = ...

local BUTTON_TEXT = "Check logs"

-- Group Finder applicants (when you are the one listing a key).
Menu.ModifyMenu("MENU_LFG_FRAME_MEMBER_APPLY", function(owner, rootDescription)
	local parent = owner and owner:GetParent()
	local applicantID = parent and parent.applicantID
	local memberIdx = owner and owner.memberIdx
	if not applicantID or not memberIdx then
		return
	end
	local name, classFile, _, _, _, _, _, _, _, role, _, _, _, _, _, specID = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
	if not name or ns.IsSecret(name) then
		return
	end
	rootDescription:CreateDivider()
	rootDescription:CreateButton(BUTTON_TEXT, function()
		ns.ShowLogsFor(name)
	end)
	if ns.LiveEnabled() then
		rootDescription:CreateButton("Look up logs again", function()
			ns.LookUpAgain(name)
		end)
	end
	if not ns.SavedPlayerMenuText then
		return -- My players needs a full restart of WoW after updating
	end
	rootDescription:CreateButton(ns.SavedPlayerMenuText(name), function()
		local spec = ns.SpecInfo(specID)
		ns.OpenPlayerDialog(name, nil, { class = not ns.IsSecret(classFile) and classFile or nil, spec = spec,
			role = not ns.IsSecret(role) and role or nil })
	end)
end)

-- Players in your group, your target, and names in chat.
local UNIT_MENUS = { "PARTY", "RAID_PLAYER", "PLAYER", "FRIEND", "GUILD", "COMMUNITIES_GUILD_MEMBER", "COMMUNITIES_WOW_MEMBER" }

for _, which in ipairs(UNIT_MENUS) do
	Menu.ModifyMenu("MENU_UNIT_" .. which, function(_, rootDescription, contextData)
		if not contextData then
			return
		end
		local name, realm = contextData.name, contextData.server
		if contextData.unit and not name then
			name, realm = UnitName(contextData.unit)
		end
		if not name or ns.IsSecret(name) or ns.IsSecret(realm) then
			return
		end
		rootDescription:CreateDivider()
		rootDescription:CreateButton(BUTTON_TEXT, function()
			ns.ShowLogsFor(name, realm)
		end)
		if which == "PARTY" and ns.GroupLookupsActive() then
			rootDescription:CreateButton("Look up logs again", function()
				ns.LookUpAgain((realm and realm ~= "") and (name .. "-" .. realm) or name, ns.GetGroupDungeon())
			end)
		end
		if not ns.SavedPlayerMenuText then
			return -- My players needs a full restart of WoW after updating
		end
		rootDescription:CreateButton(ns.SavedPlayerMenuText(name, realm), function()
			local info, unit = {}, contextData.unit
			if unit and UnitExists(unit) then
				local _, classFile = UnitClass(unit)
				local role = UnitGroupRolesAssigned(unit)
				info.class = not ns.IsSecret(classFile) and classFile or nil
				info.role = (not ns.IsSecret(role) and role ~= "NONE") and role or nil
				for _, m in ipairs(ns.groupMembers or {}) do
					if m.name == name and m.specID then
						info.spec, info.role = ns.SpecInfo(m.specID)
					end
				end
			end
			ns.OpenPlayerDialog(name, realm, info)
		end)
	end)
end
