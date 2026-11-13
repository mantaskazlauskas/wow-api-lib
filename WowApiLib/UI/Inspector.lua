--------------------------------------------------------------------------------
-- WoW API Lib -- frame inspector
--
-- /wal inspect, or the Inspect button: hover any frame to see what it is,
-- press Shift to open it in the browser, Escape to stop. Much like /fstack,
-- except what you pick lands on its widget APIs.
--
-- Only mouse-enabled frames can be picked: that is what the client's mouse
-- focus reports, and it is the same limit /fstack has.
--
-- Everything read from the frame goes through pcall. A frame can be forbidden
-- (Blizzard-owned; touching it errors), and in Midnight a value can be secret
-- (it exists but cannot be printed); both show up as text instead of errors.
-- Nothing here calls a frame's scripts or changes it.
--
-- Shift and Escape are read with a keyboard-enabled frame that passes every
-- other key through. Choosing whether a key passes through is restricted in
-- combat, so the inspector refuses to start in combat and stops when combat
-- starts.
--------------------------------------------------------------------------------

local _, ns = ...

local format = string.format
local ui = ns.ui
local C = ui.C

local driver, box, tip, tipText
local active, current

--------------------------------------------------------------------------------
-- Reading a frame safely
--------------------------------------------------------------------------------

local function Secret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

local function Str(v)
    if Secret(v) then return "<secret>" end
    if type(v) == "number" then
        local s = format("%.1f", v)
        return (s:gsub("%.0$", ""))
    end
    return tostring(v)
end

-- obj:method(...), or nil when it errors or does not exist.
local function Call(obj, method, ...)
    local ok, r1, r2, r3, r4, r5 = pcall(function(...)
        local f = obj[method]
        if type(f) ~= "function" then return nil end
        return f(obj, ...)
    end, ...)
    if ok then return r1, r2, r3, r4, r5 end
end

local function IsForbidden(f)
    local ok, r = pcall(function() return f.IsForbidden and f:IsForbidden() end)
    return not ok or r == true
end

local function NameOf(f)
    if not f then return "nil" end
    if IsForbidden(f) then return "<forbidden>" end
    local name = Call(f, "GetName")
    if type(name) == "string" and not Secret(name) then return name end
    local debug = Call(f, "GetDebugName")
    if type(debug) == "string" and debug ~= "" and not Secret(debug) then return debug end
    return "<anonymous " .. tostring(Call(f, "GetObjectType") or "frame") .. ">"
end

local SCRIPTS = {
    "OnShow", "OnHide", "OnEvent", "OnUpdate", "OnClick", "OnEnter", "OnLeave",
    "OnMouseDown", "OnMouseUp", "OnMouseWheel", "OnDragStart", "OnDragStop",
    "OnSizeChanged", "OnValueChanged", "OnTextChanged", "OnEditFocusGained",
    "OnKeyDown",
}

-- The script-object documentation names the widget APIs "Simple<Type>API".
-- Whatever this frame IsObjectType of, among those, is what applies to it.
local function DocTypes(f)
    local out, groups = {}, {}
    for _, g in ipairs(ns.Model.Groups()) do
        local doc = g.doc
        local t = doc and doc.Type == "ScriptObject" and doc.Name and doc.Name:match("^Simple(.+)API$")
        if t and Call(f, "IsObjectType", t) == true then
            out[#out + 1] = t
            groups[#groups + 1] = g
        end
    end
    return out, groups
end

-- Everything the browser shows about a frame; plain data, built once at pick.
function ns.DescribeFrame(f)
    local info = { name = NameOf(f), objectType = Call(f, "GetObjectType") }
    if not f or IsForbidden(f) then
        info.forbidden = true
        return info
    end

    local w, h = Call(f, "GetSize")
    local rows = {
        { "Size", format("%s x %s", Str(w), Str(h)) },
        { "Shown", format("%s (visible: %s)", Str(Call(f, "IsShown")), Str(Call(f, "IsVisible"))) },
    }
    -- Textures and font strings can take the mouse too, but they have no
    -- strata, children or scripts of their own.
    if Call(f, "IsObjectType", "Frame") == true then
        rows[#rows + 1] = { "Strata", format("%s, level %s", Str(Call(f, "GetFrameStrata")), Str(Call(f, "GetFrameLevel"))) }
        rows[#rows + 1] = { "Scale", format("%s (effective %s), alpha %s", Str(Call(f, "GetScale")),
                                            Str(Call(f, "GetEffectiveScale")), Str(Call(f, "GetAlpha"))) }
        rows[#rows + 1] = { "Mouse", format("enabled %s, wheel %s", Str(Call(f, "IsMouseEnabled")),
                                            Str(Call(f, "IsMouseWheelEnabled"))) }
        rows[#rows + 1] = { "Protected", Str(Call(f, "IsProtected")) }
        rows[#rows + 1] = { "Children", format("%s frames, %s regions", Str(Call(f, "GetNumChildren")),
                                               Str(Call(f, "GetNumRegions"))) }
    else
        rows[#rows + 1] = { "Layer", format("%s, alpha %s", Str(Call(f, "GetDrawLayer")), Str(Call(f, "GetAlpha"))) }
    end
    info.rows = rows

    info.parents = {}
    local p = Call(f, "GetParent")
    while p and #info.parents < 10 do
        info.parents[#info.parents + 1] = format("%s (%s)", NameOf(p), tostring(Call(p, "GetObjectType") or "?"))
        if IsForbidden(p) then break end
        p = Call(p, "GetParent")
    end

    info.points = {}
    for i = 1, tonumber(Call(f, "GetNumPoints")) or 0 do
        local point, rel, relPoint, x, y = Call(f, "GetPoint", i)
        if point then
            info.points[#info.points + 1] = format("%s to %s %s, %s, %s", Str(point),
                rel and NameOf(rel) or "screen", Str(relPoint), Str(x), Str(y))
        end
    end

    info.scripts = {}
    for _, script in ipairs(SCRIPTS) do
        if Call(f, "HasScript", script) and Call(f, "GetScript", script) then
            info.scripts[#info.scripts + 1] = script
        end
    end

    info.types, info.docGroups = DocTypes(f)
    return info
end

--------------------------------------------------------------------------------
-- Pick mode
--------------------------------------------------------------------------------

local function Hovered()
    if GetMouseFoci then
        local foci = GetMouseFoci()
        return foci and foci[1]
    end
    if GetMouseFocus then return GetMouseFocus() end
end

local function Build()
    box = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    box:SetFrameStrata("TOOLTIP")
    box:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    box:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 1)
    box:EnableMouse(false)
    box:Hide()

    tip = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    tip:SetFrameStrata("TOOLTIP")
    tip:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    tip:SetBackdropColor(C.window[1], C.window[2], C.window[3], 0.95)
    tip:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 1)
    tip:EnableMouse(false)
    tip:Hide()
    tipText = ui.Label(tip, "GameFontHighlightSmall")
    tipText:SetPoint("TOPLEFT", 8, -6)

    driver = CreateFrame("Frame", nil, UIParent)
    driver:Hide()
    driver:EnableKeyboard(true)
    driver:RegisterEvent("PLAYER_REGEN_DISABLED")
    driver:SetScript("OnEvent", function() ns.StopInspector() end)
    driver:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            ns.StopInspector(true)
        elseif key == "LSHIFT" or key == "RSHIFT" then
            self:SetPropagateKeyboardInput(false)
            local f = current
            ns.StopInspector()
            if f then ns.InspectFrame(f) end
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    driver:SetScript("OnUpdate", function()
        local f = Hovered()
        if f ~= current then
            current = f
            box:ClearAllPoints()
            local placed = f and not IsForbidden(f) and pcall(function()
                box:SetPoint("TOPLEFT", f, "TOPLEFT")
                box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT")
            end)
            box:SetShown(placed and true or false)
            local w, h
            if f and not IsForbidden(f) then w, h = Call(f, "GetSize") end
            tipText:SetText(format("%s  |cff8b909e%s  %s x %s|r\n|cff8b909eShift: inspect   Esc: stop|r",
                f and NameOf(f) or "nothing under the cursor", tostring(f and Call(f, "GetObjectType") or ""),
                Str(w or "?"), Str(h or "?")))
            tip:SetSize((tipText:GetStringWidth() or 200) + 16, (tipText:GetStringHeight() or 24) + 12)
        end
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        tip:ClearAllPoints()
        tip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 18, y / scale + 18)
    end)
end

function ns.StartInspector()
    if InCombatLockdown and InCombatLockdown() then
        ns.Print("the frame inspector can't run in combat.")
        return
    end
    if not driver then Build() end
    active, current = true, nil
    -- The browser sits above most of the UI; get it out of the way.
    ns.HideBrowser()
    driver:Show()
    tip:Show()
end

-- reopen: show the browser again (stopped with Escape rather than a pick).
function ns.StopInspector(reopen)
    if not active then return end
    active, current = false, nil
    driver:Hide()
    -- Don't stay anchored to the last hovered frame: it may be protected.
    box:ClearAllPoints()
    box:Hide()
    tip:Hide()
    if reopen then ns.ShowBrowser() end
end

function ns.IsInspecting() return active == true end
