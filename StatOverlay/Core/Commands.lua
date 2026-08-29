-- Core/Commands.lua
-- Slash command interface: /so and /statoverlay.

local ADDON, ns = ...

local Commands = ns:NewModule("Commands")

local HELP = {
    "|cff33ff99StatOverlay|r commands:",
    "  |cffffff00/so|r - toggle the overlay",
    "  |cffffff00/so lock|r / |cffffff00unlock|r - lock or unlock dragging",
    "  |cffffff00/so config|r - open the options panel",
    "  |cffffff00/so scale <0.5-2>|r - set overlay scale",
    "  |cffffff00/so width <120-320>|r - set overlay width",
    "  |cffffff00/so font <8-20>|r - set font size",
    "  |cffffff00/so stat <name>|r - toggle a stat row (see |cffffff00/so stat|r)",
    "  |cffffff00/so dps|r - report the last fight",
    "  |cffffff00/so reset dps|r - clear combat totals",
    "  |cffffff00/so reset pos|r - move the overlay back to centre",
    "  |cffffff00/so reset all|r - restore every setting to default",
    "  |cffffff00/so watch <spellID>|r - track a spell's proc and cooldown",
    "  |cffffff00/so unwatch <spellID>|r - stop tracking a spell",
    "  |cffffff00/so watch list|r - show tracked spells",
    "  |cffffff00/so scan|r - list your current buffs with their spell IDs",
}

local function PrintLines(lines, emptyMessage)
    if #lines == 0 then
        if emptyMessage then ns.Print(emptyMessage) end
        return
    end
    for _, line in ipairs(lines) do
        ns.Print(line)
    end
end

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

local handlers = {}

handlers.help = function()
    for _, line in ipairs(HELP) do
        print(line)
    end
end

handlers.lock = function()
    ns.db.locked = true
    ns.RefreshAll()
    ns.Print("overlay locked.")
end

handlers.unlock = function()
    ns.db.locked = false
    ns.RefreshAll()
    ns.Print("overlay unlocked - drag it to move.")
end

handlers.config = function()
    ns.OpenOptions()
end

handlers.scale = function(argument)
    local value = tonumber(argument)
    if not value or value < 0.5 or value > 2 then
        ns.Print("usage: /so scale <0.5-2>")
        return
    end
    ns.db.scale = value
    ns.RefreshAll()
    ns.Print(format("scale set to %.2f.", value))
end

handlers.width = function(argument)
    local value = tonumber(argument)
    if not value or value < 120 or value > 320 then
        ns.Print("usage: /so width <120-320>")
        return
    end
    ns.db.width = value
    ns.RefreshAll()
    ns.Print(format("width set to %d.", value))
end

handlers.font = function(argument)
    local value = tonumber(argument)
    if not value or value < 8 or value > 20 then
        ns.Print("usage: /so font <8-20>")
        return
    end
    ns.db.fontSize = value
    ns.RefreshAll()
    ns.Print(format("font size set to %d.", value))
end

handlers.stat = function(argument)
    if not argument or argument == "" then
        local names = {}
        for _, entry in ipairs(ns.STAT_LIST) do
            local state = ns.db.stats.show[entry.key] and "|cff44ff44on|r" or "|cff888888off|r"
            names[#names + 1] = format("%s (%s)", entry.key, state)
        end
        ns.Print("stats: " .. table.concat(names, ", "))
        return
    end

    local key = argument:lower()
    if ns.db.stats.show[key] == nil then
        ns.Print(format("unknown stat '%s'. Use /so stat to list them.", key))
        return
    end

    ns.db.stats.show[key] = not ns.db.stats.show[key]
    ns.RefreshAll()
    ns.Print(format("%s %s.", key, ns.db.stats.show[key] and "shown" or "hidden"))
end

handlers.dps = function()
    ns.Print(ns:GetModule("Combat"):GetReport())
end

handlers.reset = function(argument)
    argument = (argument or ""):lower()

    if argument == "dps" or argument == "meter" then
        ns:GetModule("Combat"):ResetSession()
        ns.Print("combat totals cleared.")
    elseif argument == "pos" or argument == "position" then
        ns.UI:ResetPosition()
        ns.Print("position reset.")
    elseif argument == "all" then
        ns.ResetConfig()
        ns.Print("all settings restored to defaults.")
    else
        ns.Print("usage: /so reset <dps|pos|all>")
    end
end

handlers.watch = function(argument)
    local procs = ns:GetModule("Procs")

    if not argument or argument == "" or argument:lower() == "list" then
        PrintLines(procs:ListWatched(), "no spells watched. Use /so watch <spellID>.")
        return
    end

    local spellID = tonumber(argument)
    if not spellID then
        ns.Print("usage: /so watch <spellID> - find IDs with /so scan")
        return
    end

    local ok, result = procs:Watch(spellID)
    if ok then
        ns.Print(format("now watching %s (%d).", result, spellID))
    else
        ns.Print(format("could not watch %d: %s.", spellID, result))
    end
end

handlers.unwatch = function(argument)
    local spellID = tonumber(argument)
    if not spellID then
        ns.Print("usage: /so unwatch <spellID>")
        return
    end

    local ok, result = ns:GetModule("Procs"):Unwatch(spellID)
    if ok then
        ns.Print(format("stopped watching %s.", result))
    else
        ns.Print(format("could not unwatch %d: %s.", spellID, result))
    end
end

handlers.scan = function()
    PrintLines(ns:GetModule("Procs"):ScanAuras(), "no buffs on you right now.")
end

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

local function HandleCommand(input)
    input = (input or ""):match("^%s*(.-)%s*$")

    if input == "" then
        if not ns.UI:Toggle() then
            ns.Print("overlay hidden. |cffffff00/so|r to show it again.")
        end
        return
    end

    local command, argument = input:match("^(%S+)%s*(.*)$")
    local handler = handlers[command:lower()]

    if handler then
        handler(argument)
    else
        handlers.help()
    end
end

function Commands:OnInit()
    SLASH_STATOVERLAY1 = "/so"
    SLASH_STATOVERLAY2 = "/statoverlay"
    SlashCmdList.STATOVERLAY = HandleCommand
end
