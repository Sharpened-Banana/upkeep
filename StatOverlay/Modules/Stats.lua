-- Modules/Stats.lua
-- Character stat readout: item level, primary stat, and secondary ratings.

local ADDON, ns = ...

local Stats = ns:NewModule("Stats")

-- These moved into C_SpecializationInfo in modern retail but the globals are
-- still around; prefer the namespaced versions when present.
local GetSpecialization = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
local GetSpecializationInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo

local STAT_STRENGTH, STAT_AGILITY, STAT_STAMINA, STAT_INTELLECT = 1, 2, 3, 4

local STAT_NAMES = {
    [STAT_STRENGTH] = "Strength",
    [STAT_AGILITY] = "Agility",
    [STAT_STAMINA] = "Stamina",
    [STAT_INTELLECT] = "Intellect",
}

local UPDATE_EVENTS = {
    "UNIT_STATS",
    "UNIT_AURA",
    "UNIT_MAXHEALTH",
    "UNIT_ATTACK_POWER",
    "COMBAT_RATING_UPDATE",
    "MASTERY_UPDATE",
    "SPEED_UPDATE",
    "LIFESTEAL_UPDATE",
    "AVOIDANCE_UPDATE",
    "PLAYER_EQUIPMENT_CHANGED",
    "PLAYER_AVG_ITEM_LEVEL_UPDATE",
    "PLAYER_SPECIALIZATION_CHANGED",
    "PLAYER_TALENT_UPDATE",
}

--------------------------------------------------------------------------------
-- Stat readers
--------------------------------------------------------------------------------

-- Which primary stat this spec actually scales with.
local function GetPrimaryStatIndex()
    local spec = GetSpecialization and GetSpecialization()
    if spec then
        local _, _, _, _, _, primaryStat = GetSpecializationInfo(spec)
        if primaryStat then return primaryStat end
    end

    -- No spec yet (low level characters): fall back to the largest of the three.
    local best, bestValue = STAT_STRENGTH, -1
    for _, index in ipairs({ STAT_STRENGTH, STAT_AGILITY, STAT_INTELLECT }) do
        local _, value = UnitStat("player", index)
        if value > bestValue then
            best, bestValue = index, value
        end
    end
    return best
end

-- Casters care about spell crit, everyone else about melee crit. Spell crit is
-- per-school, so take the best school the way the paper doll does.
local function GetBestSpellCrit()
    local best = 0
    for school = 2, 7 do
        local crit = GetSpellCritChance(school) or 0
        if crit > best then best = crit end
    end
    return best
end

local function GetCrit(primaryStat)
    if primaryStat == STAT_INTELLECT then
        return GetBestSpellCrit()
    end
    return GetCritChance() or 0
end

local function GetVersatility()
    local rating = CR_VERSATILITY_DAMAGE_DONE or 29
    return (GetCombatRatingBonus(rating) or 0) + (GetVersatilityBonus(rating) or 0)
end

local readers = {}

readers.ilvl = function()
    local _, equipped = GetAverageItemLevel()
    return "Item Level", format("%.1f", equipped or 0)
end

readers.primary = function(primaryStat)
    local _, value = UnitStat("player", primaryStat)
    return STAT_NAMES[primaryStat] or "Primary", ns.FormatNumber(value)
end

readers.stamina = function()
    local _, value = UnitStat("player", STAT_STAMINA)
    return "Stamina", ns.FormatNumber(value)
end

readers.health = function()
    return "Health", ns.FormatNumber(UnitHealthMax("player"))
end

readers.crit = function(primaryStat)
    return "Crit", ns.FormatPercent(GetCrit(primaryStat))
end

readers.haste = function()
    return "Haste", ns.FormatPercent(GetHaste() or 0)
end

readers.mastery = function()
    return "Mastery", ns.FormatPercent(GetMasteryEffect() or 0)
end

readers.vers = function()
    return "Versatility", ns.FormatPercent(GetVersatility())
end

readers.leech = function()
    local value = GetLifesteal and GetLifesteal() or GetCombatRatingBonus(CR_LIFESTEAL or 17) or 0
    return "Leech", ns.FormatPercent(value)
end

readers.avoid = function()
    local value = GetAvoidance and GetAvoidance() or GetCombatRatingBonus(CR_AVOIDANCE or 21) or 0
    return "Avoidance", ns.FormatPercent(value)
end

readers.speed = function()
    local value = GetSpeed and GetSpeed() or GetCombatRatingBonus(CR_SPEED or 14) or 0
    return "Speed", ns.FormatPercent(value)
end

readers.armor = function()
    local _, effectiveArmor = UnitArmor("player")
    return "Armor", ns.FormatNumber(effectiveArmor)
end

--------------------------------------------------------------------------------
-- Module
--------------------------------------------------------------------------------

function Stats:Update()
    local db = ns.db
    if not db.stats.enabled then
        ns.UI:SetSection("stats", nil)
        return
    end

    local primaryStat = GetPrimaryStatIndex()
    local rows = {}

    for _, entry in ipairs(ns.STAT_LIST) do
        if db.stats.show[entry.key] then
            local reader = readers[entry.key]
            if reader then
                local ok, label, value = pcall(reader, primaryStat)
                if ok then
                    rows[#rows + 1] = { label = label, value = value }
                end
            end
        end
    end

    ns.UI:SetSection("stats", rows)
end

function Stats:OnEnable()
    local function OnStatEvent(event, unit)
        -- Unit-scoped events fire for every unit in range; only ours matters.
        if unit and unit ~= "player" then return end
        self:Update()
    end

    for _, event in ipairs(UPDATE_EVENTS) do
        ns:RegisterEvent(event, OnStatEvent)
    end

    self:Update()
end

function Stats:OnConfigChanged()
    self:Update()
end
