--------------------------------------------------------------------------------
-- WoW API Lib -- widgets
--
-- Built from core widget types and long-lived Blizzard templates
-- (UIPanelButtonTemplate, InputBoxTemplate, UIPanelCloseButton,
-- UIPanelScrollFrameTemplate) rather than the ScrollBox framework: the lists
-- here are one-line rows and a scrollbar, and a hand-built virtual list is
-- a page of code that no template reshuffle can break.
--------------------------------------------------------------------------------

local _, ns = ...

local floor, max, min = math.floor, math.max, math.min

local ui = {}
ns.ui = ui

ui.ROW_H = 16
local BAR_W = 10
local WHITE = "Interface\\Buttons\\WHITE8X8"

local function Backdrop(f, alpha)
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(0.02, 0.02, 0.02, alpha or 0.6)
    f:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
end

--------------------------------------------------------------------------------
-- Window: movable, resizable, closes on Escape
--------------------------------------------------------------------------------

function ui.Window(globalName, title, width, height, minW, minH)
    local f = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.96)
    f:SetBackdropBorderColor(0, 0, 0, 1)

    f:SetMovable(true)
    f:SetResizable(true)
    f:SetResizeBounds(minW or width, minH or height)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    tinsert(UISpecialFrames, globalName)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetText(title)
    f.title:SetPoint("TOPLEFT", 14, -12)

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -2, -2)

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)
    f.grip = grip

    f:Hide()
    return f
end

function ui.Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

function ui.SearchBox(parent, width, onChange)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width, 22)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlight")
    eb:SetScript("OnTextChanged", function(self) onChange(self:GetText() or "") end)
    eb:SetScript("OnEscapePressed", function(self)
        -- First Escape clears, the next one leaves the box.
        if (self:GetText() or "") ~= "" then self:SetText("") else self:ClearFocus() end
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return eb
end

function ui.Label(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    return fs
end

--------------------------------------------------------------------------------
-- Virtual list
--
-- Only as many rows exist as fit; scrolling moves an offset and re-renders
-- them. A list of forty thousand globals costs the same as a list of ten.
--
--   opts.render(row, item)      set row.text / row.tag
--   opts.onClick(item)
--   opts.isSelected(item)       -> bool
--------------------------------------------------------------------------------

local function CreateRow(list)
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ui.ROW_H)
    row:RegisterForClicks("LeftButtonUp")

    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(0.2, 0.45, 0.9, 0.35)
    row.selected:Hide()

    row:SetHighlightTexture(WHITE)
    row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)

    row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.tag:SetPoint("RIGHT", -4, 0)
    row.tag:SetJustifyH("RIGHT")

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        if self.item and list.opts.onClick then list.opts.onClick(self.item) end
    end)
    return row
end

function ui.List(parent, opts)
    local list = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Backdrop(list)
    list.opts, list.items, list.rows, list.offset = opts, {}, {}, 0

    local bar = CreateFrame("Slider", nil, list)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(BAR_W)
    bar:SetPoint("TOPRIGHT", -2, -2)
    bar:SetPoint("BOTTOMRIGHT", -2, 2)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetObeyStepOnDrag(true)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(1, 1, 1, 0.08)
    track:SetAllPoints()
    bar:SetThumbTexture(WHITE)
    local thumb = bar:GetThumbTexture()
    thumb:SetSize(BAR_W, 24)
    thumb:SetColorTexture(0.7, 0.7, 0.7, 0.9)
    bar:SetScript("OnValueChanged", function(self, v)
        -- Refresh writes the bar back to the offset it settled on; without
        -- this that write would come straight back here as a scroll.
        if self._quiet then return end
        list.offset = floor(v + 0.5)
        list:Refresh()
    end)
    list.bar = bar

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta) self:ScrollBy(-delta * 3) end)
    list:SetScript("OnSizeChanged", function(self) self:Layout() end)

    function list:Visible()
        return max(1, floor((self:GetHeight() - 4) / ui.ROW_H))
    end

    function list:Layout()
        local n = self:Visible()
        for i = #self.rows + 1, n do self.rows[i] = CreateRow(self) end
        for i, row in ipairs(self.rows) do
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 2, -2 - (i - 1) * ui.ROW_H)
            row:SetPoint("RIGHT", self.bar, "LEFT", -2, 0)
        end
        self:Refresh()
    end

    function list:Refresh()
        local n = self:Visible()
        local maxOffset = max(0, #self.items - n)
        self.offset = min(max(0, self.offset), maxOffset)

        for i, row in ipairs(self.rows) do
            local item = i <= n and self.items[self.offset + i] or nil
            row.item = item
            if item then
                self.opts.render(row, item)
                row.selected:SetShown(self.opts.isSelected and self.opts.isSelected(item) or false)
                row:Show()
            else
                row:Hide()
            end
        end

        self.bar._quiet = true
        self.bar:SetMinMaxValues(0, maxOffset)
        self.bar:SetValue(self.offset)
        self.bar._quiet = false
        self.bar:SetShown(maxOffset > 0)
    end

    function list:ScrollBy(n)
        self.offset = self.offset + n
        self:Refresh()
    end

    function list:SetItems(items, keepOffset)
        self.items = items or {}
        if not keepOffset then self.offset = 0 end
        self:Refresh()
    end

    return list
end

--------------------------------------------------------------------------------
-- Text view: a read-only, selectable, scrollable edit box
--
-- An edit box rather than a font string so the text can be selected and
-- copied with Ctrl+C. Typing is undone as it happens.
--------------------------------------------------------------------------------

function ui.TextView(parent)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Backdrop(holder)

    local sf = CreateFrame("ScrollFrame", nil, holder, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 4, -4)
    -- The template's scrollbar hangs off the right edge; leave it room.
    sf:SetPoint("BOTTOMRIGHT", -26, 4)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetMaxLetters(0)
    eb:SetTextInsets(2, 2, 2, 2)
    eb:EnableMouse(true)
    eb:SetWidth(400)
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(self.value or "") end
    end)
    sf:SetScrollChild(eb)
    -- Hooked, not set: the template may have a handler of its own.
    sf:HookScript("OnSizeChanged", function(_, w) eb:SetWidth(max(50, w)) end)

    holder.scroll, holder.edit = sf, eb

    function holder:SetContent(text)
        eb.value = text or ""
        eb:SetText(eb.value)
        eb:SetCursorPosition(0)
        eb:ClearFocus()
        sf:SetVerticalScroll(0)
    end

    function holder:GetContent() return eb.value or "" end

    function holder:SelectAll()
        eb:SetFocus()
        eb:HighlightText()
    end

    return holder
end
