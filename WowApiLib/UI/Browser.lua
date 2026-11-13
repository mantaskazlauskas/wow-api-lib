--------------------------------------------------------------------------------
-- WoW API Lib -- the browser window
--
--   | WoW API Lib   12 matches for "map"                                    x |
--   [<][>] [Q search.............]   [Inspect] [Select text] [Export] [Reload]
--   Show [All][Functions][Events][Types]  Only [Any][Restricted][Undoc][Missing]
--   +- GROUPS ------- 3 + +- C_MAP --------- 12 + +- DETAILS ----- [Favorite]+
--   | Favorites         | | * C_Map.GetBestMap.. | | [in C_Map] [UiMapDetails]|
--   | C_Map    (MapUI)  | | ...                  | | local uiMapID = C_Map.. |
--   +-------------------+ +----------------------+ +-------------------------+
--   status bar: where the data came from
--
-- Clicking a group shows the whole group in the detail pane, one line per
-- entry; clicking an entry shows that entry in full. Both are plain text in an
-- edit box, so either can be selected and copied. Above the text, links go to
-- the entry's group and to every documented type it uses.
--
-- With a search or a filter, the groups list shows "All matches" first and
-- then every group that matched, with its count; the entries list shows the
-- matches in whichever of those is selected.
--
-- Every selection is a step in a history that the < and > buttons (and the
-- mouse's back/forward buttons, over the window) walk.
--------------------------------------------------------------------------------

local _, ns = ...

local format = string.format
local max = math.max
local ui = ns.ui
local Model, Format = ns.Model, ns.Format

local GROUP_W, ENTRY_W = 250, 340
local TOOLBAR_Y = -(ui.TITLE_H + 10)
local FILTER_Y = TOOLBAR_Y - 32
local TOP = FILTER_Y - 30
local BOTTOM, GAP = ui.STATUS_H + 10, 8
local HISTORY_MAX = 100

local frame
local groupList, entryList, detail, searchBox
local kindChips, flagChips, backButton, forwardButton, favButton, formatButton
local search                 -- Model.Search result, or nil
local filters = { kind = "all", flag = "any" }
local selectedGroup, selectedEntry
local history, hpos = {}, 0
local quiet                  -- set while the code itself changes the search box

-- Pseudo-groups: every match of the current search, and the favourites.
local ALL = { key = "*", label = "All matches" }
local FAV = { key = "fav", label = "Favorites" }

local ACCENT        = "5aa2ff"
local SOURCE_COLOUR = { docs = "ebedf2", runtime = "8fb8ff" }
local FLAG_COLOUR   = { undocumented = "a0a0a0", missing = "ff6060" }
local KIND_COLOUR   = {
    ["function"] = "ffffff", global = "d8d8d8", method = "ffffff",
    event = "ffb060", callback = "d090ff", enum = "80e080", struct = "70d0e0",
    constants = "f0e070", table = "c0c0c0", predicate = "b0b0b0",
}

local function RGB(hex)
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255,
           tonumber(hex:sub(5, 6), 16) / 255
end

--------------------------------------------------------------------------------
-- Favourites, kept in saved variables by Model.EntryKey so they survive a
-- rescan and a new client build (as long as the entry still exists).
--------------------------------------------------------------------------------

local function FavoriteSet()
    if not ns.db then return {} end
    ns.db.favorites = ns.db.favorites or {}
    return ns.db.favorites
end

local function IsFavorite(e)
    return e and e.kind ~= "frame" and FavoriteSet()[Model.EntryKey(e)] == true
end

local function FavoriteEntries()
    local out = {}
    for key in pairs(FavoriteSet()) do
        local e = Model.FindByKey(key)
        if e then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.search < b.search end)
    return out
end

--------------------------------------------------------------------------------
-- What each list shows
--------------------------------------------------------------------------------

local function GroupItems()
    local items = {}
    if search then
        items[1] = ALL
        for _, g in ipairs(search.groups) do items[#items + 1] = g end
        return items
    end
    if #FavoriteEntries() > 0 then items[1] = FAV end
    for _, g in ipairs(Model.Groups()) do items[#items + 1] = g end
    return items
end

local function EntryItems()
    local g = selectedGroup
    if not g then return {} end
    if g == ALL then return search and search.entries or {} end
    local list = g == FAV and FavoriteEntries() or g.entries
    -- A group found by its own name shows all of itself.
    if not search or search.whole[g] then return list end
    local out = {}
    for _, e in ipairs(list) do
        if search.pass(e) then out[#out + 1] = e end
    end
    return out
end

local FLAG_NAMES = { restricted = "restricted", undocumented = "undocumented", missing = "missing" }

local function SearchSummary()
    if not search then return "" end
    local parts = { format("%d matches", #search.entries) }
    if search.raw ~= "" then parts[#parts + 1] = format("for \"%s\"", search.raw) end
    if filters.kind ~= "all" then parts[#parts + 1] = "in " .. filters.kind end
    if FLAG_NAMES[filters.flag] then parts[#parts + 1] = "(" .. FLAG_NAMES[filters.flag] .. ")" end
    return table.concat(parts, " ")
end

--------------------------------------------------------------------------------
-- Detail pane
--------------------------------------------------------------------------------

local GoToEntry, GoToGroup   -- defined with the navigation below

local function DetailLinks()
    local links = {}
    local e = selectedEntry
    if not e then return links end
    if e.kind == "frame" then
        for _, g in ipairs(e.info.docGroups or {}) do
            links[#links + 1] = { label = g.label, onClick = function() GoToGroup(g) end }
        end
        local widget = e.info.objectType and Model.FindGroup("rt:widget:" .. e.info.objectType)
        if widget then
            links[#links + 1] = { label = widget.label, onClick = function() GoToGroup(widget) end }
        end
        return links
    end
    if e.group then
        local g = e.group
        links[#links + 1] = { label = "in " .. g.label, onClick = function() GoToGroup(g) end }
    end
    for _, t in ipairs(Model.RelatedTypes(e)) do
        links[#links + 1] = { label = t.full, onClick = function() GoToEntry(t) end }
    end
    return links
end

-- The detail pane shows either readable text or Lua annotations (LuaLS),
-- remembered across sessions.
local function AsLua() return ns.db and ns.db.detailFormat == "lua" end

local function ShowDetail()
    local e = selectedEntry
    local lua = AsLua()
    local EntryText = lua and ns.Annotate.Entry or Format.Entry
    local GroupText = lua and ns.Annotate.Group or Format.Group
    if e and e.kind == "frame" then
        detail:SetContent(Format.Frame(e.info))
    elseif e then
        detail:SetContent(EntryText(e))
    elseif selectedGroup == ALL then
        detail:SetContent(SearchSummary() .. ". Pick one on the left, or a group to narrow them.")
    elseif selectedGroup == FAV then
        detail:SetContent(GroupText(FAV, EntryItems()))
    elseif selectedGroup then
        detail:SetContent(GroupText(selectedGroup, search and EntryItems() or nil))
    else
        detail:SetContent("")
    end
    formatButton:SetText(lua and "As text" or "As Lua")
    detail:SetLinks(DetailLinks())

    local canFav = e and e.kind ~= "frame"
    favButton:SetShown(canFav and true or false)
    if canFav then favButton:SetText(IsFavorite(e) and "Unfavorite" or "Favorite") end
end

local function UpdateStatus()
    frame.subtitle:SetText(SearchSummary())
    groupList:SetInfo(tostring(search and #search.groups or #Model.Groups()))
    if selectedGroup then
        entryList:SetTitle(selectedGroup.label)
        entryList:SetInfo(tostring(#EntryItems()))
    else
        entryList:SetTitle("Entries")
        entryList:SetInfo("")
    end
end

local function Redraw(keepEntryOffset)
    groupList:SetItems(GroupItems(), true)
    entryList:SetItems(EntryItems(), keepEntryOffset)
    ShowDetail()
    UpdateStatus()
end

-- Scrolls a list so `item` is in view, a few rows from the top.
local function Reveal(list, item)
    for i, x in ipairs(list.items) do
        if x == item then
            if i <= list.offset or i > list.offset + list:Visible() then
                list.offset = max(0, i - 3)
                list:Refresh()
            end
            return
        end
    end
end

--------------------------------------------------------------------------------
-- Row rendering
--------------------------------------------------------------------------------

local function RenderGroup(row, g)
    if g == ALL then
        row.text:SetText("|cff" .. ACCENT .. "All matches|r")
        row.tag:SetText(search and tostring(#search.entries) or "")
        return
    elseif g == FAV then
        row.text:SetText("|cff" .. ACCENT .. "Favorites|r")
        row.tag:SetText(tostring(#FavoriteEntries()))
        return
    end
    local colour = SOURCE_COLOUR[g.source] or "ffffff"
    local sub = g.sub and ("  |cff808080" .. g.sub .. "|r") or ""
    row.text:SetText(format("|cff%s%s|r%s", colour, g.label, sub))
    row.tag:SetText(tostring(search and search.counts[g] or #g.entries))
end

local function RenderEntry(row, e)
    -- The marker carries the kind; the name is only tinted when flagged.
    row.pip:SetColorTexture(RGB(FLAG_COLOUR[e.flag] or KIND_COLOUR[e.kind] or "ffffff"))
    local colour = FLAG_COLOUR[e.flag] or SOURCE_COLOUR.docs
    row.text:SetText(format("|cff%s%s|r", colour, e.full))
    local tag = Model.KIND_TAGS[e.kind] or e.kind
    if e.flag == "undocumented" then tag = tag .. " ?" elseif e.flag == "missing" then tag = tag .. " !" end
    if Model.IsRestricted(e) then tag = "R " .. tag end
    -- The group is not visible next to a match from "All matches" or Favorites.
    if (selectedGroup == ALL or selectedGroup == FAV) and e.group then tag = e.group.label .. "  " .. tag end
    row.tag:SetText(tag)
end

--------------------------------------------------------------------------------
-- History
--------------------------------------------------------------------------------

local function UpdateNav()
    backButton:SetEnabled(hpos > 1)
    backButton:SetAlpha(hpos > 1 and 1 or 0.35)
    forwardButton:SetEnabled(hpos < #history)
    forwardButton:SetAlpha(hpos < #history and 1 or 0.35)
end

local function Snapshot()
    return { query = searchBox:GetText() or "", kind = filters.kind, flag = filters.flag,
             group = selectedGroup, entry = selectedEntry }
end

local function Same(a, b)
    return a and b and a.query == b.query and a.kind == b.kind and a.flag == b.flag
       and a.group == b.group and a.entry == b.entry
end

-- Records the current state as a new step, dropping anything forward of it.
-- Returns true when a step was added.
local function Push()
    local s = Snapshot()
    if Same(history[hpos], s) then return false end
    for i = #history, hpos + 1, -1 do history[i] = nil end
    history[#history + 1] = s
    if #history > HISTORY_MAX then table.remove(history, 1) end
    hpos = #history
    UpdateNav()
    return true
end

-- A search being typed is one step, updated on each keystroke rather than
-- a step per letter; the next navigation starts a new step after it.
local function PushSearch()
    local top = history[hpos]
    if top and top.live then
        for i = #history, hpos + 1, -1 do history[i] = nil end
        history[hpos] = Snapshot()
        history[hpos].live = true
        UpdateNav()
    elseif Push() then
        history[hpos].live = true
    end
end

local function ModelFilters()
    return { kind = filters.kind ~= "all" and filters.kind or nil,
             flag = filters.flag ~= "any" and filters.flag or nil }
end

local function RunSearch()
    search = Model.Search(searchBox:GetText(), ModelFilters())
end

local function SetSearchText(text)
    quiet = true
    searchBox:SetText(text or "")
    quiet = false
end

local function Restore(s)
    filters.kind, filters.flag = s.kind, s.flag
    kindChips:SetValue(s.kind)
    flagChips:SetValue(s.flag)
    SetSearchText(s.query)
    RunSearch()
    selectedGroup, selectedEntry = s.group, s.entry
    Redraw()
    if selectedGroup then Reveal(groupList, selectedGroup) end
    if selectedEntry then Reveal(entryList, selectedEntry) end
    UpdateNav()
end

local function Back()
    if hpos > 1 then
        hpos = hpos - 1
        Restore(history[hpos])
    end
end

local function Forward()
    if hpos < #history then
        hpos = hpos + 1
        Restore(history[hpos])
    end
end

-- The mouse's back and forward buttons. Hooked on the window and on every
-- part of it that takes the mouse, since a click goes to the frame under the
-- cursor and not to the window behind it.
local function MouseNav(_, button)
    if button == "Button4" then Back() elseif button == "Button5" then Forward() end
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function SelectGroup(g)
    selectedGroup, selectedEntry = g, nil
    Redraw()
    Push()
end

local function SelectEntry(e)
    selectedEntry = e
    entryList:Refresh()
    ShowDetail()
    Push()
end

-- Search text or filters changed.
local function Searched()
    RunSearch()
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
    PushSearch()
end

local function SetQuery()
    if not quiet then Searched() end
end

local function SetKind(v)
    filters.kind = v
    Searched()
end

local function SetFlag(v)
    filters.flag = v
    Searched()
end

-- Jumps drop the search and filters, so the target is listed where it lives.
local function ClearSearch()
    filters.kind, filters.flag = "all", "any"
    kindChips:SetValue("all")
    flagChips:SetValue("any")
    SetSearchText("")
    search = nil
end

function GoToGroup(g)
    ClearSearch()
    selectedGroup, selectedEntry = g, nil
    Redraw()
    Reveal(groupList, g)
    Push()
end

function GoToEntry(e)
    ClearSearch()
    selectedGroup, selectedEntry = e.group, e
    Redraw()
    if e.group then Reveal(groupList, e.group) end
    Reveal(entryList, e)
    Push()
end

local function ToggleFormat()
    if not ns.db then return end
    ns.db.detailFormat = not AsLua() and "lua" or nil
    ShowDetail()
end

local function ToggleFavorite()
    local e = selectedEntry
    if not e or e.kind == "frame" or not ns.db then return end
    local set, key = FavoriteSet(), Model.EntryKey(e)
    set[key] = not set[key] or nil
    -- With the last favourite gone the Favorites group is no longer listed.
    if selectedGroup == FAV and #FavoriteEntries() == 0 then selectedGroup = e.group end
    Redraw(true)
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
    frame.statusText:SetText(format("%s   \194\183   %s   \194\183   %s %s   \194\183   ? undocumented, ! missing in this client, R restricted",
        Model.Describe(), docs, version or "?", build or ""))
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function Build()
    frame = ui.Window("WowApiLibBrowser", "WoW API Lib", 1080, 660, 860, 400)
    frame:SetScript("OnMouseUp", MouseNav)

    backButton = ui.Button(frame, "<", 26, Back)
    backButton:SetPoint("TOPLEFT", 12, TOOLBAR_Y - 1)
    forwardButton = ui.Button(frame, ">", 26, Forward)
    forwardButton:SetPoint("LEFT", backButton, "RIGHT", 4, 0)

    searchBox = ui.SearchBox(frame, 300, SetQuery, "Search, or type:AuraData, field:unitTarget")
    searchBox:SetPoint("LEFT", forwardButton, "RIGHT", 8, 0)

    local reload = ui.Button(frame, "Reload UI", 84, function() ReloadUI() end)
    reload:SetPoint("TOPRIGHT", -12, TOOLBAR_Y - 1)
    local export = ui.Button(frame, "Export", 76, function() ns.Export("all") end)
    export:SetPoint("RIGHT", reload, "LEFT", -6, 0)
    local copy = ui.Button(frame, "Select text", 92, function() detail:SelectAll() end, true)
    copy:SetPoint("RIGHT", export, "LEFT", -6, 0)
    local inspect = ui.Button(frame, "Inspect", 76, function() ns.StartInspector() end)
    inspect:SetPoint("RIGHT", copy, "LEFT", -6, 0)

    local showLabel = ui.Label(frame, "GameFontHighlightSmall", ui.C.muted)
    showLabel:SetPoint("TOPLEFT", 14, FILTER_Y - 4)
    showLabel:SetText("Show")
    kindChips = ui.Chips(frame, {
        { value = "all", label = "All" }, { value = "functions", label = "Functions" },
        { value = "events", label = "Events" }, { value = "types", label = "Types" },
    }, SetKind)
    kindChips:SetPoint("LEFT", showLabel, "RIGHT", 8, 0)

    local onlyLabel = ui.Label(frame, "GameFontHighlightSmall", ui.C.muted)
    onlyLabel:SetPoint("LEFT", kindChips, "RIGHT", 18, 0)
    onlyLabel:SetText("Only")
    flagChips = ui.Chips(frame, {
        { value = "any", label = "Any" }, { value = "restricted", label = "Restricted" },
        { value = "undocumented", label = "Undocumented" }, { value = "missing", label = "Missing" },
    }, SetFlag)
    flagChips:SetPoint("LEFT", onlyLabel, "RIGHT", 8, 0)

    groupList = ui.List(frame, {
        title = "Groups",
        render = RenderGroup,
        onClick = SelectGroup,
        onMouseNav = MouseNav,
        isSelected = function(g) return g == selectedGroup end,
    })
    groupList:SetPoint("TOPLEFT", 12, TOP)
    groupList:SetPoint("BOTTOMLEFT", 12, BOTTOM)
    groupList:SetWidth(GROUP_W)

    entryList = ui.List(frame, {
        title = "Entries",
        pip = true,
        render = RenderEntry,
        onClick = SelectEntry,
        onMouseNav = MouseNav,
        isSelected = function(e) return e == selectedEntry end,
    })
    entryList:SetPoint("TOPLEFT", groupList, "TOPRIGHT", GAP, 0)
    entryList:SetPoint("BOTTOMLEFT", groupList, "BOTTOMRIGHT", GAP, 0)
    entryList:SetWidth(ENTRY_W)

    detail = ui.TextView(frame, "Details")
    detail:SetPoint("TOPLEFT", entryList, "TOPRIGHT", GAP, 0)
    detail:SetPoint("BOTTOMRIGHT", -12, BOTTOM)
    detail:SetEmptyText("Pick a group to list it in full, or an entry to see its signature, types and flags.")
    formatButton = detail:AddHeaderButton("As Lua", 64, ToggleFormat)
    favButton = detail:AddHeaderButton("Favorite", 80, ToggleFavorite)
    favButton:Hide()

    for _, f in ipairs({ groupList, entryList, detail, detail.scroll, detail.edit }) do
        f:EnableMouse(true)
        f:HookScript("OnMouseUp", MouseNav)
    end
end

--------------------------------------------------------------------------------
-- Public entry points
--------------------------------------------------------------------------------

-- query: optional; replaces the search text when given ("" clears it, which
-- is what `/wal search` with nothing after it does).
function ns.ShowBrowser(query)
    if not frame then
        Build()
        Model.Build()
        groupList:Layout()
        entryList:Layout()
        Footer()
        Redraw()
        Push()
    end
    frame:Show()
    if query and query ~= (searchBox:GetText() or "") then
        -- SetText fires OnTextChanged, which runs the search.
        searchBox:SetText(query)
    end
end

function ns.HideBrowser()
    if frame then frame:Hide() end
end

function ns.ToggleBrowser()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        ns.ShowBrowser()
    end
end

-- Opens a frame picked by the inspector: its report in the detail pane, its
-- widget type's methods in the entry list.
function ns.InspectFrame(f)
    local info = ns.DescribeFrame(f)
    ns.ShowBrowser()
    ClearSearch()
    selectedGroup = info.objectType and Model.FindGroup("rt:widget:" .. info.objectType) or nil
    selectedEntry = { kind = "frame", full = info.name, info = info }
    Redraw()
    if selectedGroup then Reveal(groupList, selectedGroup) end
    Push()
end

-- After the model has been rebuilt (/wal rescan): every group and entry the
-- window holds belongs to the old model, history included.
function ns.RefreshBrowser()
    if not frame then return end
    selectedGroup, selectedEntry = nil, nil
    history, hpos = {}, 0
    RunSearch()
    if search then selectedGroup = ALL end
    Footer()
    Redraw()
    Push()
end
