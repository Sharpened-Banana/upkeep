-- Modules/CharacterPanel.lua
-- Docks an "Upkeep Insights" panel to the character sheet: an item level
-- breakdown, enchant status per slot, and the same stat context the
-- overlay's tooltips already show, all visible without hovering anything.

local ADDON, ns = ...

local CharacterPanel = ns:NewModule("CharacterPanel")

-- Enchantable in the current expansion (Midnight, patch 12.x): Head,
-- Shoulder, Chest, both rings, Feet, and weapons. This list has changed
-- before - Cloak and Bracer enchants existed in earlier expansions and were
-- removed here, while Shoulder and Head enchants returned - and will change
-- again; update it each expansion/season rather than trusting memory.
local ENCHANT_SLOTS = {
    { slot = INVSLOT_HEAD,     label = "Head" },
    { slot = INVSLOT_SHOULDER, label = "Shoulder" },
    { slot = INVSLOT_CHEST,    label = "Chest" },
    { slot = INVSLOT_FEET,     label = "Feet" },
    { slot = INVSLOT_FINGER1,  label = "Ring 1" },
    { slot = INVSLOT_FINGER2,  label = "Ring 2" },
    { slot = INVSLOT_MAINHAND, label = "Main Hand" },
    { slot = INVSLOT_OFFHAND,  label = "Off Hand" },
}

-- Every slot that counts toward average item level - everything the
-- character panel itself counts, i.e. all equipment except shirt and tabard.
local ILVL_SLOTS = {
    INVSLOT_HEAD, INVSLOT_NECK, INVSLOT_SHOULDER, INVSLOT_CHEST, INVSLOT_WAIST,
    INVSLOT_LEGS, INVSLOT_FEET, INVSLOT_WRIST, INVSLOT_HAND,
    INVSLOT_FINGER1, INVSLOT_FINGER2, INVSLOT_TRINKET1, INVSLOT_TRINKET2,
    INVSLOT_BACK, INVSLOT_MAINHAND, INVSLOT_OFFHAND,
}

local SLOT_NAMES = {
    [INVSLOT_HEAD] = "Head", [INVSLOT_NECK] = "Neck", [INVSLOT_SHOULDER] = "Shoulder",
    [INVSLOT_CHEST] = "Chest", [INVSLOT_WAIST] = "Waist", [INVSLOT_LEGS] = "Legs",
    [INVSLOT_FEET] = "Feet", [INVSLOT_WRIST] = "Wrist", [INVSLOT_HAND] = "Hands",
    [INVSLOT_FINGER1] = "Ring 1", [INVSLOT_FINGER2] = "Ring 2",
    [INVSLOT_TRINKET1] = "Trinket 1", [INVSLOT_TRINKET2] = "Trinket 2",
    [INVSLOT_BACK] = "Back", [INVSLOT_MAINHAND] = "Main Hand", [INVSLOT_OFFHAND] = "Off Hand",
}

--------------------------------------------------------------------------------
-- Enchant status
--
-- Whether a slot is enchanted at all comes from the item link's own enchant
-- ID field - cheap and always reliable. Naming the enchant is the harder
-- part: there is no enchant-ID-to-name API, so this reads it the way
-- long-standing enchant addons (Enchantrix included) do - Blizzard's own
-- tooltip carries a line built from the ENCHANTED_TOOLTIP_LINE global string
-- ("Enchanted: %s" in English), so turning that format string into a Lua
-- pattern once and matching it against the tooltip's lines recovers the
-- exact text without an enchant database, and without assuming English.
--------------------------------------------------------------------------------

local ENCHANT_LINE_PATTERN = ENCHANTED_TOOLTIP_LINE and ENCHANTED_TOOLTIP_LINE:gsub("%%s", "(.+)")

-- { enchanted = true/false, text = descriptive text or nil }, or nil when the
-- slot holds no item at all (an empty off-hand with a two-handed weapon
-- equipped, say) - a caller treats nil as "not applicable", not "missing".
local function GetEnchantInfo(slotID)
    local ok, link = pcall(GetInventoryItemLink, "player", slotID)
    if not ok or not link then return nil end

    local enchantID = tonumber(link:match("item:%d+:(%d+)"))
    if not enchantID or enchantID == 0 then
        return { enchanted = false }
    end

    -- Naming it is best-effort: if the tooltip API is unavailable or the
    -- line format does not match, the slot still correctly reports as
    -- enchanted, just without a name.
    if ENCHANT_LINE_PATTERN and C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
        local tipOk, data = pcall(C_TooltipInfo.GetInventoryItem, "player", slotID)
        if tipOk and data and data.lines then
            for _, line in ipairs(data.lines) do
                local text = line.leftText and line.leftText:match(ENCHANT_LINE_PATTERN)
                if text then
                    return { enchanted = true, text = text }
                end
            end
        end
    end

    return { enchanted = true }
end

local function GetEnchantRows()
    local rows = {}
    for _, entry in ipairs(ENCHANT_SLOTS) do
        local info = GetEnchantInfo(entry.slot)
        if info then
            rows[#rows + 1] = { label = entry.label, enchanted = info.enchanted, text = info.text }
        end
    end
    return rows
end

--------------------------------------------------------------------------------
-- Item level
--------------------------------------------------------------------------------

-- The label and level of whichever equipped slot has the lowest item level,
-- or nil if nothing is equipped yet (fresh character, still in the barbershop).
local function GetLowestItemLevelSlot()
    local getLevel = C_Item and C_Item.GetDetailedItemLevelInfo
    if not getLevel then return nil end

    local lowestLabel, lowestLevel
    for _, slotID in ipairs(ILVL_SLOTS) do
        local ok, link = pcall(GetInventoryItemLink, "player", slotID)
        if ok and link then
            local levelOk, level = pcall(getLevel, link)
            if levelOk and level and level > 0 and (not lowestLevel or level < lowestLevel) then
                lowestLevel = level
                lowestLabel = SLOT_NAMES[slotID] or "?"
            end
        end
    end

    return lowestLabel, lowestLevel
end

--------------------------------------------------------------------------------
-- Gems
--
-- A gem socket's tooltip line - filled or empty - carries a real structured
-- line type (Enum.TooltipDataLineType.GemSocket), not just a rendered icon,
-- so counting those lines gives an honest socket count regardless of fill
-- state. C_Item.GetItemGem then says whether each one, in socket order, is
-- actually filled and with what; anything it doesn't confirm as filled is
-- reported as an empty socket rather than skipped.
--------------------------------------------------------------------------------

local GEM_SOCKET_LINE_TYPE = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.GemSocket

local function GetGemRowsForSlot(label, slotID, link)
    local rows = {}
    if not (GEM_SOCKET_LINE_TYPE and C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then
        return rows
    end

    local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", slotID)
    if not ok or not data or not data.lines then return rows end

    local getGem = (C_Item and C_Item.GetItemGem) or GetItemGem
    local socketIndex = 0

    for _, line in ipairs(data.lines) do
        if line.type == GEM_SOCKET_LINE_TYPE then
            socketIndex = socketIndex + 1

            local gemName
            if getGem then
                local gemOk, name = pcall(getGem, link, socketIndex)
                if gemOk then gemName = name end
            end

            if gemName and gemName ~= "" then
                rows[#rows + 1] = { label = label, value = gemName, filled = true }
            else
                rows[#rows + 1] = { label = label, value = line.leftText or "empty socket", filled = false }
            end
        end
    end

    return rows
end

local function GetGemRows()
    local rows = {}
    for _, slotID in ipairs(ILVL_SLOTS) do
        local ok, link = pcall(GetInventoryItemLink, "player", slotID)
        if ok and link then
            for _, row in ipairs(GetGemRowsForSlot(SLOT_NAMES[slotID] or "?", slotID, link)) do
                rows[#rows + 1] = row
            end
        end
    end
    return rows
end

--------------------------------------------------------------------------------
-- Panel construction and rendering
--------------------------------------------------------------------------------

local ROW_HEIGHT = 14
local HEADER_HEIGHT = 20
local PADDING = 10

local function CreatePanel()
    local frame = CreateFrame("Frame", "UpkeepCharacterPanel", CharacterFrame, "BackdropTemplate")
    frame:SetSize(260, 200)
    frame:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", 4, 0)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0, 0, 0, 0.8)
    frame:SetBackdropBorderColor(1, 1, 1, 0.15)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING)
    title:SetText("Upkeep Insights")

    frame.lines = {}
    return frame
end

local function GetOrCreateLine(frame, index)
    local line = frame.lines[index]
    if not line then
        line = {
            left = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
            right = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"),
        }
        line.left:SetJustifyH("LEFT")
        line.right:SetJustifyH("RIGHT")
        frame.lines[index] = line
    end
    return line
end

-- rows is an array of { left, right, header, color }. A header row spans the
-- full width in place of a left/right pair.
-- Enchant/gem names come from the game's own text and vary wildly in
-- length; the right column is a fixed width, so anything long enough to
-- run into the label gets cut short instead.
local MAX_VALUE_LENGTH = 26

local function Truncate(text)
    if type(text) ~= "string" or #text <= MAX_VALUE_LENGTH then return text end
    return text:sub(1, MAX_VALUE_LENGTH - 1) .. "\226\128\166" -- "…"
end

local function Render(frame, rows)
    local y = -(PADDING + HEADER_HEIGHT)

    for index, row in ipairs(rows) do
        local line = GetOrCreateLine(frame, index)
        local height = row.header and HEADER_HEIGHT or ROW_HEIGHT

        line.left:ClearAllPoints()
        line.right:ClearAllPoints()

        if row.header then
            line.left:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
            line.left:SetText(row.left or "")
            line.left:SetTextColor(0.4, 0.8, 1.0)
            line.right:SetText("")
        else
            line.left:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
            line.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, y)
            line.left:SetText(row.left or "")
            line.left:SetTextColor(0.85, 0.85, 0.85)
            line.right:SetText(Truncate(row.right) or "")
            if row.color then
                line.right:SetTextColor(unpack(row.color))
            else
                line.right:SetTextColor(1, 1, 1)
            end
        end

        line.left:Show()
        line.right:Show()
        y = y - height
    end

    for index = #rows + 1, #frame.lines do
        frame.lines[index].left:Hide()
        frame.lines[index].right:Hide()
    end

    frame:SetHeight(math.max(-y + PADDING, 60))
end

--------------------------------------------------------------------------------
-- Module
--------------------------------------------------------------------------------

function CharacterPanel:Update()
    local frame = self.frame
    if not frame or not frame:IsShown() then return end

    local rows = {}

    rows[#rows + 1] = { left = "Item Level", header = true }
    local overall, equipped = GetAverageItemLevel()
    rows[#rows + 1] = { left = "Equipped", right = format("%.1f", equipped or 0) }
    rows[#rows + 1] = { left = "Overall", right = format("%.1f", overall or 0) }
    local lowestLabel, lowestLevel = GetLowestItemLevelSlot()
    if lowestLabel then
        rows[#rows + 1] = { left = "Lowest slot", right = format("%s (%d)", lowestLabel, lowestLevel) }
    end

    rows[#rows + 1] = { left = "Enchants", header = true }
    local enchantRows = GetEnchantRows()
    if #enchantRows == 0 then
        rows[#rows + 1] = { left = "Nothing enchantable equipped", right = "" }
    end
    for _, entry in ipairs(enchantRows) do
        rows[#rows + 1] = {
            left = entry.label,
            right = entry.enchanted and (entry.text or "enchanted") or "missing",
            color = entry.enchanted and ns.Colors.good or ns.Colors.bad,
        }
    end

    local gemRows = GetGemRows()
    if #gemRows > 0 then
        rows[#rows + 1] = { left = "Gems", header = true }
        for _, entry in ipairs(gemRows) do
            rows[#rows + 1] = {
                left = entry.label,
                right = entry.value,
                color = entry.filled and ns.Colors.good or ns.Colors.bad,
            }
        end
    end

    rows[#rows + 1] = { left = "Stats", header = true }
    local Stats = ns:GetModule("Stats")
    local ok, statRows = pcall(function() return Stats and Stats:GetContextStats() end)
    if ok and statRows then
        for _, stat in ipairs(statRows) do
            rows[#rows + 1] = { left = stat.label, right = stat.value }
            if stat.detail then
                rows[#rows + 1] = { left = "", right = stat.detail, color = ns.Colors.neutral }
            end
        end
    end

    Render(frame, rows)
end

function CharacterPanel:OnInit()
    if not CharacterFrame then return end
    self.frame = CreatePanel()
    self.frame:Hide()
end

function CharacterPanel:OnEnable()
    if not self.frame then return end

    -- PaperDollFrame is the tab actually showing gear/stats; hiding with it
    -- (rather than with CharacterFrame) means switching to another tab, like
    -- Reputation, correctly takes this panel away too.
    if PaperDollFrame then
        PaperDollFrame:HookScript("OnShow", function()
            if ns.db.characterPanel.enabled then
                self.frame:Show()
                self:Update()
            end
        end)
        PaperDollFrame:HookScript("OnHide", function()
            self.frame:Hide()
        end)
    end

    ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() self:Update() end)
    ns:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_UPDATE", function() self:Update() end)
end

function CharacterPanel:OnConfigChanged()
    if not self.frame then return end

    if not ns.db.characterPanel.enabled then
        self.frame:Hide()
    elseif PaperDollFrame and PaperDollFrame:IsShown() then
        self.frame:Show()
        self:Update()
    end
end
