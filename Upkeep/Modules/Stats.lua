-- Modules/Stats.lua
-- Character stat readout: item level, primary stat, and secondary ratings.

local ADDON, ns = ...

local Stats = ns:NewModule("Stats")

-- These moved into C_SpecializationInfo in modern retail but the globals are
-- still around; prefer the namespaced versions when present.
local GetSpecialization = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
local GetSpecializationInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo

-- Shared guard for expressions that may touch secret values (Core/Init.lua).
local SafeCall = ns.SafeCall

local STAT_STRENGTH, STAT_AGILITY, STAT_STAMINA, STAT_INTELLECT = 1, 2, 3, 4

-- Combat rating indices, with numeric fallbacks in case a global is missing.
local RATING = {
    critMelee = CR_CRIT_MELEE or 9,
    critSpell = CR_CRIT_SPELL or 11,
    hasteMelee = CR_HASTE_MELEE or 18,
    hasteSpell = CR_HASTE_SPELL or 20,
    mastery = CR_MASTERY or 26,
    versDone = CR_VERSATILITY_DAMAGE_DONE or 29,
    versTaken = CR_VERSATILITY_DAMAGE_TAKEN or 31,
    lifesteal = CR_LIFESTEAL or 17,
    avoidance = CR_AVOIDANCE or 21,
    speed = CR_SPEED or 14,
    dodge = CR_DODGE or 12,
    parry = CR_PARRY or 13,
    block = CR_BLOCK or 15,
}

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

-- Effective attack power (base plus buffs/debuffs); mirrors StatBreakdown's
-- own summation of UnitAttackPower's three return values.
local function GetAttackPower()
    local base, posBuff, negBuff = UnitAttackPower("player")
    return (base or 0) + (posBuff or 0) + (negBuff or 0), base, posBuff, negBuff
end

-- Casters care about spell power, everyone else about attack power. Best
-- school follows the same pattern as GetBestSpellCrit above.
local function GetBestSpellPower()
    local best = 0
    for school = 2, 7 do
        local power = GetSpellBonusDamage(school) or 0
        if power > best then best = power end
    end
    return best
end

readers.power = function(primaryStat)
    if primaryStat == STAT_INTELLECT then
        return "Spell Power", ns.FormatNumber(GetBestSpellPower())
    end
    return "Attack Power", ns.FormatNumber(GetAttackPower())
end

-- format() on a secret value propagates the secret into a displayable
-- string, but a bad value would otherwise error; same contract as
-- ns.FormatNumber's fallback.
local function SafeFormat(pattern, value)
    local ok, result = pcall(format, pattern, value or 0)
    if ok then return result end
    return "-"
end

-- Main-hand and off-hand swing times, as the character sheet's Attack Speed.
local function GetAttackSpeeds()
    if not UnitAttackSpeed then return nil, nil end
    local main, off = UnitAttackSpeed("player")
    return main, off
end

readers.attackspeed = function()
    local main = GetAttackSpeeds()
    return "Attack Speed", SafeFormat("%.2f", main)
end

readers.dodge = function()
    return "Dodge", ns.FormatPercent(GetDodgeChance() or 0)
end

readers.parry = function()
    return "Parry", ns.FormatPercent(GetParryChance() or 0)
end

-- Only meaningful with a shield equipped, but shown unconditionally like
-- every other stat: 0% for a caster is as informative as the row being
-- absent, and the player controls visibility via the Stats options anyway.
readers.block = function()
    return "Block", ns.FormatPercent(GetBlockChance() or 0)
end

--------------------------------------------------------------------------------
-- Shared computation
--
-- Both the overlay row builder and the public GetStatValue accessor read a
-- stat through this one function, so there is exactly one place that turns a
-- reader key into a label/value pair.
--------------------------------------------------------------------------------

local function ReadStat(key, primaryStat)
    local reader = readers[key]
    if not reader then return nil end

    local ok, label, value = pcall(reader, primaryStat)
    if not ok then return nil end
    return label, value
end

--------------------------------------------------------------------------------
-- Tooltips
--
-- Built on hover rather than on every stat update, which fires often in combat.
--------------------------------------------------------------------------------

local function Rating(index)
    return GetCombatRating and GetCombatRating(index) or 0
end

-- What the armor actually does, the way Blizzard's own character sheet puts
-- it ("Physical damage reduction: 56.62%"), rather than only the rating.
--
-- The number comes from C_PaperDollInfo.GetArmorEffectiveness against an
-- attacker of the player's own level - "an evenly matched enemy" in
-- Blizzard's wording. There is deliberately no formula fallback: the old
-- armor/((85*level)+400) curve is obsolete (it reports ~48% where the live
-- client shows 56.62% for the same armor), so a client without the API omits
-- the line rather than printing a confidently wrong one.
-- Whether GetArmorEffectiveness reports a 0-1 ratio or an already-scaled
-- percentage, worked out ONCE from a probe made with our own literal numbers
-- and then cached as a multiplier.
--
-- The probe exists because of how secret values behave. Armor is secret in
-- restricted content, a secret argument yields a secret result, and the
-- three rules that follow from Midnight's design are:
--
--   arithmetic on a secret  -> allowed, produces another secret
--   formatting a secret     -> allowed, produces a secret string to display
--   COMPARING a secret      -> errors
--
-- (Displaying is permitted; branching on the value is what Blizzard blocks.)
-- Deciding ratio-vs-percentage per call meant comparing the live value, so
-- the moment a buff made armor secret the comparison threw, the guard
-- returned nil, and the reduction line silently vanished from the tooltip.
-- Probing with constants keeps every comparison on values that can never be
-- secret, leaving the live path to do arithmetic and formatting only.
local armorEffectivenessScale

local function GetArmorEffectivenessScale()
    if armorEffectivenessScale then return armorEffectivenessScale end
    if not (C_PaperDollInfo and C_PaperDollInfo.GetArmorEffectiveness) then return nil end

    -- Literal armor and level: never secret, so this comparison is safe.
    local ok, probe = pcall(C_PaperDollInfo.GetArmorEffectiveness, 1000, 80)
    if not ok or type(probe) ~= "number" then return nil end

    armorEffectivenessScale = (probe <= 1) and 100 or 1
    return armorEffectivenessScale
end

-- What the armor actually does, the way Blizzard's own character sheet puts
-- it ("Physical damage reduction: 56.62%"), rather than only the rating.
--
-- The number comes from C_PaperDollInfo.GetArmorEffectiveness against an
-- attacker of the player's own level - "an evenly matched enemy" in
-- Blizzard's wording. There is deliberately no formula fallback: the old
-- armor/((85*level)+400) curve is obsolete (it reports ~48% where the live
-- client shows 56.62% for the same armor), so a client without the API omits
-- the line rather than printing a confidently wrong one.
--
-- The result may itself be a secret; ns.FormatPercent renders one fine. No
-- clamping is applied, deliberately - clamping means comparing, and the API
-- does not return out-of-range effectiveness anyway.
local function GetArmorReductionPercent(effectiveArmor)
    local scale = GetArmorEffectivenessScale()
    if not scale then return nil end

    -- Re-checked rather than relying on the probe having found it: the scale
    -- is cached for the session, so a client that loses the API afterwards
    -- would otherwise reach the pcall below - where the function is looked up
    -- while building the argument list, i.e. OUTSIDE the pcall, and indexing
    -- a nil C_PaperDollInfo would throw past the guard and cost the whole
    -- tooltip its lines.
    local getEffectiveness = C_PaperDollInfo and C_PaperDollInfo.GetArmorEffectiveness
    if not getEffectiveness then return nil end

    local level
    if UnitEffectiveLevel then
        level = SafeCall(function() return UnitEffectiveLevel("player") end)
    end
    if not level and UnitLevel then
        level = SafeCall(function() return UnitLevel("player") end)
    end
    if not level then return nil end

    local ok, effectiveness = pcall(getEffectiveness, effectiveArmor, level)
    if not ok then return nil end

    -- Arithmetic only: a secret in yields a secret out, which still displays.
    return SafeCall(function() return effectiveness * scale end)
end

local function RatingLines(index, ratingLabel)
    return {
        { left = ratingLabel or "Rating", right = ns.FormatNumber(Rating(index)) },
        { left = "From rating", right = ns.FormatPercent(GetCombatRatingBonus(index) or 0) },
    }
end

local DESCRIPTIONS = {
    ilvl = "The average item level of the gear you are wearing. Overall also counts items in your bags.",
    primary = "Your specialisation's main stat. It increases the damage or healing of most of your abilities.",
    stamina = "Each point of Stamina increases your maximum health.",
    health = "The most damage you can take before dying.",
    crit = "Chance for your attacks and spells to critically strike for extra damage or healing.",
    haste = "Increases attack and casting speed, and the rate of many periodic effects and resource generation.",
    mastery = "Improves a bonus specific to your specialisation.",
    vers = "Increases damage and healing done, and reduces damage taken.",
    leech = "Heals you for a portion of the damage and healing you deal.",
    avoid = "Reduces damage taken from area-of-effect attacks.",
    speed = "Increases your movement speed.",
    armor = "Reduces the physical damage you take.",
    power = "Increases the damage of your attacks or spells, depending on which one your specialisation scales with.",
    attackspeed = "How long each of your weapon swings takes. Haste lowers it.",
    dodge = "Chance to completely avoid a melee or ranged attack.",
    parry = "Chance to deflect a melee attack and reduce the attacker's next swing timer. Requires a melee weapon.",
    block = "Chance for your shield to block part of an incoming melee hit. Requires a shield.",
}

local tooltipBuilders = {}

tooltipBuilders.ilvl = function()
    local overall, equipped = GetAverageItemLevel()
    return {
        lines = {
            { left = "Equipped", right = format("%.1f", equipped or 0) },
            { left = "Overall", right = format("%.1f", overall or 0) },
        },
    }
end

-- True only when `value` is known to be past `threshold`. A secret value
-- cannot be compared at all, so it reports false: the optional line is
-- skipped rather than the comparison erroring and costing the caller every
-- line it had already built (each tooltipBuilder runs inside a single pcall
-- in TooltipProvider, so one bad comparison loses the whole tooltip body).
local function KnownPast(value, threshold, wantGreater)
    return SafeCall(function()
        local number = value or 0
        if wantGreater then return number > threshold end
        return number < threshold
    end) == true
end

local function StatBreakdown(index)
    local base, total, posBuff, negBuff = UnitStat("player", index)
    local lines = {
        { left = "Base", right = ns.FormatNumber(base) },
    }
    if KnownPast(posBuff, 0, true) then
        lines[#lines + 1] = { left = "From gear and buffs", right = "+" .. ns.FormatNumber(posBuff) }
    end
    if KnownPast(negBuff, 0, false) then
        lines[#lines + 1] = { left = "Reduced by", right = ns.FormatNumber(negBuff) }
    end
    return lines, total
end

tooltipBuilders.primary = function(primaryStat)
    local lines = StatBreakdown(primaryStat)
    return { lines = lines }
end

tooltipBuilders.stamina = function()
    local lines = StatBreakdown(STAT_STAMINA)
    lines[#lines + 1] = { left = "Maximum health", right = ns.FormatNumber(UnitHealthMax("player")) }
    return { lines = lines }
end

tooltipBuilders.health = function()
    return {
        lines = {
            { left = "Current", right = ns.FormatNumber(UnitHealth("player")) },
            { left = "Maximum", right = ns.FormatNumber(UnitHealthMax("player")) },
        },
    }
end

tooltipBuilders.crit = function(primaryStat)
    local index = (primaryStat == STAT_INTELLECT) and RATING.critSpell or RATING.critMelee
    return { lines = RatingLines(index) }
end

tooltipBuilders.haste = function(primaryStat)
    local index = (primaryStat == STAT_INTELLECT) and RATING.hasteSpell or RATING.hasteMelee
    return { lines = RatingLines(index) }
end

tooltipBuilders.mastery = function()
    local lines = RatingLines(RATING.mastery)
    if GetMastery then
        lines[#lines + 1] = { left = "Mastery points", right = format("%.2f", GetMastery() or 0) }
    end
    return { lines = lines }
end

tooltipBuilders.vers = function()
    return {
        lines = {
            { left = "Rating", right = ns.FormatNumber(Rating(RATING.versDone)) },
            { left = "Damage and healing done", right = ns.FormatPercent(GetVersatility()) },
            { left = "Damage taken reduced by", right = ns.FormatPercent(
                (GetCombatRatingBonus(RATING.versTaken) or 0) + (GetVersatilityBonus(RATING.versTaken) or 0)) },
        },
    }
end

tooltipBuilders.leech = function() return { lines = RatingLines(RATING.lifesteal) } end
tooltipBuilders.avoid = function() return { lines = RatingLines(RATING.avoidance) } end
tooltipBuilders.speed = function() return { lines = RatingLines(RATING.speed) } end

tooltipBuilders.armor = function()
    local base, effective, _, posBuff = UnitArmor("player")
    local lines = {
        { left = "Base", right = ns.FormatNumber(base) },
        { left = "Effective", right = ns.FormatNumber(effective) },
    }
    if KnownPast(posBuff, 0, true) then
        lines[#lines + 1] = { left = "From buffs", right = "+" .. ns.FormatNumber(posBuff) }
    end

    -- What the armor is actually worth, the way the character sheet shows it.
    local reduction = GetArmorReductionPercent(effective)
    if reduction then
        lines[#lines + 1] = { left = "Physical damage reduction", right = ns.FormatPercent(reduction) }
        lines[#lines + 1] = { left = "|cff808080Against an evenly matched enemy|r", right = "" }
    end

    return { lines = lines }
end

tooltipBuilders.attackspeed = function()
    local main, off = GetAttackSpeeds()
    local lines = {
        { left = "Main hand", right = SafeFormat("%.2f sec", main) },
    }
    if off and KnownPast(off, 0, true) then
        lines[#lines + 1] = { left = "Off hand", right = SafeFormat("%.2f sec", off) }
    end

    -- Haste is what moves this number, so name the connection rather than
    -- leaving the player to infer it.
    lines[#lines + 1] = { left = "Haste", right = ns.FormatPercent(GetHaste() or 0) }
    return { lines = lines }
end

tooltipBuilders.power = function(primaryStat)
    if primaryStat == STAT_INTELLECT then
        return { lines = { { left = "Spell power", right = ns.FormatNumber(GetBestSpellPower()) } } }
    end

    local _, base, posBuff, negBuff = GetAttackPower()
    local lines = {
        { left = "Base", right = ns.FormatNumber(base) },
    }
    if KnownPast(posBuff, 0, true) then
        lines[#lines + 1] = { left = "From gear and buffs", right = "+" .. ns.FormatNumber(posBuff) }
    end
    if KnownPast(negBuff, 0, false) then
        lines[#lines + 1] = { left = "Reduced by", right = ns.FormatNumber(negBuff) }
    end
    return { lines = lines }
end

tooltipBuilders.dodge = function() return { lines = RatingLines(RATING.dodge) } end
tooltipBuilders.parry = function() return { lines = RatingLines(RATING.parry) } end
tooltipBuilders.block = function() return { lines = RatingLines(RATING.block) } end

-- Called by the UI when the mouse enters a stat row.
local function TooltipProvider(key)
    local entry
    for _, candidate in ipairs(ns.STAT_LIST) do
        if candidate.key == key then
            entry = candidate
            break
        end
    end
    if not entry then return nil end

    local primaryStat = GetPrimaryStatIndex()
    local label, value = ReadStat(key, primaryStat)

    local data = { title = label or entry.label, value = value, description = DESCRIPTIONS[key] }

    local builder = tooltipBuilders[key]
    if builder then
        local ok, built = pcall(builder, primaryStat)
        if ok and built then
            data.lines = built.lines
        end
    end

    return data
end

--------------------------------------------------------------------------------
-- Module
--------------------------------------------------------------------------------

function Stats:Update()
    if not ns.db.stats.enabled then
        ns.UI:SetSection("stats", nil)
        return
    end

    local shown = ns.StatsShown()
    local primaryStat = GetPrimaryStatIndex()
    local rows = {}

    for _, entry in ipairs(ns.STAT_LIST) do
        if shown[entry.key] then
            local label, value = ReadStat(entry.key, primaryStat)
            if value then
                rows[#rows + 1] = { label = label, value = value, tooltipKey = entry.key }
            end
        end
    end

    ns.UI:SetSection("stats", rows, TooltipProvider)
end

-- Public accessor for other code that wants just the formatted display value
-- for a stat, without caring whether the overlay is showing that row right
-- now. Returns nil for a key that does not resolve to a reader, rather than
-- erroring.
function Stats:GetStatValue(statKey)
    if type(statKey) ~= "string" then return nil end

    local _, value = ReadStat(statKey, GetPrimaryStatIndex())
    return value
end

function Stats:OnEnable()
    local function OnStatEvent(event, unit)
        -- Unit-scoped events fire for every unit in range; only ours matters.
        -- UNIT_AURA's payload is fully secret while auras are secret, and
        -- comparing a secret value errors, so an unreadable unit falls
        -- through to updating rather than taking the handler down.
        local ok, other = pcall(function() return unit and unit ~= "player" end)
        if ok and other then return end
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
