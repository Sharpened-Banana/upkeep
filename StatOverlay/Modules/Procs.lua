-- Modules/Procs.lua
-- Proc and cooldown tracking.
--
-- Two sources feed this list:
--   * a per-character watch list of spell IDs, always shown with aura or
--     cooldown state;
--   * optional auto-detection, which surfaces any short player buff so common
--     trinket and talent procs show up with no configuration at all.

local ADDON, ns = ...

local Procs = ns:NewModule("Procs")

local UPDATE_INTERVAL = 0.1

--------------------------------------------------------------------------------
-- API shims
--
-- Retail moved these into the C_Spell namespace; keep working either way.
--------------------------------------------------------------------------------

local function GetSpellName(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        return info and info.name
    end
    return (GetSpellInfo(spellID))
end

local function GetSpellIcon(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    end
    return select(3, GetSpellInfo(spellID))
end

-- Returns remaining cooldown in seconds, or 0 when ready.
local function GetCooldownRemaining(spellID)
    local start, duration
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)
        if not info then return 0 end
        start, duration = info.startTime, info.duration
    else
        start, duration = GetSpellCooldown(spellID)
    end

    if not start or not duration or duration <= 0 then return 0 end

    -- The 1.5s global cooldown is not worth reporting as "on cooldown".
    if duration <= 1.5 then return 0 end

    local remaining = start + duration - GetTime()
    return remaining > 0 and remaining or 0
end

-- This module updates on a 0.1s ticker and on every UNIT_AURA, so a refusal
-- guaranteed to fail for the rest of an encounter would otherwise fail
-- thousands of times over; ns.AurasReadable/ns.NoteAurasBlocked (Core/Init.lua)
-- hold the shared back-off, since a refusal applies to every module reading
-- auras, not just this one.

-- Lets callers (the slash commands) explain an empty result rather than
-- implying there are no buffs.
function Procs:AurasBlocked()
    return ns.AurasBlocked()
end

local function GetPlayerAura(spellID)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
    if not ns.AurasReadable() then return nil end

    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    if not ok then
        ns.NoteAurasBlocked()
        return nil
    end
    return aura
end

--------------------------------------------------------------------------------
-- Aura collection
--------------------------------------------------------------------------------

-- Collects short-duration buffs on the player, newest procs included, so the
-- caller can show them without the player configuring anything.
local function CollectAutoProcs(watchedSet, maxDuration)
    local found = {}

    if not AuraUtil or not AuraUtil.ForEachAura then return found end
    if not ns.AurasReadable() then return found end

    -- The whole iteration is wrapped, not just the per-aura callback: a
    -- refusal is thrown from inside ForEachAura itself, before the callback
    -- below ever runs.
    local ok = pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(aura)
        if not aura or not aura.spellId then return end
        if watchedSet[aura.spellId] then return end

        local duration = aura.duration or 0
        if duration <= 0 or duration > maxDuration then return end

        found[#found + 1] = {
            spellID = aura.spellId,
            name = aura.name,
            icon = aura.icon,
            expirationTime = aura.expirationTime or 0,
            count = aura.applications or 0,
        }
    end, true)

    if not ok then
        ns.NoteAurasBlocked()
        -- Whatever the iteration managed before it was refused is a partial
        -- view of the player's buffs; showing half a proc list is worse than
        -- showing none.
        return {}
    end

    -- Shortest remaining first, so the thing about to fall off is on top.
    table.sort(found, function(a, b) return a.expirationTime < b.expirationTime end)

    return found
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local COLOR_ACTIVE = { 0.4, 1, 0.4 }
local COLOR_COOLDOWN = { 1, 0.5, 0.5 }
local COLOR_READY = { 0.6, 0.6, 0.6 }

-- Proc rows show the game's own spell tooltip on hover.
local function TooltipProvider(spellID)
    return { spellID = spellID }
end

local function BuildWatchedRow(spellID)
    local name = GetSpellName(spellID)
    if not name then
        -- Unknown or invalid ID; show the raw value so the player can fix it.
        return {
            label = "Spell " .. spellID,
            value = "?",
            valueColor = COLOR_READY,
            alpha = 0.6,
        }
    end

    local icon = GetSpellIcon(spellID)
    local aura = GetPlayerAura(spellID)

    if aura then
        local remaining = (aura.expirationTime or 0) - GetTime()
        local label = name
        if (aura.applications or 0) > 1 then
            label = format("%s (%d)", name, aura.applications)
        end
        return {
            label = label,
            value = (aura.duration or 0) > 0 and ns.FormatTime(remaining) or "on",
            icon = icon,
            valueColor = COLOR_ACTIVE,
            tooltipKey = spellID,
        }
    end

    local cooldown = GetCooldownRemaining(spellID)
    if cooldown > 0 then
        return {
            label = name,
            value = ns.FormatTime(cooldown),
            icon = icon,
            desaturate = true,
            valueColor = COLOR_COOLDOWN,
            alpha = 0.7,
            tooltipKey = spellID,
        }
    end

    if not ns.db.procs.showInactiveWatched then return nil end

    return {
        label = name,
        value = "ready",
        icon = icon,
        desaturate = true,
        valueColor = COLOR_READY,
        alpha = 0.5,
        tooltipKey = spellID,
    }
end

function Procs:Update()
    local db = ns.db
    if not db.procs.enabled then
        ns.UI:SetSection("procs", nil)
        return
    end

    local rows = {}
    local watchedSet = {}

    for _, spellID in ipairs(ns.chardb.watch) do
        watchedSet[spellID] = true
        local row = BuildWatchedRow(spellID)
        if row then
            rows[#rows + 1] = row
        end
    end

    if db.procs.autoDetect then
        local auto = CollectAutoProcs(watchedSet, db.procs.maxDuration)
        local limit = math.min(#auto, db.procs.maxAuto)
        for index = 1, limit do
            local proc = auto[index]
            local remaining = proc.expirationTime - GetTime()
            local label = proc.name
            if proc.count > 1 then
                label = format("%s (%d)", proc.name, proc.count)
            end
            rows[#rows + 1] = {
                label = label,
                value = ns.FormatTime(remaining),
                icon = proc.icon,
                valueColor = COLOR_ACTIVE,
                tooltipKey = proc.spellID,
            }
        end
    end

    ns.UI:SetSection("procs", rows, TooltipProvider)
end

--------------------------------------------------------------------------------
-- Watch list management
--------------------------------------------------------------------------------

function Procs:Watch(spellID)
    for _, existing in ipairs(ns.chardb.watch) do
        if existing == spellID then
            return false, "already watched"
        end
    end

    local name = GetSpellName(spellID)
    if not name then
        return false, "no spell with that ID"
    end

    table.insert(ns.chardb.watch, spellID)
    self:Update()
    return true, name
end

function Procs:Unwatch(spellID)
    for index, existing in ipairs(ns.chardb.watch) do
        if existing == spellID then
            table.remove(ns.chardb.watch, index)
            self:Update()
            return true, GetSpellName(spellID) or tostring(spellID)
        end
    end
    return false, "not watched"
end

function Procs:ListWatched()
    local list = {}
    for _, spellID in ipairs(ns.chardb.watch) do
        list[#list + 1] = format("%s |cff888888(%d)|r", GetSpellName(spellID) or "?", spellID)
    end
    return list
end

-- Dumps current player buffs so the player can find the spell ID to watch.
-- Returns the list plus a `blocked` flag, so /so scan can say "this content
-- hides auras" instead of the misleading "no buffs on you right now".
function Procs:ScanAuras()
    local results = {}
    if not AuraUtil or not AuraUtil.ForEachAura then return results, false end

    -- Player-invoked, so it retries immediately rather than waiting out the
    -- back-off a ticker refusal may have started.
    local ok = pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(aura)
        if aura and aura.spellId then
            results[#results + 1] = format("%s |cff888888(%d)|r", aura.name or "?", aura.spellId)
        end
    end, true)

    if not ok then
        ns.NoteAurasBlocked()
        return {}, true
    end

    return results, false
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Procs:OnEnable()
    -- Aura events drive correctness; the ticker only keeps the timers ticking.
    ns:RegisterEvent("UNIT_AURA", function(_, unit)
        if unit == "player" then
            Procs:Update()
        end
    end)

    self.ticker = C_Timer.NewTicker(UPDATE_INTERVAL, function()
        if ns.db.procs.enabled then
            Procs:Update()
        end
    end)

    self:Update()
end

function Procs:OnConfigChanged()
    self:Update()
end
