-- luacheck configuration for Upkeep.
-- WoW runs Lua 5.1 and exposes a large set of globals.

std = "lua51"
max_line_length = 120

exclude_files = { "tests/" }

-- Addon saved variables and slash command globals are written by us.
globals = {
    "UpkeepDB",
    "UpkeepCharDB",
    "UpkeepFrame",
    "SLASH_UPKEEP1",
    "SLASH_UPKEEP2",
    "SlashCmdList",
    "Upkeep_PinHoveredTooltip",
    "BINDING_HEADER_UPKEEP",
    "BINDING_NAME_UPKEEP_PIN_TOOLTIP",
}

-- Everything the client provides, read-only from our point of view.
read_globals = {
    -- Namespaces
    "C_AddOns", "C_ClassColor", "C_DamageMeter", "C_Item", "C_PaperDollInfo", "C_Spell",
    "C_SpecializationInfo", "C_Timer", "C_TooltipInfo", "C_UnitAuras", "AuraUtil", "Enum",
    "Settings", "MinimalSliderWithSteppersMixin",

    -- Frames and widgets
    "CreateFrame", "UIParent", "GameFontNormal", "GameFontNormalSmall",
    "GameFontHighlightSmall", "BackdropTemplateMixin", "GameTooltip",
    "CharacterFrame", "PaperDollFrame",

    -- Inventory slot IDs (stable across expansions)
    "INVSLOT_HEAD", "INVSLOT_NECK", "INVSLOT_SHOULDER", "INVSLOT_CHEST", "INVSLOT_WAIST",
    "INVSLOT_LEGS", "INVSLOT_FEET", "INVSLOT_WRIST", "INVSLOT_HAND",
    "INVSLOT_FINGER1", "INVSLOT_FINGER2", "INVSLOT_TRINKET1", "INVSLOT_TRINKET2",
    "INVSLOT_BACK", "INVSLOT_MAINHAND", "INVSLOT_OFFHAND",
    "GetInventoryItemLink", "GetItemGem", "ENCHANTED_TOOLTIP_LINE",

    -- Settings API helpers
    "CreateSettingsListSectionHeaderInitializer", "CreateSettingsButtonInitializer",

    -- Unit and character info
    "UnitGUID", "UnitStat", "UnitArmor", "UnitHealth", "UnitHealthMax", "UnitLevel", "InCombatLockdown",
    "UnitExists", "UnitCanAttack", "UnitClass", "IsInGroup",
    "GetAverageItemLevel", "GetCritChance", "GetSpellCritChance", "GetRangedCritChance",
    "GetHaste", "GetMasteryEffect", "GetMastery",
    "GetCombatRating", "GetCombatRatingBonus", "GetVersatilityBonus",
    "GetLifesteal", "GetAvoidance", "GetSpeed",
    "GetSpecialization", "GetSpecializationInfo", "GetSpecializationMasterySpells", "GetSpellDescription",
    "GetSpellInfo", "GetSpellCooldown", "GetAddOnMetadata",

    -- Combat log
    "CombatLogGetCurrentEventInfo",
    "COMBATLOG_OBJECT_AFFILIATION_MINE",
    "COMBATLOG_OBJECT_TYPE_PET",
    "COMBATLOG_OBJECT_TYPE_GUARDIAN",
    "CR_VERSATILITY_DAMAGE_DONE", "CR_VERSATILITY_DAMAGE_TAKEN",
    "CR_LIFESTEAL", "CR_AVOIDANCE", "CR_SPEED",
    "CR_CRIT_MELEE", "CR_CRIT_SPELL", "CR_HASTE_MELEE", "CR_HASTE_SPELL", "CR_MASTERY",

    -- Misc
    "GetTime", "format", "strjoin", "tostringall", "bit",
}
