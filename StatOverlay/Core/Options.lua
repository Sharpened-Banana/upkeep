-- Core/Options.lua
-- Interface Options entry built on the retail Settings API.

local ADDON, ns = ...

local Options = ns:NewModule("Options")

--------------------------------------------------------------------------------
-- Settings API helpers
--
-- Every call is guarded: the Settings API has changed signatures across
-- expansions, and a broken options panel should never take the overlay with it.
--------------------------------------------------------------------------------

-- RegisterProxySetting dropped its `variableTbl` argument in a later revision.
-- Try the current signature first, then the older one.
local function RegisterProxy(category, variable, varType, name, default, get, set)
    local ok, setting = pcall(Settings.RegisterProxySetting, category, variable, varType, name, default, get, set)
    if ok and setting then return setting end

    ok, setting = pcall(Settings.RegisterProxySetting, category, variable, nil, varType, name, default, get, set)
    if ok and setting then return setting end

    return nil
end

local function AddCheckbox(category, variable, name, tooltip, get, set)
    local setting = RegisterProxy(category, variable, Settings.VarType.Boolean, name, get(), get, function(value)
        set(value)
        ns.RefreshAll()
    end)
    if setting then
        pcall(Settings.CreateCheckbox, category, setting, tooltip)
    end
end

local function AddSlider(category, variable, name, tooltip, minValue, maxValue, step, formatter, get, set)
    local setting = RegisterProxy(category, variable, Settings.VarType.Number, name, get(), get, function(value)
        set(value)
        ns.RefreshAll()
    end)
    if not setting then return end

    local ok, options = pcall(Settings.CreateSliderOptions, minValue, maxValue, step)
    if ok and options and options.SetLabelFormatter then
        pcall(options.SetLabelFormatter, options, MinimalSliderWithSteppersMixin.Label.Right, formatter)
    end
    pcall(Settings.CreateSlider, category, setting, options, tooltip)
end

local function AddHeader(layout, text)
    if not CreateSettingsListSectionHeaderInitializer then return end
    pcall(layout.AddInitializer, layout, CreateSettingsListSectionHeaderInitializer(text))
end

local function AddButton(layout, name, buttonText, onClick, tooltip)
    if not CreateSettingsButtonInitializer then return end
    pcall(layout.AddInitializer, layout, CreateSettingsButtonInitializer(name, buttonText, onClick, tooltip))
end

-- Builds get/set closures for a boolean living at db[...path].
local function Accessors(getTable, key)
    return function() return getTable()[key] end,
           function(value) getTable()[key] = value end
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local function BuildPanel()
    local category, layout = Settings.RegisterVerticalLayoutCategory("StatOverlay")
    if not category then return nil end

    local db = function() return ns.db end
    local statsTable = function() return ns.db.stats end
    local combatTable = function() return ns.db.combat end
    local procsTable = function() return ns.db.procs end
    local showTable = function() return ns.StatsShown() end

    ------------------------------------------------------------------ Display
    AddHeader(layout, "Display")

    do
        local get, set = Accessors(db, "locked")
        AddCheckbox(category, "SO_locked", "Lock overlay",
            "Stops the overlay from being dragged and lets clicks pass through it.", get, set)
    end

    do
        local get, set = Accessors(db, "hideOutOfCombat")
        AddCheckbox(category, "SO_hideOOC", "Hide out of combat",
            "Only show the overlay while you are in combat.", get, set)
    end

    do
        local get, set = Accessors(db, "showHeaders")
        AddCheckbox(category, "SO_headers", "Show section headers",
            "Show the Stats / Combat / Procs labels.", get, set)
    end

    do
        local get, set = Accessors(db, "tooltips")
        AddCheckbox(category, "SO_tooltips", "Show tooltips on hover",
            "Explain each stat and show the rating behind it when you hover a row. "
            .. "Clicks still pass through to whatever is underneath.", get, set)
    end

    do
        local get, set = Accessors(db, "scale")
        AddSlider(category, "SO_scale", "Scale", "Overall size of the overlay.",
            0.5, 2.0, 0.05, function(value) return format("%.2f", value) end, get, set)
    end

    do
        local get, set = Accessors(db, "opacity")
        AddSlider(category, "SO_opacity", "Background opacity", "Transparency of the overlay background.",
            0, 1, 0.05, function(value) return format("%d%%", value * 100) end, get, set)
    end

    do
        local get, set = Accessors(db, "width")
        AddSlider(category, "SO_width", "Width", "Overlay width in pixels.",
            120, 320, 10, function(value) return format("%d", value) end, get, set)
    end

    do
        local get, set = Accessors(db, "fontSize")
        AddSlider(category, "SO_fontSize", "Font size", "Text size used for rows.",
            8, 20, 1, function(value) return format("%d", value) end, get, set)
    end

    AddButton(layout, "Position", "Reset position", function()
        ns.UI:ResetPosition()
    end, "Move the overlay back to its default spot.")

    ------------------------------------------------------------------- Stats
    AddHeader(layout, "Stats (this character)")

    do
        local get, set = Accessors(statsTable, "enabled")
        AddCheckbox(category, "SO_stats", "Show stats section", nil, get, set)
    end

    for _, entry in ipairs(ns.STAT_LIST) do
        local get, set = Accessors(showTable, entry.key)
        AddCheckbox(category, "SO_stat_" .. entry.key, entry.label,
            "Shown on this character only.", get, set)
    end

    ------------------------------------------------------------------ Combat
    AddHeader(layout, "Combat")

    local combatOptions = {
        { key = "enabled", label = "Show combat section" },
        { key = "showDPS", label = "Damage per second" },
        { key = "showHPS", label = "Healing per second" },
        { key = "showDamageTaken", label = "Damage taken per second" },
        { key = "showCombatTime", label = "Fight duration" },
        { key = "showSessionTotals", label = "Session totals" },
        { key = "includePets", label = "Count pet damage" },
    }

    for _, entry in ipairs(combatOptions) do
        local get, set = Accessors(combatTable, entry.key)
        AddCheckbox(category, "SO_combat_" .. entry.key, entry.label, nil, get, set)
    end

    AddButton(layout, "Meters", "Reset session", function()
        ns:GetModule("Combat"):ResetSession()
    end, "Clear accumulated damage, healing and time.")

    ------------------------------------------------------------------- Procs
    AddHeader(layout, "Procs")

    do
        local get, set = Accessors(procsTable, "enabled")
        AddCheckbox(category, "SO_procs", "Show procs section", nil, get, set)
    end

    do
        local get, set = Accessors(procsTable, "autoDetect")
        AddCheckbox(category, "SO_procs_auto", "Auto-detect procs",
            "Automatically show short buffs on you, such as trinket and talent procs.", get, set)
    end

    do
        local get, set = Accessors(procsTable, "showInactiveWatched")
        AddCheckbox(category, "SO_procs_inactive", "Show watched spells when ready",
            "Keep watched spells on the list even when they are not active.", get, set)
    end

    do
        local get, set = Accessors(procsTable, "maxAuto")
        AddSlider(category, "SO_procs_maxAuto", "Max auto-detected procs",
            "How many auto-detected procs to show at once.",
            1, 10, 1, function(value) return format("%d", value) end, get, set)
    end

    do
        local get, set = Accessors(procsTable, "maxDuration")
        AddSlider(category, "SO_procs_maxDuration", "Max proc duration",
            "Ignore buffs longer than this, so flasks and food do not show up.",
            5, 120, 5, function(value) return format("%ds", value) end, get, set)
    end

    Settings.RegisterAddOnCategory(category)
    return category
end

function Options:OnEnable()
    if not Settings or not Settings.RegisterVerticalLayoutCategory then
        ns.Print("this game version has no Settings API; use /so for configuration.")
        return
    end

    local ok, category = pcall(BuildPanel)
    if ok and category then
        self.category = category
    else
        ns.Print("could not build the options panel; use /so for configuration.")
    end
end

function ns.OpenOptions()
    local category = Options.category
    if not category or not Settings or not Settings.OpenToCategory then
        ns.Print("options panel unavailable; use /so help for commands.")
        return
    end
    Settings.OpenToCategory(category:GetID())
end
