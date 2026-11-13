--------------------------------------------------------------------------------
-- WoW API Lib -- launchers: the minimap button and the addon compartment entry
--
-- Both open or close the browser on click and show a tooltip on hover.
--
-- Minimap button: a plain named Button parented to Minimap, in the usual round
-- style. Button collectors (EllesmereUI's minimap grid, Enhance QoL's button
-- sink and others) gather named buttons parented to Minimap -- EllesmereUI
-- also hides Blizzard's compartment, so without this button the addon has no
-- launcher there at all. Once a collector has re-parented the button, it stops
-- positioning itself. `/wal minimap` hides or shows it.
--
-- Addon compartment: registered from code rather than with the .toc's
-- AddonCompartmentFunc lines: only Retail reads those, while the Classic-based
-- clients that have the compartment (the _forever_ client among them) only
-- take RegisterAddon. Doing both would list us twice on Retail.
--
-- Same approach as NpcSonar's Launchers.lua.
--------------------------------------------------------------------------------

local _, ns = ...

local ICON = "Interface\\Icons\\INV_Misc_Book_09"
local DEFAULT_ANGLE = 200   -- degrees, left of the minimap, a little below centre

ns.LAUNCHER_ICON = ICON

local function ShowTooltip(owner)
    if type(owner) == "table" and owner.GetObjectType then
        GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    else
        -- ANCHOR_LEFT on UIParent would put the tooltip off the screen.
        GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
    end
    GameTooltip:SetText("WoW API Lib")
    GameTooltip:AddLine("Click to open or close the API browser.", 1, 1, 1)
    GameTooltip:AddLine("/wal help for commands", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Minimap button
--
-- Built at file load and left shown: collectors take a button's visibility at
-- the moment they first find it as what the addon wants, and some scan before
-- ADDON_LOADED. A user who hid it gets it hidden again in SetupLaunchers.
--------------------------------------------------------------------------------

local mini = CreateFrame("Button", "WowApiLibMinimapButton", Minimap)
mini:SetSize(31, 31)
mini:SetFrameStrata("MEDIUM")
mini:SetFrameLevel(8)
mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mini:RegisterForDrag("LeftButton")
mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local background = mini:CreateTexture(nil, "BACKGROUND")
background:SetSize(20, 20)
background:SetPoint("TOPLEFT", 7, -5)
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

local icon = mini:CreateTexture(nil, "ARTWORK")
icon:SetSize(19, 19)
icon:SetPoint("TOPLEFT", 6, -6)
icon:SetTexture(ICON)
-- Trim the square icon's baked-in edge so it sits cleanly inside the ring.
icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

local border = mini:CreateTexture(nil, "OVERLAY")
border:SetSize(53, 53)
border:SetPoint("TOPLEFT")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function OwnedByMinimap()
    return mini:GetParent() == Minimap
end

local function PlaceOnRim()
    if not OwnedByMinimap() then return end
    local angle = math.rad((ns.db and ns.db.minimapAngle) or DEFAULT_ANGLE)
    local radius = Minimap:GetWidth() / 2 + 5
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function FollowCursor()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not (mx and cx and scale) then return end
    ns.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    PlaceOnRim()
end

mini:SetScript("OnDragStart", function(self)
    if not OwnedByMinimap() or not ns.db then return end  -- a collector is managing it
    self:SetScript("OnUpdate", FollowCursor)
    GameTooltip:Hide()
end)
mini:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)
mini:SetScript("OnClick", function() ns.ToggleBrowser() end)
mini:SetScript("OnEnter", function(self) ShowTooltip(self) end)
mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
PlaceOnRim()

function ns.UpdateMinimapButton()
    if ns.db and ns.db.minimapHidden then
        mini:Hide()
    else
        PlaceOnRim()
        mini:Show()
    end
end

function ns.ToggleMinimapButton()
    if not ns.db then return end
    ns.db.minimapHidden = not ns.db.minimapHidden or nil
    ns.UpdateMinimapButton()
    ns.Print(ns.db.minimapHidden
        and "Minimap button hidden. Type /wal minimap to show it again."
        or "Minimap button shown.")
end

--------------------------------------------------------------------------------
-- Addon compartment
--------------------------------------------------------------------------------

if AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon then
    AddonCompartmentFrame:RegisterAddon({
        text = "WoW API Lib",
        icon = ICON,
        notCheckable = true,
        func = function() ns.ToggleBrowser() end,
        funcOnEnter = function(button) ShowTooltip(button) end,
        funcOnLeave = function() GameTooltip:Hide() end,
    })
end

--------------------------------------------------------------------------------

-- Called from Core/Namespace.lua once the saved variables exist.
function ns.SetupLaunchers()
    ns.UpdateMinimapButton()
end
