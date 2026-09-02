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

-- optionsList is an array of { value, label }. Passing a generator function
-- to CreateDropdown (rather than a fixed list) matches the real API and
-- keeps this reusable for any dropdown, not just the theme picker.
-- Dropdown-backed settings here are always numeric, never string. The one
-- confirmed-working example in Blizzard's own settings-menu documentation
-- backs a dropdown with a plain number (RegisterAddOnSetting's default is 1,
-- typed via type(1) == "number"); VarType.String is not something that
-- example - or any other found - actually uses for a dropdown, and mismatched
-- setting metadata is exactly what surfaces later as an assertion failure
-- deep inside Blizzard_SettingControls.lua when the control gets built.
-- Callers translate their real values to and from an index via get/set.
local function AddDropdown(category, variable, name, tooltip, optionsList, get, set)
    local setting = RegisterProxy(category, variable, Settings.VarType.Number, name, get(), get, function(value)
        set(value)
        ns.RefreshAll()
    end)
    if not setting then return end

    local function GetOptions()
        local ok, container = pcall(Settings.CreateControlTextContainer)
        if not ok or not container then return nil end
        for _, entry in ipairs(optionsList) do
            container:Add(entry.value, entry.label)
        end
        return container:GetData()
    end

    pcall(Settings.CreateDropdown, category, setting, GetOptions, tooltip)
end

-- Builds the initializer as its own pcall'd step rather than inline as an
-- argument to the outer pcall: an argument expression is evaluated by the
-- caller before pcall is ever invoked, so a throw there is NOT protected -
-- it takes down the whole options panel instead of just this one control.
-- That is exactly what happened with AddButton below.
local function AddHeader(layout, text)
    if not CreateSettingsListSectionHeaderInitializer then return end
    local ok, initializer = pcall(CreateSettingsListSectionHeaderInitializer, text)
    if ok and initializer then
        pcall(layout.AddInitializer, layout, initializer)
    end
end

local function AddButton(layout, name, buttonText, onClick, tooltip)
    if not CreateSettingsButtonInitializer then return end
    -- addSearchTags (5th arg) became required at some point: Blizzard's own
    -- CreateSettingsButtonInitializer asserts it is not nil, and omitting it
    -- is exactly what surfaced as "Blizzard_SettingControls.lua: assertion
    -- failed!" taking down the entire panel. true = searchable by name/text,
    -- the normal case for an action button like these.
    local ok, initializer = pcall(CreateSettingsButtonInitializer, name, buttonText, onClick, tooltip, true)
    if ok and initializer then
        pcall(layout.AddInitializer, layout, initializer)
    end
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
    local category, layout = Settings.RegisterVerticalLayoutCategory("Upkeep")
    if not category then return nil end

    local db = function() return ns.db end
    local statsTable = function() return ns.db.stats end
    local combatTable = function() return ns.db.combat end
    local procsTable = function() return ns.db.procs end
    local buffsTable = function() return ns.db.buffs end
    local showTable = function() return ns.StatsShown() end

    ------------------------------------------------------------------ Display
    AddHeader(layout, "Display")

    do
        local get, set = Accessors(db, "locked")
        AddCheckbox(category, "UP_locked", "Lock overlay",
            "Stops the overlay from being dragged and lets clicks pass through it.", get, set)
    end

    do
        local get, set = Accessors(db, "hideOutOfCombat")
        AddCheckbox(category, "UP_hideOOC", "Hide out of combat",
            "Only show the overlay while you are in combat.", get, set)
    end

    do
        local get, set = Accessors(db, "showHeaders")
        AddCheckbox(category, "UP_headers", "Show section headers",
            "Show the Stats / Combat / Procs / Buffs labels.", get, set)
    end

    do
        local get, set = Accessors(db, "tooltips")
        AddCheckbox(category, "UP_tooltips", "Show tooltips on hover",
            "Explain each stat and show the rating behind it when you hover a row. "
            .. "Clicks still pass through to whatever is underneath.", get, set)
    end

    do
        local options = {}
        for index, key in ipairs(ns.THEME_ORDER) do
            options[index] = { value = index, label = ns.THEMES[key].label }
        end

        local function IndexOfTheme(key)
            for index, candidate in ipairs(ns.THEME_ORDER) do
                if candidate == key then return index end
            end
            return 1
        end

        local function get() return IndexOfTheme(db().theme) end
        local function set(index) db().theme = ns.THEME_ORDER[index] or ns.THEME_ORDER[1] end

        AddDropdown(category, "UP_theme", "Theme",
            "How the panel's border and background look.", options, get, set)
    end

    do
        local get, set = Accessors(db, "scale")
        AddSlider(category, "UP_scale", "Scale", "Overall size of the overlay.",
            0.5, 2.0, 0.05, function(value) return format("%.2f", value) end, get, set)
    end

    do
        local get, set = Accessors(db, "opacity")
        AddSlider(category, "UP_opacity", "Background opacity", "Transparency of the overlay background.",
            0, 1, 0.05, function(value) return format("%d%%", value * 100) end, get, set)
    end

    do
        local get, set = Accessors(db, "width")
        AddSlider(category, "UP_width", "Width", "Overlay width in pixels.",
            120, 320, 10, function(value) return format("%d", value) end, get, set)
    end

    do
        local get, set = Accessors(db, "fontSize")
        AddSlider(category, "UP_fontSize", "Font size", "Text size used for rows.",
            8, 20, 1, function(value) return format("%d", value) end, get, set)
    end

    AddButton(layout, "Position", "Reset position", function()
        ns.UI:ResetPosition()
    end, "Move the overlay back to its default spot.")

    ------------------------------------------------------------------- Stats
    AddHeader(layout, "Stats (this character)")

    do
        local get, set = Accessors(statsTable, "enabled")
        AddCheckbox(category, "UP_stats", "Show stats section", nil, get, set)
    end

    for _, entry in ipairs(ns.STAT_LIST) do
        local get, set = Accessors(showTable, entry.key)
        AddCheckbox(category, "UP_stat_" .. entry.key, entry.label,
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
        AddCheckbox(category, "UP_combat_" .. entry.key, entry.label, nil, get, set)
    end

    AddButton(layout, "Meters", "Reset session", function()
        ns:GetModule("Combat"):ResetSession()
    end, "Clear accumulated damage, healing and time.")

    ------------------------------------------------------------------- Procs
    AddHeader(layout, "Procs")

    do
        local get, set = Accessors(procsTable, "enabled")
        AddCheckbox(category, "UP_procs", "Show procs section", nil, get, set)
    end

    do
        local get, set = Accessors(procsTable, "autoDetect")
        AddCheckbox(category, "UP_procs_auto", "Auto-detect procs",
            "Automatically show short buffs on you, such as trinket and talent procs.", get, set)
    end

    do
        local get, set = Accessors(procsTable, "showInactiveWatched")
        AddCheckbox(category, "UP_procs_inactive", "Show watched spells when ready",
            "Keep watched spells on the list even when they are not active.", get, set)
    end

    do
        local get, set = Accessors(procsTable, "maxAuto")
        AddSlider(category, "UP_procs_maxAuto", "Max auto-detected procs",
            "How many auto-detected procs to show at once.",
            1, 10, 1, function(value) return format("%d", value) end, get, set)
    end

    do
        local get, set = Accessors(procsTable, "maxDuration")
        AddSlider(category, "UP_procs_maxDuration", "Max proc duration",
            "Ignore buffs longer than this, so flasks and food do not show up.",
            5, 120, 5, function(value) return format("%ds", value) end, get, set)
    end

    ------------------------------------------------------------------- Buffs
    AddHeader(layout, "Buffs")

    do
        local get, set = Accessors(buffsTable, "enabled")
        AddCheckbox(category, "UP_buffs", "Show buffs section", nil, get, set)
    end

    do
        local get, set = Accessors(buffsTable, "showRaidBuffs")
        AddCheckbox(category, "UP_buffs_raid", "Missing raid buffs",
            "While in a group, flag raid buffs (Battle Shout, Arcane Intellect, and the like) that are not on you.",
            get, set)
    end

    do
        local get, set = Accessors(buffsTable, "showSelfBuffs")
        AddCheckbox(category, "UP_buffs_self", "Missing flask/food",
            "Flag when you have no flask or well fed buff active.", get, set)
    end

    -------------------------------------------------------- Character panel
    AddHeader(layout, "Character panel")

    do
        local charPanelTable = function() return ns.db.characterPanel end
        local get, set = Accessors(charPanelTable, "enabled")
        AddCheckbox(category, "UP_charpanel", "Show Upkeep Insights on the character sheet",
            "Docks item level, enchant status, and stat context next to the character panel "
            .. "while it is open.", get, set)
    end

    Settings.RegisterAddOnCategory(category)
    return category
end

function Options:OnEnable()
    if not Settings or not Settings.RegisterVerticalLayoutCategory then
        ns.Print("this game version has no Settings API; use /up for configuration.")
        return
    end

    local ok, category = pcall(BuildPanel)
    if ok and category then
        self.category = category
    else
        ns.Print(format("could not build the options panel (%s); use /up for configuration.",
            ok and "no category returned" or tostring(category)))
    end
end

function ns.OpenOptions()
    local category = Options.category
    if not category or not Settings or not Settings.OpenToCategory then
        ns.Print("options panel unavailable; use /up help for commands.")
        return
    end
    Settings.OpenToCategory(category:GetID())
end
