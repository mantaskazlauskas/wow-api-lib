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
        if not docEnums[name] then enumNames[#enumNames + 1] = name end
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
end

-- Forgets the model; the next Build rescans the runtime and re-reads the docs
-- (the docs themselves are only ever loaded once).
function Model.Reset()
    groups, entries, stats = nil, nil, nil
    ns.Runtime.Scan(true)
end

function Model.Groups()    Model.Build() return groups end
function Model.Entries()   Model.Build() return entries end
function Model.Stats()     Model.Build() return stats end
function Model.DocsError() return docsError end

--------------------------------------------------------------------------------
-- Search
--
-- Plain, case-insensitive substring matching on the qualified name. Returns
-- the matching entries in model order, and the groups to show: every group
-- with a matching entry, plus every group whose own name matches, with how
-- many of its entries matched.
--------------------------------------------------------------------------------

function Model.Search(query)
    Model.Build()
    local q = lower(strtrim(query or ""))
    if q == "" then return nil end

    local matched, counts = {}, {}
    for _, g in ipairs(groups) do
        local n = 0
        for _, e in ipairs(g.entries) do
            if e.search:find(q, 1, true) then
                matched[#matched + 1] = e
                n = n + 1
            end
        end
        counts[g] = n
    end

    local shown = {}
    for _, g in ipairs(groups) do
        if counts[g] > 0 or g.search:find(q, 1, true) then shown[#shown + 1] = g end
    end

    return { query = q, entries = matched, groups = shown, counts = counts }
end

function Model.Describe()
    local s = Model.Stats()
    local k, f = s.kinds, s.flags
    return format("%d groups, %d functions, %d events, %d types, %d widget methods; %d undocumented, %d missing",
        s.groups, (k["function"] or 0) + (k.global or 0), k.event or 0,
        (k.enum or 0) + (k.struct or 0) + (k.constants or 0) + (k.callback or 0) + (k.table or 0),
        k.method or 0, f.undocumented or 0, f.missing or 0)
end
