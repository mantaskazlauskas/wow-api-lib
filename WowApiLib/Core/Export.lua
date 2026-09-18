--------------------------------------------------------------------------------
-- WoW API Lib -- export to disk
--
-- An addon cannot write a file. What it can do is put data in its saved
-- variables, which the client writes to
--
--   WTF\Account\<ACCOUNT>\SavedVariables\WowApiLib.lua
--
-- on /reload or logout. tools/convert.py reads that file and turns it into
-- JSON and Markdown.
--
-- The export is the raw material, not the browser's model: the documentation
-- files exactly as Blizzard wrote them (cleaned of the mixins' methods and back
-- references) and the runtime scan as it came back. The converter can then be
-- changed to produce anything without a trip back into the game.
--
-- It is a few megabytes. It stays in the saved variables, and is read at every
-- login, until /wal clear drops it.
--------------------------------------------------------------------------------

local _, ns = ...

local format = string.format

-- Bumped when the shape of `export` changes, so the converter can tell.
local SCHEMA = 1

-- The name of the WOW_PROJECT_* constant equal to WOW_PROJECT_ID, e.g.
-- "MAINLINE" -- looked up rather than tabled here, so a flavour added after
-- this was written still gets its name.
local function ProjectName()
    local found = {}
    for k, v in pairs(_G) do
        if v == WOW_PROJECT_ID and type(k) == "string" and k ~= "WOW_PROJECT_ID"
           and k:find("^WOW_PROJECT_") then
            found[#found + 1] = k:sub(#"WOW_PROJECT_" + 1)
        end
    end
    table.sort(found)
    return found[1]
end

-- A documented no-argument build query, or nil where this client lacks it.
local function Ask(name)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn)
    if ok then return v end
end

-- Retail, PTR and beta share a project id and can share a version string;
-- the build number, the test/beta flags and (added by the converter) the
-- client folder are what tell them apart.
local function Meta(what)
    local version, build, buildDate, interface, localizedVersion, buildInfo = GetBuildInfo()
    return {
        schema           = SCHEMA,
        what             = what,
        addonVersion     = ns.VERSION,
        gameVersion      = version,
        build            = build,
        buildDate        = buildDate,
        interface        = interface,
        localizedVersion = localizedVersion,
        buildInfo        = buildInfo,
        project          = WOW_PROJECT_ID,
        projectName      = ProjectName(),
        testBuild        = Ask("IsTestBuild"),
        betaBuild        = Ask("IsBetaBuild"),
        publicTestClient = Ask("IsPublicTestClient"),
        locale           = GetLocale(),
        exportedAt       = date("!%Y-%m-%dT%H:%M:%SZ"),
    }
end

-- "12.0.1 (64914) MAINLINE, PTR" -- for the chat line.
local function Describe(meta)
    local s = format("%s (%s)", tostring(meta.gameVersion), tostring(meta.build))
    if meta.projectName then s = s .. " " .. meta.projectName end
    if meta.publicTestClient then s = s .. ", PTR" end
    if meta.betaBuild then s = s .. ", beta" end
    return s
end

local function CountDocs(files)
    local systems, functions, events, tables = 0, 0, 0, 0
    for _, f in ipairs(files) do
        if f.Name then systems = systems + 1 end
        functions = functions + #(f.Functions or {})
        events    = events + #(f.Events or {})
        tables    = tables + #(f.Tables or {})
    end
    return systems, functions, events, tables
end

-- what: "all" (default), "docs" or "runtime". Returns true on success.
function ns.Export(what)
    what = what or "all"
    if what ~= "all" and what ~= "docs" and what ~= "runtime" then
        ns.Print("export what? all, docs or runtime")
        return false
    end
    if not ns.db then
        ns.Print("saved variables are not loaded yet")
        return false
    end

    local out = { meta = Meta(what) }
    local parts = {}

    if what ~= "runtime" then
        local ok, err = ns.Docs.Load()
        if ok then
            local files = ns.Docs.CleanFiles()
            out.docs = { complete = ns.Docs.IsComplete(), files = files }
            local s, f, e, t = CountDocs(files)
            parts[#parts + 1] = format("docs: %d files, %d systems, %d functions, %d events, %d tables%s",
                #files, s, f, e, t, ns.Docs.IsComplete() and "" or " (rebuilt; predicates of shared files missing)")
        else
            ns.Print("API documentation unavailable: " .. tostring(err))
            if what == "docs" then return false end
        end
    end

    if what ~= "docs" then
        local rt = ns.Runtime.Scan()
        out.runtime = rt
        local nNamespaces, nEnums, nWidgets = 0, 0, 0
        for _ in pairs(rt.namespaces) do nNamespaces = nNamespaces + 1 end
        for _ in pairs(rt.enums)      do nEnums = nEnums + 1 end
        for _ in pairs(rt.widgets)    do nWidgets = nWidgets + 1 end
        parts[#parts + 1] = format("runtime: %d global functions, %d namespaces, %d enums, %d widget types",
            #rt.functions, nNamespaces, nEnums, nWidgets)
    end

    ns.db.export = out
    ns.Print("exported WoW " .. Describe(out.meta))
    for _, p in ipairs(parts) do ns.Print(p) end
    ns.Print("export ready. |cffffd100/reload|r writes it to SavedVariables\\WowApiLib.lua, then run tools/convert.py.")
    return true
end

function ns.ClearExport()
    if ns.db then ns.db.export = nil end
    ns.Print("export cleared; /reload to shrink the saved variables file.")
end

function ns.HasExport()
    return ns.db and ns.db.export ~= nil
end
