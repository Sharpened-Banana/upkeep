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

-- Why every call here is guarded, and why the failures are now *recorded*
-- rather than silently dropped: a settings panel that half-registers is
-- indistinguishable from one that never built, and the previous version
-- swallowed the error text from three separate pcalls, so "/so config does
-- nothing" carried no way to find out why. Anything that goes wrong lands in
-- this list and is reported once, with the real Lua error.
local failures = {}

local function RecordFailure(what, err)
    failures[#failures + 1] = format("%s: %s", what, tostring(err))
end

-- Settings.VarType is the documented way to declare a setting's type, but it
-- is a table lookup on a global that has moved before; fall back to the
-- plain Lua type names it holds, which is what the API compares against.
local function VarType(name)
    local varType = Settings.VarType and Settings.VarType[name]
    if varType ~= nil then return varType end
    return name:lower()
end

-- RegisterProxySetting has shipped with two argument orders: the current
-- 7-argument one, and an older 8-argument one carrying a `variableTbl` after
-- `variable`. Which one a client wants is decided ONCE, with throwaway probe
-- variable names, and then used for every real setting.
--
-- Retrying per setting instead - attempt the 7-arg form, and on failure
-- attempt the 8-arg form under the SAME variable name - is a trap on a client
-- wanting the 8-arg form: the first attempt can claim the variable name
-- before it fails, so the retry dies on a duplicate registration and *every*
-- setting is lost while the category itself still registers fine. The result
-- is a settings panel that opens completely empty, indistinguishable from
-- "/so config does nothing".
local PROBE_PREFIX = "StatOverlay_signature_probe_"
local probeCount = 0
local proxyStyle

local function ProbeStyle(category)
    probeCount = probeCount + 1
    local variable = PROBE_PREFIX .. probeCount
    local get = function() return false end
    local set = function() end

    local ok, setting = pcall(Settings.RegisterProxySetting, category, variable,
        VarType("Boolean"), "probe", false, get, set)
    if ok and setting then return "modern" end
    local modernErr = setting

    probeCount = probeCount + 1
    variable = PROBE_PREFIX .. probeCount
    ok, setting = pcall(Settings.RegisterProxySetting, category, variable,
        nil, VarType("Boolean"), "probe", false, get, set)
    if ok and setting then return "legacy" end

    RecordFailure("signature probe", modernErr)
    return "unsupported"
end

local function RegisterProxy(category, variable, varType, name, default, get, set)
    if not proxyStyle then
        proxyStyle = ProbeStyle(category)
    end
    if proxyStyle == "unsupported" then return nil end

    local ok, setting
    if proxyStyle == "legacy" then
        ok, setting = pcall(Settings.RegisterProxySetting, category, variable, nil, varType, name, default, get, set)
    else
        ok, setting = pcall(Settings.RegisterProxySetting, category, variable, varType, name, default, get, set)
    end
    if ok and setting then return setting end

    RecordFailure(variable, ok and "registered nothing" or setting)
    return nil
end

local function AddCheckbox(category, variable, name, tooltip, get, set)
    -- A checkbox whose current value is not a boolean would be rejected by
    -- the client's own type check with a far less obvious error than this.
    local current = get()
    if type(current) ~= "boolean" then
        current = current and true or false
    end

    local setting = RegisterProxy(category, variable, VarType("Boolean"), name, current, get, function(value)
        set(value)
        ns.RefreshAll()
    end)
    if not setting then return end

    local ok, err = pcall(Settings.CreateCheckbox, category, setting, tooltip)
    if not ok then RecordFailure(variable .. " (checkbox)", err) end
end

local function AddSlider(category, variable, name, tooltip, minValue, maxValue, step, formatter, get, set)
    local current = tonumber(get()) or minValue

    local setting = RegisterProxy(category, variable, VarType("Number"), name, current, get, function(value)
        set(value)
        ns.RefreshAll()
    end)
    if not setting then return end

    local ok, options = pcall(Settings.CreateSliderOptions, minValue, maxValue, step)
    if not ok then
        RecordFailure(variable .. " (slider options)", options)
        options = nil
    end

    -- MinimalSliderWithSteppersMixin.Label.Right was indexed *outside* the
    -- pcall that was meant to protect it, so a client without that global
    -- (or without .Label on it) threw straight out of BuildPanel and killed
    -- the whole panel over one slider's label format.
    if options and options.SetLabelFormatter then
        local labelPosition = MinimalSliderWithSteppersMixin
            and MinimalSliderWithSteppersMixin.Label
            and MinimalSliderWithSteppersMixin.Label.Right
        if labelPosition ~= nil then
            pcall(options.SetLabelFormatter, options, labelPosition, formatter)
        end
    end

    local created, err = pcall(Settings.CreateSlider, category, setting, options, tooltip)
    if not created then RecordFailure(variable .. " (slider)", err) end
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
    -- Rebuilding starts from a clean slate so a retry cannot report stale
    -- failures from a previous attempt.
    failures = {}
    proxyStyle = nil

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
    if not Settings.RegisterProxySetting then
        ns.Print("this game version has no Settings.RegisterProxySetting; use /so for configuration.")
        return
    end

    local ok, category = pcall(BuildPanel)
    if ok and category then
        self.category = category
        -- Individually failed widgets no longer pass unnoticed: the panel
        -- opens with whatever registered, and the reason the rest did not is
        -- printed once instead of being lost inside three pcalls.
        if #failures > 0 then
            ns.Print(format("|cffff4444%d option(s) failed to register|r - first: %s", #failures, failures[1]))
        end
    else
        -- pcall's second return is the error; printing it is the whole point.
        ns.Print("|cffff4444could not build the options panel|r: " .. tostring(category))
        ns.Print("use /so help for the slash-command equivalents.")
    end
end

-- Opens the panel. OpenToCategory takes a category ID (category:GetID()),
-- but GetID has not always existed on the returned category, and passing the
-- category object itself is accepted by some revisions - so try the ID and
-- fall back to the object rather than erroring out of the slash command.
function ns.OpenOptions()
    local category = Options.category
    if not category or not Settings or not Settings.OpenToCategory then
        ns.Print("options panel unavailable; use /so help for commands.")
        return
    end

    local categoryID
    if type(category.GetID) == "function" then
        local ok, id = pcall(category.GetID, category)
        if ok then categoryID = id end
    end

    if categoryID ~= nil and pcall(Settings.OpenToCategory, categoryID) then return end
    if pcall(Settings.OpenToCategory, category) then return end

    ns.Print("could not open the options panel; use /so help for commands.")
end
