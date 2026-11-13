--------------------------------------------------------------------------------
-- WoW API Lib -- widgets
--
-- A flat, dark theme drawn from solid colour textures and backdrops, built on
-- core widget types only: no Blizzard templates beyond BackdropTemplate, and
-- not the ScrollBox framework. The lists here are one-line rows and a
-- scrollbar, and a hand-built virtual list is a page of code that no template
-- reshuffle can break. The same reasoning keeps the art to WHITE8X8 and a
-- couple of long-lived icon files rather than atlases, which get renamed.
--
-- Every colour lives in ui.C, so the look is changed in one place.
--------------------------------------------------------------------------------

local _, ns = ...

local floor, max, min = math.floor, math.max, math.min

local ui = {}
ns.ui = ui

ui.ROW_H    = 18
ui.TITLE_H  = 32
ui.STATUS_H = 22
ui.HEADER_H = 22
local BAR_W = 6
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- r, g, b[, a]
ui.C = {
    window   = { 0.067, 0.071, 0.082, 0.97 },
    titlebar = { 0.098, 0.102, 0.118, 1 },
    statbar  = { 0.051, 0.055, 0.063, 1 },
    panel    = { 0.039, 0.043, 0.051, 0.95 },
    header   = { 0.090, 0.094, 0.110, 1 },
    border   = { 0.180, 0.188, 0.216, 1 },
    divider  = { 1, 1, 1, 0.06 },
    control  = { 0.125, 0.133, 0.153, 1 },
    hover    = { 0.180, 0.188, 0.220, 1 },
    field    = { 0.031, 0.035, 0.043, 1 },
    accent   = { 0.239, 0.557, 1.000, 1 },
    accentHi = { 0.353, 0.635, 1.000, 1 },
    danger   = { 0.800, 0.250, 0.250, 1 },
    text     = { 0.922, 0.929, 0.949 },
    muted    = { 0.545, 0.565, 0.620 },
    faint    = { 0.380, 0.396, 0.439 },
}
local C = ui.C

local function Unpack(c, a) return c[1], c[2], c[3], a or c[4] or 1 end

local function Fill(f, bg, border)
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(Unpack(bg))
    f:SetBackdropBorderColor(Unpack(border or C.border))
end

local function Solid(parent, layer, colour, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub)
    t:SetColorTexture(Unpack(colour))
    return t
end

local function Text(parent, template, colour)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetTextColor(Unpack(colour or C.text))
    fs:SetJustifyH("LEFT")
    return fs
end

-- A drawn "x", so a close or clear button needs no art that can go missing.
local function Cross(b, half, colour)
    local lines = {}
    for i, d in ipairs({ { -1, 1, 1, -1 }, { -1, -1, 1, 1 } }) do
        local l = b:CreateLine(nil, "OVERLAY")
        l:SetThickness(1.5)
        l:SetStartPoint("CENTER", b, d[1] * half, d[2] * half)
        l:SetEndPoint("CENTER", b, d[3] * half, d[4] * half)
        l:SetColorTexture(Unpack(colour))
        lines[i] = l
    end
    function b:SetCrossColour(c)
        for _, l in ipairs(lines) do l:SetColorTexture(Unpack(c)) end
    end
end

local function IconButton(parent, size, half, hoverBg)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(size, size)
    b:SetBackdrop({ bgFile = WHITE })
    b:SetBackdropColor(0, 0, 0, 0)
    Cross(b, half, C.muted)
    b:SetScript("OnEnter", function(self)
        self:SetBackdropColor(Unpack(hoverBg))
        self:SetCrossColour(C.text)
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetCrossColour(C.muted)
    end)
    return b
end

--------------------------------------------------------------------------------
-- Window: title bar, status bar, movable, resizable, closes on Escape
--
--   f.title, f.subtitle   title bar text
--   f.statusText          status bar text
--   f.close, f.grip
--------------------------------------------------------------------------------

function ui.Window(globalName, title, width, height, minW, minH)
    local f = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    Fill(f, C.window, { 0, 0, 0, 1 })

    f:SetMovable(true)
    f:SetResizable(true)
    f:SetResizeBounds(minW or width, minH or height)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    tinsert(UISpecialFrames, globalName)

    local bar = Solid(f, "BORDER", C.titlebar)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(ui.TITLE_H - 1)
    local rule = Solid(f, "BORDER", C.divider, 1)
    rule:SetPoint("TOPLEFT", bar, "BOTTOMLEFT")
    rule:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT")
    rule:SetHeight(1)

    local mark = Solid(f, "ARTWORK", C.accent)
    mark:SetSize(3, 14)
    mark:SetPoint("LEFT", bar, "LEFT", 12, 0)

    f.title = Text(f, "GameFontHighlight")
    f.title:SetText(title)
    f.title:SetPoint("LEFT", mark, "RIGHT", 8, 0)

    f.subtitle = Text(f, "GameFontHighlightSmall", C.muted)
    f.subtitle:SetPoint("LEFT", f.title, "RIGHT", 10, 0)

    f.close = IconButton(f, ui.TITLE_H - 8, 5, C.danger)
    f.close:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
    f.close:SetScript("OnClick", function() f:Hide() end)
    -- Holds the search query, so it must stop short of the close button.
    f.subtitle:SetPoint("RIGHT", f.close, "LEFT", -8, 0)
    f.subtitle:SetWordWrap(false)

    local status = Solid(f, "BORDER", C.statbar)
    status:SetPoint("BOTTOMLEFT", 1, 1)
    status:SetPoint("BOTTOMRIGHT", -1, 1)
    status:SetHeight(ui.STATUS_H - 1)
    local srule = Solid(f, "BORDER", C.divider, 1)
    srule:SetPoint("BOTTOMLEFT", status, "TOPLEFT")
    srule:SetPoint("BOTTOMRIGHT", status, "TOPRIGHT")
    srule:SetHeight(1)

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)
    f.grip = grip

    f.statusText = Text(f, "GameFontHighlightSmall", C.faint)
    f.statusText:SetPoint("LEFT", status, "LEFT", 10, 0)
    f.statusText:SetPoint("RIGHT", grip, "LEFT", -8, 0)
    f.statusText:SetWordWrap(false)

    f:Hide()
    return f
end

--------------------------------------------------------------------------------
-- Controls
--------------------------------------------------------------------------------

-- primary: filled with the accent colour, for the one action that matters most.
function ui.Button(parent, text, width, onClick, primary)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, 24)
    local bg, hover = primary and C.accent or C.control, primary and C.accentHi or C.hover
    Fill(b, bg, primary and C.accent or C.border)

    local fs = Text(b, "GameFontHighlightSmall")
    fs:SetJustifyH("CENTER")
    b:SetFontString(fs)
    b:SetText(text)
    b:SetPushedTextOffset(0, -1)

    b:SetScript("OnEnter", function(self) self:SetBackdropColor(Unpack(hover)) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropColor(Unpack(bg)) end)
    b:SetScript("OnClick", onClick)
    return b
end

function ui.SearchBox(parent, width, onChange, hint)
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    eb:SetSize(width, 26)
    Fill(eb, C.field)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlight")
    eb:SetTextColor(Unpack(C.text))
    eb:SetTextInsets(26, 24, 0, 0)

    local icon = eb:CreateTexture(nil, "OVERLAY")
    icon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", 8, -1)
    icon:SetVertexColor(Unpack(C.muted))

    local placeholder = Text(eb, "GameFontHighlight", C.faint)
    placeholder:SetPoint("LEFT", 26, 0)
    placeholder:SetText(hint or "Search")

    local clear = IconButton(eb, 18, 4, C.hover)
    clear:SetPoint("RIGHT", -4, 0)
    clear:SetScript("OnClick", function() eb:SetText("") end)

    local function Sync(self)
        local empty = (self:GetText() or "") == ""
        placeholder:SetShown(empty and not self:HasFocus())
        clear:SetShown(not empty)
    end

    eb:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(Unpack(C.accent))
        icon:SetVertexColor(Unpack(C.text))
        Sync(self)
    end)
    eb:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(Unpack(C.border))
        icon:SetVertexColor(Unpack(C.muted))
        Sync(self)
    end)
    eb:SetScript("OnTextChanged", function(self)
        Sync(self)
        onChange(self:GetText() or "")
    end)
    eb:SetScript("OnEscapePressed", function(self)
        -- First Escape clears, the next one leaves the box.
        if (self:GetText() or "") ~= "" then self:SetText("") else self:ClearFocus() end
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    Sync(eb)
    return eb
end

function ui.Label(parent, template, colour)
    return Text(parent, template, colour)
end

--------------------------------------------------------------------------------
-- Panel: a box with a header strip
--
--   panel:SetTitle(text)   left of the header, upper-cased
--   panel:SetInfo(text)    right of the header
--------------------------------------------------------------------------------

function ui.Panel(parent, title)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Fill(p, C.panel)

    local head = Solid(p, "BORDER", C.header)
    head:SetPoint("TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", -1, -1)
    head:SetHeight(ui.HEADER_H - 1)
    local rule = Solid(p, "BORDER", C.divider, 1)
    rule:SetPoint("TOPLEFT", head, "BOTTOMLEFT")
    rule:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT")
    rule:SetHeight(1)

    p.info = Text(p, "GameFontHighlightSmall", C.muted)
    p.info:SetPoint("RIGHT", head, "RIGHT", -8, 0)
    p.info:SetJustifyH("RIGHT")

    p.titleText = Text(p, "GameFontNormalSmall", C.muted)
    p.titleText:SetPoint("LEFT", head, "LEFT", 8, 0)
    p.titleText:SetPoint("RIGHT", p.info, "LEFT", -8, 0)
    p.titleText:SetWordWrap(false)

    function p:SetTitle(text) self.titleText:SetText(text and text:upper() or "") end
    function p:SetInfo(text) self.info:SetText(text or "") end

    p:SetTitle(title)
    return p
end

--------------------------------------------------------------------------------
-- Scrollbar: slim, with a thumb sized to how much of the content is in view
--
--   bar:SetRange(maxValue, visibleFraction)
--   bar:SetPosition(v)     moves the thumb without calling onScroll
--------------------------------------------------------------------------------

local function Scrollbar(parent, onScroll)
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(BAR_W)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)

    local track = Solid(bar, "BACKGROUND", { 1, 1, 1, 0.04 })
    track:SetAllPoints()
    bar:SetThumbTexture(WHITE)
    local thumb = bar:GetThumbTexture()
    thumb:SetSize(BAR_W, 24)
    thumb:SetColorTexture(Unpack(C.faint))

    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function() thumb:SetColorTexture(Unpack(C.muted)) end)
    bar:SetScript("OnLeave", function() thumb:SetColorTexture(Unpack(C.faint)) end)
    bar:SetScript("OnValueChanged", function(self, v)
        -- The owner writes the bar back to the position it settled on;
        -- without this that write would come straight back as a scroll.
        if self._quiet then return end
        onScroll(v)
    end)

    function bar:SetPosition(v)
        self._quiet = true
        self:SetValue(v)
        self._quiet = false
    end

    function bar:SetRange(maxValue, fraction)
        self._quiet = true
        self:SetMinMaxValues(0, max(0, maxValue))
        self._quiet = false
        local h = self:GetHeight() or 0
        thumb:SetHeight(max(24, floor(h * min(1, fraction or 1))))
        self:SetShown(maxValue > 0)
    end

    return bar
end

--------------------------------------------------------------------------------
-- Virtual list
--
-- Only as many rows exist as fit; scrolling moves an offset and re-renders
-- them. A list of forty thousand globals costs the same as a list of ten.
--
--   opts.title                  panel header
--   opts.pip                    leave room for a coloured marker, row.pip
--   opts.render(row, item)      set row.text / row.tag (/ row.pip)
--   opts.onClick(item)
--   opts.isSelected(item)       -> bool
--------------------------------------------------------------------------------

local function CreateRow(list)
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ui.ROW_H)
    row:RegisterForClicks("LeftButtonUp")

    row.stripe = Solid(row, "BACKGROUND", { 1, 1, 1, 0.018 })
    row.stripe:SetAllPoints()

    row.selected = Solid(row, "BACKGROUND", { C.accent[1], C.accent[2], C.accent[3], 0.22 }, 1)
    row.selected:SetAllPoints()
    row.selected:Hide()
    row.edge = Solid(row, "ARTWORK", C.accent)
    row.edge:SetPoint("TOPLEFT")
    row.edge:SetPoint("BOTTOMLEFT")
    row.edge:SetWidth(2)
    row.edge:Hide()

    row:SetHighlightTexture(WHITE)
    row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)

    local left = 8
    if list.opts.pip then
        row.pip = row:CreateTexture(nil, "ARTWORK")
        row.pip:SetSize(6, 6)
        row.pip:SetPoint("LEFT", 8, 0)
        row.pip:SetColorTexture(Unpack(C.muted))
        left = 20
    end

    row.tag = Text(row, "GameFontHighlightSmall", C.faint)
    row.tag:SetPoint("RIGHT", -6, 0)
    row.tag:SetJustifyH("RIGHT")

    row.text = Text(row, "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", left, 0)
    row.text:SetPoint("RIGHT", row.tag, "LEFT", -8, 0)
    row.text:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        if self.item and list.opts.onClick then list.opts.onClick(self.item) end
    end)
    return row
end

function ui.List(parent, opts)
    local list = ui.Panel(parent, opts.title)
    list.opts, list.items, list.rows, list.offset = opts, {}, {}, 0

    local top = ui.HEADER_H + 2
    local bar = Scrollbar(list, function(v)
        list.offset = floor(v + 0.5)
        list:Refresh()
    end)
    bar:SetPoint("TOPRIGHT", -3, -top - 1)
    bar:SetPoint("BOTTOMRIGHT", -3, 3)
    list.bar = bar

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta) self:ScrollBy(-delta * 3) end)
    list:SetScript("OnSizeChanged", function(self) self:Layout() end)

    function list:Visible()
        return max(1, floor((self:GetHeight() - top - 2) / ui.ROW_H))
    end

    function list:Layout()
        local n = self:Visible()
        for i = #self.rows + 1, n do self.rows[i] = CreateRow(self) end
        for i, row in ipairs(self.rows) do
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 1, -top - (i - 1) * ui.ROW_H)
            row:SetPoint("RIGHT", self.bar, "LEFT", -3, 0)
            row.stripe:SetShown(i % 2 == 0)
        end
        self:Refresh()
    end

    function list:Refresh()
        local n = self:Visible()
        local total = #self.items
        local maxOffset = max(0, total - n)
        self.offset = min(max(0, self.offset), maxOffset)

        for i, row in ipairs(self.rows) do
            local item = i <= n and self.items[self.offset + i] or nil
            row.item = item
            if item then
                self.opts.render(row, item)
                local sel = self.opts.isSelected and self.opts.isSelected(item) or false
                row.selected:SetShown(sel)
                row.edge:SetShown(sel)
                row:Show()
            else
                row:Hide()
            end
        end

        self.bar:SetRange(maxOffset, total > 0 and n / total or 1)
        self.bar:SetPosition(self.offset)
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
-- Text view: a read-only, selectable, scrollable edit box in a panel
--
-- An edit box rather than a font string so the text can be selected and
-- copied with Ctrl+C. Typing is undone as it happens.
--
--   holder:SetEmptyText(text)   shown, centred, while there is no content
--------------------------------------------------------------------------------

function ui.TextView(parent, title)
    local holder = ui.Panel(parent, title)
    local top = ui.HEADER_H + 6

    local sf = CreateFrame("ScrollFrame", nil, holder)
    sf:SetPoint("TOPLEFT", 8, -top)
    sf:SetPoint("BOTTOMRIGHT", -14, 6)

    local bar = Scrollbar(holder, function(v) sf:SetVerticalScroll(v) end)
    bar:SetPoint("TOPRIGHT", -3, -ui.HEADER_H - 3)
    bar:SetPoint("BOTTOMRIGHT", -3, 3)

    local function ScrollTo(v)
        local range = sf:GetVerticalScrollRange() or 0
        v = min(max(0, v), range)
        sf:SetVerticalScroll(v)
        bar:SetPosition(v)
    end

    -- Also clamps: when a wider window reflows the text into fewer lines the
    -- range can drop below the current offset, leaving blank space below.
    local function SyncBar()
        local range = sf:GetVerticalScrollRange() or 0
        local h = sf:GetHeight() or 0
        bar:SetRange(range, (h + range) > 0 and h / (h + range) or 1)
        ScrollTo(sf:GetVerticalScroll() or 0)
    end

    sf:SetScript("OnScrollRangeChanged", SyncBar)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        ScrollTo((self:GetVerticalScroll() or 0) - delta * ui.ROW_H * 3)
    end)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlight")
    eb:SetTextColor(Unpack(C.text))
    eb:SetMaxLetters(0)
    eb:SetTextInsets(2, 2, 2, 2)
    eb:EnableMouse(true)
    eb:SetWidth(400)
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        -- The revert moves the cursor to the end; don't let that scroll.
        self._reverting = true
        self:SetText(self.value or "")
        self:SetCursorPosition(0)
        self._reverting = false
    end)
    -- Keep the cursor in view while selecting with the keyboard.
    eb:SetScript("OnCursorChanged", function(self, _, y, _, h)
        if self._reverting or not self:HasFocus() then return end
        local cy, scroll, view = -(y or 0), sf:GetVerticalScroll() or 0, sf:GetHeight() or 0
        if cy < scroll then
            ScrollTo(cy)
        elseif cy + (h or 0) > scroll + view then
            ScrollTo(cy + (h or 0) - view)
        end
    end)
    sf:SetScrollChild(eb)
    sf:SetScript("OnSizeChanged", function(_, w)
        eb:SetWidth(max(50, w or 0))
        SyncBar()
    end)

    local empty = Text(holder, "GameFontHighlight", C.faint)
    empty:SetPoint("CENTER", sf, "CENTER")
    empty:SetJustifyH("CENTER")
    empty:SetWidth(260)

    holder.scroll, holder.edit = sf, eb

    function holder:SetEmptyText(text) empty:SetText(text or "") end

    function holder:SetContent(text)
        eb.value = text or ""
        eb:SetText(eb.value)
        eb:SetCursorPosition(0)
        eb:ClearFocus()
        empty:SetShown(eb.value == "")
        ScrollTo(0)
    end

    function holder:GetContent() return eb.value or "" end

    function holder:SelectAll()
        eb:SetFocus()
        eb:HighlightText()
    end

    return holder
end
