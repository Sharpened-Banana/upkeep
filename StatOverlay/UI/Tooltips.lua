-- UI/Tooltips.lua
-- Hover tooltips and pinned ("sticky") tooltips.
--
-- The shared GameTooltip cannot be pinned: everything in the UI reuses it, so
-- the next hover would wipe whatever we left there. Both the hover tooltip and
-- each pin are therefore our own GameTooltipTemplate frames.
--
-- Pinning happens either by clicking the hover tooltip or through a key binding
-- while a row is hovered. Rows themselves stay click-through, so the locked
-- overlay never swallows a click meant for the world behind it.

local ADDON, ns = ...

local Tooltips = ns:NewModule("Tooltips")
ns.Tooltips = Tooltips

-- How long the hover tooltip survives after the mouse leaves the row, giving
-- the pointer time to travel into the tooltip to click it.
local HOVER_GRACE = 0.3
local PIN_REFRESH = 0.5
local PIN_GAP = 8
local MAX_PINS = 12

local hoverFrame
local hovered
local hideToken = 0

local pins = {}      -- id -> pin frame
local pinOrder = {}  -- ids, in the order they were pinned
local pinPool = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function PinID(sectionID, key)
    return tostring(sectionID) .. ":" .. tostring(key)
end

local function IndexOf(list, value)
    for index, entry in ipairs(list) do
        if entry == value then return index end
    end
    return nil
end

-- Draws tooltip data into any tooltip frame. `hint` adds the line telling the
-- player how to make it stay.
local function Render(tooltip, data, hint)
    if not data then return false end

    tooltip:ClearLines()

    if data.spellID then
        tooltip:SetSpellByID(data.spellID)
    else
        tooltip:AddDoubleLine(data.title or "", data.value or "", 1, 1, 1, 1, 0.82, 0)

        for _, line in ipairs(data.lines or {}) do
            tooltip:AddDoubleLine(line.left, line.right, 0.8, 0.8, 0.8, 1, 1, 1)
        end

        if data.description then
            tooltip:AddLine(" ")
            tooltip:AddLine(data.description, 0.6, 0.8, 1, true)
        end
    end

    if hint then
        tooltip:AddLine(" ")
        tooltip:AddLine("Click to keep this on screen", 0.5, 0.5, 0.5)
    end

    tooltip:Show()
    return true
end

--------------------------------------------------------------------------------
-- Hover tooltip
--------------------------------------------------------------------------------

local function CreateHoverFrame()
    local frame = CreateFrame("GameTooltip", "StatOverlayHoverTooltip", UIParent, "GameTooltipTemplate")
    frame:SetClampedToScreen(true)

    -- Mouse-enabled so the player can move into it and click to pin.
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function() Tooltips:CancelHide() end)
    frame:SetScript("OnLeave", function() Tooltips:ScheduleHide() end)
    frame:SetScript("OnMouseDown", function() Tooltips:PinHovered() end)

    return frame
end

function Tooltips:CancelHide()
    hideToken = hideToken + 1
end

function Tooltips:ScheduleHide()
    hideToken = hideToken + 1
    local token = hideToken

    C_Timer.After(HOVER_GRACE, function()
        -- A newer enter or leave has happened since; that one owns the state.
        if token == hideToken then
            Tooltips:HideHover()
        end
    end)
end

function Tooltips:HideHover()
    hovered = nil
    if hoverFrame then
        hoverFrame:Hide()
    end
end

function Tooltips:OnRowEnter(row)
    if not ns.db.tooltips then return end
    if not row.tooltipProvider or row.tooltipKey == nil then return end

    self:CancelHide()

    -- Already pinned: no point showing the same thing twice.
    if pins[PinID(row.sectionID, row.tooltipKey)] then
        self:HideHover()
        return
    end

    hovered = {
        sectionID = row.sectionID,
        key = row.tooltipKey,
        provider = row.tooltipProvider,
    }

    hoverFrame:SetOwner(row, "ANCHOR_NONE")
    hoverFrame:ClearAllPoints()
    hoverFrame:SetPoint("TOPLEFT", row, "TOPRIGHT", 4, 6)

    if not Render(hoverFrame, row.tooltipProvider(row.tooltipKey), true) then
        self:HideHover()
    end
end

function Tooltips:OnRowLeave()
    self:ScheduleHide()
end

function Tooltips:GetHovered()
    return hovered
end

--------------------------------------------------------------------------------
-- Pinned tooltips
--------------------------------------------------------------------------------

local function SavePinPosition(pin)
    local saved = ns.db.pinnedTooltips[pin.pinID]
    if not saved then return end

    local point, _, relPoint, x, y = pin:GetPoint()
    saved.point, saved.relPoint, saved.x, saved.y = point, relPoint, x, y
    saved.custom = true
end

local function CreatePinFrame(index)
    local frame = CreateFrame("GameTooltip", "StatOverlayPinnedTooltip" .. index, UIParent, "GameTooltipTemplate")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")

    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePinPosition(self)
    end)

    -- Right-click anywhere on a pin closes it.
    frame:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            Tooltips:Unpin(self.pinID)
        end
    end)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() Tooltips:Unpin(frame.pinID) end)
    frame.closeButton = close

    return frame
end

-- Counts frames ever created, not currently active: reusing an index would
-- hand two frames the same global name.
local pinFramesCreated = 0

local function AcquirePin()
    local frame = table.remove(pinPool)
    if not frame then
        pinFramesCreated = pinFramesCreated + 1
        frame = CreatePinFrame(pinFramesCreated)
    end
    return frame
end

-- Pins with no position of their own stack down the right edge of the overlay.
-- Anchoring each to the one above avoids needing to know their heights.
local function RestackPins()
    local previous
    for _, id in ipairs(pinOrder) do
        local pin = pins[id]
        local saved = ns.db.pinnedTooltips[id]

        if pin and not (saved and saved.custom) then
            pin:ClearAllPoints()
            if previous then
                pin:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -PIN_GAP)
            else
                pin:SetPoint("TOPLEFT", ns.UI.frame, "TOPRIGHT", PIN_GAP, 0)
            end
            -- Only pins actually in the stack chain anchor the next one; a
            -- custom-dragged pin sitting between two stacked pins would
            -- otherwise pull the rest of the stack to wherever it was
            -- dropped instead of leaving them on the overlay's edge.
            previous = pin
        end
    end
end

local function RefreshPin(pin)
    local provider = ns.UI:GetSectionProvider(pin.sectionID)
    if not provider then return end

    local data = provider(pin.key)
    if data then
        Render(pin, data, false)
    end
end

function Tooltips:Pin(sectionID, key)
    local id = PinID(sectionID, key)

    if pins[id] then
        return false, "already pinned"
    end
    if #pinOrder >= MAX_PINS then
        return false, format("at the limit of %d pinned tooltips", MAX_PINS)
    end

    local provider = ns.UI:GetSectionProvider(sectionID)
    if not provider then
        return false, "nothing to pin there"
    end

    local frame = AcquirePin()
    frame.pinID, frame.sectionID, frame.key = id, sectionID, key

    pins[id] = frame
    pinOrder[#pinOrder + 1] = id

    local saved = ns.db.pinnedTooltips[id]
    if not saved then
        saved = { section = sectionID, key = key }
        ns.db.pinnedTooltips[id] = saved
    end

    frame:SetOwner(UIParent, "ANCHOR_NONE")
    frame:ClearAllPoints()
    if saved.custom and saved.point then
        frame:SetPoint(saved.point, UIParent, saved.relPoint, saved.x, saved.y)
    end

    RefreshPin(frame)
    RestackPins()

    return true, id
end

function Tooltips:Unpin(id)
    local frame = pins[id]
    if not frame then return false end

    frame:Hide()
    pins[id] = nil
    ns.db.pinnedTooltips[id] = nil

    local index = IndexOf(pinOrder, id)
    if index then table.remove(pinOrder, index) end

    pinPool[#pinPool + 1] = frame
    RestackPins()
    return true
end

function Tooltips:UnpinAll()
    local removed = 0
    -- Iterate over a copy: Unpin mutates pinOrder.
    for _, id in ipairs({ unpack(pinOrder) }) do
        if self:Unpin(id) then removed = removed + 1 end
    end
    return removed
end

function Tooltips:PinHovered()
    if not hovered then
        return false, "hover a row first"
    end

    local sectionID, key = hovered.sectionID, hovered.key
    local ok, result = self:Pin(sectionID, key)
    if ok then
        self:HideHover()
    end
    return ok, result
end

-- A human-readable label for a pinned tooltip - the stat's display label, or
-- a proc's spell name - rather than the internal "section:key" id
-- (e.g. "stats:armor", "procs:190319") that id is built from.
local function FriendlyPinLabel(id)
    local pin = pins[id]
    if not pin then return id end

    if pin.sectionID == "stats" then
        for _, entry in ipairs(ns.STAT_LIST) do
            if entry.key == pin.key then return entry.label end
        end
    elseif pin.sectionID == "procs" then
        local name
        if C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(pin.key)
            name = info and info.name
        elseif GetSpellInfo then
            name = (GetSpellInfo(pin.key))
        end
        if name then return name end
    end

    return id
end

function Tooltips:ListPinned()
    local list = {}
    for _, id in ipairs(pinOrder) do
        list[#list + 1] = FriendlyPinLabel(id)
    end
    return list
end

function Tooltips:IsPinned(sectionID, key)
    return pins[PinID(sectionID, key)] ~= nil
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Recreates pins saved from a previous session, once the modules have published
-- their providers.
function Tooltips:RestoreSaved()
    for id, saved in pairs(ns.db.pinnedTooltips) do
        if not pins[id] and saved.section and saved.key ~= nil then
            self:Pin(saved.section, saved.key)
        end
    end
end

function Tooltips:OnInit()
    hoverFrame = CreateHoverFrame()
    hoverFrame:Hide()
end

function Tooltips:OnEnable()
    -- Providers only exist after the modules have rendered once.
    C_Timer.After(1, function() Tooltips:RestoreSaved() end)

    self.ticker = C_Timer.NewTicker(PIN_REFRESH, function()
        for _, id in ipairs(pinOrder) do
            local pin = pins[id]
            if pin then RefreshPin(pin) end
        end
    end)
end

function Tooltips:OnConfigChanged()
    if not ns.db.tooltips then
        self:HideHover()
    end
end

--------------------------------------------------------------------------------
-- Key binding
--------------------------------------------------------------------------------

BINDING_HEADER_STATOVERLAY = "StatOverlay"
BINDING_NAME_STATOVERLAY_PIN_TOOLTIP = "Pin hovered tooltip"

function StatOverlay_PinHoveredTooltip()
    local ok, result = ns.Tooltips:PinHovered()
    if not ok then
        ns.Print(result or "nothing to pin.")
    end
end
