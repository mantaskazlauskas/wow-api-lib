--------------------------------------------------------------------------------
-- WoW API Lib -- the browsable model
--
-- Joins the two sources into one list of groups, each holding entries:
--
--   group  { key, label, sub, source, doc, entries, search }
--   entry  { kind, name, full, group, doc, flag, search }
--
-- A documented system is a group; so is each script object (the widget APIs),
-- the pool of shared types that belong to no system, every namespace and Lua
-- library that exists at runtime but is not documented, the global functions
-- the documentation does not describe, undocumented enums, and each widget
-- type's methods.
--
-- `flag` is where the two sources disagree:
--
--   "undocumented"  exists in this client, absent from the documentation
--   "missing"       documented, absent from this client -- usually a
--                   SecureOnly system, or an API for another client flavour
--
-- The model is built once, the first time something asks for it. Everything
-- that reads it treats it as immutable.
--------------------------------------------------------------------------------

local _, ns = ...

local lower, sort, format = string.lower, table.sort, string.format

local Model = {}
ns.Model = Model

local groups, entries, stats
local docsError
local typeIndex, keyIndex, predicateNames

-- Short tags, as the entry list shows them.
Model.KIND_TAGS = {
    ["function"] = "fn",
    event        = "event",
    enum         = "enum",
    struct       = "struct",
    constants    = "const",
    callback     = "callback",
    predicate    = "pred",
    table        = "table",
    method       = "method",
    global       = "global",
}

--------------------------------------------------------------------------------
-- Construction helpers
--------------------------------------------------------------------------------

local function NewGroup(key, label, sub, source, doc)
    local g = {
        key = key, label = label, sub = sub, source = source, doc = doc,
        entries = {},
        search = lower(label .. (sub and (" " .. sub) or "")),
    }
    groups[#groups + 1] = g
    return g
end

local function AddEntry(g, kind, name, full, doc, flag)
    local e = {
        kind = kind, name = name, full = full or name,
        group = g, doc = doc, flag = flag,
    }
    e.search = lower(e.full)
    g.entries[#g.entries + 1] = e
    entries[#entries + 1] = e
    return e
end

local TABLE_KINDS = {
    Enumeration  = "enum",
    Structure    = "struct",
    Constants    = "constants",
    CallbackType = "callback",
}

-- Where a documented table lives at runtime, when it lives anywhere.
local function TablePath(t)
    if t.Type == "Enumeration" then return "Enum." .. t.Name end
    if t.Type == "Constants"   then return "Constants." .. t.Name end
    return t.Name
end

local function FunctionPath(system, fn)
    if system.Type == "ScriptObject" then return system.Name .. ":" .. fn.Name end
    if system.Namespace then return system.Namespace .. "." .. fn.Name end
    return fn.Name
end

local function AddTables(g, list)
    for _, t in ipairs(list or {}) do
        AddEntry(g, TABLE_KINDS[t.Type] or "table", t.Name, TablePath(t), t)
    end
end

local function AddPredicates(g, list)
    for _, p in ipairs(list or {}) do
        AddEntry(g, "predicate", p.Name, p.Name, p)
    end
end

local function SortEntries(g)
    local order = { ["function"] = 1, method = 1, global = 1, event = 2, callback = 3,
                    struct = 4, enum = 5, constants = 6, table = 7, predicate = 8 }
    sort(g.entries, function(a, b)
        local oa, ob = order[a.kind] or 9, order[b.kind] or 9
        if oa ~= ob then return oa < ob end
        return a.search < b.search
    end)
end

local function Set(list)
    local s = {}
    for i = 1, #(list or {}) do s[list[i]] = true end
    return s
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function BuildDocs(docGlobals, docNamespaces, docEnums)
    local systems, scripts = {}, {}
    local shared

    for _, f in ipairs(ns.Docs.Files()) do
        if f.Name then
            local g = NewGroup("sys:" .. f.Name, f.Namespace or f.Name,
                               f.Namespace and f.Name or nil, "docs", f)
            if f.Type == "ScriptObject" then
                scripts[#scripts + 1] = g
            else
                systems[#systems + 1] = g
            end

            for _, fn in ipairs(f.Functions or {}) do
                AddEntry(g, "function", fn.Name, FunctionPath(f, fn), fn)
                if f.Type ~= "ScriptObject" then
                    if f.Namespace then
                        local set = docNamespaces[f.Namespace]
                        if not set then
                            set = { group = g, names = {} }
                            docNamespaces[f.Namespace] = set
                        end
                        set.names[fn.Name] = true
                    else
                        docGlobals[fn.Name] = true
                    end
                end
            end
            for _, ev in ipairs(f.Events or {}) do
                AddEntry(g, "event", ev.LiteralName or ev.Name, nil, ev)
            end
            AddTables(g, f.Tables)
            AddPredicates(g, f.Predicates)
        else
            shared = shared or NewGroup("shared", "Shared types", "types used by several systems", "docs")
            AddTables(shared, f.Tables)
            AddPredicates(shared, f.Predicates)
        end

        for _, t in ipairs(f.Tables or {}) do
            if t.Type == "Enumeration" then docEnums[t.Name] = true end
        end
    end

    return systems, scripts, shared
end

-- Marks documented functions that do not exist here, and adds the ones that
-- exist here but are not documented, to the documented group they belong to.
local function Diff(rt, docNamespaces)
    for nsName, set in pairs(docNamespaces) do
        local live = rt.namespaces[nsName]
        local liveSet = Set(live)
        -- More than one system can document the same namespace.
        for _, g in ipairs(groups) do
            local doc = g.doc
            if doc and doc.Type ~= "ScriptObject" and doc.Namespace == nsName then
                for _, e in ipairs(g.entries) do
                    if e.kind == "function" and not liveSet[e.name] then e.flag = "missing" end
                end
            end
        end
        -- Undocumented ones go to the first system that documents the namespace.
        for _, name in ipairs(live or {}) do
            if not set.names[name] then
                AddEntry(set.group, "function", name, nsName .. "." .. name, nil, "undocumented")
            end
        end
    end

    local liveGlobals = Set(rt.functions)
    for _, g in ipairs(groups) do
        local doc = g.doc
        if doc and doc.Type ~= "ScriptObject" and not doc.Namespace then
            for _, e in ipairs(g.entries) do
                -- An addon may have defined the same name, so check the global
                -- itself rather than only the list of Blizzard's.
                if e.kind == "function" and not liveGlobals[e.name]
                   and type(rawget(_G, e.name)) ~= "function" then
                    e.flag = "missing"
                end
            end
        end
    end
end

-- Enum values are usually numbers, but not always: Enum.CDMLayoutMode holds
-- booleans, and `<` on booleans is an error. Orders by type first, so a mix
-- of types still sorts consistently; false sorts before true.
local function ValueLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end

-- Enum.FooMeta is the client's companion to Enum.Foo -- NumValues, MinValue
-- and MaxValue, which the documentation already has on Foo. Nearly every enum
-- has one, and listed as undocumented they outnumber the real finds ten to one.
local META_KEYS = { NumValues = true, MinValue = true, MaxValue = true }
local function IsMetaEnum(name, enums)
    local base = name:match("^(.+)Meta$")
    if not base or not enums[base] then return false end
    local any = false
    for k in pairs(enums[name]) do
        if not META_KEYS[k] then return false end
        any = true
    end
    return any
end

local function BuildRuntime(rt, docGlobals, docNamespaces, docEnums)
    local names = {}
    for name in pairs(rt.namespaces) do
        if not docNamespaces[name] then names[#names + 1] = name end
    end
    sort(names)
    for _, name in ipairs(names) do
        local lua = not name:find("^C_")
        local g = NewGroup("rt:" .. name, name, lua and "Lua library" or "not in docs", "runtime")
        for _, fn in ipairs(rt.namespaces[name]) do
            AddEntry(g, "function", fn, name .. "." .. fn, nil, not lua and "undocumented" or nil)
        end
    end

    local globals = NewGroup("rt:globals", "Global functions", "not in docs", "runtime")
    for _, fn in ipairs(rt.functions) do
        if not docGlobals[fn] then
            AddEntry(globals, "global", fn, nil, nil, "undocumented")
        end
    end

    local enumNames = {}
    for name in pairs(rt.enums) do
        if not docEnums[name] and not IsMetaEnum(name, rt.enums) then enumNames[#enumNames + 1] = name end
    end
    sort(enumNames)
    if #enumNames > 0 then
        local g = NewGroup("rt:enum", "Enum", "not in docs", "runtime")
        for _, name in ipairs(enumNames) do
            -- Shaped like a documented enumeration, so it formats the same way.
            local fields = {}
            for k, v in pairs(rt.enums[name]) do
                fields[#fields + 1] = { Name = k, Type = name, EnumValue = v }
            end
            sort(fields, function(a, b)
                if a.EnumValue ~= b.EnumValue then return ValueLess(a.EnumValue, b.EnumValue) end
                return a.Name < b.Name
            end)
            AddEntry(g, "enum", name, "Enum." .. name,
                     { Name = name, Type = "Enumeration", Fields = fields }, "undocumented")
        end
    end

    local widgetNames = {}
    for name in pairs(rt.widgets) do widgetNames[#widgetNames + 1] = name end
    sort(widgetNames)
    for _, name in ipairs(widgetNames) do
        local g = NewGroup("rt:widget:" .. name, "Widget: " .. name, "methods", "runtime")
        for _, m in ipairs(rt.widgets[name]) do
            AddEntry(g, "method", m, name .. ":" .. m)
        end
    end
end

local function ByLabel(a, b) return a.search < b.search end

local TYPE_KINDS = { enum = true, struct = true, constants = true, callback = true, table = true }

function Model.Build()
    if groups then return end
    groups, entries = {}, {}

    local ok, err = ns.Docs.Load()
    docsError = not ok and err or nil

    local docGlobals, docNamespaces, docEnums = {}, {}, {}
    local systems, scripts, shared = BuildDocs(docGlobals, docNamespaces, docEnums)

    local rt = ns.Runtime.Scan()
    Diff(rt, docNamespaces)

    -- Runtime groups are appended after the documented ones, so the documented
    -- order is settled here and the runtime order by BuildRuntime.
    sort(systems, ByLabel)
    sort(scripts, ByLabel)
    local ordered = {}
    for _, g in ipairs(systems) do ordered[#ordered + 1] = g end
    for _, g in ipairs(scripts) do ordered[#ordered + 1] = g end
    if shared then ordered[#ordered + 1] = shared end

    local docCount = #groups
    BuildRuntime(rt, docGlobals, docNamespaces, docEnums)
    for i = docCount + 1, #groups do ordered[#ordered + 1] = groups[i] end
    groups = ordered

    stats = { groups = #groups, entries = #entries, kinds = {}, flags = {} }
    for _, e in ipairs(entries) do
        stats.kinds[e.kind] = (stats.kinds[e.kind] or 0) + 1
        if e.flag then stats.flags[e.flag] = (stats.flags[e.flag] or 0) + 1 end
    end
    for _, g in ipairs(groups) do SortEntries(g) end

    typeIndex, keyIndex, predicateNames = {}, {}, {}
    for _, e in ipairs(entries) do
        local key = Model.EntryKey(e)
        if not keyIndex[key] then keyIndex[key] = e end
        if e.kind == "predicate" then predicateNames[e.name] = true end
        if TYPE_KINDS[e.kind] then
            -- Documented definitions are added before runtime ones, so they win.
            if not typeIndex[e.name] then typeIndex[e.name] = e end
            if not typeIndex[e.full] then typeIndex[e.full] = e end
        end
    end
end

-- Forgets the model; the next Build rescans the runtime and re-reads the docs
-- (the docs themselves are only ever loaded once).
function Model.Reset()
    groups, entries, stats = nil, nil, nil
    typeIndex, keyIndex, predicateNames = nil, nil, nil
    ns.Runtime.Scan(true)
end

--------------------------------------------------------------------------------
-- Lookups
--------------------------------------------------------------------------------

-- A stable name for an entry across sessions, for favourites.
function Model.EntryKey(e) return e.kind .. "|" .. e.full end

function Model.FindByKey(key)
    Model.Build()
    return keyIndex[key]
end

function Model.FindGroup(key)
    for _, g in ipairs(Model.Groups()) do
        if g.key == key then return g end
    end
end

-- The entry defining a type name as fields use it ("UIMapType", "AuraData"),
-- or by its full path ("Enum.UIMapType").
function Model.TypeEntry(name)
    Model.Build()
    return name and typeIndex[name] or nil
end

-- Calls fn(field) for every argument, return, payload value and field.
local FIELD_LISTS = { "Arguments", "Returns", "Payload", "Fields", "Values" }
local function EachField(d, fn)
    if type(d) ~= "table" then return end
    for _, key in ipairs(FIELD_LISTS) do
        local list = d[key]
        if type(list) == "table" then
            for _, f in ipairs(list) do
                if type(f) == "table" then fn(f) end
            end
        end
    end
end

-- Entries for the types an entry refers to, in the order they first appear.
-- An enumeration's values carry its own name as their type, so it is skipped.
function Model.RelatedTypes(e)
    local out, seen = {}, { [e] = true }
    EachField(e.doc, function(f)
        for _, name in ipairs({ f.Type or false, f.InnerType or false, f.KeyType or false }) do
            local t = name and Model.TypeEntry(name)
            if t and not seen[t] then
                seen[t] = true
                out[#out + 1] = t
            end
        end
    end)
    return out
end

-- Restriction flags, as the converter's glossary defines them: a declared
-- predicate (RequiresValidMap, HasRestrictions...) or a Secret* flag.
function Model.IsRestrictionKey(k)
    return type(k) == "string" and ((predicateNames and predicateNames[k]) or k:find("Secret", 1, true) ~= nil)
end

local function HasRestriction(d)
    for k in pairs(d) do
        if Model.IsRestrictionKey(k) then return true end
    end
    return false
end

function Model.IsRestricted(e)
    if e.restricted == nil then
        local d = e.doc
        local r = false
        if type(d) == "table" and e.kind ~= "predicate" then
            r = HasRestriction(d)
            if not r then EachField(d, function(f) r = r or HasRestriction(f) end) end
        end
        e.restricted = r
    end
    return e.restricted
end

-- Type names and field names an entry mentions, built the first time a
-- type: or field: search needs them.
local function Deep(e)
    if not e.deepTypes then
        local types, fields = { "|" }, { "|" }
        EachField(e.doc, function(f)
            for _, t in ipairs({ f.Type or false, f.InnerType or false, f.KeyType or false, f.Mixin or false }) do
                if t then types[#types + 1] = lower(tostring(t)) .. "|" end
            end
            if f.Name then fields[#fields + 1] = lower(tostring(f.Name)) .. "|" end
        end)
        e.deepTypes, e.deepFields = table.concat(types), table.concat(fields)
    end
    return e
end

function Model.Groups()    Model.Build() return groups end
function Model.Entries()   Model.Build() return entries end
function Model.Stats()     Model.Build() return stats end
function Model.DocsError() return docsError end

--------------------------------------------------------------------------------
-- Search
--
-- Case-insensitive substring matching. The query matches qualified names,
-- unless it starts with an operator:
--
--   type:AuraData     entries whose arguments, returns, payload or fields
--                     use that type
--   field:unitTarget  entries with an argument, return, payload value or
--                     field of that name
--
-- filters (optional): { kind = "functions"|"events"|"types",
--                       flag = "restricted"|"undocumented"|"missing" }
--
-- Returns nil when there is neither a query nor a filter. Otherwise the
-- matching entries in model order, the groups to show (every group with a
-- match, plus, for a plain name search without filters, every group whose
-- own name matches -- those are in `whole` and show all their entries),
-- per-group counts, and `pass`, the test itself.
--------------------------------------------------------------------------------

Model.KIND_FILTERS = {
    functions = { ["function"] = true, method = true, global = true },
    events    = { event = true },
    types     = { enum = true, struct = true, constants = true, callback = true, table = true },
}

function Model.Search(query, filters)
    Model.Build()
    local raw = strtrim(query or "")
    local kinds = filters and Model.KIND_FILTERS[filters.kind]
    local flag = filters and filters.flag
    if raw == "" and not kinds and not flag then return nil end

    local mode, q = "name", lower(raw)
    local op, rest = q:match("^(%a+):%s*(.*)$")
    if op == "type" or op == "field" then mode, q = op, rest end

    local function Pass(e)
        if kinds and not kinds[e.kind] then return false end
        if flag == "restricted" then
            if not Model.IsRestricted(e) then return false end
        elseif flag and e.flag ~= flag then
            return false
        end
        if q == "" then return true end
        if mode == "type" then return Deep(e).deepTypes:find(q, 1, true) ~= nil end
        if mode == "field" then return Deep(e).deepFields:find(q, 1, true) ~= nil end
        return e.search:find(q, 1, true) ~= nil
    end

    local byName = mode == "name" and q ~= "" and not kinds and not flag
    local matched, counts, shown, whole = {}, {}, {}, {}
    for _, g in ipairs(groups) do
        local n = 0
        for _, e in ipairs(g.entries) do
            if Pass(e) then
                matched[#matched + 1] = e
                n = n + 1
            end
        end
        counts[g] = n
        if byName and g.search:find(q, 1, true) then whole[g] = true end
        if n > 0 or whole[g] then shown[#shown + 1] = g end
    end

    return { query = q, raw = raw, mode = mode, entries = matched, groups = shown,
             counts = counts, whole = whole, pass = Pass }
end

function Model.Describe()
    local s = Model.Stats()
    local k, f = s.kinds, s.flags
    return format("%d groups, %d functions, %d events, %d types, %d widget methods; %d undocumented, %d missing",
        s.groups, (k["function"] or 0) + (k.global or 0), k.event or 0,
        (k.enum or 0) + (k.struct or 0) + (k.constants or 0) + (k.callback or 0) + (k.table or 0),
        k.method or 0, f.undocumented or 0, f.missing or 0)
end
