-- WoW can't open a browser or write to the clipboard, so we show the link
-- pre-selected in a text box: press Ctrl+C (Cmd+C on Mac) and paste it in a browser.
local _, ns = ...

local popup

local function CreatePopup()
	local frame = CreateFrame("Frame", "PugLogsCopyPopup", UIParent, "BackdropTemplate")
	frame:SetSize(520, 110)
	frame:SetPoint("CENTER", 0, 150)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	tinsert(UISpecialFrames, "PugLogsCopyPopup") -- Escape closes it

	frame.title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	frame.title:SetPoint("TOP", 0, -18)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local editBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	editBox:SetSize(470, 24)
	editBox:SetPoint("TOP", 0, -42)
	editBox:SetAutoFocus(true)
	editBox:SetFontObject("ChatFontNormal")
	editBox:SetScript("OnEscapePressed", function() frame:Hide() end)
	editBox:SetScript("OnEnterPressed", function() frame:Hide() end)
	-- Keep the box read-only: undo any typing and re-select the link.
	editBox:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(frame.url)
			self:HighlightText()
		end
	end)
	editBox:SetScript("OnMouseUp", function(self) self:HighlightText() end)
	-- Close shortly after Ctrl+C / Cmd+C so the copy goes through first.
	editBox:SetScript("OnKeyDown", function(_, key)
		if key == "C" and (IsControlKeyDown() or IsMetaKeyDown()) then
			C_Timer.After(0.1, function()
				frame:Hide()
				ns.Print("Link copied - paste it in your browser.")
			end)
		end
	end)
	frame.editBox = editBox

	local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	hint:SetPoint("TOP", editBox, "BOTTOM", 0, -8)
	hint:SetText(IsMacClient() and "Press Cmd+C to copy, then paste in your browser."
		or "Press Ctrl+C to copy, then paste in your browser.")

	return frame
end

function ns.ShowCopyPopup(title, url)
	popup = popup or CreatePopup()
	popup.url = url
	popup.title:SetText(title)
	popup.editBox:SetText(url)
	popup:Show()
	popup.editBox:SetFocus()
	popup.editBox:HighlightText()
end
