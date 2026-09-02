-- Modules/Buffs.lua
-- Flags raid buffs and personal consumables that are currently missing.
--
-- Unlike the other sections, this one shows nothing when everything is fine:
-- an empty rows table hides the section entirely (UI/Overlay.lua), so it only
-- ever asks for attention when something actually needs fixing.

local ADDON, ns = ...

local Buffs = ns:NewModule("Buffs")

local UPDATE_INTERVAL = 1

-- One raid buff per source, so at most one of these is ever missing per raid
-- regardless of which class provides it. Blizzard has temporarily excluded
-- these five specifically from its "secret value" restriction so addons can
-- keep tracking them; if that ever changes, GetPlayerAuraBySpellID failing
-- reads as "can't tell" (see IsBuffActive), not "missing".
local RAID_BUFFS = {
    { spellID = 6673,   label = "Battle Shout" },
    { spellID = 1459,   label = "Arcane Intellect" },
    { spellID = 21562,  label = "Fortitude" },
    { spellID = 1126,   label = "Mark of the Wild" },
    { spellID = 462854, label = "Skyfury" },
}

-- Personal consumables, matched by name rather than spell ID: every food
-- item's buff is named "Well Fed" regardless of which one was eaten, and
-- every flask is named "Flask of <something>" - both survive next season's
-- flask/food items changing without a spell ID to update.
local SELF_BUFF_PATTERNS = {
    { pattern = "^Well Fed$", label = "Well Fed" },
    { pattern = "^Flask of ", label = "Flask" },
}

-- True/false when the read succeeded, nil when it could not be attempted
-- (blocked, or the API is unavailable) - the caller treats nil as "can't
-- tell" rather than "missing".
local function IsBuffActive(spellID)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
    if not ns.AurasReadable() then return nil end

    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    if not ok then
        ns.NoteAurasBlocked()
        return nil
    end
    return aura ~= nil
end

-- Returns a set of SELF_BUFF_PATTERNS labels currently matched by some buff
-- on the player, or nil if the read could not be attempted.
local function MatchSelfBuffs()
    if not AuraUtil or not AuraUtil.ForEachAura then return {} end
    if not ns.AurasReadable() then return nil end

    local matched = {}
    -- The whole iteration is wrapped, not just the per-aura callback: a
    -- refusal is thrown from inside ForEachAura itself, before the callback
    -- below ever runs.
    local ok = pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(aura)
        if not aura or not aura.name then return end
        for _, entry in ipairs(SELF_BUFF_PATTERNS) do
            if aura.name:find(entry.pattern) then
                matched[entry.label] = true
            end
        end
    end, true)

    if not ok then
        ns.NoteAurasBlocked()
        return nil
    end
    return matched
end

local COLOR_MISSING = ns.Colors.bad

function Buffs:Update()
    local db = ns.db.buffs
    if not db.enabled then
        ns.UI:SetSection("buffs", nil)
        return
    end

    local rows = {}

    -- Solo, nobody else can hand these out, and several of them cannot be
    -- self-cast either; asking about them would just nag a player who has no
    -- way to fix it.
    if db.showRaidBuffs and IsInGroup and IsInGroup() then
        for _, buff in ipairs(RAID_BUFFS) do
            if IsBuffActive(buff.spellID) == false then
                rows[#rows + 1] = { label = buff.label, value = "missing", valueColor = COLOR_MISSING }
            end
        end
    end

    if db.showSelfBuffs then
        local matched = MatchSelfBuffs()
        if matched then
            for _, entry in ipairs(SELF_BUFF_PATTERNS) do
                if not matched[entry.label] then
                    rows[#rows + 1] = { label = entry.label, value = "missing", valueColor = COLOR_MISSING }
                end
            end
        end
    end

    ns.UI:SetSection("buffs", rows)
end

function Buffs:OnEnable()
    ns:RegisterEvent("UNIT_AURA", function(_, unit)
        if unit == "player" then
            Buffs:Update()
        end
    end)

    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        Buffs:Update()
    end)

    self.ticker = C_Timer.NewTicker(UPDATE_INTERVAL, function()
        if ns.db.buffs.enabled then
            Buffs:Update()
        end
    end)

    self:Update()
end

function Buffs:OnConfigChanged()
    self:Update()
end
