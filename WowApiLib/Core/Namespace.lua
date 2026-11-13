--------------------------------------------------------------------------------
-- WoW API Lib -- namespace
--
-- Loaded first. Everything else hangs off `ns`.
--
-- Nothing in this addon runs at login beyond resolving the saved-variables
-- table. The documentation and the runtime scan are loaded the first time the
-- browser opens or an export is asked for: the generated documentation is a
-- few megabytes of tables, and nobody should pay for it on a login where they
-- never type /wal.
--------------------------------------------------------------------------------

local ADDON, ns = ...

ns.ADDON = ADDON
ns.VERSION = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WoW API Lib|r: " .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Saved variables
--
-- One table, WowApiLibDB. `export` is the only key that is ever large; it is
-- written by Core/Export.lua and read back by tools/convert.py, never by the
-- addon itself.
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")

    WowApiLibDB = type(WowApiLibDB) == "table" and WowApiLibDB or {}
    ns.db = WowApiLibDB
    ns.SetupLaunchers()
end)

--------------------------------------------------------------------------------
-- Cross-file stubs, replaced by the file that implements each, so a caller can
-- invoke them unconditionally.
--------------------------------------------------------------------------------

-- UI/Browser.lua
function ns.ShowBrowser(_) end
function ns.ToggleBrowser() end
function ns.RefreshBrowser() end
function ns.HideBrowser() end
function ns.InspectFrame(_) end

-- UI/Inspector.lua
function ns.StartInspector() end

-- UI/Launchers.lua
function ns.SetupLaunchers() end
function ns.ToggleMinimapButton() end
