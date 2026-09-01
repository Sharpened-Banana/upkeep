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

-- Cooldown starts, aura durations and expiration times are all secret values
-- in Midnight's restricted content, and comparing or doing arithmetic on one
-- errors - on this module's 0.1s ticker that would mean an error per tick,
-- thousands deep within one fight. ns.SafeCall (Core/Init.lua) is the shared
-- guard for those expressions.
local SafeCall = ns.SafeCall

-- Returns remaining cooldown in seconds, or 0 when ready. Protected cooldown
-- data reads as ready rather than erroring: better to underreport a state we
-- are not allowed to inspect than to spam.
local function GetCooldownRemaining(spellID)
    local start, duration
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)
        if not info then return 0 end
        start, duration = info.startTime, info.duration
    else
        start, duration = GetSpellCooldown(spellID)
    end

    return SafeCall(function()
        if not start or not duration or duration <= 0 then return 0 end

        -- The 1.5s global cooldown is not worth reporting as "on cooldown".
        if duration <= 1.5 then return 0 end

        local remaining = start + duration - GetTime()
        return remaining > 0 and remaining or 0
    end) or 0
end

--------------------------------------------------------------------------------
-- Aura availability
--
-- In Midnight's restricted content the aura APIs do not merely return secret
-- values, they refuse addon access outright: AuraUtil.ForEachAura throws
-- "Auras cannot be accessed when secret while tainted by 'Upkeep'" from
-- inside GetAuraSlots, before our callback ever runs. Guarding the values a
-- callback receives is therefore not enough - the call itself has to be
-- wrapped.
--
-- It also has to stop being retried. This module updates on a 0.1s ticker
-- and on every UNIT_AURA, so a call that is guaranteed to fail for the
-- duration of an encounter fails thousands of times (25k+ in one session
-- before this guard existed). Once a refusal is seen, aura reads are parked
-- for a few seconds before being tried again - long enough to cost nothing,
-- short enough that leaving restricted content restores procs promptly.
--------------------------------------------------------------------------------

local AURA_RETRY_INTERVAL = 5
local auraBlockedUntil = 0
local auraNoticeShown = false

local function AurasReadable()
    return GetTime() >= auraBlockedUntil
end

local function NoteAurasBlocked()
    auraBlockedUntil = GetTime() + AURA_RETRY_INTERVAL

    -- Said once per session, not once per refusal: the player should know
    -- why the Procs section emptied out, but this is a game restriction, not
    -- an addon fault, and it must never become its own spam.
    if not auraNoticeShown then
        auraNoticeShown = true
        ns.Print("this content hides aura information from addons, so proc tracking is paused here.")
    end
end

-- True when aura access is currently being refused. Lets callers (the slash
-- commands) explain an empty result rather than implying there are no buffs.
function Procs:AurasBlocked()
    return not AurasReadable()
end

local function GetPlayerAura(spellID)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
    if not AurasReadable() then return nil end

    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    if not ok then
        NoteAurasBlocked()
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
    if not AurasReadable() then return found end

    -- The whole iteration is wrapped, not just the per-aura work: the
    -- refusal comes from GetAuraSlots inside ForEachAura, so it throws
    -- before the callback below is ever reached.
    local ok = pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(aura)
        if not aura or not aura.spellId then return end
        if watchedSet[aura.spellId] then return end

        -- An aura whose duration is secret cannot be classified as "short"
        -- at all; skip it rather than error (see SafeCall above).
        local keep = SafeCall(function()
            local duration = aura.duration or 0
            return duration > 0 and duration <= maxDuration
        end)
        if not keep then return end

        found[#found + 1] = {
            spellID = aura.spellId,
            name = aura.name,
            icon = aura.icon,
            expirationTime = aura.expirationTime or 0,
            count = aura.applications or 0,
        }
    end, true)

    if not ok then
        NoteAurasBlocked()
        -- Whatever the iteration managed before it was refused is a partial
        -- view of the player's buffs; showing half a proc list is worse than
        -- showing none.
        return {}
    end

    -- Shortest remaining first, so the thing about to fall off is on top.
    -- Sorted under pcall as one unit: a comparator that errors partway
    -- through (a secret expirationTime) would otherwise take the whole
    -- Update down, and pcalling inside the comparator instead would feed
    -- sort an inconsistent order. Unsorted is a fine fallback.
    pcall(table.sort, found, function(a, b) return a.expirationTime < b.expirationTime end)

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
        local label = name
        if SafeCall(function() return (aura.applications or 0) > 1 end) then
            label = format("%s (%d)", name, aura.applications)
        end

        -- A secret duration/expiration renders as a plain "on" - active is
        -- the one thing we still know for sure.
        local value = "on"
        if SafeCall(function() return (aura.duration or 0) > 0 end) then
            local remaining = SafeCall(function() return (aura.expirationTime or 0) - GetTime() end)
            if remaining then value = ns.FormatTime(remaining) end
        end

        return {
            label = label,
            value = value,
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
            local remaining = SafeCall(function() return proc.expirationTime - GetTime() end)
            local label = proc.name
            if SafeCall(function() return proc.count > 1 end) then
                label = format("%s (%d)", proc.name, proc.count)
            end
            rows[#rows + 1] = {
                label = label,
                value = remaining and ns.FormatTime(remaining) or "on",
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
-- Returns the list plus a `blocked` flag, so /up scan can say "this content
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
        NoteAurasBlocked()
        return {}, true
    end

    return results, false
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Procs:OnEnable()
    -- Aura events drive correctness; the ticker only keeps the timers ticking.
    --
    -- UNIT_AURA now delivers a fully secret payload while auras are secret,
    -- so even the unit token can be a secret value - comparing one errors.
    -- An unreadable unit is treated as "might be us" and updates anyway;
    -- Update itself is cheap and fully guarded.
    ns:RegisterEvent("UNIT_AURA", function(_, unit)
        local isPlayer = SafeCall(function() return unit == "player" end)
        if isPlayer ~= false then
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
