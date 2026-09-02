-- UI/Overlay.lua
-- The movable overlay frame and its row-layout engine.
--
-- Modules never touch frames directly. They hand the UI a list of rows via
-- UI:SetSection(id, rows) and the layout is rebuilt on the next frame.

local ADDON, ns = ...

local UI = ns:NewModule("UI")
ns.UI = UI

local SECTION_ORDER = { "stats", "combat", "procs", "buffs" }
local SECTION_TITLES = { stats = "Stats", combat = "Combat", procs = "Procs", buffs = "Buffs" }

local PADDING = 8
local SECTION_GAP = 6
local HEADER_HEIGHT = 14
local ICON_SIZE = 12

local sections = {}
local layoutDirty = false

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------

-- Rebuilds the backdrop from the chosen theme and applies its colors. Called
-- on creation and on every config change, since either the theme or the
-- opacity slider can be what changed.
local function ApplyTheme(frame, db)
    local theme = ns.GetTheme(db.theme)

    frame:SetBackdrop({
        bgFile = theme.bgTexture,
        edgeFile = theme.edgeTexture,
        edgeSize = theme.edgeSize,
    })

    local br, bgc, bb = unpack(theme.bgColor)
    frame:SetBackdropColor(br, bgc, bb, db.opacity)

    local er, eg, eb, ea = theme.GetEdgeColor()
    frame:SetBackdropBorderColor(er, eg, eb, ea)
end

local function CreateOverlayFrame()
    local frame = CreateFrame("Frame", "UpkeepFrame", UIParent, "BackdropTemplate")
    frame:SetSize(190, 100)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    ApplyTheme(frame, ns.db)

    frame:SetScript("OnDragStart", function(self)
        if ns.db.locked then return end
        self:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        local pos = ns.db.position
        pos.point, pos.relPoint, pos.x, pos.y = point, relPoint, x, y
    end)

    -- Title, shown only while unlocked so the overlay stays clean in combat.
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
    title:SetText("Upkeep |cff888888(drag to move)|r")
    frame.title = title

    return frame
end

--------------------------------------------------------------------------------
-- Row pooling
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Tooltip hand-off
--
-- Modules stay frame-free: a row carries a tooltipKey, and its section carries
-- a provider that turns that key into displayable data on hover. Rendering and
-- pinning live in UI/Tooltips.lua; rows only report enter and leave.
--------------------------------------------------------------------------------

local function ShowRowTooltip(row)
    if ns.Tooltips then
        ns.Tooltips:OnRowEnter(row)
    end
end

local function HideRowTooltip(row)
    if ns.Tooltips then
        ns.Tooltips:OnRowLeave(row)
    end
end

local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(14)

    row:SetScript("OnEnter", ShowRowTooltip)
    row:SetScript("OnLeave", HideRowTooltip)

    -- Let clicks fall through to whatever is underneath, so hover tooltips do
    -- not cost the click-through that makes a locked overlay unobtrusive.
    -- Guarded: these calls do not exist on every game version.
    pcall(row.SetPropagateMouseClicks, row, true)
    pcall(row.SetPropagateMouseMotion, row, false)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetJustifyH("LEFT")
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)

    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.value:SetJustifyH("RIGHT")
    row.value:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    return row
end

local function GetSection(id)
    local section = sections[id]
    if not section then
        section = { id = id, rows = {}, data = {}, frames = {} }
        sections[id] = section
    end
    return section
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- rows is an array of { label, value, icon, labelColor, valueColor, alpha,
-- tooltipKey }. tooltipProvider is called as provider(tooltipKey) on hover and
-- returns either { spellID } or { title, value, lines, description }.
function UI:SetSection(id, rows, tooltipProvider)
    local section = GetSection(id)
    section.data = rows or {}
    section.tooltipProvider = tooltipProvider
    layoutDirty = true
end

function UI:MarkDirty()
    layoutDirty = true
end

-- Pinned tooltips outlive the row they were opened from, so they look their
-- provider up by section rather than holding onto a recycled row frame.
function UI:GetSectionProvider(id)
    local section = sections[id]
    return section and section.tooltipProvider
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function ApplyFont(fontString, size, isValue)
    local font = GameFontNormal:GetFont()
    fontString:SetFont(font, size, "OUTLINE")
    if not isValue then
        fontString:SetTextColor(0.85, 0.85, 0.85)
    end
end

local function LayoutSection(section, parent, yOffset, db)
    local rowHeight = db.fontSize + 3
    local data = section.data

    if #data == 0 then
        for _, row in ipairs(section.rows) do row:Hide() end
        if section.header then section.header:Hide() end
        return yOffset, false
    end

    if db.showHeaders then
        if not section.header then
            section.header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            section.header:SetJustifyH("LEFT")
        end
        section.header:ClearAllPoints()
        section.header:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, yOffset)
        section.header:SetText(SECTION_TITLES[section.id] or section.id)
        ApplyFont(section.header, db.fontSize, true)
        section.header:SetTextColor(0.4, 0.8, 1.0)
        section.header:Show()
        yOffset = yOffset - HEADER_HEIGHT
    elseif section.header then
        section.header:Hide()
    end

    for index, entry in ipairs(data) do
        local row = section.rows[index]
        if not row then
            row = CreateRow(parent)
            section.rows[index] = row
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, yOffset)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PADDING, yOffset)
        row:SetHeight(rowHeight)
        row:SetAlpha(entry.alpha or 1)

        -- A row only takes mouse input when it has something to say.
        local hasTooltip = db.tooltips and entry.tooltipKey and section.tooltipProvider
        row.tooltipKey = hasTooltip and entry.tooltipKey or nil
        row.tooltipProvider = hasTooltip and section.tooltipProvider or nil
        row.sectionID = section.id
        row:EnableMouse(hasTooltip and true or false)

        local labelInset = 0
        if entry.icon then
            row.icon:SetTexture(entry.icon)
            row.icon:SetSize(db.fontSize, db.fontSize)
            row.icon:SetDesaturated(entry.desaturate or false)
            row.icon:Show()
            labelInset = db.fontSize + 3
        else
            row.icon:Hide()
        end

        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", row, "LEFT", labelInset, 0)
        row.label:SetText(entry.label or "")
        ApplyFont(row.label, db.fontSize, false)
        if entry.labelColor then
            row.label:SetTextColor(unpack(entry.labelColor))
        end

        row.value:SetText(entry.value or "")
        ApplyFont(row.value, db.fontSize, true)
        if entry.valueColor then
            row.value:SetTextColor(unpack(entry.valueColor))
        else
            row.value:SetTextColor(1, 1, 1)
        end

        row:Show()
        yOffset = yOffset - rowHeight
    end

    -- Hide rows left over from a previous, longer layout.
    for index = #data + 1, #section.rows do
        section.rows[index]:Hide()
    end

    return yOffset, true
end

function UI:Relayout()
    local frame = self.frame
    if not frame then return end

    local db = ns.db
    local yOffset = -PADDING
    local drewAny = false

    for _, id in ipairs(SECTION_ORDER) do
        local section = sections[id]
        if section then
            -- Only spend a gap on a section that actually draws something,
            -- otherwise an empty section leaves a hole in the panel.
            local gap = (drewAny and #section.data > 0) and SECTION_GAP or 0
            local drew
            yOffset, drew = LayoutSection(section, frame, yOffset - gap, db)
            drewAny = drewAny or drew
        end
    end

    frame:SetWidth(db.width)
    frame:SetHeight(math.max(-yOffset + PADDING, 20))
end

--------------------------------------------------------------------------------
-- Visibility & configuration
--------------------------------------------------------------------------------

function UI:UpdateVisibility()
    local frame = self.frame
    if not frame then return end

    -- An explicit /up hide always wins; the combat filter only applies when the
    -- player has not hidden the overlay by hand.
    if ns.db.hidden then
        frame:Hide()
        return
    end

    frame:SetShown(not (ns.db.hideOutOfCombat and not InCombatLockdown()))
end

function UI:Toggle()
    ns.db.hidden = not ns.db.hidden
    self:UpdateVisibility()
    return not ns.db.hidden
end

function UI:OnConfigChanged()
    local frame = self.frame
    if not frame then return end

    local db = ns.db
    frame:SetScale(db.scale)
    ApplyTheme(frame, db)
    frame:EnableMouse(not db.locked)
    frame.title:SetShown(not db.locked)

    local pos = db.position
    frame:ClearAllPoints()
    frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)

    self:UpdateVisibility()
    self:Relayout()
end

function UI:ResetPosition()
    local pos = ns.db.position
    local defaults = ns.DEFAULTS.position
    pos.point, pos.relPoint, pos.x, pos.y = defaults.point, defaults.relPoint, defaults.x, defaults.y
    self:OnConfigChanged()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function UI:OnInit()
    self.frame = CreateOverlayFrame()

    -- The driver is separate from the overlay so layout keeps being applied
    -- while the overlay itself is hidden (a hidden frame gets no OnUpdate).
    -- Relayout runs at most once per frame no matter how many modules updated.
    local driver = CreateFrame("Frame", nil, UIParent)
    driver:SetScript("OnUpdate", function()
        if layoutDirty then
            layoutDirty = false
            UI:Relayout()
        end
    end)
    self.driver = driver
end

function UI:OnEnable()
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() UI:UpdateVisibility() end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() UI:UpdateVisibility() end)
    self:OnConfigChanged()
end
