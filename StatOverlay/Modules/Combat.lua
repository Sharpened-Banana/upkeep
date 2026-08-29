-- Modules/Combat.lua
-- Live combat metrics parsed from the combat log: DPS, HPS, damage taken.
--
-- Two segments are tracked at once: the current (or most recent) fight, and a
-- running session total that only resets when asked.

local ADDON, ns = ...

local Combat = ns:NewModule("Combat")

local band = bit.band

-- Combat log payload layouts. The number is the index of `amount` in the
-- variadic returned by CombatLogGetCurrentEventInfo().
local DAMAGE_EVENTS = {
    SWING_DAMAGE = 12,
    ENVIRONMENTAL_DAMAGE = 13,
    RANGE_DAMAGE = 15,
    SPELL_DAMAGE = 15,
    SPELL_PERIODIC_DAMAGE = 15,
    SPELL_BUILDING_DAMAGE = 15,
    DAMAGE_SHIELD = 15,
    DAMAGE_SPLIT = 15,
}

local HEAL_EVENTS = {
    SPELL_HEAL = 15,
    SPELL_PERIODIC_HEAL = 15,
}

local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local TYPE_PET = COMBATLOG_OBJECT_TYPE_PET or 0x00001000
local TYPE_GUARDIAN = COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x00002000
local PET_MASK = TYPE_PET + TYPE_GUARDIAN

local UPDATE_INTERVAL = 0.25

--------------------------------------------------------------------------------
-- Segments
--------------------------------------------------------------------------------

local function NewSegment()
    return { damage = 0, healing = 0, taken = 0, time = 0 }
end

local current = NewSegment()
local session = NewSegment()

local inCombat = false
local combatStart = 0

local function ElapsedFor(segment)
    if inCombat then
        return segment.time + (GetTime() - combatStart)
    end
    return segment.time
end

local function AddDamage(amount)
    current.damage = current.damage + amount
    session.damage = session.damage + amount
end

local function AddHealing(amount)
    current.healing = current.healing + amount
    session.healing = session.healing + amount
end

local function AddTaken(amount)
    current.taken = current.taken + amount
    session.taken = session.taken + amount
end

--------------------------------------------------------------------------------
-- Combat log
--------------------------------------------------------------------------------

-- True when the source is the player, or a pet/guardian the player owns and
-- pet damage is being counted.
local function IsPlayerSource(guid, flags)
    if guid == ns.playerGUID then return true end
    if not ns.db.combat.includePets then return false end
    if not flags then return false end
    return band(flags, AFFILIATION_MINE) ~= 0 and band(flags, PET_MASK) ~= 0
end

local function OnCombatLogEvent()
    local _, subevent, _, sourceGUID, _, sourceFlags, _, destGUID = CombatLogGetCurrentEventInfo()

    local damageIndex = DAMAGE_EVENTS[subevent]
    if damageIndex then
        local amount = select(damageIndex, CombatLogGetCurrentEventInfo()) or 0

        if IsPlayerSource(sourceGUID, sourceFlags) then
            AddDamage(amount)
        end
        if destGUID == ns.playerGUID then
            AddTaken(amount)
        end
        return
    end

    local healIndex = HEAL_EVENTS[subevent]
    if healIndex and IsPlayerSource(sourceGUID, sourceFlags) then
        local amount, overhealing = select(healIndex, CombatLogGetCurrentEventInfo())
        -- Overhealing is not throughput; only count what actually landed.
        local effective = (amount or 0) - (overhealing or 0)
        if effective > 0 then
            AddHealing(effective)
        end
    end
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

local function PerSecond(total, elapsed)
    if elapsed <= 0 then return 0 end
    return total / elapsed
end

function Combat:Update()
    local db = ns.db
    if not db.combat.enabled then
        ns.UI:SetSection("combat", nil)
        return
    end

    local elapsed = ElapsedFor(current)
    local rows = {}

    if db.combat.showDPS then
        rows[#rows + 1] = {
            label = "DPS",
            value = ns.FormatNumber(PerSecond(current.damage, elapsed)),
            valueColor = { 1, 0.82, 0 },
        }
    end

    if db.combat.showHPS then
        rows[#rows + 1] = {
            label = "HPS",
            value = ns.FormatNumber(PerSecond(current.healing, elapsed)),
            valueColor = { 0.4, 1, 0.4 },
        }
    end

    if db.combat.showDamageTaken then
        rows[#rows + 1] = {
            label = "DTPS",
            value = ns.FormatNumber(PerSecond(current.taken, elapsed)),
            valueColor = { 1, 0.4, 0.4 },
        }
    end

    if db.combat.showCombatTime then
        rows[#rows + 1] = {
            label = inCombat and "Time" or "Last Fight",
            value = ns.FormatTime(elapsed),
        }
    end

    if db.combat.showSessionTotals then
        local sessionElapsed = ElapsedFor(session)
        rows[#rows + 1] = {
            label = "Session DPS",
            value = ns.FormatNumber(PerSecond(session.damage, sessionElapsed)),
            alpha = 0.8,
        }
        rows[#rows + 1] = {
            label = "Session Dmg",
            value = ns.FormatNumber(session.damage),
            alpha = 0.8,
        }
    end

    ns.UI:SetSection("combat", rows)
end

--------------------------------------------------------------------------------
-- Public helpers (used by slash commands)
--------------------------------------------------------------------------------

function Combat:ResetSession()
    session = NewSegment()
    current = NewSegment()
    if inCombat then
        combatStart = GetTime()
    end
    self:Update()
end

function Combat:GetReport()
    local elapsed = ElapsedFor(current)
    return format(
        "last fight %s over %s - damage %s, healing %s, taken %s",
        ns.FormatNumber(PerSecond(current.damage, elapsed)) .. " dps",
        ns.FormatTime(elapsed),
        ns.FormatNumber(current.damage),
        ns.FormatNumber(current.healing),
        ns.FormatNumber(current.taken)
    )
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Combat:OnEnable()
    ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLogEvent)

    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if inCombat then return end
        -- A fresh pull starts a new segment; the session keeps accumulating.
        current = NewSegment()
        inCombat = true
        combatStart = GetTime()
    end)

    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if not inCombat then return end
        local duration = GetTime() - combatStart
        inCombat = false
        current.time = current.time + duration
        session.time = session.time + duration
        self:Update()
    end)

    self.ticker = C_Timer.NewTicker(UPDATE_INTERVAL, function()
        if ns.db.combat.enabled then
            Combat:Update()
        end
    end)

    self:Update()
end

function Combat:OnConfigChanged()
    self:Update()
end
