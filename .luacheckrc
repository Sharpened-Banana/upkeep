-- luacheck configuration for StatOverlay.
-- WoW runs Lua 5.1 and exposes a large set of globals.

std = "lua51"
max_line_length = 120

exclude_files = { "tests/" }

-- Addon saved variables and slash command globals are written by us.
globals = {
    "StatOverlayDB",
    "StatOverlayCharDB",
    "StatOverlayFrame",
    "SLASH_STATOVERLAY1",
    "SLASH_STATOVERLAY2",
    "SlashCmdList",
}

-- Everything the client provides, read-only from our point of view.
read_globals = {
    -- Namespaces
    "C_AddOns", "C_Spell", "C_SpecializationInfo", "C_Timer", "C_UnitAuras",
    "AuraUtil", "Settings", "MinimalSliderWithSteppersMixin",

    -- Frames and widgets
    "CreateFrame", "UIParent", "GameFontNormal", "GameFontNormalSmall",
    "GameFontHighlightSmall", "BackdropTemplateMixin",

    -- Settings API helpers
    "CreateSettingsListSectionHeaderInitializer", "CreateSettingsButtonInitializer",

    -- Unit and character info
    "UnitGUID", "UnitStat", "UnitArmor", "UnitHealthMax", "InCombatLockdown",
    "GetAverageItemLevel", "GetCritChance", "GetSpellCritChance", "GetRangedCritChance",
    "GetHaste", "GetMasteryEffect", "GetCombatRatingBonus", "GetVersatilityBonus",
    "GetLifesteal", "GetAvoidance", "GetSpeed",
    "GetSpecialization", "GetSpecializationInfo",
    "GetSpellInfo", "GetSpellCooldown", "GetAddOnMetadata",

    -- Combat log
    "CombatLogGetCurrentEventInfo",
    "COMBATLOG_OBJECT_AFFILIATION_MINE",
    "COMBATLOG_OBJECT_TYPE_PET",
    "COMBATLOG_OBJECT_TYPE_GUARDIAN",
    "CR_VERSATILITY_DAMAGE_DONE", "CR_LIFESTEAL", "CR_AVOIDANCE", "CR_SPEED",

    -- Misc
    "GetTime", "format", "strjoin", "tostringall", "bit",
}
