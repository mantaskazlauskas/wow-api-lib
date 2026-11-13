--------------------------------------------------------------------------------
-- WoW API Lib -- slash commands
--
-- /wal and /apilib. /api is Blizzard's own and stays theirs.
--------------------------------------------------------------------------------

local _, ns = ...

local lower = string.lower

local HELP = {
    "/wal                     open or close the browser",
    "/wal search <text>       open the browser searching for <text>",
    "/wal export [all|docs|runtime]   put the API into saved variables, then /reload",
    "/wal clear               drop the export from saved variables",
    "/wal rescan              rescan the runtime (after other addons load more UI)",
    "/wal stats               counts",
    "/wal minimap             hide or show the minimap button",
}

local verbs = {}

verbs[""] = function() ns.ToggleBrowser() end

verbs.search = function(arg) ns.ShowBrowser(arg) end
verbs.s = verbs.search

verbs.export = function(arg) ns.Export(arg ~= "" and lower(arg) or "all") end

verbs.clear = function() ns.ClearExport() end

verbs.rescan = function()
    ns.Model.Reset()
    ns.Print(ns.Model.Describe())
    ns.RefreshBrowser()
end

verbs.stats = function()
    ns.Print(ns.Model.Describe())
    local err = ns.Model.DocsError()
    if err then
        ns.Print("API documentation unavailable: " .. err)
    elseif not ns.Docs.IsComplete() then
        ns.Print("docs were already loaded by /api, so they were rebuilt rather than captured; shared-file predicates are missing until the next /reload.")
    end
    ns.Print(ns.HasExport() and "an export is waiting in saved variables." or "no export in saved variables.")
end

verbs.minimap = function() ns.ToggleMinimapButton() end

verbs.help = function()
    for _, line in ipairs(HELP) do ns.Print(line) end
end

SLASH_WOWAPILIB1 = "/wal"
SLASH_WOWAPILIB2 = "/apilib"
SlashCmdList.WOWAPILIB = function(msg)
    local verb, arg = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    local fn = verbs[lower(verb or "")]
    if fn then
        fn(arg or "")
    else
        verbs.help()
    end
end
