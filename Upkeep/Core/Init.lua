-- Core/Init.lua
-- Addon bootstrap: namespace, module registry, event bus, printing helpers.

local ADDON, ns = ...

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

ns.name = ADDON
ns.version = GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version") or "1.0.0"

local PREFIX = "|cff33ff99Upkeep|r: "

function ns.Print(...)
    print(PREFIX .. strjoin(" ", tostringall(...)))
end

--------------------------------------------------------------------------------
-- Module registry
--
-- Modules are plain tables created at file-load time. Core calls OnInit after
-- saved variables exist, and OnEnable once the player is in the world.
--------------------------------------------------------------------------------

local modules, moduleOrder = {}, {}

function ns:NewModule(name)
    local module = { name = name }
    modules[name] = module
    moduleOrder[#moduleOrder + 1] = module
    return module
end

function ns:GetModule(name)
    return modules[name]
end

--------------------------------------------------------------------------------
-- Event bus
--
-- One frame fans events out to any number of handlers so modules do not each
-- need their own frame.
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns:RegisterEvent(event, callback)
    local list = handlers[event]
    if not list then
        -- Events come and go between game versions, and registering an unknown
        -- one throws. Skip it rather than taking the whole addon down.
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
            return false
        end
        list = {}
        handlers[event] = list
    end
    list[#list + 1] = callback
    return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        list[i](event, ...)
    end
end)

--------------------------------------------------------------------------------
-- Aura availability
--
-- Some content refuses aura access to addons outright rather than merely
-- hiding values: AuraUtil.ForEachAura and C_UnitAuras.GetPlayerAuraBySpellID
-- can throw instead of returning. Shared across every module that reads
-- auras (Procs, Buffs) so one refusal backs all of them off together rather
-- than each discovering, and re-announcing, the same restriction on its own.
-- A module still has to wrap its own call in pcall and call ns.NoteAurasBlocked
-- on failure; this just holds the shared cooldown and one-time notice.
--------------------------------------------------------------------------------

local AURA_RETRY_INTERVAL = 5
local auraBlockedUntil = 0
local auraNoticeShown = false

function ns.AurasReadable()
    return GetTime() >= auraBlockedUntil
end

function ns.NoteAurasBlocked()
    auraBlockedUntil = GetTime() + AURA_RETRY_INTERVAL

    -- Said once per session, not once per refusal: the player should know why
    -- proc and buff tracking emptied out, but this is a game restriction, not
    -- an addon fault, and it must never become its own spam.
    if not auraNoticeShown then
        auraNoticeShown = true
        ns.Print("this content hides aura information from addons, so proc and buff tracking is paused here.")
    end
end

-- Lets callers (the slash commands) explain an empty result rather than
-- implying there is nothing to report.
function ns.AurasBlocked()
    return not ns.AurasReadable()
end

--------------------------------------------------------------------------------
-- Number / text helpers
--------------------------------------------------------------------------------

function ns.FormatNumber(value)
    value = value or 0
    if value >= 1e9 then
        return format("%.2fB", value / 1e9)
    elseif value >= 1e6 then
        return format("%.2fM", value / 1e6)
    elseif value >= 1e4 then
        return format("%.1fK", value / 1e3)
    end
    return format("%d", value)
end

function ns.FormatPercent(value)
    return format("%.2f%%", value or 0)
end

function ns.FormatTime(seconds)
    seconds = seconds or 0
    if seconds >= 60 then
        return format("%d:%02d", seconds / 60, seconds % 60)
    end
    return format("%.1fs", seconds)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function CallModules(method)
    for i = 1, #moduleOrder do
        local module = moduleOrder[i]
        if module[method] then
            local ok, err = pcall(module[method], module)
            if not ok then
                ns.Print(format("|cffff4444error in %s:%s()|r %s", module.name, method, tostring(err)))
            end
        end
    end
end

-- Pushes config changes out to every module that cares.
function ns.RefreshAll()
    CallModules("OnConfigChanged")
end

ns:RegisterEvent("ADDON_LOADED", function(_, loadedAddon)
    if loadedAddon ~= ADDON then return end
    ns.InitConfig()
    CallModules("OnInit")
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
    ns.playerGUID = UnitGUID("player")
    CallModules("OnEnable")
    ns.RefreshAll()
end)
