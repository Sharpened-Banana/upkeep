-- Core/Commands.lua
-- Slash command interface: /up and /upkeep.

local ADDON, ns = ...

local Commands = ns:NewModule("Commands")

local HELP = {
    "|cff33ff99Upkeep|r commands:",
    "  |cffffff00/up|r - toggle the overlay",
    "  |cffffff00/up lock|r / |cffffff00unlock|r - lock or unlock dragging",
    "  |cffffff00/up config|r - open the options panel",
    "  |cffffff00/up scale <0.5-2>|r - set overlay scale",
    "  |cffffff00/up width <120-320>|r - set overlay width",
    "  |cffffff00/up font <8-20>|r - set font size",
    "  |cffffff00/up stat <name>|r - toggle a stat row for this character",
    "  |cffffff00/up tooltips|r - toggle hover tooltips",
    "  |cffffff00/up pin [stat]|r - keep a tooltip on screen (hovered one if no stat given)",
    "  |cffffff00/up unpin [stat|all]|r - close pinned tooltips",
    "  |cffffff00/up pins|r - list what is pinned",
    "  |cffffff00/up dps|r - report the last fight",
    "  |cffffff00/up reset dps|r - clear combat totals",
    "  |cffffff00/up reset pos|r - move the overlay back to centre",
    "  |cffffff00/up reset all|r - restore every setting to default",
    "  |cffffff00/up watch <spellID>|r - track a spell's proc and cooldown",
    "  |cffffff00/up unwatch <spellID>|r - stop tracking a spell",
    "  |cffffff00/up watch list|r - show tracked spells",
    "  |cffffff00/up scan|r - list your current buffs with their spell IDs",
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
        ns.Print("usage: /up scale <0.5-2>")
        return
    end
    ns.db.scale = value
    ns.RefreshAll()
    ns.Print(format("scale set to %.2f.", value))
end

handlers.width = function(argument)
    local value = tonumber(argument)
    if not value or value < 120 or value > 320 then
        ns.Print("usage: /up width <120-320>")
        return
    end
    ns.db.width = value
    ns.RefreshAll()
    ns.Print(format("width set to %d.", value))
end

handlers.font = function(argument)
    local value = tonumber(argument)
    if not value or value < 8 or value > 20 then
        ns.Print("usage: /up font <8-20>")
        return
    end
    ns.db.fontSize = value
    ns.RefreshAll()
    ns.Print(format("font size set to %d.", value))
end

handlers.stat = function(argument)
    local shown = ns.StatsShown()

    if not argument or argument == "" then
        local names = {}
        for _, entry in ipairs(ns.STAT_LIST) do
            local state = shown[entry.key] and "|cff44ff44on|r" or "|cff888888off|r"
            names[#names + 1] = format("%s (%s)", entry.key, state)
        end
        ns.Print("stats for this character: " .. table.concat(names, ", "))
        return
    end

    local key = argument:lower()
    if shown[key] == nil then
        ns.Print(format("unknown stat '%s'. Use /up stat to list them.", key))
        return
    end

    shown[key] = not shown[key]
    ns.RefreshAll()
    ns.Print(format("%s %s on this character.", key, shown[key] and "shown" or "hidden"))
end

handlers.pin = function(argument)
    if not argument or argument == "" then
        local ok, result = ns.Tooltips:PinHovered()
        ns.Print(ok and format("pinned %s.", result) or format("could not pin: %s.", result))
        return
    end

    -- Pin by name so a stat can be pinned without hovering it.
    local key = argument:lower()
    if ns.StatsShown()[key] ~= nil then
        local ok, result = ns.Tooltips:Pin("stats", key)
        ns.Print(ok and format("pinned %s.", key) or format("could not pin %s: %s.", key, result))
        return
    end

    local spellID = tonumber(argument)
    if spellID then
        local ok, result = ns.Tooltips:Pin("procs", spellID)
        ns.Print(ok and format("pinned spell %d.", spellID) or format("could not pin: %s.", result))
        return
    end

    ns.Print(format("unknown stat '%s'. Use /up stat to list them.", key))
end

handlers.unpin = function(argument)
    argument = (argument or ""):lower()

    if argument == "" or argument == "all" then
        local removed = ns.Tooltips:UnpinAll()
        ns.Print(format("closed %d pinned tooltip%s.", removed, removed == 1 and "" or "s"))
        return
    end

    if ns.Tooltips:Unpin("stats:" .. argument) or ns.Tooltips:Unpin("procs:" .. argument) then
        ns.Print(format("unpinned %s.", argument))
    else
        ns.Print(format("%s is not pinned.", argument))
    end
end

handlers.pins = function()
    PrintLines(ns.Tooltips:ListPinned(), "nothing pinned.")
end

handlers.tooltips = function()
    ns.db.tooltips = not ns.db.tooltips
    ns.RefreshAll()
    ns.Print(format("tooltips %s.", ns.db.tooltips and "enabled" or "disabled"))
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
        ns.Print("usage: /up reset <dps|pos|all>")
    end
end

handlers.watch = function(argument)
    local procs = ns:GetModule("Procs")

    if not argument or argument == "" or argument:lower() == "list" then
        PrintLines(procs:ListWatched(), "no spells watched. Use /up watch <spellID>.")
        return
    end

    local spellID = tonumber(argument)
    if not spellID then
        ns.Print("usage: /up watch <spellID> - find IDs with /up scan")
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
        ns.Print("usage: /up unwatch <spellID>")
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
    local lines, blocked = ns:GetModule("Procs"):ScanAuras()
    local emptyMessage = blocked
        and "this content hides aura information from addons right now."
        or "no buffs on you right now."
    PrintLines(lines, emptyMessage)
end

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

local function HandleCommand(input)
    input = (input or ""):match("^%s*(.-)%s*$")

    if input == "" then
        if not ns.UI:Toggle() then
            ns.Print("overlay hidden. |cffffff00/up|r to show it again.")
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
    SLASH_UPKEEP1 = "/up"
    SLASH_UPKEEP2 = "/upkeep"
    SlashCmdList.UPKEEP = HandleCommand
end
