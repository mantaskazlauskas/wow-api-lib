--------------------------------------------------------------------------------
-- WoW API Lib -- what actually exists in this client, right now
--
-- The documentation is what Blizzard chose to describe. This is what is
-- there: every global function, every C_ namespace and Lua library table and
-- the functions in it, every Enum, and the methods of every widget type.
-- Model.lua sets one against the other, which is how undocumented functions
-- and documented-but-gone ones are found.
--
-- Nothing here calls an API function. It only looks at names and types, so
-- the scan is the same in or out of combat and never touches a restricted or
-- secret value.
--
-- The result is plain data -- names, and numbers or strings for enum values --
-- so it goes into saved variables as it is.
--------------------------------------------------------------------------------

local _, ns = ...

local sort, pcall, rawget, type = table.sort, pcall, rawget, type

local Runtime = {}
ns.Runtime = Runtime

local result
local widgets

-- The Lua standard library tables, browsed the same way as C_ namespaces.
local LUA_LIBS = {
    bit = true, coroutine = true, debug = true, math = true,
    os = true, string = true, table = true,
}

-- Frame types built to read their method tables. Browser and Checkout are
-- left out on purpose: they are store and web-view frames, and creating one
-- just to look at it is not worth what it might start.
local FRAME_TYPES = {
    "Frame", "Button", "CheckButton", "EditBox", "ScrollFrame", "Slider",
    "StatusBar", "Cooldown", "ColorSelect", "GameTooltip", "MessageFrame",
    "ScrollingMessageFrame", "SimpleHTML", "Model", "PlayerModel",
    "DressUpModel", "CinematicModel", "TabardModel", "ModelScene",
    "MovieFrame", "FogOfWarFrame", "UnitPositionFrame",
    "ArchaeologyDigSiteFrame", "QuestPOIFrame", "ScenarioPOIFrame",
}

local ANIMATION_TYPES = {
    "Animation", "Alpha", "Translation", "LineTranslation", "Scale",
    "LineScale", "Rotation", "Path", "FlipBook", "VertexColor",
    "TextureCoordTranslation",
}

--------------------------------------------------------------------------------

local function SortedFunctionKeys(t)
    local out = {}
    for k, v in pairs(t) do
        if type(k) == "string" and type(v) == "function" then out[#out + 1] = k end
    end
    sort(out)
    return out
end

local function Methods(obj)
    local mt = obj and getmetatable(obj)
    local index = mt and mt.__index
    if type(index) ~= "table" then return nil end
    return SortedFunctionKeys(index)
end

-- Widgets are created once, hidden, and never parented to anything visible.
local function ScanWidgets()
    local out = {}
    local function Add(name, make)
        local ok, obj = pcall(make)
        if ok and obj then
            if obj.Hide then pcall(obj.Hide, obj) end
            out[name] = Methods(obj)
        end
        return ok and obj or nil
    end

    for _, t in ipairs(FRAME_TYPES) do
        Add(t, function() return CreateFrame(t) end)
    end

    local host = CreateFrame("Frame")
    host:Hide()
    Add("Texture",     function() return host:CreateTexture() end)
    Add("MaskTexture", function() return host:CreateMaskTexture() end)
    Add("FontString",  function() return host:CreateFontString() end)
    Add("Line",        function() return host:CreateLine() end)
    Add("Font",        function() return CreateFont("WowApiLibScanFont") end)

    local group = Add("AnimationGroup", function() return host:CreateAnimationGroup() end)
    if group then
        for _, t in ipairs(ANIMATION_TYPES) do
            local anim = Add(t, function() return group:CreateAnimation(t) end)
            if t == "Path" and anim then
                Add("ControlPoint", function() return anim:CreateControlPoint() end)
            end
        end
    end

    return out
end

-- Enum is data, not functions: copied whole, values only.
local function ScanEnums()
    local out = {}
    local E = rawget(_G, "Enum")
    if type(E) ~= "table" then return out end
    for name, t in pairs(E) do
        if type(name) == "string" and type(t) == "table" then
            local values = {}
            for k, v in pairs(t) do
                local tv = type(v)
                if type(k) == "string" and (tv == "number" or tv == "string" or tv == "boolean") then
                    values[k] = v
                end
            end
            out[name] = values
        end
    end
    return out
end

-- true when a global was put there by Blizzard (the C API or Blizzard's own UI
-- code), false when an addon defined it. Without issecurevariable, which every
-- retail client has, everything counts as Blizzard's.
local function IsBlizzard(name)
    if not issecurevariable then return true end
    local ok, secure = pcall(issecurevariable, _G, name)
    return not ok or secure
end

--------------------------------------------------------------------------------

-- Scans once and keeps the result. `force` rescans, for after other addons
-- have loaded more of the UI.
function Runtime.Scan(force)
    if result and not force then return result end

    local names = {}
    for k in pairs(_G) do
        if type(k) == "string" then names[#names + 1] = k end
    end
    sort(names)

    local functions, namespaces = {}, {}
    local addonFunctions = 0
    for i = 1, #names do
        local name = names[i]
        local v = rawget(_G, name)
        local t = type(v)
        if t == "function" then
            if IsBlizzard(name) then
                functions[#functions + 1] = name
            else
                addonFunctions = addonFunctions + 1
            end
        elseif t == "table" and (name:find("^C_") or LUA_LIBS[name]) then
            namespaces[name] = SortedFunctionKeys(v)
        end
    end

    -- Widget methods do not change within a session, and every scan would
    -- otherwise leave another set of frames behind that can never be freed.
    widgets = widgets or ScanWidgets()

    result = {
        functions      = functions,
        namespaces     = namespaces,
        enums          = ScanEnums(),
        widgets        = widgets,
        -- Counted, not listed: another addon's globals are not the WoW API.
        addonFunctions = addonFunctions,
    }
    return result
end

function Runtime.IsScanned() return result ~= nil end
