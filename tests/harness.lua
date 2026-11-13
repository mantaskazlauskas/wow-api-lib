--------------------------------------------------------------------------------
-- Test harness: a stubbed WoW client, then the addon loaded in .toc order.
--
--   ADDON     path to WowApiLib/
--   FIXTURES  path to tests/fixtures/
--   UI_ROOT   optional: a folder holding Blizzard_APIDocumentation/ and
--             Blizzard_APIDocumentationGenerated/ (Interface/AddOns of a
--             wow-ui-source checkout). Given, the real mixins and the real
--             generated documentation are loaded instead of the fixtures.
--   SCENARIO  "fresh"      docs loaded by the addon, as on a normal login
--             "preloaded"  /api was typed first, so the docs are already in
--             "noapi"      the documentation addon refuses to load
--
-- Globals for suites: ok, eq, section, FAILED, NS, CHAT, Slash, DB.
--------------------------------------------------------------------------------

local ADDON, FIXTURES, UI_ROOT = ...
REAL = UI_ROOT ~= nil

FAILED = 0
function section(name) print("\n-- " .. name) end
function ok(cond, what)
    if cond then print("  ok    " .. what) else FAILED = FAILED + 1; print("  FAIL  " .. what) end
    return cond
end
function eq(got, want, what)
    return ok(got == want, what .. (got == want and "" or ("  (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")))
end

--------------------------------------------------------------------------------
-- Lua library bits WoW has as globals
--------------------------------------------------------------------------------

format  = string.format
tinsert = table.insert
wipe    = function(t) for k in pairs(t) do t[k] = nil end return t end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
date    = os.date
string.split = function(sep, s)
    local out = {}
    for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
    return unpack(out)
end

function Mixin(obj, ...)
    for i = 1, select("#", ...) do
        for k, v in pairs((select(i, ...))) do obj[k] = v end
    end
    return obj
end
function CreateFromMixins(...) return Mixin({}, ...) end

--------------------------------------------------------------------------------
-- Widgets
--
-- Each type's methods live in one table, and that table is the object's
-- metatable __index, as in the client -- which is what Runtime.lua reads to
-- list widget methods. Methods not written out here are no-ops, supplied by a
-- second metatable on the method table so they never show up in pairs().
--------------------------------------------------------------------------------

local noop = function() end
local METHODS = {}

local function Methods(objType)
    local m = METHODS[objType]
    if m then return m end
    -- Only method names (capitalised) fall back to a no-op; an object's own
    -- unset fields (`_h`, `item`, ...) must still read as nil.
    m = setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:find("^%u") then return noop end
    end })

    function m:SetScript(name, fn) self._scripts[name] = fn end
    function m:GetScript(name) return self._scripts[name] end
    function m:HookScript(name, fn) self._scripts[name] = fn end
    function m:Show() self._shown = true end
    function m:Hide() self._shown = false end
    function m:SetShown(v) self._shown = not not v end
    function m:IsShown() return self._shown end
    function m:SetText(t)
        self._text = t
        if objType == "EditBox" and self._scripts.OnTextChanged then
            self._scripts.OnTextChanged(self, false)
        end
    end
    function m:GetText() return self._text end
    function m:SetSize(w, h) self._w, self._h = w, h end
    function m:SetWidth(w) self._w = w end
    function m:SetHeight(h) self._h = h end
    -- Anchored frames have no size in the stub; a list gets room for rows.
    function m:GetWidth() return self._w or 300 end
    function m:GetHeight() return self._h or 400 end
    function m:GetParent() return self._parent end
    function m:RegisterEvent(e) self._events[e] = true end
    function m:UnregisterEvent(e) self._events[e] = nil end
    function m:SetMinMaxValues(a, b) self._min, self._max = a, b end
    function m:SetValue(v)
        self._value = v
        if self._scripts.OnValueChanged then self._scripts.OnValueChanged(self, v) end
    end
    function m:GetHighlightTexture() return self._hl end
    function m:SetHighlightTexture() self._hl = NewObject("Texture", self) end
    function m:GetThumbTexture() return self._thumb end
    function m:SetThumbTexture() self._thumb = NewObject("Texture", self) end
    function m:CreateFontString() return NewObject("FontString", self) end
    function m:CreateTexture() return NewObject("Texture", self) end
    function m:CreateMaskTexture() return NewObject("MaskTexture", self) end
    function m:CreateLine() return NewObject("Line", self) end
    function m:CreateAnimationGroup() return NewObject("AnimationGroup", self) end
    function m:CreateAnimation(t) return NewObject(t or "Animation", self) end
    function m:CreateControlPoint() return NewObject("ControlPoint", self) end

    METHODS[objType] = m
    return m
end

FRAMES = {}

function NewObject(objType, parent, name)
    local o = setmetatable({ _type = objType, _parent = parent, _scripts = {}, _events = {}, _shown = true },
                           { __index = Methods(objType) })
    FRAMES[#FRAMES + 1] = o
    if name then _G[name] = o end
    return o
end

-- Frame types this client refuses to create, as some real types are refused.
REFUSED_TYPES = { ArchaeologyDigSiteFrame = true }

function CreateFrame(objType, name, parent)
    if REFUSED_TYPES[objType] then error("Unknown frame type " .. objType) end
    return NewObject(objType, parent, name)
end
function CreateFont(name) return NewObject("Font", nil, name) end

UIParent = NewObject("Frame")
UISpecialFrames = {}
SlashCmdList = {}
WOW_PROJECT_ID = 1
WOW_PROJECT_MAINLINE = 1
WOW_PROJECT_CLASSIC = 2
function ReloadUI() RELOADED = true end
function GetBuildInfo()
    return "12.0.1", "99999", "Jan 1 2026", 120100, "Version 12.0.1", "Release x64"
end
-- A PTR client; IsBetaBuild is left undefined, as a client lacking a query.
function IsPublicTestClient() return true end
function IsTestBuild() return false end
function GetLocale() return "enUS" end

CHAT = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) CHAT[#CHAT + 1] = msg end, SetMaxLines = noop }

function hooksecurefunc(t, name, hook)
    local orig = t[name]
    t[name] = function(...)
        local r = { orig(...) }
        hook(...)
        return unpack(r)
    end
end

-- Globals an addon (not Blizzard) defined.
ADDON_GLOBALS = { SomeAddonGlobal = true }
function issecurevariable(t, name)
    if ADDON_GLOBALS[name] then return false, "SomeAddon" end
    return true
end

--------------------------------------------------------------------------------
-- The world the runtime scan finds
--------------------------------------------------------------------------------

if REAL then
    -- The real documentation reads Enum.X.Y and Constants.X.Y at file scope.
    local function Auto()
        return setmetatable({}, { __index = function(t, k)
            local sub = setmetatable({}, { __index = function() return 0 end })
            rawset(t, k, sub)
            return sub
        end })
    end
    Enum, Constants = Auto(), Auto()
else
    C_Map = {
        GetBestMapForUnit = noop,
        ClearUserWaypoint = noop,
        SecretNewThing    = noop,       -- not in the fixture docs
    }
    C_Hidden = { Foo = noop, Bar = noop } -- a whole namespace the docs miss
    UnitName = noop
    SomeBlizzardGlobal = noop
    SomeAddonGlobal = noop
    Enum = {
        UIMapType     = { Cosmic = 0, World = 1, Continent = 2 },
        UIMapTypeMeta = { NumValues = 3, MinValue = 0, MaxValue = 2 },
        -- Named like UndocumentedE's companion, but holding a real value too.
        UndocumentedEMeta = { NumValues = 2, Extra = 2 },
        UndocumentedE = { A = 1, B = 2 },
        -- As the live client has it: Enum.CDMLayoutMode holds booleans.
        CDMLayoutMode = { AccessOnly = false, AllowCreate = true },
        MixedE        = { N = 1, S = "x", F = false, T = true, M = 0 },
    }
end

--------------------------------------------------------------------------------
-- Blizzard's documentation addons
--------------------------------------------------------------------------------

local LOADED = {}

local function TocFiles(dir, toc)
    local out = {}
    for line in io.lines(dir .. "/" .. toc) do
        line = line:gsub("\r", ""):gsub("%s*%[.-%]%s*$", "")
        if line ~= "" and not line:find("^#") then out[#out + 1] = line end
    end
    return out
end

-- Enough of Blizzard_APIDocumentation to stand in for it with fixtures:
-- the processed lists, the back references and the methods the mixins add,
-- because those are exactly what Docs.lua has to strip.
local function StubAPIDocumentation()
    local api = { systems = {}, tables = {}, functions = {}, events = {}, fields = {} }
    local function Decorate(t, parentKey, parent)
        t.GetName = function(self) return self.Name end
        t.loweredName = (t.Name or ""):lower()
        if parentKey then t[parentKey] = parent end
    end
    local function AddTable(t)
        Decorate(t)
        api.tables[#api.tables + 1] = t
        for _, f in ipairs(t.Fields or {}) do Decorate(f, "Table", t) end
    end
    function api:AddDocumentationTable(info)
        if info.Name then
            Decorate(info)
            api.systems[#api.systems + 1] = info
            for _, fn in ipairs(info.Functions) do
                Decorate(fn, "System", info)
                api.functions[#api.functions + 1] = fn
                for _, a in ipairs(fn.Arguments or {}) do Decorate(a, "Function", fn) end
                for _, r in ipairs(fn.Returns or {}) do Decorate(r, "Function", fn) end
            end
            for _, ev in ipairs(info.Events) do
                Decorate(ev, "System", info)
                for _, p in ipairs(ev.Payload or {}) do Decorate(p, "Event", ev) end
            end
            for _, t in ipairs(info.Tables) do AddTable(t); t.System = info end
        else
            for _, t in ipairs(info.Tables) do AddTable(t) end
        end
    end
    return api
end

local function LoadBase()
    if REAL then
        local dir = UI_ROOT .. "/Blizzard_APIDocumentation"
        for _, f in ipairs(TocFiles(dir, "Blizzard_APIDocumentation.toc")) do
            assert(loadfile(dir .. "/" .. f))()
        end
    else
        APIDocumentation = StubAPIDocumentation()
    end
end

local function LoadGenerated()
    if REAL then
        local dir = UI_ROOT .. "/Blizzard_APIDocumentationGenerated"
        GENERATED_FILES = TocFiles(dir, "Blizzard_APIDocumentationGenerated.toc")
        for _, f in ipairs(GENERATED_FILES) do assert(loadfile(dir .. "/" .. f))() end
    else
        GENERATED_FILES = TocFiles(FIXTURES, "fixtures.toc")
        for _, f in ipairs(GENERATED_FILES) do assert(loadfile(FIXTURES .. "/" .. f))() end
    end
end

C_AddOns = {}
function C_AddOns.GetAddOnMetadata(_, key) return key == "Version" and "test" or nil end
function C_AddOns.IsAddOnLoaded(name) return LOADED[name] == true end
function C_AddOns.LoadAddOn(name)
    if LOADED[name] then return true end
    if SCENARIO == "noapi" and name:find("^Blizzard_APIDocumentation") then
        return false, "DISABLED"
    end
    if name == "Blizzard_APIDocumentation" then
        LoadBase()
    elseif name == "Blizzard_APIDocumentationGenerated" then
        if not LOADED.Blizzard_APIDocumentation then return false, "DEP_MISSING" end
        LoadGenerated()
    else
        return false, "MISSING"
    end
    LOADED[name] = true
    return true
end

if SCENARIO == "preloaded" then
    C_AddOns.LoadAddOn("Blizzard_APIDocumentation")
    C_AddOns.LoadAddOn("Blizzard_APIDocumentationGenerated")
end

--------------------------------------------------------------------------------
-- The addon, in .toc order
--------------------------------------------------------------------------------

NS = {}
for _, f in ipairs(TocFiles(ADDON, "WowApiLib.toc")) do
    local path = ADDON .. "/" .. f:gsub("\\", "/")
    assert(loadfile(path))("WowApiLib", NS)
end

-- ADDON_LOADED, as the client fires it after the saved variables are read.
for _, fr in ipairs(FRAMES) do
    if fr._events.ADDON_LOADED then fr._scripts.OnEvent(fr, "ADDON_LOADED", "WowApiLib") end
end
DB = WowApiLibDB

function Slash(msg) SlashCmdList.WOWAPILIB(msg) end

--------------------------------------------------------------------------------
-- Saved variables, written the way the client writes them
--------------------------------------------------------------------------------

local function Quote(s)
    return '"' .. s:gsub('[\\"\n\r]', { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r" }) .. '"'
end

local function Write(v, out, seen)
    local t = type(v)
    if t == "string" then out[#out + 1] = Quote(v)
    elseif t == "number" then
        out[#out + 1] = (v == math.floor(v) and math.abs(v) < 2^53) and string.format("%d", v) or string.format("%.17g", v)
    elseif t == "boolean" then out[#out + 1] = tostring(v)
    elseif t == "table" then
        assert(not seen[v], "cycle in saved variables")
        seen[v] = true
        out[#out + 1] = "{\n"
        local n = #v
        for i = 1, n do Write(v[i], out, seen); out[#out + 1] = ",\n" end
        for k, x in pairs(v) do
            local tk = type(k)
            if not (tk == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                assert(tk == "string" or tk == "number", "bad key type " .. tk)
                local tx = type(x)
                assert(tx ~= "function" and tx ~= "userdata" and tx ~= "thread",
                       "unsaveable value at key " .. tostring(k))
                out[#out + 1] = "[" .. (tk == "string" and Quote(k) or tostring(k)) .. "] = "
                Write(x, out, seen)
                out[#out + 1] = ",\n"
            end
        end
        out[#out + 1] = "}"
        seen[v] = nil
    else
        error("unsaveable " .. t)
    end
end

function SerializeSavedVariables()
    local out = { "\nWowApiLibDB = " }
    Write(WowApiLibDB, out, {})
    out[#out + 1] = "\n"
    return table.concat(out)
end
