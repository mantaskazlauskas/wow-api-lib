--------------------------------------------------------------------------------
-- The whole addon: docs capture, the model, formatting, the browser and the
-- export. Fixture assertions are exact; with the real documentation (REAL)
-- the same paths are checked for invariants and for not erroring on any of
-- the thousands of real entries.
--------------------------------------------------------------------------------

local Docs, Model, Format, Runtime = NS.Docs, NS.Model, NS.Format, NS.Runtime

local function FindGroup(label)
    for _, g in ipairs(Model.Groups()) do
        if g.label == label then return g end
    end
end

local function FindEntry(g, full)
    for _, e in ipairs(g and g.entries or {}) do
        if e.full == full then return e end
    end
end

local function Has(text, needle, what)
    return ok(text and text:find(needle, 1, true) ~= nil, what .. "  [" .. needle .. "]")
end

local function ChatHas(needle)
    for _, m in ipairs(CHAT) do
        if m:find(needle, 1, true) then return true end
    end
    return false
end

--------------------------------------------------------------------------------
section("login")
--------------------------------------------------------------------------------

ok(type(DB) == "table", "saved variables resolved on ADDON_LOADED")
ok(not Docs.IsLoaded(), "documentation not loaded at login")
ok(not Runtime.IsScanned(), "runtime not scanned at login")

--------------------------------------------------------------------------------
section("browser opens")
--------------------------------------------------------------------------------

local t0 = os.clock()
Slash("")
local built = os.clock() - t0
ok(WowApiLibBrowser and WowApiLibBrowser:IsShown(), "/wal shows the browser")
print(string.format("        model built in %.2fs", built))
ok(#Model.Groups() > 0, "there are groups to browse")

--------------------------------------------------------------------------------
if SCENARIO == "noapi" then
    section("without the documentation addon")
    ok(Model.DocsError() ~= nil, "the failure is reported")
    ok(FindGroup("Global functions") ~= nil, "runtime groups are still browsable")
    if not REAL then
        ok(FindGroup("C_Map") and FindGroup("C_Map").source == "runtime", "C_Map shows up as an undocumented namespace")
    end

    Slash("export docs")
    ok(DB.export == nil, "a docs-only export writes nothing")
    Slash("export")
    ok(DB.export and DB.export.runtime and not DB.export.docs, "a full export still writes the runtime")
    return
end

--------------------------------------------------------------------------------
section("documentation capture")
--------------------------------------------------------------------------------

ok(Docs.IsLoaded(), "documentation loaded on first open")
eq(Docs.IsComplete(), SCENARIO == "fresh", "complete only when the load was watched")
if SCENARIO == "fresh" then
    eq(#Docs.Files(), #GENERATED_FILES, "one captured table per generated file")
end

--------------------------------------------------------------------------------
section("clean copies are plain data")
--------------------------------------------------------------------------------

local clean = Docs.CleanFiles()
local bad, tables, seen = {}, 0, {}
local function Walk(v, path)
    if type(v) == "function" then bad[#bad + 1] = "function at " .. path return end
    if type(v) ~= "table" then return end
    if seen[v] then bad[#bad + 1] = "shared table at " .. path return end
    seen[v] = true
    tables = tables + 1
    for k, x in pairs(v) do
        if type(k) == "string" and not k:find("^%u") then bad[#bad + 1] = "key " .. k .. " at " .. path end
        Walk(x, path .. "." .. tostring(k))
    end
end
Walk(clean, "files")
ok(#bad == 0, "no functions, lowercase caches or shared tables" .. (bad[1] and ("  first: " .. bad[1]) or ""))
ok(tables > #clean, "copied " .. tables .. " tables")

local originals = Docs.Files()
ok(originals[1].Functions == nil or originals[1].Functions ~= clean[1].Functions, "copies, not the originals")

--------------------------------------------------------------------------------
if not REAL then
    section("model: documented against runtime")

    local map = FindGroup("C_Map")
    ok(map and map.source == "docs" and map.sub == "MapUI", "C_Map is a documented group titled by namespace")
    local best = FindEntry(map, "C_Map.GetBestMapForUnit")
    ok(best and best.flag == nil, "a function in both is not flagged")
    eq(FindEntry(map, "C_Map.GoneInThisClient") and FindEntry(map, "C_Map.GoneInThisClient").flag, "missing",
       "documented, absent at runtime -> missing")
    eq(FindEntry(map, "C_Map.SecretNewThing") and FindEntry(map, "C_Map.SecretNewThing").flag, "undocumented",
       "present at runtime, absent from docs -> undocumented, in the documented group")
    ok(FindEntry(map, "MAP_EXPLORATION_UPDATED"), "events are listed by their literal name")
    ok(FindEntry(map, "Enum.UIMapType"), "enumerations are listed at their runtime path")
    ok(FindEntry(map, "RequiresValidMap"), "a system's predicates are listed")

    local unit = FindGroup("Unit")
    eq(FindEntry(unit, "UnitName") and tostring(FindEntry(unit, "UnitName").flag), "nil", "a live global function is not flagged")
    eq(FindEntry(unit, "UnitRemovedLongAgo") and FindEntry(unit, "UnitRemovedLongAgo").flag, "missing", "a gone global is missing")

    local hidden = FindGroup("C_Hidden")
    ok(hidden and hidden.source == "runtime" and #hidden.entries == 2, "an undocumented namespace is its own group")

    local globals = FindGroup("Global functions")
    ok(FindEntry(globals, "SomeBlizzardGlobal"), "an undocumented Blizzard global is listed")
    ok(not FindEntry(globals, "SomeAddonGlobal"), "an addon's global is not")
    ok(not FindEntry(globals, "UnitName"), "a documented global is not repeated")
    eq(Runtime.Scan().addonFunctions, 1, "addon globals are counted")

    local enums = FindGroup("Enum")
    ok(FindEntry(enums, "Enum.UndocumentedE") and not FindEntry(enums, "Enum.UIMapType"), "only undocumented enums are listed")
    ok(not FindEntry(enums, "Enum.UIMapTypeMeta"), "an enum's Meta companion is not listed")
    ok(FindEntry(enums, "Enum.UndocumentedEMeta"), "a ...Meta name with other values is still listed")
    local cdm = FindEntry(enums, "Enum.CDMLayoutMode")
    ok(cdm and cdm.doc.Fields[1].Name == "AccessOnly", "boolean enum values sort, false first")
    Has(cdm and Format.Entry(cdm), "AllowCreate = true", "boolean enum values format")
    local mixed = FindEntry(enums, "Enum.MixedE")
    local order = {}
    for _, f in ipairs(mixed and mixed.doc.Fields or {}) do order[#order + 1] = f.Name end
    eq(table.concat(order, " "), "F T M N S", "mixed value types sort by type, then value")

    ok(FindGroup("Widget: Frame") and FindEntry(FindGroup("Widget: Frame"), "Frame:SetScript"), "widget methods are read from the metatable")
    ok(FindGroup("Widget: ControlPoint"), "path control points are reached through an animation")
    ok(not FindGroup("Widget: ArchaeologyDigSiteFrame"), "a frame type the client refuses is skipped")
    ok(FindEntry(FindGroup("SimpleFrameAPI"), "SimpleFrameAPI:AbortDrag"), "script object functions use ':'")

    local shared = FindGroup("Shared types")
    ok(FindEntry(shared, "Constants.AuctionConstants"), "tables from a nameless file are in the shared group")
    eq(FindEntry(shared, "SecretWhenSharedThing") ~= nil, SCENARIO == "fresh",
       "a nameless file's predicates survive only when captured")

    section("format")
    local text = Format.Entry(best)
    Has(text, "local uiMapID = C_Map.GetBestMapForUnit(unitToken)", "call signature")
    Has(text, "System MapUI, namespace C_Map", "where it lives")
    Has(text, "Only works for the player and party members.", "documentation")
    Has(text, "uiMapID  number, nilable", "returns with types")
    Has(Format.Entry(FindEntry(unit, "UnitName")), "realm  cstring, nilable", "names padded to the longest")
    Has(text, "SecretArguments: AllowedWhenUntainted", "flags printed generically")

    text = Format.Entry(FindEntry(map, "C_Map.GoneInThisClient"))
    Has(text, "C_Map.GoneInThisClient(mapIDs, scale?)", "defaulted argument marked optional")
    Has(text, "table of number", "inner type")
    Has(text, "default 1", "default value")
    Has(text, "AddsForbiddenAspects: { { Argument=self, Aspect=3 } }", "table-valued flag inlined")
    Has(text, "not present in this client", "missing explained")

    text = Format.Entry(FindEntry(map, "MAP_EXPLORATION_UPDATED"))
    Has(text, "MAP_EXPLORATION_UPDATED: uiMapID", "event signature")
    Has(text, "ConditionalSecret: true", "field-level flag")
    Has(text, "Documented as: MapExplorationUpdated", "documented name kept")
    Has(Format.Entry(FindEntry(map, "Enum.UIMapType")), "Continent = 2", "enum values")
    Has(Format.Entry(FindEntry(map, "UiMapDetails")), "vector2 (Vector2DMixin)", "mixin type")
    Has(Format.Entry(FindEntry(shared, "Constants.AuctionConstants")), "DEFAULT_AUCTION_PRICE_MULTIPLIER = 1.5", "constants")
    Has(Format.Entry(FindEntry(unit, "UnitCallback")), "UnitCallback = function(unit)", "callback")
    Has(Format.Entry(FindEntry(hidden, "C_Hidden.Foo")), "Not in Blizzard's API documentation", "undocumented explained")

    text = Format.Group(map)
    Has(text, "Functions (4)", "group headings count")
    Has(text, "C_Map.SecretNewThing(...)  [undocumented]", "undocumented marked in group")
    Has(text, "[missing]", "missing marked in group")

    section("search")
    local r = Model.Search("  BestMap ")
    ok(r and #r.entries == 1 and r.entries[1] == best, "trimmed, case-insensitive substring")
    r = Model.Search("c_hid")
    ok(r and r.counts[hidden] == 2, "a namespace match finds its functions")
    ok(Model.Search("") == nil, "empty search is no search")
    ok(#Model.Search("zzzznothing").entries == 0, "no match is an empty result")
else
    section("real documentation")
    local s = Model.Stats()
    ok(s.groups > 300, s.groups .. " groups")
    ok((s.kinds["function"] or 0) > 5000, (s.kinds["function"] or 0) .. " functions")
    ok((s.kinds.event or 0) > 1000, (s.kinds.event or 0) .. " events")

    local r = Model.Search("GetBestMapForUnit")
    ok(r and r.entries[1] and r.entries[1].full == "C_Map.GetBestMapForUnit", "search finds C_Map.GetBestMapForUnit")
    Has(Format.Entry(r.entries[1]), "local uiMapID = C_Map.GetBestMapForUnit(unitToken)", "real signature")

    local failures, first = 0, nil
    t0 = os.clock()
    for _, e in ipairs(Model.Entries()) do
        local okf, err = pcall(Format.Entry, e)
        if not okf then failures = failures + 1; first = first or (e.full .. ": " .. tostring(err)) end
    end
    for _, g in ipairs(Model.Groups()) do
        local okf, err = pcall(Format.Group, g)
        if not okf then failures = failures + 1; first = first or (g.label .. ": " .. tostring(err)) end
    end
    ok(failures == 0, "every entry and group formats" .. (first and ("  first: " .. first) or ""))
    print(string.format("        formatted %d entries in %.2fs", #Model.Entries(), os.clock() - t0))

    t0 = os.clock()
    Model.Search("unit")
    print(string.format("        one search over everything: %.3fs", os.clock() - t0))
end

--------------------------------------------------------------------------------
section("browser")
--------------------------------------------------------------------------------

local function Rows()
    local out = {}
    for _, f in ipairs(FRAMES) do
        if f._type == "Button" and f.item and f._shown then out[#out + 1] = f end
    end
    return out
end

local function DetailText()
    for _, f in ipairs(FRAMES) do
        if f._type == "EditBox" and f.value then return f.value end
    end
end

Slash("search GetBestMapForUnit")
local matchRow
for _, row in ipairs(Rows()) do
    if row.item.full == "C_Map.GetBestMapForUnit" then matchRow = row end
end
ok(matchRow ~= nil, "/wal search lists the match")
if matchRow then
    matchRow._scripts.OnClick(matchRow)
    Has(DetailText(), "C_Map.GetBestMapForUnit(unitToken)", "clicking a match shows it")
end

local groupRow
for _, row in ipairs(Rows()) do
    if row.item.label == "C_Map" and row.item.entries then groupRow = row end
end
ok(groupRow ~= nil, "the matching group is listed")
if groupRow then
    groupRow._scripts.OnClick(groupRow)
    Has(DetailText(), "C_Map  (MapUI)", "clicking a group shows the group")
end

Slash("search ")
ok(DetailText() ~= nil, "clearing the search does not error")

--------------------------------------------------------------------------------
section("export")
--------------------------------------------------------------------------------

Slash("export")
local ex = DB.export
ok(ex and ex.meta and ex.meta.schema == 1, "export written with a schema")
eq(ex and ex.meta.build, "99999", "build recorded")
eq(ex and ex.meta.gameVersion, "12.0.1", "version recorded")
eq(ex and ex.meta.localizedVersion, "Version 12.0.1", "localized version recorded")
eq(ex and ex.meta.buildInfo, "Release x64", "build info recorded")
eq(ex and ex.meta.projectName, "MAINLINE", "project named from its WOW_PROJECT_ constant")
eq(ex and ex.meta.publicTestClient, true, "PTR flag recorded")
eq(ex and ex.meta.testBuild, false, "test build flag recorded")
eq(ex and tostring(ex.meta.betaBuild), "nil", "a query this client lacks is left out")
ok(ChatHas("exported WoW 12.0.1 (99999) MAINLINE, PTR"), "the export names the client in chat")
ok(ex and ex.docs and #ex.docs.files == #Docs.Files(), "every documentation file exported")
eq(ex and ex.docs.complete, SCENARIO == "fresh", "completeness recorded")
ok(ex and ex.runtime and #ex.runtime.functions > 0, "runtime exported")
ok(ChatHas("/reload"), "tells you to /reload")

Slash("clear")
ok(DB.export == nil, "/wal clear drops it")
Slash("export")
ok(DB.export ~= nil, "exported again for the converter")

Slash("rescan")
ok(ChatHas("groups,"), "/wal rescan reports the new model")
ok(#Model.Groups() > 0, "the rebuilt model has groups")
