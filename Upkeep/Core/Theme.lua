-- Core/Theme.lua
-- Shared status-color palette and panel-chrome theme presets.
--
-- Centralizing colors here means a palette fix applies everywhere at once
-- instead of being repeated (and drifting) across every module, and a new
-- theme is one table added to THEMES rather than a change scattered across
-- UI/Overlay.lua and Core/Options.lua.

local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Status colors
--
-- Blue-green/orange rather than green/red: under deuteranopia and
-- protanopia, the two most common forms of color blindness, red and green
-- collapse toward the same hue at similar brightness. Blue-green and orange
-- stay distinguishable, so "good" and "bad" states read correctly either way.
--------------------------------------------------------------------------------

ns.Colors = {
    good    = { 0.13, 0.71, 0.55 }, -- HPS, active procs, buffs present
    bad     = { 0.89, 0.59, 0.04 }, -- damage taken, missing buffs
    warn    = { 0.84, 0.45, 0.04 }, -- on cooldown
    gold    = { 1, 0.82, 0 },       -- DPS, headline numbers
    neutral = { 0.6, 0.6, 0.6 },    -- ready / inactive / dim
}

--------------------------------------------------------------------------------
-- Panel chrome presets
--
-- Each theme describes how the overlay's backdrop is built: a texture pair
-- SetBackdrop can use directly, plus a border color. GetEdgeColor is a
-- function rather than a fixed table so a theme can compute its color at
-- apply time - class-colored reads the player's actual class each time
-- rather than baking in whichever class built the addon.
--------------------------------------------------------------------------------

local function ClassAccent()
    local ok, _, classFilename = pcall(UnitClass, "player")
    local color = ok and classFilename and C_ClassColor and C_ClassColor.GetClassColor(classFilename)
    if color then return color.r, color.g, color.b end
    return 0.4, 0.8, 1.0
end

ns.THEMES = {
    minimal = {
        label = "Minimal",
        bgTexture = "Interface\\Buttons\\WHITE8X8",
        bgColor = { 0, 0, 0 },
        edgeTexture = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        GetEdgeColor = function() return 1, 1, 1, 0.12 end,
    },
    bordered = {
        label = "Bordered",
        bgTexture = "Interface\\Tooltips\\UI-Tooltip-Background",
        bgColor = { 0.05, 0.04, 0.03 },
        edgeTexture = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        GetEdgeColor = function() return 0.79, 0.63, 0.36, 1 end,
    },
    classcolor = {
        label = "Class-colored",
        bgTexture = "Interface\\Buttons\\WHITE8X8",
        bgColor = { 0, 0, 0 },
        edgeTexture = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        GetEdgeColor = function()
            local r, g, b = ClassAccent()
            return r, g, b, 0.9
        end,
    },
}

-- Display order for the Options dropdown; add a new theme here (and above)
-- and nothing else needs to change to offer it.
ns.THEME_ORDER = { "minimal", "bordered", "classcolor" }

function ns.GetTheme(key)
    return ns.THEMES[key] or ns.THEMES.minimal
end
