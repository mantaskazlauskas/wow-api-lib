--------------------------------------------------------------------------------
-- WoW API Lib -- entries as Lua annotations (LuaLS / sumneko format)
--
--   ---@param unitToken string
--   ---@return number? uiMapID
--   function C_Map.GetBestMapForUnit(unitToken) end
--
-- Paste one into a definitions file and the language server gives types and
-- completion for it; paste it into a chat and it is the exact signature. The
-- output is always valid Lua (the tests compile every entry), so it can be
-- dropped into any .lua file.
--
-- Blizzard's documentation types are not Lua types, so each one is mapped:
-- built-in names through TYPE_MAP below, documented enums and structures to
-- their own names, the script-object types (SimpleFrame...) to their widget
-- class, other capitalised names (classes Blizzard defines in Lua, like
-- AuraData) kept as they are, and anything else to `any`. tools/convert.py is
-- meant to use the same table when it writes annotations for the whole API --
-- keep the two in step.
--------------------------------------------------------------------------------

local _, ns = ...

local format, concat = string.format, table.concat

local Annotate = {}
ns.Annotate = Annotate

-- Blizzard documentation type -> LuaLS type.
Annotate.TYPE_MAP = {
    -- strings
    string = "string", cstring = "string", stringView = "string",
    WOWGUID = "string", UnitToken = "string", UnitTokenVariant = "string",
    UnitTokenPvPRestrictedForAddOns = "string", UnitTokenRestrictedForAddOns = "string",
    ClubId = "string", ClubStreamId = "string", kstringClubId = "string",
    textureKit = "string", textureAtlas = "string", TextureAsset = "string",
    TextureAssetDisk = "string", FileAsset = "string", uiAddon = "string", mouseButton = "string",
    kstringLfgListApplicant = "string", AuraFilters = "string", ScriptTypeName = "string",
    -- widget string enums ("TOPLEFT", "ARTWORK", "ADD"...)
    FramePoint = "string", DrawLayer = "string", BlendMode = "string", Orientation = "string",
    JustifyHorizontal = "string", JustifyVertical = "string", HTMLTextType = "string",
    -- numbers
    number = "number", luaIndex = "number", uiUnit = "number", fileID = "number",
    BigUInteger = "number", BigInteger = "number", time_t = "number", size = "number",
    SingleColorValue = "number", DurationSeconds = "number", WOWMONEY = "number",
    normalizedValue = "number", uiFontHeight = "number", Seconds = "number",
    FrameTime = "number", SoundHandle = "number",
    -- others
    bool = "boolean", boolean = "boolean", table = "table",
    luaFunction = "function", ["function"] = "function", LuaFunctionReference = "function",
    LuaValueVariant = "any", LuaValueReference = "any", any = "any",
    SpellIdentifier = "number|string",
    -- Blizzard mixins, as the types are declared in the UI source
    vector2 = "Vector2DMixin", vector3 = "Vector3DMixin",
    colorRGB = "ColorMixin", colorRGBA = "ColorMixin",
    ItemLocation = "ItemLocationMixin",
}

-- Script-object documentation is named Simple<X>API, and for most of them <X>
-- is the widget class GetObjectType returns. These are the exceptions.
Annotate.WIDGET_RENAMES = {
    Anim = "Animation", AnimGroup = "AnimationGroup",
    AnimAlpha = "Alpha", AnimFlipBook = "FlipBook", AnimPath = "Path",
    AnimRotation = "Rotation", AnimScale = "Scale", AnimScaleLine = "LineScale",
    AnimTranslation = "Translation", AnimTranslationLine = "LineTranslation",
    AnimTextureCoordTranslation = "TextureCoordTranslation", AnimVertexColor = "VertexColor",
    Checkbox = "CheckButton", HTML = "SimpleHTML", Movie = "MovieFrame",
}

-- "Anim" (from SimpleAnimAPI) -> "Animation"; most names pass through.
function Annotate.WidgetClass(name)
    return Annotate.WIDGET_RENAMES[name] or name
end

local RESERVED = {}
for w in ("and break do else elseif end false for function if in local nil not or repeat return then true until while")
         :gmatch("%a+") do
    RESERVED[w] = true
end

-- A name usable as a Lua identifier.
local function Ident(name)
    name = tostring(name or "_"):gsub("[^%w_]", "_")
    if name == "" or name:find("^%d") or RESERVED[name] then name = name .. "_" end
    return name
end

-- A table key, quoted when it is not an identifier.
local function Key(name)
    name = tostring(name)
    if name:find("^[%a_][%w_]*$") and not RESERVED[name] then return name end
    return format("[%q]", name)
end

-- A number as Lua source: infinities and NaN spelled so they evaluate, and
-- no precision lost to tostring's 14 digits.
local function Number(v)
    if v ~= v then return "0/0" end
    if v == math.huge then return "math.huge" end
    if v == -math.huge then return "-math.huge" end
    local s = format("%.14g", v)
    if tonumber(s) ~= v then s = format("%.17g", v) end
    return s
end

local function Literal(v)
    if type(v) == "string" then return format("%q", v) end
    if type(v) == "number" then return Number(v) end
    if type(v) == "boolean" then return tostring(v) end
    return "nil --[[ " .. type(v) .. " ]]"
end

-- Any value that ends up inside a `---` comment: one line, or the rest of it
-- would be read as code.
local function Flat(v)
    return (tostring(v):gsub("[\r\n]+", " "))
end

-- One documentation type name -> LuaLS.
function Annotate.Type(name)
    if not name then return "any" end
    local mapped = Annotate.TYPE_MAP[name]
    if mapped then return mapped end
    local t = ns.Model.TypeEntry(name)
    if t then
        if t.kind == "enum" then return t.full end
        if t.kind == "constants" then return "table" end
        return t.name
    end
    local widget = name:match("^Simple(%u%w*)$")
    if widget then return Annotate.WidgetClass(widget) end
    if name:find("^kstring") then return "string" end   -- kstringClubMessage...
    -- A class Blizzard defines in its Lua (AuraData, TooltipData, ItemInfo...):
    -- the name says far more than `any`, and type libraries such as Ketho's
    -- "WoW API" extension define most of them.
    if name:find("^%u[%w_]*$") then return name end
    return "any"
end

-- A field's full type: lists, maps and mixins included.
local function FieldType(f)
    if f.KeyType then
        return format("table<%s, %s>", Annotate.Type(f.KeyType), Annotate.Type(f.InnerType))
    end
    if f.InnerType and (f.Type == "table" or not f.Type) then
        local inner = Annotate.Type(f.InnerType)
        return inner:find("|", 1, true) and ("(" .. inner .. ")[]") or (inner .. "[]")
    end
    if f.Mixin then return f.Mixin end
    return Annotate.Type(f.Type)
end

local function Optional(f) return f.Nilable or f.Default ~= nil end

-- Free text on one comment line.
local function Words(list)
    if type(list) ~= "table" then return nil end
    local s = concat(list, " "):gsub("[\r\n]+", " ")
    return s ~= "" and s or nil
end

-- What follows a @param/@field/@return: documentation, default and flags.
local FIELD_KEYS = { Name = true, Type = true, Nilable = true, Default = true, InnerType = true,
                     KeyType = true, Mixin = true, Documentation = true, EnumValue = true,
                     -- an enumeration's size, which the values already show
                     NumValues = true, MinValue = true, MaxValue = true }
local function FieldNote(f)
    local parts = {}
    local doc = Words(f.Documentation)
    if doc then parts[#parts + 1] = doc end
    if f.Default ~= nil then parts[#parts + 1] = "default " .. Flat(f.Default) end
    local flags = {}
    for k, v in pairs(f) do
        if type(k) == "string" and not FIELD_KEYS[k] and k:find("^%u") and type(v) ~= "table" and type(v) ~= "function" then
            flags[#flags + 1] = v == true and k or (k .. "=" .. Flat(v))
        end
    end
    table.sort(flags)
    if #flags > 0 then parts[#parts + 1] = "(" .. concat(flags, ", ") .. ")" end
    return #parts > 0 and (" " .. concat(parts, " ")) or ""
end

-- Comment lines for the documentation and the entry-level flags.
local function Header(e, out)
    local d = e.doc
    if d then
        local doc = Words(d.Documentation)
        if doc then out[#out + 1] = "--- " .. doc end
    end
    if e.flag == "undocumented" then
        out[#out + 1] = "--- Undocumented: exists in this client, signature unknown."
    elseif e.flag == "missing" then
        out[#out + 1] = "--- Missing: documented, but not in this client."
    end
    if not d then return end
    local restrictions, other = {}, {}
    for k, v in pairs(d) do
        if type(k) == "string" and k:find("^%u") and type(v) ~= "function" and not ns.Docs.BACKREFS[k]
           and not FIELD_KEYS[k] and k ~= "Arguments" and k ~= "Returns" and k ~= "Payload" and k ~= "Fields"
           and k ~= "Values" and k ~= "LiteralName" then
            local text = (v == true) and k or (type(v) == "table" and k or (k .. ": " .. Flat(v)))
            local list = ns.Model.IsRestrictionKey(k) and restrictions or other
            list[#list + 1] = text
        end
    end
    table.sort(restrictions)
    table.sort(other)
    if #restrictions > 0 then out[#out + 1] = "--- Restrictions: " .. concat(restrictions, ", ") end
    if #other > 0 then out[#out + 1] = "--- Flags: " .. concat(other, ", ") end
end

local function ArgNames(list)
    local names = {}
    for _, f in ipairs(list or {}) do names[#names + 1] = Ident(f.Name) end
    return concat(names, ", ")
end

local function Params(list, out)
    for _, f in ipairs(list or {}) do
        out[#out + 1] = format("---@param %s%s %s%s", Ident(f.Name), Optional(f) and "?" or "", FieldType(f), FieldNote(f))
    end
end

-- Where a function is declared: methods of a documented script object belong
-- to its widget class (SimpleFrameAPI:Show -> Frame:Show).
local function FunctionTarget(e)
    local owner, method = e.full:match("^([^:]+):(.+)$")
    if owner then
        local widget = owner:match("^Simple(%u%w*)API$")
        return format("%s:%s", Ident(widget and Annotate.WidgetClass(widget) or owner), Ident(method))
    end
    local parts = {}
    for piece in e.full:gmatch("[^.]+") do parts[#parts + 1] = Ident(piece) end
    return concat(parts, ".")
end

local function Function(e, out)
    local d = e.doc
    Header(e, out)
    if not d then
        out[#out + 1] = "---@return any"
        out[#out + 1] = format("function %s(...) end", FunctionTarget(e))
        return
    end
    Params(d.Arguments, out)
    for _, f in ipairs(d.Returns or {}) do
        out[#out + 1] = format("---@return %s%s %s%s", FieldType(f), Optional(f) and "?" or "", Ident(f.Name), FieldNote(f))
    end
    out[#out + 1] = format("function %s(%s) end", FunctionTarget(e), ArgNames(d.Arguments))
end

local function Event(e, out)
    local d = e.doc
    out[#out + 1] = "--- Event " .. e.full
    Header(e, out)
    out[#out + 1] = "---@param self Frame"
    out[#out + 1] = format("---@param event %q", e.full)
    Params(d and d.Payload, out)
    local args = ArgNames(d and d.Payload)
    out[#out + 1] = format("local function On_%s(self, event%s) end", Ident(e.full), args ~= "" and (", " .. args) or "")
end

local function Enum(e, out)
    local d = e.doc or {}
    Header(e, out)
    out[#out + 1] = "---@enum " .. e.full
    out[#out + 1] = format("%s = {", FunctionTarget(e))
    for _, f in ipairs(d.Fields or {}) do
        out[#out + 1] = format("    %s = %s,", Key(f.Name), Literal(f.EnumValue))
    end
    out[#out + 1] = "}"
end

local function Struct(e, out)
    local d = e.doc or {}
    Header(e, out)
    out[#out + 1] = "---@class " .. Ident(e.name)
    for _, f in ipairs(d.Fields or {}) do
        out[#out + 1] = format("---@field %s%s %s%s", Key(f.Name), Optional(f) and "?" or "",
                               FieldType(f), FieldNote(f))
    end
end

local function Constants(e, out)
    local d = e.doc or {}
    Header(e, out)
    out[#out + 1] = format("%s = {", FunctionTarget(e))
    for _, v in ipairs(d.Values or {}) do
        out[#out + 1] = format("    %s = %s, -- %s", Key(v.Name), Literal(v.Value), tostring(v.Type or "?"))
    end
    out[#out + 1] = "}"
end

local function Callback(e, out)
    local d = e.doc or {}
    Header(e, out)
    local args = {}
    for _, f in ipairs(d.Arguments or {}) do
        args[#args + 1] = format("%s%s: %s", Ident(f.Name), Optional(f) and "?" or "", FieldType(f))
    end
    out[#out + 1] = format("---@alias %s fun(%s)", Ident(e.name), concat(args, ", "))
end

local function Predicate(e, out)
    local d = e.doc or {}
    out[#out + 1] = format("--- Restriction flag %s (%s)", e.full, tostring(d.Type or "?"))
    local doc = Words(d.Documentation)
    if doc then out[#out + 1] = "--- " .. doc end
    if d.FailureMode then out[#out + 1] = "--- FailureMode: " .. Flat(d.FailureMode) end
end

local WRITERS = {
    ["function"] = Function, method = Function, global = Function,
    event = Event, enum = Enum, struct = Struct, constants = Constants,
    callback = Callback, predicate = Predicate, table = Struct,
}

function Annotate.Entry(e)
    local out = {}
    local write = WRITERS[e.kind]
    if write then write(e, out) else out[1] = "-- " .. tostring(e.full) end
    return concat(out, "\n")
end

-- Longest group the detail pane is given, in entries; the export has the rest.
local GROUP_CAP = 400

function Annotate.Group(g, list)
    list = list or g.entries
    local out = { "-- " .. g.label .. (g.sub and ("  (" .. g.sub .. ")") or "") }
    for i, e in ipairs(list) do
        if i > GROUP_CAP then
            out[#out + 1] = ""
            out[#out + 1] = format("-- ... %d more. /wal export writes all of it to disk.", #list - GROUP_CAP)
            break
        end
        out[#out + 1] = ""
        out[#out + 1] = Annotate.Entry(e)
    end
    return concat(out, "\n")
end
