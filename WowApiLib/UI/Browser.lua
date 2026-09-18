--------------------------------------------------------------------------------
-- WoW API Lib -- the browser window
--
--   [search..............]  status                [Select text] [Export] [Reload]
--   +-- groups --------+ +-- entries ------------+ +-- detail -----------------+
--   | C_Map    (MapUI) | | C_Map.GetBestMapFor.. | | local uiMapID = C_Map...  |
--   | ...              | | ...                   | |                           |
--   +------------------+ +-----------------------+ +---------------------------+
--   footer: where the data came from
--
-- Clicking a group shows the whole group in the detail pane, one line per
-- entry; clicking an entry shows that entry in full. Both are plain text in an
-- edit box, so either can be selected and copied.
--
-- With a search, the groups list shows "All matches" first and then every
-- group that matched, with its count; the entries list shows the matches in
-- whichever of those is selected.
--------------------------------------------------------------------------------

local _, ns = ...

local format = string.format
local ui = ns.ui
local Model, Format = ns.Model, ns.Format

local GROUP_W, ENTRY_W = 250, 340
local TOP, BOTTOM, GAP = -72, 28, 6

local frame
local groupList, entryList, detail, searchBox, status, footer
local search                 -- Model.Search result, or nil
local selectedGroup, selectedEntry

-- The pseudo-group listing every match of the current search.
local ALL = { key = "*", label = "All matches" }

local SOURCE_COLOUR = { docs = "ffffff", runtime = "8fb8ff" }
local FLAG_COLOUR   = { undocumented = "a0a0a0", missing = "ff6060" }
local KIND_COLOUR   = {
    ["function"] = "ffffff", global = "d8d8d8", method = "ffffff",
    event = "ffb060", callback = "d090ff", enum = "80e080", struct = "70d0e0",
    constants = "f0e070", table = "c0c0c0", predicate = "b0b0b0",
}

--------------------------------------------------------------------------------
-- What each list shows
--------------------------------------------------------------------------------

local function GroupItems()
    if not search then return Model.Groups() end
    local items = { ALL }
    for _, g in ipairs(search.groups) do items[#items + 1] = g end
    return items
end

local function EntryItems()
    local g = selectedGroup
    if not g then return {} end
    if g == ALL then return search and search.entries or {} end
    if not search then return g.entries end

    local q, out = search.query, {}
    -- A group found by its own name shows all of itself.
    if g.search:find(q, 1, true) then return g.entries end
    for _, e in ipairs(g.entries) do
        if e.search:find(q, 1, true) then out[#out + 1] = e end
    end
    return out
end

local function ShowDetail()
    if selectedEntry then
        detail:SetContent(Format.Entry(selectedEntry))
    elseif selectedGroup == ALL then
        detail:SetContent(format("%d matches for \"%s\". Pick one on the left, or a group to narrow them.",
            search and #search.entries or 0, search and search.query or ""))
    elseif selectedGroup then
        detail:SetContent(Format.Group(selectedGroup, search and EntryItems() or nil))
    else
        detail:SetContent("")
    end
end

local function UpdateStatus()
    local n = #EntryItems()
    if search then
        status:SetText(format("%d matches", #search.entries))
    else
        status:SetText(format("%d groups", #Model.Groups()))
    end
    if selectedGroup and selectedGroup ~= ALL then
        status:SetText(status:GetText() .. format("  |  %s: %d", selectedGroup.label, n))
    end
end

local function Redraw(keepEntryOffset)
    groupList:SetItems(GroupItems(), true)
    entryList:SetItems(EntryItems(), keepEntryOffset)
    ShowDetail()
    UpdateStatus()
end

--------------------------------------------------------------------------------
-- Row rendering
--------------------------------------------------------------------------------

local function RenderGroup(row, g)
    if g == ALL then
        row.text:SetText("|cffffd100All matches|r")
        row.tag:SetText(search and tostring(#search.entries) or "")
        return
    end
    local colour = SOURCE_COLOUR[g.source] or "ffffff"
    local sub = g.sub and ("  |cff808080" .. g.sub .. "|r") or ""
    row.text:SetText(format("|cff%s%s|r%s", colour, g.label, sub))
    row.tag:SetText(tostring(search and search.counts[g] or #g.entries))
end

local function RenderEntry(row, e)
    local colour = FLAG_COLOUR[e.flag] or KIND_COLOUR[e.kind] or "ffffff"
    row.text:SetText(format("|cff%s%s|r", colour, e.full))
    local tag = Model.KIND_TAGS[e.kind] or e.kind
    if e.flag == "undocumented" then tag = tag .. " ?" elseif e.flag == "missing" then tag = tag .. " !" end
    -- The group is not visible next to a match from "All matches".
    if selectedGroup == ALL and e.group then tag = e.group.label .. "  " .. tag end
    row.tag:SetText(tag)
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function SelectGroup(g)
    selectedGroup, selectedEntry = g, nil
    Redraw()
end

local function SelectEntry(e)
    selectedEntry = e
    entryList:Refresh()
    ShowDetail()
end

local function SetQuery(text)
    search = Model.Search(text)
    selectedEntry = nil
    if search then
        -- Keep the selected group when it still matches; otherwise all matches.
        local keep = false
        for _, g in ipairs(search.groups) do
            if g == selectedGroup then keep = true break end
        end
        if not keep then selectedGroup = ALL end
    elseif selectedGroup == ALL then
        selectedGroup = nil
    end
    groupList.offset = 0
    Redraw()
end

local function Footer()
    local version, build = GetBuildInfo()
    local docs
    local err = Model.DocsError()
    if err then
        docs = "|cffff6060docs unavailable: " .. err .. "|r"
    elseif ns.Docs.IsComplete() then
        docs = format("docs: %d files", #ns.Docs.Files())
    else
        docs = "docs: rebuilt after /api (shared predicates missing until /reload)"
    end
    footer:SetText(format("%s  |  %s  |  %s %s  |  ? undocumented, ! missing in this client",
        Model.Describe(), docs, version or "?", build or ""))
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function Build()
    frame = ui.Window("WowApiLibBrowser", "WoW API Lib", 1080, 640, 820, 380)

    searchBox = ui.SearchBox(frame, 260, SetQuery)
    searchBox:SetPoint("TOPLEFT", 20, -38)

    status = ui.Label(frame)
    status:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)

    local reload = ui.Button(frame, "Reload UI", 90, function() ReloadUI() end)
    reload:SetPoint("TOPRIGHT", -14, -36)
    local export = ui.Button(frame, "Export", 80, function() ns.Export("all") end)
    export:SetPoint("RIGHT", reload, "LEFT", -6, 0)
    local copy = ui.Button(frame, "Select text", 100, function() detail:SelectAll() end)
    copy:SetPoint("RIGHT", export, "LEFT", -6, 0)

    groupList = ui.List(frame, {
        render = RenderGroup,
        onClick = SelectGroup,
        isSelected = function(g) return g == selectedGroup end,
    })
    groupList:SetPoint("TOPLEFT", 12, TOP)
    groupList:SetPoint("BOTTOMLEFT", 12, BOTTOM)
    groupList:SetWidth(GROUP_W)

    entryList = ui.List(frame, {
        render = RenderEntry,
        onClick = SelectEntry,
        isSelected = function(e) return e == selectedEntry end,
    })
    entryList:SetPoint("TOPLEFT", groupList, "TOPRIGHT", GAP, 0)
    entryList:SetPoint("BOTTOMLEFT", groupList, "BOTTOMRIGHT", GAP, 0)
    entryList:SetWidth(ENTRY_W)

    detail = ui.TextView(frame)
    detail:SetPoint("TOPLEFT", entryList, "TOPRIGHT", GAP, 0)
    detail:SetPoint("BOTTOMRIGHT", -12, BOTTOM)

    footer = ui.Label(frame, "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 14, 9)
    footer:SetPoint("RIGHT", frame.grip, "LEFT", -6, 0)
    footer:SetWordWrap(false)
end

--------------------------------------------------------------------------------
-- Public entry points
--------------------------------------------------------------------------------

-- query: optional; replaces the search text when given.
function ns.ShowBrowser(query)
    if not frame then
        Build()
        Model.Build()
        groupList:Layout()
        entryList:Layout()
        Footer()
        Redraw()
    end
    frame:Show()
    if query and query ~= "" then
        -- SetText fires OnTextChanged, which runs the search.
        searchBox:SetText(query)
    end
end

function ns.ToggleBrowser()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        ns.ShowBrowser()
    end
end

-- After the model has been rebuilt (/wal rescan): every group and entry the
-- window holds belongs to the old model.
function ns.RefreshBrowser()
    if not frame then return end
    selectedGroup, selectedEntry = nil, nil
    search = Model.Search(searchBox:GetText())
    if search then selectedGroup = ALL end
    Footer()
    Redraw()
end
