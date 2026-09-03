-- Modules/Stats.lua
-- Character stat readout: item level, primary stat, and secondary ratings.

local ADDON, ns = ...

local Stats = ns:NewModule("Stats")

-- These moved into C_SpecializationInfo in modern retail but the globals are
-- still around; prefer the namespaced versions when present.
local GetSpecialization = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
local GetSpecializationInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo
local GetSpecializationMasterySpells = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationMasterySpells)
    or GetSpecializationMasterySpells
local GetSpellDescription = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
local RequestLoadSpellData = C_Spell and C_Spell.RequestLoadSpellData

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

-- Effective armor has been observed reading as an implausible 0 - below
-- base plus a buff independently known to be positive - for a single read,
-- then reading correctly again moments later; Blizzard's own character
-- panel reads this identical field the identical way, so it is not a
-- misread on our end, just a transient value neither of us protects
-- against. Rather than display or calculate from a number that contradicts
-- its own inputs, fall back to the one figure we can compute ourselves.
local function SaneEffectiveArmor(base, effective, posBuff)
    if not ns.KnownPast(posBuff, 0, true) then return effective end
    local floor = ns.SafeCall(function() return base + posBuff end)
    if not floor then return effective end
    if ns.KnownPast(effective, floor, false) then
        return floor
    end
    return effective
end

readers.armor = function()
    local base, effectiveArmor, _, posBuff = UnitArmor("player")
    return "Armor", ns.FormatNumber(SaneEffectiveArmor(base, effectiveArmor, posBuff))
end

-- Brewmaster-specific, but shown the same way every other stat is: opt-in via
-- statsShow, with no class gating - a Monk not specced Brewmaster just sees 0%.
readers.stagger = function()
    local getStagger = C_PaperDollInfo and C_PaperDollInfo.GetStaggerPercentage
    local stagger = 0
    if getStagger then
        local ok, value = pcall(getStagger, "player")
        if ok then stagger = value or 0 end
    end
    return "Stagger", ns.FormatPercent(stagger)
end

--------------------------------------------------------------------------------
-- Tooltips
--
-- Built on hover rather than on every stat update, which fires often in combat.
--------------------------------------------------------------------------------

local function Rating(index)
    return GetCombatRating and GetCombatRating(index) or 0
end

-- Some clients return GetArmorEffectiveness as a 0-1 ratio, others as an
-- already-scaled percentage. Worked out once from literal, unambiguous
-- constants and cached for the session rather than re-checked on every call.
local armorEffectivenessScale

local function GetArmorEffectivenessScale()
    if armorEffectivenessScale then return armorEffectivenessScale end
    if not (C_PaperDollInfo and C_PaperDollInfo.GetArmorEffectiveness) then return nil end

    local ok, probe = pcall(C_PaperDollInfo.GetArmorEffectiveness, 1000, 80)
    if not ok or type(probe) ~= "number" then return nil end

    armorEffectivenessScale = (probe <= 1) and 100 or 1
    return armorEffectivenessScale
end

-- What the armor actually does, the way the character sheet puts it
-- ("Physical damage reduction: 56.62%"), rather than only the raw value.
local function GetArmorReductionPercent(effectiveArmor)
    local scale = GetArmorEffectivenessScale()
    if not scale then return nil end

    local level = UnitLevel and UnitLevel("player")
    if not level or level <= 0 then return nil end

    local ok, effectiveness = pcall(C_PaperDollInfo.GetArmorEffectiveness, effectiveArmor, level)
    if not ok or type(effectiveness) ~= "number" then return nil end

    return effectiveness * scale
end

-- Same idea, but against the player's actual current target rather than an
-- assumed same-level enemy - what the character panel shows once you have
-- someone selected. Shares the same scale as GetArmorEffectiveness: they are
-- clearly the same family of API, just against a different attacker.
local function GetArmorReductionAgainstTarget(effectiveArmor)
    local scale = GetArmorEffectivenessScale()
    if not scale then return nil end
    if not (C_PaperDollInfo.GetArmorEffectivenessAgainstTarget and UnitExists and UnitCanAttack) then return nil end
    if not (UnitExists("target") and UnitCanAttack("player", "target")) then return nil end

    local ok, effectiveness = pcall(C_PaperDollInfo.GetArmorEffectivenessAgainstTarget, effectiveArmor)
    if not ok or type(effectiveness) ~= "number" then return nil end

    return effectiveness * scale
end

--------------------------------------------------------------------------------
-- Manual armor-reduction estimate
--
-- The two functions above go through Blizzard's own curve via
-- C_PaperDollInfo, which is why they are trustworthy - but that call can
-- fail even when the API exists at all: effective armor is a secret value
-- during some combat/content states (see Core/Init.lua), and Blizzard's own
-- internal comparisons against a secret throw, caught above only as "no
-- result." When that happens this manual formula, built from pure
-- arithmetic (division and addition only, never a comparison on the armor
-- value itself), still works on a secret the same way ns.FormatNumber does.
--
-- The formula is Blizzard's published post-squish curve, unchanged since
-- Legion aside from one new linear term added at each later level-cap
-- bump (60, 80, 85); it is used here ONLY as a last resort and is never
-- trusted blindly - see ValidateEstimate below.
--------------------------------------------------------------------------------

local function EstimateArmorConstant(level)
    local k = 400 + 85 * level
    if level > 59 then k = k + 4.5 * (level - 59) end
    if level > 80 then k = k + 20 * (level - 80) end
    if level > 85 then k = k + 22 * (level - 85) end
    return k
end

-- armor is never tested for truthiness here - it can be the same secret
-- value the live API just failed on, and a plain `if`/`not` on one throws
-- exactly like a comparison does. Only pure arithmetic touches it. The
-- result can end up secret too (division doesn't strip the tag), so success
-- is reported through pcall's own boolean - never by testing the number
-- itself - and callers must do the same rather than write `if estimate`.
local function EstimateArmorReductionPercent(armor, level)
    if not level or level <= 0 then return false, nil end
    local ok, pct = pcall(function()
        local raw = (armor / (armor + EstimateArmorConstant(level))) * 100
        if ns.KnownPast(raw, 75, true) then return 75 end
        return raw
    end)
    if not ok then return false, nil end
    return true, pct
end

-- A future level squish or curve rework would make the formula above wrong
-- without throwing - it would just quietly compute a different number. So
-- rather than trust it forever, check it against the real API every time
-- that succeeds, using the exact armor/level pair just proven live: one
-- comparison more than about a percentage point off is enough to stop
-- offering the estimate for the rest of the session.
local estimateTrusted = true

local function ValidateEstimate(armor, level, actualPercent)
    if not estimateTrusted then return end

    -- effective armor has been observed reading as an implausible 0 for a
    -- moment (see SaneEffectiveArmor below) - comparing an estimate against
    -- a live result computed from a momentarily-bad input would read as the
    -- FORMULA being wrong and disable it for the rest of the session over
    -- nothing. Only validate when armor is confirmed to be a real positive
    -- number.
    if not ns.KnownPast(armor, 0, true) then return end

    local haveEstimate, estimate = EstimateArmorReductionPercent(armor, level)
    if not haveEstimate then return end

    local withinTolerance = ns.SafeCall(function()
        return math.abs(estimate - actualPercent) < 1
    end)
    if withinTolerance ~= true then
        estimateTrusted = false
    end
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
    stagger = "Brewmaster: the portion of incoming damage held back to be taken over time instead of all at once.",
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

local function StatBreakdown(index)
    local base, total, posBuff, negBuff = UnitStat("player", index)
    local lines = {
        { left = "Base", right = ns.FormatNumber(base) },
    }
    if ns.KnownPast(posBuff, 0, true) then
        lines[#lines + 1] = { left = "From gear and buffs", right = "+" .. ns.FormatNumber(posBuff) }
    end
    if ns.KnownPast(negBuff, 0, false) then
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

-- Mastery is the one secondary stat whose effect is entirely spec-specific
-- ("Frostbolt and Frozen Orb deal more damage", "your shield absorbs more"),
-- so a single fixed description would either be too vague to mean anything
-- or wrong for most specs reading it. The spell description already comes
-- back fully computed with this character's current mastery plugged in, so
-- it doubles as an explanation and a live value.
local function GetMasterySpellDescription()
    if not (GetSpecializationMasterySpells and GetSpecialization and GetSpellDescription) then return nil end

    local spec = GetSpecialization()
    if not spec then return nil end

    local ok, spell1, spell2 = pcall(GetSpecializationMasterySpells, spec)
    if not ok then return nil end

    local lines = {}
    for _, spellID in ipairs({ spell1 or 0, spell2 or 0 }) do
        if spellID > 0 then
            local descOk, desc = pcall(GetSpellDescription, spellID)
            if descOk and desc and desc ~= "" then
                lines[#lines + 1] = desc
            elseif RequestLoadSpellData then
                -- Spell text loads asynchronously; an empty description just
                -- means it hasn't arrived yet (a documented C_Spell quirk,
                -- not a real absence). Kick off the load so a later hover -
                -- there is no event worth waiting on here - gets the real
                -- text instead of the generic fallback forever.
                pcall(RequestLoadSpellData, spellID)
            end
        end
    end

    if #lines == 0 then return nil end
    return table.concat(lines, "\n\n")
end

tooltipBuilders.mastery = function()
    local lines = RatingLines(RATING.mastery)
    if GetMastery then
        lines[#lines + 1] = { left = "Mastery points", right = format("%.2f", GetMastery() or 0) }
    end
    return { lines = lines, description = GetMasterySpellDescription() }
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
    effective = SaneEffectiveArmor(base, effective, posBuff)
    local lines = {
        { left = "Base", right = ns.FormatNumber(base) },
        { left = "Effective", right = ns.FormatNumber(effective) },
    }
    if ns.KnownPast(posBuff, 0, true) then
        lines[#lines + 1] = { left = "From buffs", right = "+" .. ns.FormatNumber(posBuff) }
    end

    -- Recomputed from the current effective armor every call, so a pinned
    -- tooltip's periodic refresh (and a fresh hover) picks up gear, buff,
    -- debuff, or target changes rather than showing a stale reduction.
    local targetLevel = UnitLevel and UnitLevel("target")
    local playerLevel = UnitLevel and UnitLevel("player")
    local targetReduction = GetArmorReductionAgainstTarget(effective)
    local reduction = not targetReduction and GetArmorReductionPercent(effective) or nil

    if targetReduction then
        ValidateEstimate(effective, targetLevel, targetReduction)
        lines[#lines + 1] = { left = "Physical damage reduction", right = ns.FormatPercent(targetReduction) }
        lines[#lines + 1] = { left = "|cff808080Against your current target|r", right = "" }
    elseif reduction then
        ValidateEstimate(effective, playerLevel, reduction)
        lines[#lines + 1] = { left = "Physical damage reduction", right = ns.FormatPercent(reduction) }
        lines[#lines + 1] = { left = "|cff808080Against an evenly matched enemy|r", right = "" }
    else
        -- The live call failed - almost always because effective armor is
        -- unreadable right now, either a Patch 12.0 secret value mid-combat
        -- or this instance restricting addon reads outright (the same
        -- reason Procs/Buffs may be reporting aura tracking as paused).
        -- Fall back to the manual estimate rather than a cached pre-fight
        -- figure, which would be actively misleading during the exact
        -- moment a big armor buff is up.
        --
        -- The fallback note below is shown unconditionally rather than
        -- gated on the API "existing" (formerly checked via the scale
        -- probe): that probe can fail for the exact same live-read reasons
        -- the two calls above just did, which would otherwise go silent
        -- here too rather than say anything at all.
        local haveEstimate, estimate = false, nil
        if estimateTrusted then
            haveEstimate, estimate = EstimateArmorReductionPercent(effective, playerLevel)
        end

        if haveEstimate then
            lines[#lines + 1] = { left = "Physical damage reduction (estimated)", right = ns.FormatPercent(estimate) }
            lines[#lines + 1] = { left = "|cff808080Live figure unavailable right now|r", right = "" }
        else
            lines[#lines + 1] = { left = "|cff808080Damage reduction unavailable right now|r", right = "" }
        end
    end

    return { lines = lines }
end

tooltipBuilders.stagger = function()
    local getStagger = C_PaperDollInfo and C_PaperDollInfo.GetStaggerPercentage
    local stagger, staggerAgainstTarget = 0, nil
    if getStagger then
        local ok, value, valueAgainstTarget = pcall(getStagger, "player")
        if ok then
            stagger, staggerAgainstTarget = value or 0, valueAgainstTarget
        end
    end

    local lines = {
        { left = "Of health staggered", right = ns.FormatPercent(stagger or 0) },
    }
    if staggerAgainstTarget then
        lines[#lines + 1] = { left = "From your current target", right = ns.FormatPercent(staggerAgainstTarget) }
    end

    return { lines = lines }
end

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
    local reader = readers[key]
    local label, value
    if reader then
        local ok, readLabel, readValue = pcall(reader, primaryStat)
        if ok then
            label, value = readLabel, readValue
        end
    end

    local data = { title = label or entry.label, value = value, description = DESCRIPTIONS[key] }

    local builder = tooltipBuilders[key]
    if builder then
        local ok, built = pcall(builder, primaryStat)
        if ok and built then
            data.lines = built.lines
            -- A builder can supply a live, spec-specific description (see
            -- mastery) that's more useful than the fixed one in DESCRIPTIONS;
            -- falling back to the static text when it can't (e.g. no spec yet).
            if built.description then
                data.description = built.description
            end
        end
    end

    return data
end

--------------------------------------------------------------------------------
-- Public accessors
--
-- For other UI surfaces (the character-panel insights panel) that want the
-- same rating-and-what-it's-worth breakdown the tooltips already show,
-- without needing a hover to build it.
--------------------------------------------------------------------------------

function Stats:GetContextStats()
    local primaryStat = GetPrimaryStatIndex()
    local critIndex = (primaryStat == STAT_INTELLECT) and RATING.critSpell or RATING.critMelee
    local hasteIndex = (primaryStat == STAT_INTELLECT) and RATING.hasteSpell or RATING.hasteMelee

    local rows = {}
    local function AddRating(label, index, getPercent)
        local ok, percent = pcall(getPercent)
        if not ok then return end
        rows[#rows + 1] = {
            label = label,
            value = ns.FormatPercent(percent),
            detail = ns.FormatNumber(Rating(index)) .. " rating",
        }
    end

    AddRating("Crit", critIndex, function() return GetCrit(primaryStat) end)
    AddRating("Haste", hasteIndex, function() return GetHaste() or 0 end)
    AddRating("Mastery", RATING.mastery, function() return GetMasteryEffect() or 0 end)
    AddRating("Versatility", RATING.versDone, GetVersatility)

    local ok, base, effectiveArmor, _, posBuff = pcall(UnitArmor, "player")
    if ok then
        effectiveArmor = SaneEffectiveArmor(base, effectiveArmor, posBuff)
        local reduction = GetArmorReductionAgainstTarget(effectiveArmor) or GetArmorReductionPercent(effectiveArmor)
        if reduction then
            rows[#rows + 1] = {
                label = "Armor",
                value = ns.FormatPercent(reduction),
                detail = "physical damage reduction",
            }
        end
    end

    return rows
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
            local reader = readers[entry.key]
            if reader then
                local ok, label, value = pcall(reader, primaryStat)
                if ok then
                    rows[#rows + 1] = { label = label, value = value, tooltipKey = entry.key }
                end
            end
        end
    end

    ns.UI:SetSection("stats", rows, TooltipProvider)
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
