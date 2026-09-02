-- tests/wow_mock.lua
-- A minimal stand-in for the parts of the WoW API that Upkeep touches.
--
-- This is not an emulator. It exists so the addon can be loaded and driven
-- outside the game, which catches load-order mistakes, nil API calls and bad
-- combat-log parsing without a 30GB client.

local mock = {}

--------------------------------------------------------------------------------
-- Clock
--------------------------------------------------------------------------------

mock.now = 1000

function GetTime()
    return mock.now
end

function mock.Advance(seconds)
    mock.now = mock.now + seconds
end

--------------------------------------------------------------------------------
-- Lua globals WoW provides
--------------------------------------------------------------------------------

format = string.format
strjoin = function(sep, ...) return table.concat({ ... }, sep) end

function tostringall(...)
    local out, count = {}, select("#", ...)
    for i = 1, count do
        out[i] = tostring((select(i, ...)))
    end
    return unpack(out, 1, count)
end

-- Lua 5.1 has no bit library; the addon only needs band over small flags.
bit = {
    band = function(a, b)
        local result, bitValue = 0, 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then
                result = result + bitValue
            end
            a, b, bitValue = math.floor(a / 2), math.floor(b / 2), bitValue * 2
        end
        return result
    end,
}

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local function NewRegion(kind)
    local region = { kind = kind, shown = true, points = {} }

    function region:SetPoint(...) table.insert(self.points, { ... }) end
    function region:ClearAllPoints() self.points = {} end
    function region:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function region:SetSize(w, h) self.width, self.height = w, h end
    function region:SetWidth(w) self.width = w end
    function region:SetHeight(h) self.height = h end
    function region:GetWidth() return self.width or 0 end
    function region:GetHeight() return self.height or 0 end
    function region:SetAlpha(a) self.alpha = a end
    function region:Show() self.shown = true end
    function region:Hide() self.shown = false end
    function region:IsShown() return self.shown end
    function region:SetShown(value) self.shown = value and true or false end

    return region
end

local function NewFontString()
    local fs = NewRegion("fontstring")
    function fs:SetText(text) self.text = text end
    function fs:GetText() return self.text end
    function fs:SetJustifyH() end
    function fs:SetFont(path, size) self.font, self.fontSize = path, size end
    function fs:GetFont() return self.font or "Fonts\\FRIZQT__.TTF", self.fontSize or 12, "" end
    function fs:SetTextColor(r, g, b) self.color = { r, g, b } end
    return fs
end

local function NewTexture()
    local texture = NewRegion("texture")
    function texture:SetTexture(value) self.texture = value end
    function texture:SetTexCoord() end
    function texture:SetDesaturated(value) self.desaturated = value end
    return texture
end

mock.frames = {}

function CreateFrame(frameType, name, parent, template)
    local frame = NewRegion("frame")
    frame.frameType, frame.name, frame.parent, frame.template = frameType, name, parent, template
    frame.scripts = {}
    frame.events = {}
    frame.children = {}

    function frame:SetScript(event, handler) self.scripts[event] = handler end
    function frame:GetScript(event) return self.scripts[event] end
    function frame:HookScript(event, handler) self.scripts[event] = handler end
    function frame:RegisterEvent(event)
        assert(type(event) == "string" and event ~= "", "bad event name")
        assert(mock.KNOWN_EVENTS[event], "unknown event: " .. event)
        self.events[event] = true
    end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:RegisterForDrag() end
    function frame:SetMovable() end
    function frame:SetClampedToScreen() end
    function frame:SetResizable() end
    function frame:EnableMouse(value) self.mouseEnabled = value end
    function frame:SetPropagateMouseClicks(value) self.propagateClicks = value end
    function frame:SetPropagateMouseMotion(value) self.propagateMotion = value end
    function frame:StartMoving() end
    function frame:StopMovingOrSizing() end
    function frame:SetScale(value) self.scale = value end
    function frame:GetScale() return self.scale or 1 end
    function frame:SetBackdrop(value) self.backdrop = value end
    function frame:SetBackdropColor(r, g, b, a) self.backdropColor = { r, g, b, a } end
    function frame:SetBackdropBorderColor(r, g, b, a) self.backdropBorderColor = { r, g, b, a } end
    function frame:SetFrameStrata() end
    function frame:SetFrameLevel() end

    -- Tooltip surface, for frames created from GameTooltipTemplate.
    frame.lines = {}
    function frame:SetOwner(owner, anchor)
        self.owner, self.anchor = owner, anchor
        self.lines = {}
        self.spellID = nil
    end
    function frame:ClearLines() self.lines = {}; self.spellID = nil end
    function frame:AddLine(text) table.insert(self.lines, { left = text }) end
    function frame:AddDoubleLine(left, right) table.insert(self.lines, { left = left, right = right }) end
    function frame:SetSpellByID(spellID)
        self.spellID = spellID
        local spell = mock.spells[spellID]
        table.insert(self.lines, { left = spell and spell.name or ("Spell " .. spellID) })
    end
    function frame:NumLines() return #self.lines end
    function frame:Dump()
        local out = {}
        for _, line in ipairs(self.lines) do
            out[#out + 1] = tostring(line.left) .. (line.right and ("=" .. tostring(line.right)) or "")
        end
        return out
    end

    function frame:CreateFontString()
        local fs = NewFontString()
        table.insert(self.children, fs)
        return fs
    end

    function frame:CreateTexture()
        local texture = NewTexture()
        table.insert(self.children, texture)
        return texture
    end

    if name then _G[name] = frame end
    table.insert(mock.frames, frame)
    return frame
end

UIParent = CreateFrame("Frame", "UIParent")

GameFontNormal = NewFontString()
GameFontNormalSmall = NewFontString()
GameFontHighlightSmall = NewFontString()

--------------------------------------------------------------------------------
-- Events
--
-- The addon guards RegisterEvent with pcall, so an unknown event would be
-- silently skipped in game. The mock asserts instead, turning a typo in an
-- event name into a loud test failure.
--------------------------------------------------------------------------------

mock.KNOWN_EVENTS = {}
for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "COMBAT_LOG_EVENT_UNFILTERED",
    "UNIT_STATS", "UNIT_AURA", "UNIT_MAXHEALTH", "UNIT_ATTACK_POWER",
    "COMBAT_RATING_UPDATE", "MASTERY_UPDATE", "SPEED_UPDATE",
    "LIFESTEAL_UPDATE", "AVOIDANCE_UPDATE",
    "PLAYER_EQUIPMENT_CHANGED", "PLAYER_AVG_ITEM_LEVEL_UPDATE",
    "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_TALENT_UPDATE",
    "GROUP_ROSTER_UPDATE",
}) do
    mock.KNOWN_EVENTS[event] = true
end

function mock.Fire(event, ...)
    for _, frame in ipairs(mock.frames) do
        if frame.events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event, ...)
        end
    end
end

-- Runs every frame's OnUpdate once, the way the client would.
function mock.Tick(elapsed)
    mock.Advance(elapsed or 0)
    for _, frame in ipairs(mock.frames) do
        if frame.shown and frame.scripts.OnUpdate then
            frame.scripts.OnUpdate(frame, elapsed or 0)
        end
    end
end

--------------------------------------------------------------------------------
-- Timers
--------------------------------------------------------------------------------

mock.tickers = {}

C_Timer = {
    NewTicker = function(interval, callback)
        local ticker = { interval = interval, callback = callback }
        function ticker:Cancel() self.cancelled = true end
        table.insert(mock.tickers, ticker)
        return ticker
    end,
    After = function(delay, callback)
        table.insert(mock.pending, { delay = delay, callback = callback })
    end,
}

mock.pending = {}

-- Runs every callback queued with C_Timer.After.
function mock.RunAfter()
    local queued = mock.pending
    mock.pending = {}
    for _, entry in ipairs(queued) do
        entry.callback()
    end
end

function mock.RunTickers()
    for _, ticker in ipairs(mock.tickers) do
        if not ticker.cancelled then ticker.callback() end
    end
end

--------------------------------------------------------------------------------
-- Combat log constants and flags
--------------------------------------------------------------------------------

COMBATLOG_OBJECT_AFFILIATION_MINE = 0x00000001
COMBATLOG_OBJECT_TYPE_PET = 0x00001000
COMBATLOG_OBJECT_TYPE_GUARDIAN = 0x00002000

CR_VERSATILITY_DAMAGE_DONE = 29
CR_VERSATILITY_DAMAGE_TAKEN = 31
CR_LIFESTEAL = 17
CR_AVOIDANCE = 21
CR_SPEED = 14
CR_CRIT_MELEE = 9
CR_CRIT_SPELL = 11
CR_HASTE_MELEE = 18
CR_HASTE_SPELL = 20
CR_MASTERY = 26

mock.combatLogPayload = {}

function CombatLogGetCurrentEventInfo()
    return unpack(mock.combatLogPayload, 1, mock.combatLogPayload.n or #mock.combatLogPayload)
end

-- Fires one combat log event with the given payload.
function mock.FireCombatLog(...)
    mock.combatLogPayload = { n = select("#", ...), ... }
    mock.Fire("COMBAT_LOG_EVENT_UNFILTERED")
end

--------------------------------------------------------------------------------
-- Character state
--------------------------------------------------------------------------------

mock.inCombat = false
mock.stats = { [1] = 1000, [2] = 8500, [3] = 12000, [4] = 900 }
mock.auras = {}

function InCombatLockdown() return mock.inCombat end
function UnitGUID(unit) return unit == "player" and "Player-1234-ABCDEF" or "Pet-0-1234" end
function UnitStat(_, index) return mock.stats[index] - 200, mock.stats[index], 200, 0 end
function UnitHealthMax() return 4250000 end
function UnitHealth() return 3100000 end
mock.armor = { base = 3000, effective = 4500, posBuff = 0 }
function UnitArmor()
    return mock.armor.base, mock.armor.effective, mock.armor.effective, mock.armor.posBuff, 0
end
function UnitLevel(unit) return unit == "player" and 80 or 1 end

-- Returns a 0-1 ratio, matching the client convention the addon's scale
-- probe is meant to detect (a probe <= 1 means "multiply by 100 to display").
--
-- Mirrors Blizzard's actual published armor-mitigation curve (see
-- Stats.lua's EstimateArmorConstant) rather than an arbitrary constant, so
-- the addon's manual estimate agrees with this "live" call by default and a
-- test can deliberately break that agreement to exercise the distrust path.
local function ArmorConstant(level)
    local k = 400 + 85 * level
    if level > 59 then k = k + 4.5 * (level - 59) end
    if level > 80 then k = k + 20 * (level - 80) end
    if level > 85 then k = k + 22 * (level - 85) end
    return k
end

-- Real armor mitigation caps at 75% regardless of level, most visible at
-- low target levels where the constant above is small.
local function ArmorRatio(armor, level)
    local ratio = armor / (armor + ArmorConstant(level))
    return ratio > 0.75 and 0.75 or ratio
end

C_PaperDollInfo = C_PaperDollInfo or {}
function C_PaperDollInfo.GetArmorEffectiveness(armor, level)
    return ArmorRatio(armor, level)
end

-- Blizzard's real API takes no level argument here either - it reads the
-- target's level internally. The mock target is always level 1 (see
-- UnitLevel above), so this uses that level's constant directly, which
-- naturally still differs from the same-level curve above (level 80).
function C_PaperDollInfo.GetArmorEffectivenessAgainstTarget(armor)
    return ArmorRatio(armor, 1)
end

mock.target = { exists = false, hostile = false }
function UnitExists(unit) return unit == "target" and mock.target.exists or false end
function UnitCanAttack(_, unit) return unit == "target" and mock.target.hostile or false end

mock.stagger = { percent = 0, againstTarget = nil }
function C_PaperDollInfo.GetStaggerPercentage(unit)
    if unit ~= "player" then return 0 end
    return mock.stagger.percent, mock.stagger.againstTarget
end
function GetAverageItemLevel() return 639.5, 636.2, 0 end

--------------------------------------------------------------------------------
-- Inventory slots (character panel)
--------------------------------------------------------------------------------

INVSLOT_HEAD, INVSLOT_NECK, INVSLOT_SHOULDER, INVSLOT_CHEST, INVSLOT_WAIST = 1, 2, 3, 5, 6
INVSLOT_LEGS, INVSLOT_FEET, INVSLOT_WRIST, INVSLOT_HAND = 7, 8, 9, 10
INVSLOT_FINGER1, INVSLOT_FINGER2, INVSLOT_TRINKET1, INVSLOT_TRINKET2 = 11, 12, 13, 14
INVSLOT_BACK, INVSLOT_MAINHAND, INVSLOT_OFFHAND = 15, 16, 17

mock.equipment = {}     -- slot -> item link (nil = empty)
mock.itemLevels = {}    -- item link -> item level
mock.enchantTexts = {}  -- item link -> the enchant's descriptive tooltip text
mock.sockets = {}       -- item link -> { gemName-or-false, ... }, one per socket

-- Builds a fake item link with a real enchant-ID field, so the addon's own
-- link:match("item:%d+:(%d+)") parsing exercises the real code path rather
-- than a shortcut. enchantText and sockets are optional and back the
-- tooltip- and gem-lookup mocks below.
function mock.Equip(slot, itemID, enchantID, itemLevel, enchantText, sockets)
    local link = format("item:%d:%d:0:0:0:0:0:0:0:0:0:0:0:0", itemID, enchantID or 0)
    mock.equipment[slot] = link
    mock.itemLevels[link] = itemLevel or 300
    mock.enchantTexts[link] = enchantText
    mock.sockets[link] = sockets
    return link
end

function mock.Unequip(slot)
    mock.equipment[slot] = nil
end

function GetInventoryItemLink(unit, slot)
    if unit ~= "player" then return nil end
    return mock.equipment[slot]
end

C_Item = C_Item or {}
function C_Item.GetDetailedItemLevelInfo(link)
    local level = mock.itemLevels[link]
    if not level then return nil end
    return level, false, level
end

-- mock.sockets[link] is an array, one entry per socket on the item: a
-- string names a filled gem, `false` is an empty socket of that name/type.
-- Using false (never nil) keeps the array hole-free so ipairs sees every
-- socket, filled or not.
function C_Item.GetItemGem(link, index)
    local sockets = mock.sockets[link]
    local entry = sockets and sockets[index]
    if type(entry) == "string" then return entry end
    return nil
end

-- Real client convention this addon relies on: the enchant line is built
-- from this format string, so the mock renders it the same way rather than
-- hardcoding "Enchanted: " directly.
ENCHANTED_TOOLTIP_LINE = "Enchanted: %s"

-- Gem socket tooltip lines carry this structured line type in the real
-- client (filled or empty) rather than being distinguishable only by
-- rendered icon texture - the mock exposes the same marker so the addon's
-- real detection logic runs, not a shortcut around it.
Enum = Enum or {}
Enum.TooltipDataLineType = Enum.TooltipDataLineType or {}
Enum.TooltipDataLineType.GemSocket = 3

C_TooltipInfo = C_TooltipInfo or {}
function C_TooltipInfo.GetInventoryItem(unit, slot)
    if unit ~= "player" then return nil end
    local link = mock.equipment[slot]
    if not link then return nil end

    local lines = {}
    local text = mock.enchantTexts[link]
    if text then
        lines[#lines + 1] = { leftText = format(ENCHANTED_TOOLTIP_LINE, text) }
    end

    local sockets = mock.sockets[link]
    if sockets then
        for _, entry in ipairs(sockets) do
            if type(entry) == "string" then
                lines[#lines + 1] = { type = Enum.TooltipDataLineType.GemSocket, leftText = entry }
            else
                lines[#lines + 1] = { type = Enum.TooltipDataLineType.GemSocket, leftText = "Prismatic Socket" }
            end
        end
    end

    return { lines = lines }
end

-- Unlike a plain CreateFrame call, these start hidden in the real client
-- (the character panel is closed until the player presses C) - the mock's
-- shown-by-default new-frame behavior would otherwise misrepresent that.
CharacterFrame = CreateFrame("Frame", "CharacterFrame", UIParent)
CharacterFrame:Hide()
PaperDollFrame = CreateFrame("Frame", "PaperDollFrame", CharacterFrame)
PaperDollFrame:Hide()
function GetCritChance() return 21.34 end
function GetSpellCritChance(school) return 18 + school end
function GetRangedCritChance() return 21.34 end
function GetHaste() return 14.77 end
function GetMasteryEffect() return 31.02 end
function GetCombatRatingBonus() return 4.5 end
function GetCombatRating(index) return 1000 + index end
function GetVersatilityBonus() return 3.1 end
function GetMastery() return 24.5 end
function GetLifesteal() return 2.4 end
function GetAvoidance() return 1.8 end
function GetSpeed() return 0.9 end
function GetSpecialization() return 2 end
function GetSpecializationInfo() return 252, "Frost", "desc", 135773, "DAMAGER", 2 end

mock.masterySpells = { 999888 }
function GetSpecializationMasterySpells() return mock.masterySpells[1], mock.masterySpells[2] end

mock.inGroup = false
function IsInGroup() return mock.inGroup end

mock.class = "MAGE"
local CLASS_LOCALIZED_NAMES = { MAGE = "Mage", WARRIOR = "Warrior" }
function UnitClass(unit)
    if unit ~= "player" then return "Creature", nil end
    return CLASS_LOCALIZED_NAMES[mock.class] or mock.class, mock.class
end

C_ClassColor = {
    GetClassColor = function(classFilename)
        local colors = {
            MAGE = { r = 0.41, g = 0.80, b = 0.94 },
            WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
        }
        return colors[classFilename]
    end,
}

--------------------------------------------------------------------------------
-- Spells and auras
--------------------------------------------------------------------------------

mock.spells = {
    [190319] = { name = "Combustion", icon = 135824 },
    [12472]  = { name = "Icy Veins", icon = 135838 },
    [377097] = { name = "Trinket Proc", icon = 136116 },
}

mock.cooldowns = {}

C_Spell = {
    GetSpellInfo = function(spellID)
        local spell = mock.spells[spellID]
        if not spell then return nil end
        return { name = spell.name, iconID = spell.icon, spellID = spellID }
    end,
    GetSpellTexture = function(spellID)
        local spell = mock.spells[spellID]
        return spell and spell.icon
    end,
    GetSpellCooldown = function(spellID)
        local cooldown = mock.cooldowns[spellID]
        if not cooldown then
            return { startTime = 0, duration = 0, isEnabled = true, modRate = 1 }
        end
        return { startTime = cooldown.start, duration = cooldown.duration, isEnabled = true, modRate = 1 }
    end,
    GetSpellDescription = function(spellID)
        return mock.spellDescriptions[spellID]
    end,
    RequestLoadSpellData = function(spellID)
        mock.spellDataRequested[spellID] = true
    end,
}

mock.spellDataRequested = {}

mock.spellDescriptions = {
    [999888] = "Increases the damage of your Frostbolt and Frozen Orb.",
}

-- Some content refuses aura access outright rather than merely hiding
-- values; toggle this to simulate that refusal in a test.
mock.aurasBlocked = false

C_UnitAuras = {
    GetPlayerAuraBySpellID = function(spellID)
        if mock.aurasBlocked then error("Auras cannot be accessed when secret") end
        for _, aura in ipairs(mock.auras) do
            if aura.spellId == spellID then return aura end
        end
        return nil
    end,
}

AuraUtil = {
    ForEachAura = function(_, _, _, callback)
        if mock.aurasBlocked then error("Auras cannot be accessed when secret") end
        for _, aura in ipairs(mock.auras) do
            if callback(aura) then return end
        end
    end,
}

-- Adds a buff to the player for the duration of the test.
function mock.AddAura(spellID, duration, applications)
    local spell = mock.spells[spellID] or { name = "Spell " .. spellID, icon = 0 }
    table.insert(mock.auras, {
        spellId = spellID,
        name = spell.name,
        icon = spell.icon,
        duration = duration,
        expirationTime = mock.now + duration,
        applications = applications or 1,
        sourceUnit = "player",
    })
end

function mock.ClearAuras()
    mock.auras = {}
end

--------------------------------------------------------------------------------
-- Tooltip
--
-- Records what was rendered so tests can assert on tooltip content.
--------------------------------------------------------------------------------

GameTooltip = {
    lines = {},
    shown = false,
}

function GameTooltip:SetOwner(owner, anchor)
    self.owner, self.anchor = owner, anchor
    self.lines = {}
    self.spellID = nil
end

function GameTooltip:ClearLines() self.lines = {} end

function GameTooltip:AddLine(text)
    table.insert(self.lines, { left = text })
end

function GameTooltip:AddDoubleLine(left, right)
    table.insert(self.lines, { left = left, right = right })
end

function GameTooltip:SetSpellByID(spellID)
    self.spellID = spellID
    local spell = mock.spells[spellID]
    table.insert(self.lines, { left = spell and spell.name or ("Spell " .. spellID) })
end

function GameTooltip:Show() self.shown = true end
function GameTooltip:Hide() self.shown = false end

-- Returns the rendered tooltip as a flat list of "left=right" strings.
function GameTooltip:Dump()
    local out = {}
    for _, line in ipairs(self.lines) do
        out[#out + 1] = tostring(line.left) .. (line.right and ("=" .. tostring(line.right)) or "")
    end
    return out
end

--------------------------------------------------------------------------------
-- Addon metadata, settings, slash commands
--------------------------------------------------------------------------------

C_AddOns = {
    GetAddOnMetadata = function(_, field)
        if field == "Version" then return "1.0.0" end
        return nil
    end,
}

SlashCmdList = {}

MinimalSliderWithSteppersMixin = { Label = { Right = 1 } }

local function NewSettingsCategory(name)
    local category = { name = name, id = name, settingsByVariable = {} }
    function category:GetID() return self.id end
    return category
end

Settings = {
    VarType = { Boolean = "boolean", Number = "number", String = "string" },

    RegisterVerticalLayoutCategory = function(name)
        local layout = { initializers = {} }
        function layout:AddInitializer(initializer)
            table.insert(self.initializers, initializer)
        end
        return NewSettingsCategory(name), layout
    end,

    -- Current signature: (category, variable, variableType, name, default, get, set)
    RegisterProxySetting = function(category, variable, variableType, name, _, get, set)
        assert(type(variableType) == "string",
            "RegisterProxySetting called with the legacy signature for " .. tostring(variable))
        assert(type(get) == "function", "missing getter for " .. tostring(variable))
        assert(type(set) == "function", "missing setter for " .. tostring(variable))
        local setting = { variable = variable, name = name, varType = variableType, get = get, set = set }
        if category and category.settingsByVariable then
            category.settingsByVariable[variable] = setting
        end
        return setting
    end,

    CreateCheckbox = function(_, setting) return setting end,
    CreateSlider = function(_, setting) return setting end,
    CreateSliderOptions = function(minValue, maxValue, step)
        local options = { min = minValue, max = maxValue, step = step }
        function options:SetLabelFormatter(_, formatter) self.formatter = formatter end
        return options
    end,
    CreateControlTextContainer = function()
        local container = { data = {} }
        function container:Add(value, label, tooltip)
            table.insert(self.data, { value = value, label = label, tooltip = tooltip })
        end
        function container:GetData() return self.data end
        return container
    end,
    -- Records what the generator produced, rather than resolving it lazily
    -- the way the client would, so a test can inspect setting.options
    -- straight after the panel is built.
    CreateDropdown = function(_, setting, getOptions, tooltip)
        setting.options = getOptions and getOptions()
        setting.tooltip = tooltip
        return setting
    end,
    RegisterAddOnCategory = function() end,
    OpenToCategory = function() end,
}

function CreateSettingsListSectionHeaderInitializer(text)
    return { kind = "header", text = text }
end

-- addSearchTags mirrors the real Blizzard_SettingControls.lua, which asserts
-- this is not nil - omitting it is a real bug that once took down the whole
-- options panel (a throw evaluated outside any pcall), so the mock enforces
-- the same contract rather than silently accepting a missing argument.
function CreateSettingsButtonInitializer(name, buttonText, onClick, tooltip, addSearchTags)
    assert(addSearchTags ~= nil, "CreateSettingsButtonInitializer requires addSearchTags")
    return { kind = "button", name = name, text = buttonText, onClick = onClick, tooltip = tooltip }
end

--------------------------------------------------------------------------------
-- Loader
--------------------------------------------------------------------------------

-- Loads addon files in TOC order, sharing one namespace table the way the
-- client does, and hands the namespace back for inspection.
function mock.LoadAddon(basePath, files, addonName)
    local ns = {}
    for _, file in ipairs(files) do
        local path = basePath .. "/" .. file:gsub("\\", "/")
        local chunk, err = loadfile(path)
        assert(chunk, "failed to load " .. path .. ": " .. tostring(err))
        chunk(addonName, ns)
    end
    return ns
end

return mock
