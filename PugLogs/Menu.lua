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
	local name = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
	if not name or ns.IsSecret(name) then
		return
	end
	rootDescription:CreateDivider()
	rootDescription:CreateButton(BUTTON_TEXT, function()
		ns.ShowLogsFor(name)
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
	end)
end
