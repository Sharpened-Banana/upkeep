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

    position = { point = "CENTER", relPoint = "CENTER", x = 300, y = 0 },

    stats = {
        enabled = true,
        show = {
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
        },
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
}

local CHAR_DEFAULTS = {
    -- Spell IDs the player explicitly asked to track, in display order.
    watch = {},
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

function ns.InitConfig()
    StatOverlayDB = CopyDefaults(StatOverlayDB or {}, DEFAULTS)
    StatOverlayCharDB = CopyDefaults(StatOverlayCharDB or {}, CHAR_DEFAULTS)
    ns.db = StatOverlayDB
    ns.chardb = StatOverlayCharDB
end

function ns.ResetConfig()
    StatOverlayDB = CopyDefaults({}, DEFAULTS)
    ns.db = StatOverlayDB
    ns.RefreshAll()
end
