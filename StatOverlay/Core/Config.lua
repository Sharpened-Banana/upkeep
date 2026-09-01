-- Core/Config.lua
-- Saved-variable defaults and initialisation.

local ADDON, ns = ...

-- Stats the overlay knows how to display, in the order they are drawn.
ns.STAT_LIST = {
    { key = "ilvl",    label = "Item Level" },
    { key = "primary", label = "Primary" },
    { key = "stamina", label = "Stamina" },
    { key = "health",  label = "Health" },
    { key = "crit",    label = "Crit" },
    { key = "haste",   label = "Haste" },
    { key = "mastery", label = "Mastery" },
    { key = "vers",    label = "Versatility" },
    { key = "leech",   label = "Leech" },
    { key = "avoid",   label = "Avoidance" },
    { key = "speed",   label = "Speed" },
    { key = "armor",   label = "Armor" },
    { key = "stagger", label = "Stagger" },
}

local DEFAULTS = {
    hidden = false,
    locked = false,
    scale = 1.0,
    opacity = 0.75,
    width = 190,
    fontSize = 12,
    showHeaders = true,
    hideOutOfCombat = false,
    tooltips = true,

    -- Pinned tooltips, keyed by "section:key", each { section, key, custom,
    -- point, relPoint, x, y }. Only dragged pins carry a position; the rest
    -- stack down the side of the overlay.
    pinnedTooltips = {},

    position = { point = "CENTER", relPoint = "CENTER", x = 300, y = 0 },

    -- Which stats are shown lives per character, in StatOverlayCharDB.
    stats = {
        enabled = true,
    },

    combat = {
        enabled = true,
        includePets = true,
        showDPS = true,
        showHPS = true,
        showDamageTaken = false,
        showCombatTime = true,
        showSessionTotals = false,
    },

    procs = {
        enabled = true,
        autoDetect = true,
        maxAuto = 5,
        maxDuration = 60,
        showInactiveWatched = true,
    },

    buffs = {
        enabled = true,
        showRaidBuffs = true,
        -- Off by default: relevant to everyone, but noisy while just
        -- questing around with no flask or food up.
        showSelfBuffs = false,
    },
}

-- Anything class- or spec-specific belongs here rather than in the shared DB:
-- a tank and a healer want different rows on screen.
local CHAR_DEFAULTS = {
    -- Spell IDs the player explicitly asked to track, in display order.
    watch = {},

    -- Which stat rows this character shows. Defaults suit a damage dealer;
    -- tanks will want armor and avoidance on.
    statsShow = {
        ilvl = true,
        primary = true,
        stamina = false,
        health = false,
        crit = true,
        haste = true,
        mastery = true,
        vers = true,
        leech = false,
        avoid = false,
        speed = false,
        armor = false,
        stagger = false,
    },
}

-- Recursively fills missing keys from a defaults table without clobbering
-- values the player has already set.
local function CopyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            CopyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

ns.CopyDefaults = CopyDefaults
ns.DEFAULTS = DEFAULTS

-- Stat visibility used to live in the shared DB. Move an existing account-wide
-- choice onto this character the first time it is seen, so upgrading does not
-- silently reset anyone's layout.
local function MigrateStatVisibility(db, chardb)
    local legacy = db.stats and db.stats.show
    if not legacy then return end

    if not chardb.migratedStatVisibility then
        for key, value in pairs(legacy) do
            if chardb.statsShow[key] ~= nil then
                chardb.statsShow[key] = value
            end
        end
        chardb.migratedStatVisibility = true
    end

    -- Only drop the shared copy once every character that could inherit it has.
    -- Keeping it costs a few bytes and makes the migration safe to repeat.
end

function ns.InitConfig()
    StatOverlayDB = CopyDefaults(StatOverlayDB or {}, DEFAULTS)
    StatOverlayCharDB = CopyDefaults(StatOverlayCharDB or {}, CHAR_DEFAULTS)
    ns.db = StatOverlayDB
    ns.chardb = StatOverlayCharDB

    MigrateStatVisibility(ns.db, ns.chardb)
end

-- Single point of truth for which stats this character shows.
function ns.StatsShown()
    return ns.chardb.statsShow
end

-- Restores display settings and this character's stat rows. The watch list is
-- deliberately kept: it is curated data, not a setting.
function ns.ResetConfig()
    -- Close pins against the old table before it is replaced, or their frames
    -- would linger on screen with nothing backing them.
    if ns.Tooltips then
        ns.Tooltips:UnpinAll()
    end

    StatOverlayDB = CopyDefaults({}, DEFAULTS)
    ns.db = StatOverlayDB

    ns.chardb.statsShow = CopyDefaults({}, CHAR_DEFAULTS.statsShow)

    ns.RefreshAll()
end
