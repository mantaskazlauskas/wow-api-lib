--------------------------------------------------------------------------------
-- WoW API Lib -- Blizzard's generated API documentation
--
-- The client ships two load-on-demand addons behind the /api command:
--
--   Blizzard_APIDocumentation           the mixins and the /api command
--   Blizzard_APIDocumentationGenerated  ~600 files, each one call to
--                                       APIDocumentation:AddDocumentationTable
--
-- Every file is a plain table literal, and that table is the best description
-- of the API that exists. So rather than read Blizzard's processed lists back,
-- this file watches AddDocumentationTable while the generated addon loads and
-- keeps each table exactly as it was handed over, in load order.
--
-- The processed lists are not enough on their own: a file with no system name
-- is only ever split into its Tables, so the Predicates it declares
-- (preconditions such as RequiresValidActionSlot) exist nowhere afterwards.
--
-- If the generated addon is already loaded when we get here -- someone typed
-- /api first -- the call has already happened and cannot be watched. The files
-- are then rebuilt from APIDocumentation.systems and .tables, which is
-- everything except those orphaned predicates, and `complete` says so.
--------------------------------------------------------------------------------

local _, ns = ...

local format = string.format

local Docs = {}
ns.Docs = Docs

local BASE      = "Blizzard_APIDocumentation"
local GENERATED = "Blizzard_APIDocumentationGenerated"

local files       -- documentation tables in load order, nil until Load succeeds
local complete    -- false when rebuilt rather than watched
local watching    -- the list AddDocumentationTable is currently appending to
local hooked

--------------------------------------------------------------------------------
-- Clean copies
--
-- The tables Blizzard keeps are not plain data by the time we see them. The
-- mixins add methods to each one, cache lowered names on it (`loweredName`),
-- and point each child back at its parent -- System, Function, Table, Event --
-- which makes every system a cycle. None of that can go into saved variables.
--
-- Everything the documentation authors wrote is keyed with an uppercase name
-- (Name, Type, Arguments, SecretArguments, ...) or an array index, and nothing
-- the mixins add is, so the rule below is exact rather than a list of known
-- fields that would go stale the next time Blizzard adds one.
--------------------------------------------------------------------------------

local BACKREFS = { System = true, Function = true, Table = true, Event = true }
Docs.BACKREFS = BACKREFS

local function Clean(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do
        local tk, tx = type(k), type(x)
        if tx ~= "function" then
            if tk == "number" then
                out[k] = Clean(x)
            elseif tk == "string" and k:find("^%u") and not BACKREFS[k] then
                out[k] = Clean(x)
            end
        end
    end
    return out
end

Docs.Clean = Clean

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local function Rebuild()
    local api = APIDocumentation
    local out = {}
    for i = 1, #api.systems do out[#out + 1] = api.systems[i] end

    -- A table that belongs to no system came from a file with no system name.
    local orphans = {}
    for i = 1, #api.tables do
        local t = api.tables[i]
        if not t.System then orphans[#orphans + 1] = t end
    end
    if #orphans > 0 then out[#out + 1] = { Tables = orphans } end
    return out
end

local function Load(name)
    if C_AddOns.IsAddOnLoaded(name) then return true end
    local ok, reason = C_AddOns.LoadAddOn(name)
    if not ok then
        return false, format("could not load %s (%s)", name, tostring(reason))
    end
    return true
end

-- Returns true, or false and a reason. Safe to call repeatedly.
function Docs.Load()
    if files then return true end

    local ok, err = Load(BASE)
    if not ok then return false, err end

    local api = APIDocumentation
    if not (api and api.AddDocumentationTable) then
        return false, BASE .. " loaded but APIDocumentation is missing"
    end

    if C_AddOns.IsAddOnLoaded(GENERATED) then
        files, complete = Rebuild(), false
        return true
    end

    -- A post-hook, so Blizzard's own table is never replaced and /api keeps
    -- working exactly as before. It stays installed after the load, which is
    -- harmless: nothing calls AddDocumentationTable again, and `watching` is
    -- nil by then.
    if not hooked then
        hooked = true
        hooksecurefunc(api, "AddDocumentationTable", function(_, info)
            if watching then watching[#watching + 1] = info end
        end)
    end

    watching = {}
    ok, err = Load(GENERATED)
    local got = watching
    watching = nil
    if not ok then return false, err end

    files, complete = got, true
    return true
end

function Docs.IsLoaded()   return files ~= nil end
function Docs.IsComplete() return complete == true end

-- The documentation tables as Blizzard holds them -- read them, never write
-- them, and never store them; Clean first.
function Docs.Files() return files or {} end

-- Plain copies of every file, for saved variables.
function Docs.CleanFiles()
    local out = {}
    for i, f in ipairs(Docs.Files()) do out[i] = Clean(f) end
    return out
end
