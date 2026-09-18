--------------------------------------------------------------------------------
-- WoW API Lib -- entries and groups as text
--
-- Plain text, no colour codes: the detail pane is an edit box so it can be
-- selected and copied, and escape sequences would come along with the copy.
--
-- A function is written the way it is called --
--
--   local uiMapID = C_Map.GetBestMapForUnit(unitToken)
--
-- -- followed by its arguments and returns with their types, then every other
-- field Blizzard put on the declaration (SecretArguments, MayReturnNothing,
-- the Midnight restriction flags...). Those are printed generically, by key,
-- so a flag added in a later build shows up without a change here.
--------------------------------------------------------------------------------

local _, ns = ...

local format, concat, rep, sort = string.format, table.concat, string.rep, table.sort
local tostring, type = tostring, type

local Format = {}
ns.Format = Format

-- Longest group listing the detail pane is given. The biggest groups run to
-- tens of thousands of lines, which an edit box renders slowly and nobody
-- reads; the export has all of it.
local GROUP_LINE_CAP = 3000

-- Keys the layout below already presents; everything else is a flag.
local LAID_OUT = {
    Name = true, Type = true, Arguments = true, Returns = true, Payload = true,
    Fields = true, Values = true, Documentation = true, LiteralName = true,
    Namespace = true, Functions = true, Events = true, Tables = true,
    Predicates = true,
}

--------------------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------------------

-- The entries here are Blizzard's own tables, still carrying the mixins'
-- links back to their parents; following one walks into a cycle.
local BACKREFS = ns.Docs.BACKREFS

-- A value on one line, for flags whose value is itself a table, e.g.
-- AddsForbiddenAspects = { { Argument = "self", Aspect = 3 } }.
local function Inline(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return tostring(v) end
    if depth > 4 then return "{ ... }" end
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = Inline(v[i], depth + 1) end
    local keys = {}
    for k, x in pairs(v) do
        if (type(k) ~= "number" or k < 1 or k > #v) and not BACKREFS[k] and type(x) ~= "function" then
            keys[#keys + 1] = k
        end
    end
    sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. Inline(v[k], depth + 1) end
    return "{ " .. concat(parts, ", ") .. " }"
end

-- What a field line already shows, on top of LAID_OUT.
local FIELD_LAID_OUT = {
    Nilable = true, Default = true, InnerType = true, KeyType = true,
    Mixin = true, EnumValue = true,
}

local function Flags(doc, out, indent, skip)
    local keys = {}
    for k in pairs(doc) do
        if type(k) == "string" and not LAID_OUT[k] and not (skip and skip[k]) and not BACKREFS[k]
           and k:find("^%u") and type(doc[k]) ~= "function" then
            keys[#keys + 1] = k
        end
    end
    sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = format("%s%s: %s", indent or "", k, Inline(doc[k]))
    end
end

local function Documentation(doc, out, indent)
    if type(doc.Documentation) ~= "table" then return end
    for _, line in ipairs(doc.Documentation) do out[#out + 1] = (indent or "") .. line end
end

local function IsOptional(f) return f.Nilable or f.Default ~= nil end

local function TypeOf(f)
    local t = f.Type or "?"
    if f.KeyType then
        t = format("table<%s, %s>", f.KeyType, f.InnerType or "?")
    elseif f.InnerType then
        t = format("%s of %s", t, f.InnerType)
    end
    if f.Mixin then t = t .. " (" .. f.Mixin .. ")" end
    return t
end

-- One argument, return, payload or structure field.
local function FieldLines(list, out, heading)
    if type(list) ~= "table" or #list == 0 then return end
    out[#out + 1] = heading
    local width = 0
    for _, f in ipairs(list) do
        if #(f.Name or "") > width then width = #f.Name end
    end
    for _, f in ipairs(list) do
        local extra = {}
        if f.Nilable then extra[#extra + 1] = "nilable" end
        if f.Default ~= nil then extra[#extra + 1] = "default " .. tostring(f.Default) end
        local line = format("  %s%s  %s", f.Name or "?", rep(" ", width - #(f.Name or "?")), TypeOf(f))
        if #extra > 0 then line = line .. ", " .. concat(extra, ", ") end
        if type(f.Documentation) == "table" then line = line .. "  -- " .. concat(f.Documentation, " ") end
        out[#out + 1] = line
        -- Field-level flags, e.g. a payload value that is ConditionalSecret.
        Flags(f, out, "      ", FIELD_LAID_OUT)
    end
end

local function Names(list, optionalMark)
    local parts = {}
    for _, f in ipairs(list or {}) do
        parts[#parts + 1] = (f.Name or "?") .. ((optionalMark and IsOptional(f)) and "?" or "")
    end
    return concat(parts, ", ")
end

--------------------------------------------------------------------------------
-- One line per entry, for lists and group dumps
--------------------------------------------------------------------------------

function Format.Signature(e)
    local d = e.doc
    local k = e.kind
    if (k == "function" or k == "method" or k == "global") then
        if not d then return e.full .. "(...)" end
        local call = format("%s(%s)", e.full, Names(d.Arguments, true))
        if d.Returns and #d.Returns > 0 then
            return format("local %s = %s", Names(d.Returns), call)
        end
        return call
    elseif k == "event" then
        if d and d.Payload and #d.Payload > 0 then
            return format("%s: %s", e.full, Names(d.Payload, true))
        end
        return e.full
    elseif k == "callback" then
        return format("%s = function(%s)", e.full, Names(d and d.Arguments))
    end
    return e.full
end

--------------------------------------------------------------------------------
-- Entry detail
--------------------------------------------------------------------------------

local FLAG_TEXT = {
    undocumented = "Not in Blizzard's API documentation -- it exists in this client, but nothing describes its arguments.",
    missing      = "Documented, but not present in this client. Usually a SecureOnly system or an API for another game flavour.",
}

local function Where(e, out)
    local g = e.group
    local doc = g and g.doc
    if doc and doc.Name then
        if doc.Namespace then
            out[#out + 1] = format("System %s, namespace %s", doc.Name, doc.Namespace)
        else
            out[#out + 1] = format("%s %s", doc.Type == "ScriptObject" and "Script object" or "System", doc.Name)
        end
        if doc.Environment and doc.Environment ~= "All" then
            out[#out + 1] = "Environment: " .. doc.Environment
        end
    elseif g then
        out[#out + 1] = g.label .. (g.sub and (" (" .. g.sub .. ")") or "")
    end
end

local function TableBody(d, out)
    if d.Type == "Enumeration" then
        local width = 0
        for _, f in ipairs(d.Fields or {}) do
            if #f.Name > width then width = #f.Name end
        end
        out[#out + 1] = "Values"
        for _, f in ipairs(d.Fields or {}) do
            out[#out + 1] = format("  %s%s = %s", f.Name, rep(" ", width - #f.Name), tostring(f.EnumValue))
        end
    elseif d.Type == "Constants" then
        out[#out + 1] = "Values"
        for _, v in ipairs(d.Values or {}) do
            out[#out + 1] = format("  %s = %s  (%s)", v.Name, tostring(v.Value), v.Type or "?")
        end
    elseif d.Type == "CallbackType" then
        FieldLines(d.Arguments, out, "Arguments")
    else
        FieldLines(d.Fields, out, "Fields")
        FieldLines(d.Values, out, "Values")
    end
end

function Format.Entry(e)
    local out = {}
    local d = e.doc

    out[#out + 1] = Format.Signature(e)
    out[#out + 1] = ""
    Where(e, out)
    out[#out + 1] = "Kind: " .. e.kind .. ((d and d.Type) and (" (" .. d.Type .. ")") or "")
    if e.kind == "event" and d and d.Name ~= e.full then
        out[#out + 1] = "Documented as: " .. d.Name
    end
    if e.flag then
        out[#out + 1] = ""
        out[#out + 1] = FLAG_TEXT[e.flag] or e.flag
    end

    if d then
        if d.Documentation then
            out[#out + 1] = ""
            Documentation(d, out)
        end

        local body = {}
        if e.kind == "function" or e.kind == "method" or e.kind == "global" then
            FieldLines(d.Arguments, body, "Arguments")
            FieldLines(d.Returns, body, "Returns")
        elseif e.kind == "event" then
            FieldLines(d.Payload, body, "Payload")
        elseif e.kind ~= "predicate" then
            TableBody(d, body)
        end
        if #body > 0 then
            out[#out + 1] = ""
            for _, l in ipairs(body) do out[#out + 1] = l end
        end

        local flags = {}
        Flags(d, flags, "  ")
        if #flags > 0 then
            out[#out + 1] = ""
            out[#out + 1] = "Flags"
            for _, l in ipairs(flags) do out[#out + 1] = l end
        end
    end

    return concat(out, "\n")
end

--------------------------------------------------------------------------------
-- Group listing
--------------------------------------------------------------------------------

local HEADINGS = {
    { kinds = { ["function"] = true, global = true }, title = "Functions" },
    { kinds = { method = true },    title = "Methods" },
    { kinds = { event = true },     title = "Events" },
    { kinds = { callback = true },  title = "Callbacks" },
    { kinds = { struct = true },    title = "Structures" },
    { kinds = { enum = true },      title = "Enumerations" },
    { kinds = { constants = true }, title = "Constants" },
    { kinds = { table = true },     title = "Other tables" },
    { kinds = { predicate = true }, title = "Predicates" },
}

-- `list` defaults to all of the group's entries; the browser passes the
-- search matches instead while a search is active.
function Format.Group(g, list)
    list = list or g.entries
    local out = {}
    out[#out + 1] = g.label .. (g.sub and ("  (" .. g.sub .. ")") or "")
    local doc = g.doc
    if doc then
        if doc.Environment and doc.Environment ~= "All" then
            out[#out + 1] = "Environment: " .. doc.Environment
        end
        Documentation(doc, out)
    end

    local lines = 0
    for _, h in ipairs(HEADINGS) do
        local section = {}
        for _, e in ipairs(list) do
            if h.kinds[e.kind] then section[#section + 1] = e end
        end
        if #section > 0 then
            out[#out + 1] = ""
            out[#out + 1] = format("%s (%d)", h.title, #section)
            for _, e in ipairs(section) do
                if lines >= GROUP_LINE_CAP then break end
                local mark = e.flag == "undocumented" and "  [undocumented]"
                          or e.flag == "missing" and "  [missing]" or ""
                out[#out + 1] = "  " .. Format.Signature(e) .. mark
                lines = lines + 1
            end
        end
    end

    if lines >= GROUP_LINE_CAP and #list > lines then
        out[#out + 1] = ""
        out[#out + 1] = format("... %d more. /wal export writes all of it to disk.", #list - lines)
    end

    return concat(out, "\n")
end
