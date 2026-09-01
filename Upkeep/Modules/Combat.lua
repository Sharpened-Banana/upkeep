-- Modules/Combat.lua
-- Live combat metrics parsed from the combat log: DPS, HPS, damage taken.
--
-- Two segments are tracked at once: the current (or most recent) fight, and a
-- running session total that only resets when asked.

local ADDON, ns = ...

local Combat = ns:NewModule("Combat")

local band = bit.band

--------------------------------------------------------------------------------
-- Midnight's sanctioned meter
--
-- 12.0 removed combat-log access for addons outright: registering
-- COMBAT_LOG_EVENT_UNFILTERED errors (Core/Init.lua's pcall guard turns that
-- into a silent no-op), so on a 12.x client the legacy parser below never
-- receives a single event. C_DamageMeter is the replacement Blizzard ships
-- for exactly this use: it hands back per-source rows the game tallied
-- itself, with isLocalPlayer marking ours. Amounts are secret while in
-- combat - fine for display (ns.FormatNumber degrades gracefully), useless
-- for logic, which this module does not do.
--------------------------------------------------------------------------------

local HAS_DAMAGE_METER = C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and true or false

-- Enum fallbacks follow the same defensive pattern as Stats.lua's RATING
-- table: prefer the real enum, keep the documented numeric value as a
-- backstop.
local SESSION_TYPE = {
    overall = (Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Overall) or 0,
    current = (Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current) or 1,
}

local METER_TYPE = {
    damage = (Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone) or 0,
    dps = (Enum and Enum.DamageMeterType and Enum.DamageMeterType.Dps) or 1,
    hps = (Enum and Enum.DamageMeterType and Enum.DamageMeterType.Hps) or 3,
    taken = (Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageTaken) or 7,
}

-- Reads the local player's amount for one metric out of one session. Returns
-- nil when the session has no row for us (not in combat yet, or the API
-- hiccuped) so callers can fall back to 0.
local function GetLocalPlayerAmount(sessionType, meterType, perSecond)
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, meterType)
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table" then
        return nil
    end

    for _, source in ipairs(session.combatSources) do
        if source.isLocalPlayer then
            return perSecond and source.amountPerSecond or source.totalAmount
        end
    end
    return nil
end

-- Combat log payload layouts. The number is the index of `amount` in the
-- variadic returned by CombatLogGetCurrentEventInfo().
--
-- Deliberately not tracked: SPELL_ABSORBED (absorbed damage/healing) and
-- SWING_DAMAGE_LANDED (a duplicate of SWING_DAMAGE for melee swings against
-- multiple targets). Both would double-count against what SWING_DAMAGE/
-- SPELL_DAMAGE/SPELL_HEAL already report; this is not an oversight.
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

-- Highest payload index anything below reads (SPELL_HEAL's overhealing sits
-- at 16); capturing exactly that many locals lets every subevent be indexed
-- out of a single CombatLogGetCurrentEventInfo() call instead of calling it
-- again per index. COMBAT_LOG_EVENT_UNFILTERED can fire thousands of times a
-- second in a raid, and each call returns ~20 values, so doing this two or
-- three times per event (damage the player both dealt and took) was pure
-- waste.
local function OnCombatLogEvent()
    local _, subevent, _, sourceGUID, _, sourceFlags, _, destGUID,
        _, _, _, p12, p13, p14, p15, p16 = CombatLogGetCurrentEventInfo()

    local damageIndex = DAMAGE_EVENTS[subevent]
    if damageIndex then
        local amount
        if damageIndex == 12 then amount = p12
        elseif damageIndex == 13 then amount = p13
        else amount = p15 end
        amount = amount or 0

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
        -- Both current HEAL_EVENTS entries read amount/overhealing at 15/16.
        local amount, overhealing = p15, p16
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

-- The current-fight numbers for the three throughput rows, from whichever
-- source this client supports. Per-second values come from the game's own
-- meter on 12.x (no arithmetic of ours on its secret amounts) and from the
-- legacy segments elsewhere.
local function CurrentThroughput()
    if HAS_DAMAGE_METER then
        return GetLocalPlayerAmount(SESSION_TYPE.current, METER_TYPE.dps, true) or 0,
            GetLocalPlayerAmount(SESSION_TYPE.current, METER_TYPE.hps, true) or 0,
            GetLocalPlayerAmount(SESSION_TYPE.current, METER_TYPE.taken, true) or 0
    end

    local elapsed = ElapsedFor(current)
    return PerSecond(current.damage, elapsed),
        PerSecond(current.healing, elapsed),
        PerSecond(current.taken, elapsed)
end

function Combat:Update()
    local db = ns.db
    if not db.combat.enabled then
        ns.UI:SetSection("combat", nil)
        return
    end

    local dps, hps, taken = CurrentThroughput()
    local rows = {}

    if db.combat.showDPS then
        rows[#rows + 1] = {
            label = "DPS",
            value = ns.FormatNumber(dps),
            valueColor = { 1, 0.82, 0 },
        }
    end

    if db.combat.showHPS then
        rows[#rows + 1] = {
            label = "HPS",
            value = ns.FormatNumber(hps),
            valueColor = { 0.4, 1, 0.4 },
        }
    end

    if db.combat.showDamageTaken then
        rows[#rows + 1] = {
            label = "DTPS",
            value = ns.FormatNumber(taken),
            valueColor = { 1, 0.4, 0.4 },
        }
    end

    if db.combat.showCombatTime then
        rows[#rows + 1] = {
            label = inCombat and "Time" or "Last Fight",
            value = ns.FormatTime(ElapsedFor(current)),
        }
    end

    if db.combat.showSessionTotals then
        if HAS_DAMAGE_METER then
            rows[#rows + 1] = {
                label = "Session DPS",
                value = ns.FormatNumber(GetLocalPlayerAmount(SESSION_TYPE.overall, METER_TYPE.dps, true) or 0),
                alpha = 0.8,
            }
            rows[#rows + 1] = {
                label = "Session Dmg",
                value = ns.FormatNumber(GetLocalPlayerAmount(SESSION_TYPE.overall, METER_TYPE.damage) or 0),
                alpha = 0.8,
            }
        else
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
    -- The game's own meter keeps the 12.x session data; ask it to clear too
    -- when it offers a way, so "Reset session" means the same thing on every
    -- client. Existence-guarded: the exact reset entry point may vary (or be
    -- absent) across builds, and a missing one just leaves Blizzard's
    -- overall tally alone.
    if HAS_DAMAGE_METER and C_DamageMeter.ResetCombatSessions then
        pcall(C_DamageMeter.ResetCombatSessions)
    end
    self:Update()
end

function Combat:GetReport()
    -- Everything here can be secret mid-combat on 12.x, and printing a
    -- secret string to chat is not display in Blizzard's sense the way
    -- SetText is - so build the line under pcall and fall back to an honest
    -- "not right now" rather than erroring out of the slash command.
    local dps, _, _ = CurrentThroughput()
    local elapsed = ElapsedFor(current)

    local damage, healing, taken
    if HAS_DAMAGE_METER then
        damage = GetLocalPlayerAmount(SESSION_TYPE.current, METER_TYPE.damage) or 0
        healing = GetLocalPlayerAmount(SESSION_TYPE.current, METER_TYPE.hps) or 0
        taken = GetLocalPlayerAmount(SESSION_TYPE.current, METER_TYPE.taken) or 0
    else
        damage, healing, taken = current.damage, current.healing, current.taken
    end

    local ok, report = pcall(format,
        "last fight %s over %s - damage %s, healing %s, taken %s",
        ns.FormatNumber(dps) .. " dps",
        ns.FormatTime(elapsed),
        ns.FormatNumber(damage),
        ns.FormatNumber(healing),
        ns.FormatNumber(taken)
    )
    if ok then return report end
    return "combat numbers are protected while you are in combat - try again after the fight."
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Combat:OnEnable()
    -- Legacy clients only: on 12.x this registration errors inside
    -- RegisterEvent's pcall and the meter data comes from C_DamageMeter
    -- instead (see CurrentThroughput). Skipping it explicitly keeps the dead
    -- parser from even being wired up where it can never fire.
    if not HAS_DAMAGE_METER then
        ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLogEvent)
    end

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
