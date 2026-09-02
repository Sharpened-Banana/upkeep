-- tests/run.lua
-- Loads Upkeep against the mock API and drives it through a session.
--
-- Run with:  lua5.1 tests/run.lua

package.path = "tests/?.lua;" .. package.path

local mock = require("wow_mock")

--------------------------------------------------------------------------------
-- Tiny test harness
--------------------------------------------------------------------------------

local passed, failed = 0, 0

local function check(condition, description, detail)
    if condition then
        passed = passed + 1
        print("  ok   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description .. (detail and ("  -> " .. tostring(detail)) or ""))
    end
end

local function section(title)
    print("\n" .. title)
end

--------------------------------------------------------------------------------
-- Load the addon exactly as the TOC lists it
--------------------------------------------------------------------------------

local FILES = {
    "Core\\Init.lua",
    "Core\\Config.lua",
    "Core\\Theme.lua",
    "UI\\Overlay.lua",
    "UI\\Tooltips.lua",
    "Modules\\Stats.lua",
    "Modules\\Combat.lua",
    "Modules\\Procs.lua",
    "Modules\\Buffs.lua",
    "Modules\\CharacterPanel.lua",
    "Core\\Options.lua",
    "Core\\Commands.lua",
}

-- Keep addon chat output from drowning the test log.
local realPrint = print
local addonOutput = {}
_G.print = function(...)
    addonOutput[#addonOutput + 1] = table.concat({ mock and "" or "" }, "") .. tostring((select(1, ...)))
end

local ns = mock.LoadAddon("Upkeep", FILES, "Upkeep")

_G.print = realPrint

-- Record every section the modules render, without touching production code.
local rendered = {}
local realSetSection = ns.UI.SetSection
ns.UI.SetSection = function(self, id, rows, tooltipProvider)
    rendered[id] = rows or {}
    return realSetSection(self, id, rows, tooltipProvider)
end

local function findRow(sectionID, labelPattern)
    for _, row in ipairs(rendered[sectionID] or {}) do
        if row.label and row.label:find(labelPattern, 1, true) then
            return row
        end
    end
    return nil
end

--------------------------------------------------------------------------------
section("Load and initialisation")
--------------------------------------------------------------------------------

check(ns.name == "Upkeep", "namespace carries the addon name")
check(ns.UI ~= nil, "UI module registered at load time")

mock.Fire("ADDON_LOADED", "SomeOtherAddon")
check(ns.db == nil, "ignores ADDON_LOADED for other addons")

mock.Fire("ADDON_LOADED", "Upkeep")
check(ns.db ~= nil, "saved variables initialised")
check(ns.db.scale == 1.0, "defaults applied", ns.db and ns.db.scale)
check(ns.chardb ~= nil and type(ns.chardb.watch) == "table", "per-character watch list created")
check(ns.UI.frame ~= nil, "overlay frame built")
check(SlashCmdList.UPKEEP ~= nil, "slash command registered")

-- Defaults must not be shared by reference, or one character's settings would
-- leak into another's.
ns.chardb.statsShow.crit = false
check(ns.DEFAULTS.stats.enabled == true, "defaults are deep-copied, not referenced")
ns.chardb.statsShow.crit = true

mock.Fire("PLAYER_LOGIN")
check(ns.playerGUID == "Player-1234-ABCDEF", "player GUID cached on login")

--------------------------------------------------------------------------------
section("Number formatting under secret values")
--------------------------------------------------------------------------------

-- Some unit stats become secret while in combat (Patch 12.0+); comparing one
-- throws even though formatting it does not. A real secret value cannot be
-- constructed in plain Lua, but a string reproduces the same shape: Lua's
-- relational operators never coerce across types (a string compared to a
-- number always throws, regardless of content), while string.format's %d
-- and %f happily coerce a numeric string - so "42" throws exactly where a
-- secret would, and formats exactly where a secret would too.
check(ns.FormatNumber("42") == "42",
    "FormatNumber falls back to a plain render when comparison isn't possible", ns.FormatNumber("42"))
check(ns.FormatPercent("42") == "42.00%",
    "FormatPercent falls back the same way", ns.FormatPercent("42"))
check(ns.FormatTime("42") == "42.0s",
    "FormatTime falls back the same way", ns.FormatTime("42"))

-- A value that cannot even be formatted (not just compared) still never
-- throws - it just degrades further instead of taking the row down.
check(ns.FormatNumber({}) == "?", "an unformattable value degrades to a placeholder rather than erroring")
check(ns.FormatPercent({}) == "?%", "same for FormatPercent")
check(ns.FormatTime({}) == "?", "same for FormatTime")

-- The ordinary case is unaffected by any of the above.
check(ns.FormatNumber(12345) == "12.3K", "normal numbers still format normally", ns.FormatNumber(12345))

-- ns.SafeCall/ns.KnownPast are the shared way modules guard a comparison or
-- arithmetic expression against the same risk, rather than each reinventing
-- its own pcall wrapper.
check(ns.SafeCall(function() return 1 + 1 end) == 2, "SafeCall returns a normal result unchanged")
check(ns.SafeCall(function() return "x" >= 1 end) == nil,
    "SafeCall swallows a throw and returns nil instead of propagating it")

check(ns.KnownPast(5, 0, true) == true, "KnownPast reports a real value correctly (greater)")
check(ns.KnownPast(-5, 0, false) == true, "KnownPast reports a real value correctly (less)")
check(ns.KnownPast(5, 10, true) == false, "KnownPast reports false when the value isn't past the threshold")
check(ns.KnownPast(nil, 0, true) == false, "KnownPast treats a missing value as 0, not an error")
check(ns.KnownPast("50", 0, true) == false,
    "KnownPast reports false, not an error, when the value can't be compared at all")

--------------------------------------------------------------------------------
section("Stats module")
--------------------------------------------------------------------------------

check(#(rendered.stats or {}) > 0, "stats section renders rows")
check(findRow("stats", "Item Level") ~= nil, "item level row present")

local primaryRow = findRow("stats", "Agility")
check(primaryRow ~= nil, "primary stat resolved from spec (Agility for spec primaryStat=2)")
-- Values below 10,000 stay exact; only larger numbers get abbreviated.
check(primaryRow and primaryRow.value == "8500", "primary stat shown exactly below the abbreviation threshold",
    primaryRow and primaryRow.value)

local healthRowBefore = findRow("stats", "Health")
check(healthRowBefore == nil, "health row off by default")
ns.chardb.statsShow.health = true
ns.RefreshAll()
local healthRow = findRow("stats", "Health")
check(healthRow and healthRow.value == "4.25M", "large numbers abbreviated", healthRow and healthRow.value)
ns.chardb.statsShow.health = false
ns.RefreshAll()

local critRow = findRow("stats", "Crit")
check(critRow ~= nil and critRow.value == "21.34%", "melee crit used for a non-Intellect spec", critRow and critRow.value)

local versRow = findRow("stats", "Versatility")
check(versRow ~= nil and versRow.value == "7.60%", "versatility sums rating bonus and versatility bonus", versRow and versRow.value)

check(findRow("stats", "Stamina") == nil, "stats disabled by default are not drawn")

ns.chardb.statsShow.stamina = true
ns.RefreshAll()
check(findRow("stats", "Stamina") ~= nil, "enabling a stat adds its row")
ns.chardb.statsShow.stamina = false
ns.RefreshAll()

check(findRow("stats", "Stagger") == nil, "stagger off by default like other niche stats")
mock.stagger.percent = 12.5
ns.chardb.statsShow.stagger = true
ns.RefreshAll()
local staggerRow = findRow("stats", "Stagger")
check(staggerRow ~= nil and staggerRow.value == "12.50%",
    "stagger stat reads from GetStaggerPercentage", staggerRow and staggerRow.value)
ns.chardb.statsShow.stagger = false
ns.RefreshAll()

--------------------------------------------------------------------------------
section("Combat module")
--------------------------------------------------------------------------------

local PLAYER = "Player-1234-ABCDEF"
local PET = "Pet-0-1234"
local ENEMY = "Creature-0-9999"
local MINE_PET_FLAGS = 0x00000001 + 0x00001000

mock.inCombat = true
mock.Fire("PLAYER_REGEN_DISABLED")

-- SPELL_DAMAGE: amount sits at index 15.
mock.FireCombatLog(mock.now, "SPELL_DAMAGE", false, PLAYER, "Player", 0, 0, ENEMY, "Target", 0, 0,
    12345, "Frostbolt", 16, 60000, 0, 16, 0, 0, 0, false)

-- SWING_DAMAGE: amount sits at index 12.
mock.FireCombatLog(mock.now, "SWING_DAMAGE", false, PLAYER, "Player", 0, 0, ENEMY, "Target", 0, 0,
    40000, 0, 1, 0, 0, 0, false)

mock.Advance(10)
mock.RunTickers()

local dpsRow = findRow("combat", "DPS")
check(dpsRow ~= nil, "DPS row rendered")
check(dpsRow and dpsRow.value == "10.0K", "damage from both payload layouts counted (100k over 10s)", dpsRow and dpsRow.value)

-- Healing must exclude overhealing.
mock.FireCombatLog(mock.now, "SPELL_HEAL", false, PLAYER, "Player", 0, 0, PLAYER, "Player", 0, 0,
    2061, "Heal", 2, 50000, 30000, 0, false)
mock.RunTickers()

local hpsRow = findRow("combat", "HPS")
check(hpsRow and hpsRow.value == "2000", "overhealing excluded from HPS (20k effective over 10s)", hpsRow and hpsRow.value)

-- Damage taken is tracked separately from damage done.
ns.db.combat.showDamageTaken = true
mock.FireCombatLog(mock.now, "SPELL_DAMAGE", false, ENEMY, "Target", 0, 0, PLAYER, "Player", 0, 0,
    999, "Smash", 1, 30000, 0, 1, 0, 0, 0, false)
mock.RunTickers()

local dtpsRow = findRow("combat", "DTPS")
check(dtpsRow and dtpsRow.value == "3000", "incoming damage tracked as DTPS", dtpsRow and dtpsRow.value)

-- Enemy damage must not inflate the player's own DPS.
dpsRow = findRow("combat", "DPS")
check(dpsRow and dpsRow.value == "10.0K", "enemy damage did not count towards player DPS", dpsRow and dpsRow.value)

-- Pet damage respects the includePets setting.
mock.FireCombatLog(mock.now, "SPELL_DAMAGE", false, PET, "Pet", MINE_PET_FLAGS, 0, ENEMY, "Target", 0, 0,
    111, "Claw", 1, 20000, 0, 1, 0, 0, 0, false)
mock.RunTickers()
dpsRow = findRow("combat", "DPS")
check(dpsRow and dpsRow.value == "12.0K", "pet damage counted when includePets is on", dpsRow and dpsRow.value)

ns.db.combat.includePets = false
mock.FireCombatLog(mock.now, "SPELL_DAMAGE", false, PET, "Pet", MINE_PET_FLAGS, 0, ENEMY, "Target", 0, 0,
    111, "Claw", 1, 20000, 0, 1, 0, 0, 0, false)
mock.RunTickers()
dpsRow = findRow("combat", "DPS")
check(dpsRow and dpsRow.value == "12.0K", "pet damage ignored when includePets is off", dpsRow and dpsRow.value)

-- Leaving combat freezes the fight clock.
mock.inCombat = false
mock.Fire("PLAYER_REGEN_ENABLED")
local frozen = findRow("combat", "Last Fight")
check(frozen ~= nil, "fight duration label switches out of combat")
mock.Advance(30)
mock.RunTickers()
local stillFrozen = findRow("combat", "Last Fight")
check(stillFrozen and stillFrozen.value == frozen.value, "fight clock does not advance out of combat",
    stillFrozen and stillFrozen.value)

-- A new pull starts a fresh segment.
mock.inCombat = true
mock.Fire("PLAYER_REGEN_DISABLED")
mock.Advance(5)
mock.RunTickers()
dpsRow = findRow("combat", "DPS")
check(dpsRow and dpsRow.value == "0", "new pull resets fight damage", dpsRow and dpsRow.value)
mock.inCombat = false
mock.Fire("PLAYER_REGEN_ENABLED")

--------------------------------------------------------------------------------
section("Damage meter fallback (Patch 12.0)")
--------------------------------------------------------------------------------

-- Combat.lua decides whether C_DamageMeter exists once, at module-load time,
-- so exercising that path means loading a second, independent instance with
-- the API already in place - not toggling a global against the instance
-- already under test above. Only Core/Init.lua and Modules/Combat.lua are
-- needed; db/UI are stubbed directly rather than booting the whole addon.
-- Nothing later in this file fires ADDON_LOADED or PLAYER_LOGIN again, so
-- this instance's own (otherwise-unusable) copies of those handlers are
-- never invoked and can't cross-talk with the instance above.
mock.damageMeterSessions = {}
C_DamageMeter = {
    GetCombatSessionFromType = function(sessionType, meterType)
        return mock.damageMeterSessions[sessionType .. ":" .. meterType]
    end,
    ResetCombatSessions = function()
        mock.damageMeterResetCalled = true
    end,
}
-- Merged onto the shared Enum table rather than replacing it - a full
-- reassignment here would silently wipe out any Enum members the mock's
-- baseline setup (or code loaded after this point) relies on.
Enum = Enum or {}
Enum.DamageMeterSessionType = { Overall = 0, Current = 1, Expired = 2 }
Enum.DamageMeterType = { DamageDone = 0, Dps = 1, HealingDone = 2, Hps = 3, DamageTaken = 7 }

local function SetMeterAmount(sessionType, meterType, amount)
    mock.damageMeterSessions[sessionType .. ":" .. meterType] = {
        combatSources = {
            -- A second source first, so picking the local player's row
            -- actually has to look past it rather than just taking index 1.
            { isLocalPlayer = false, totalAmount = 999999, amountPerSecond = 999999 },
            { isLocalPlayer = true, totalAmount = amount, amountPerSecond = amount },
        },
    }
end

local meterRendered = {}
local ns2 = mock.LoadAddon("Upkeep", { "Core\\Init.lua", "Core\\Theme.lua", "Modules\\Combat.lua" }, "Upkeep")
check(ns2:GetModule("Combat") ~= nil, "an instance loaded with C_DamageMeter present still builds its Combat module")

ns2.playerGUID = PLAYER
ns2.db = { combat = {
    enabled = true, includePets = false, showDPS = true, showHPS = true,
    showDamageTaken = true, showCombatTime = true, showSessionTotals = true,
} }
ns2.UI = { SetSection = function(_, id, rows) meterRendered[id] = rows or {} end }

local function meterRow(label)
    for _, row in ipairs(meterRendered.combat or {}) do
        if row.label == label then return row end
    end
    return nil
end

SetMeterAmount(1, 1, 4321) -- current/dps
SetMeterAmount(1, 3, 2222) -- current/hps
SetMeterAmount(1, 7, 1111) -- current/taken
SetMeterAmount(0, 1, 4321) -- overall/dps, for the session row below

local Combat2 = ns2:GetModule("Combat")
Combat2:OnEnable()

check(meterRow("DPS") and meterRow("DPS").value == "4321",
    "meter-sourced DPS reads the current session's dps metric", meterRow("DPS") and meterRow("DPS").value)
check(meterRow("HPS") and meterRow("HPS").value == "2222",
    "meter-sourced HPS picks the isLocalPlayer row out of several sources", meterRow("HPS") and meterRow("HPS").value)
check(meterRow("DTPS") and meterRow("DTPS").value == "1111",
    "meter-sourced DTPS reads the DamageTaken metric", meterRow("DTPS") and meterRow("DTPS").value)
check(meterRow("Session DPS") and meterRow("Session DPS").value == "4321",
    "session rows read the Overall session type instead of Current", meterRow("Session DPS") and meterRow("Session DPS").value)

-- No session yet (e.g. before the first pull) falls back to 0 instead of erroring.
mock.damageMeterSessions = {}
Combat2:Update()
check(meterRow("DPS") and meterRow("DPS").value == "0",
    "a missing session reports 0 rather than erroring", meterRow("DPS") and meterRow("DPS").value)

-- Resetting the session asks the game's own meter to clear too.
mock.damageMeterResetCalled = false
Combat2:ResetSession()
check(mock.damageMeterResetCalled == true, "resetting the session also resets the game's meter")

-- The slash-command report still renders when sourced from the meter.
SetMeterAmount(1, 1, 500)
local report = Combat2:GetReport()
check(report:find("500 dps", 1, true) ~= nil, "the combat report reads its dps figure from the meter too", report)

--------------------------------------------------------------------------------
section("Procs module")
--------------------------------------------------------------------------------

mock.ClearAuras()
mock.AddAura(377097, 12)
mock.Fire("UNIT_AURA", "player")

local procRow = findRow("procs", "Trinket Proc")
check(procRow ~= nil, "auto-detected proc rendered")
check(procRow and procRow.icon == 136116, "proc row carries the spell icon", procRow and procRow.icon)

-- Long buffs (flasks, food) must not be treated as procs.
mock.AddAura(12472, 3600)
mock.Fire("UNIT_AURA", "player")
check(findRow("procs", "Icy Veins") == nil, "buffs longer than maxDuration are ignored")

mock.ClearAuras()
mock.Fire("UNIT_AURA", "player")

-- Watched spells show their state even with no aura up.
local ok, result = ns:GetModule("Procs"):Watch(190319)
check(ok, "watching a valid spell succeeds", result)
check(findRow("procs", "Combustion") ~= nil, "watched spell shows while ready")

local readyRow = findRow("procs", "Combustion")
check(readyRow and readyRow.value == "ready", "ready watched spell labelled", readyRow and readyRow.value)

mock.cooldowns[190319] = { start = mock.now, duration = 120 }
ns:GetModule("Procs"):Update()
local cdRow = findRow("procs", "Combustion")
check(cdRow and cdRow.value == "2:00", "watched spell shows cooldown remaining", cdRow and cdRow.value)
check(cdRow and cdRow.desaturate == true, "cooldown row is desaturated")

-- The global cooldown should never read as "on cooldown".
mock.cooldowns[190319] = { start = mock.now, duration = 1.5 }
ns:GetModule("Procs"):Update()
local gcdRow = findRow("procs", "Combustion")
check(gcdRow and gcdRow.value == "ready", "global cooldown is not reported as a cooldown", gcdRow and gcdRow.value)

-- An active aura takes priority over cooldown display.
mock.cooldowns[190319] = { start = mock.now, duration = 120 }
mock.AddAura(190319, 10, 3)
ns:GetModule("Procs"):Update()
local activeRow = findRow("procs", "Combustion")
check(activeRow and activeRow.value == "10.0s", "active aura shows remaining duration", activeRow and activeRow.value)
check(activeRow and activeRow.label == "Combustion (3)", "stack count shown", activeRow and activeRow.label)

local unwatched = ns:GetModule("Procs"):Unwatch(190319)
check(unwatched, "unwatching removes the spell")
check(#ns.chardb.watch == 0, "watch list empty after unwatch")

local badWatch, reason = ns:GetModule("Procs"):Watch(999999)
check(not badWatch, "watching an unknown spell ID is rejected", reason)

--------------------------------------------------------------------------------
section("Aura access blocked")
--------------------------------------------------------------------------------

local Procs = ns:GetModule("Procs")

mock.cooldowns[190319] = nil
Procs:Watch(190319)
mock.AddAura(190319, 10, 1)
mock.Fire("UNIT_AURA", "player")
check(findRow("procs", "Combustion") ~= nil, "watched spell reads normally before any refusal")
check(not Procs:AurasBlocked(), "AurasBlocked reports false while reads are working")

-- Content that refuses aura access outright must not crash the addon.
mock.aurasBlocked = true
local updateOk = pcall(function() Procs:Update() end)
check(updateOk, "a refused aura read does not error out of Update")
check(Procs:AurasBlocked(), "AurasBlocked reports true once a read is refused")

local blockedRow = findRow("procs", "Combustion")
check(blockedRow and blockedRow.value == "ready",
    "a refused aura read falls back to ready rather than erroring", blockedRow and blockedRow.value)

-- /up scan reports the refusal rather than claiming there are no buffs.
local scanLines, scanBlocked = Procs:ScanAuras()
check(#scanLines == 0 and scanBlocked == true, "ScanAuras reports blocked instead of an empty buff list")

-- The refusal is not retried on every tick; it holds for a back-off window
-- even after the underlying API would succeed again.
mock.aurasBlocked = false
check(Procs:AurasBlocked(), "refusal is not cleared before the retry window elapses")

mock.Advance(5.1)
check(not Procs:AurasBlocked(), "aura reads resume once the retry window elapses")
Procs:Update()
local recoveredRow = findRow("procs", "Combustion")
check(recoveredRow and recoveredRow.value == "4.9s",
    "watched spell reads normally again once unblocked", recoveredRow and recoveredRow.value)

Procs:Unwatch(190319)
mock.ClearAuras()

--------------------------------------------------------------------------------
section("Buffs module")
--------------------------------------------------------------------------------

local Buffs = ns:GetModule("Buffs")
mock.spells[6673] = { name = "Battle Shout", icon = 1 }
mock.spells[1459] = { name = "Arcane Intellect", icon = 2 }
mock.spells[99101] = { name = "Well Fed", icon = 3 }
mock.spells[99102] = { name = "Flask of the Whispered Pact", icon = 4 }

mock.ClearAuras()
mock.inGroup = false
Buffs:Update()
check(findRow("buffs", "Battle Shout") == nil, "raid buffs are not checked while solo")

mock.inGroup = true
Buffs:Update()
check(findRow("buffs", "Battle Shout") ~= nil, "a missing raid buff is flagged while grouped")
check(findRow("buffs", "Skyfury") ~= nil, "every tracked raid buff is checked")

mock.AddAura(6673, 3600)
mock.Fire("UNIT_AURA", "player")
check(findRow("buffs", "Battle Shout") == nil, "an active raid buff is no longer flagged")
check(findRow("buffs", "Arcane Intellect") ~= nil, "other missing raid buffs are still flagged")

check(findRow("buffs", "Well Fed") == nil, "self buffs are not checked until enabled")
ns.db.buffs.showSelfBuffs = true
ns.RefreshAll()
check(findRow("buffs", "Well Fed") ~= nil, "missing food is flagged once self buffs are enabled")
check(findRow("buffs", "Flask") ~= nil, "missing flask is flagged once self buffs are enabled")

mock.AddAura(99101, 3600)
mock.AddAura(99102, 3600)
mock.Fire("UNIT_AURA", "player")
check(findRow("buffs", "Well Fed") == nil, "food matched by name clears the row regardless of spell ID")
check(findRow("buffs", "Flask") == nil, "a flask matched by its \"Flask of\" prefix clears the row")

ns.db.buffs.enabled = false
ns.RefreshAll()
check(#(rendered.buffs or {}) == 0, "disabling the buffs section clears its rows")

ns.db.buffs.enabled = true
ns.db.buffs.showSelfBuffs = false
mock.inGroup = false
mock.ClearAuras()
ns.RefreshAll()

--------------------------------------------------------------------------------
section("Per-character stat visibility")
--------------------------------------------------------------------------------

check(ns.StatsShown() == ns.chardb.statsShow, "stat visibility reads from the character DB")
check(ns.db.stats.show == nil, "stat visibility no longer lives in the shared DB")

-- Toggling on this character must not touch the account-wide table.
ns.StatsShown().armor = true
ns.RefreshAll()
check(findRow("stats", "Armor") ~= nil, "enabling armor on this character shows it")
check(ns.db.stats.show == nil, "toggling did not write back to the shared DB")
ns.StatsShown().armor = false
ns.RefreshAll()

-- A second character starts from its own defaults, not the first one's choices.
local firstCharacter = UpkeepCharDB
ns.StatsShown().speed = true
UpkeepCharDB = nil
ns.InitConfig()
check(ns.chardb ~= firstCharacter, "a new character gets a fresh character DB")
check(ns.chardb.statsShow.speed == false, "second character does not inherit the first character's choices",
    ns.chardb.statsShow.speed)
check(firstCharacter.statsShow.speed == true, "first character keeps its own choice")

-- An upgrade from the account-wide layout carries the old choice across once.
UpkeepDB.stats.show = { crit = false, armor = true, haste = false }
UpkeepCharDB = nil
ns.InitConfig()
check(ns.chardb.statsShow.crit == false, "legacy account-wide choice migrated (crit off)", ns.chardb.statsShow.crit)
check(ns.chardb.statsShow.armor == true, "legacy account-wide choice migrated (armor on)", ns.chardb.statsShow.armor)
check(ns.chardb.migratedStatVisibility == true, "migration is marked done")

-- Migration must not run twice and undo later changes.
ns.chardb.statsShow.crit = true
ns.InitConfig()
check(ns.chardb.statsShow.crit == true, "migration does not re-run over later changes")

UpkeepDB.stats.show = nil
UpkeepCharDB = firstCharacter
ns.InitConfig()
ns.RefreshAll()

--------------------------------------------------------------------------------
section("Tooltips")
--------------------------------------------------------------------------------

-- Find the live row frames so hover can be simulated the way the client does.
local function rowFrameFor(key)
    for _, frame in ipairs(mock.frames) do
        if frame.tooltipKey == key then return frame end
    end
    return nil
end

ns.db.tooltips = true
ns.RefreshAll()
ns.UI:Relayout()

local hoverTip = UpkeepHoverTooltip
check(hoverTip ~= nil, "addon owns a hover tooltip frame rather than reusing GameTooltip")

local function dumpOf(frame)
    return table.concat(frame:Dump(), " | ")
end

local critFrame = rowFrameFor("crit")
check(critFrame ~= nil, "stat rows carry a tooltip key")
check(critFrame and critFrame.mouseEnabled == true, "tooltip rows accept mouse input")
check(critFrame and critFrame.propagateClicks == true, "clicks still pass through for click-through locking")

critFrame.scripts.OnEnter(critFrame)
local dump = dumpOf(hoverTip)
check(hoverTip.shown, "hovering a stat shows a tooltip")
check(dump:find("Crit=21.34%%") ~= nil, "tooltip headline shows the stat and its value", dump)
check(dump:find("Rating=1009") ~= nil, "tooltip shows the underlying combat rating", dump)
check(dump:find("From rating=4.50%%") ~= nil, "tooltip shows what the rating converts to", dump)
check(dump:find("critically strike") ~= nil, "tooltip explains what the stat does", dump)
check(dump:find("Click to keep this on screen") ~= nil, "hover tooltip explains how to pin it", dump)

-- Leaving the row must not hide instantly, or the mouse could never reach the
-- tooltip to click it.
critFrame.scripts.OnLeave(critFrame)
check(hoverTip.shown, "tooltip survives leaving the row long enough to be reached")
mock.RunAfter()
check(not hoverTip.shown, "tooltip hides once the grace period expires")

-- Moving into the tooltip cancels the pending hide.
critFrame.scripts.OnEnter(critFrame)
critFrame.scripts.OnLeave(critFrame)
hoverTip.scripts.OnEnter(hoverTip)
mock.RunAfter()
check(hoverTip.shown, "entering the tooltip cancels the scheduled hide")

-- Versatility reports both halves of what it does.
local versFrame = rowFrameFor("vers")
versFrame.scripts.OnEnter(versFrame)
dump = dumpOf(hoverTip)
check(dump:find("Damage and healing done") ~= nil, "versatility tooltip covers damage done", dump)
check(dump:find("Damage taken reduced by") ~= nil, "versatility tooltip covers damage reduction", dump)

-- Mastery's description comes from the current spec's actual mastery spell,
-- not a generic fixed line - it's the one secondary stat whose effect is
-- entirely spec-specific.
local masteryFrame = rowFrameFor("mastery")
masteryFrame.scripts.OnEnter(masteryFrame)
dump = dumpOf(hoverTip)
check(dump:find("Increases the damage of your Frostbolt and Frozen Orb.", 1, true) ~= nil,
    "mastery tooltip describes the current spec's actual mastery effect", dump)
check(dump:find("Improves a bonus specific to your specialisation.", 1, true) == nil,
    "the generic mastery description is replaced, not just supplemented", dump)

-- Some specs have two mastery spells; both get described.
mock.spellDescriptions[999889] = "Your critical strikes heal nearby allies."
mock.masterySpells = { 999888, 999889 }
masteryFrame.scripts.OnEnter(masteryFrame)
dump = dumpOf(hoverTip)
check(dump:find("Frostbolt and Frozen Orb", 1, true) ~= nil and dump:find("critical strikes heal", 1, true) ~= nil,
    "both mastery spells are described when a spec has two", dump)

-- No mastery spell data available (e.g. no spec chosen yet) falls back to
-- the generic description rather than showing nothing.
mock.masterySpells = {}
masteryFrame.scripts.OnEnter(masteryFrame)
dump = dumpOf(hoverTip)
check(dump:find("Improves a bonus specific to your specialisation.", 1, true) ~= nil,
    "falls back to the generic description when no mastery spell data is available", dump)

mock.masterySpells = { 999888 }
masteryFrame.scripts.OnEnter(masteryFrame)

-- Spell text loads asynchronously in the real client: an empty description
-- just means it has not arrived yet, not that there is none. That must
-- trigger a load request (so a later hover gets the real text) rather than
-- being treated as a permanent absence.
mock.spellDescriptions[999888] = nil
mock.spellDataRequested[999888] = nil
masteryFrame.scripts.OnEnter(masteryFrame)
dump = dumpOf(hoverTip)
check(dump:find("Improves a bonus specific to your specialisation.", 1, true) ~= nil,
    "not-yet-loaded spell text falls back to the generic description for now", dump)
check(mock.spellDataRequested[999888] == true,
    "an empty description triggers a load request for next time")

mock.spellDescriptions[999888] = "Increases the damage of your Frostbolt and Frozen Orb."
masteryFrame.scripts.OnEnter(masteryFrame)
dump = dumpOf(hoverTip)
check(dump:find("Increases the damage of your Frostbolt and Frozen Orb.", 1, true) ~= nil,
    "once the spell data loads, a later hover shows the real description", dump)

-- Stagger only carries a second line when the API actually hands one back.
ns.chardb.statsShow.stagger = true
mock.stagger = { percent = 12.5, againstTarget = nil }
ns.RefreshAll()
ns.UI:Relayout()
local staggerFrame = rowFrameFor("stagger")
check(staggerFrame ~= nil, "stagger row carries a tooltip key once enabled")
staggerFrame.scripts.OnEnter(staggerFrame)
dump = dumpOf(hoverTip)
check(dump:find("Of health staggered=12.50%%") ~= nil, "stagger tooltip shows the staggered portion", dump)
check(dump:find("From your current target") == nil,
    "no target-specific line when the API does not provide one", dump)

mock.stagger.againstTarget = 30
ns.RefreshAll()
staggerFrame.scripts.OnEnter(staggerFrame)
dump = dumpOf(hoverTip)
check(dump:find("From your current target=30.00%%") ~= nil,
    "stagger tooltip adds the target-specific figure when the API provides one", dump)

ns.chardb.statsShow.stagger = false
mock.stagger = { percent = 0, againstTarget = nil }
ns.RefreshAll()
ns.UI:Relayout()

-- Primary stat breaks down base versus buffs.
local primaryFrame = rowFrameFor("primary")
primaryFrame.scripts.OnEnter(primaryFrame)
dump = dumpOf(hoverTip)
check(dump:find("Base=8300") ~= nil, "primary tooltip shows base value", dump)
check(dump:find("From gear and buffs=%+200") ~= nil, "primary tooltip shows the buffed portion", dump)

-- Item level distinguishes equipped from overall.
local ilvlFrame = rowFrameFor("ilvl")
ilvlFrame.scripts.OnEnter(ilvlFrame)
dump = dumpOf(hoverTip)
check(dump:find("Equipped=636.2") ~= nil, "item level tooltip shows equipped", dump)
check(dump:find("Overall=639.5") ~= nil, "item level tooltip shows overall", dump)

-- Proc rows defer to the game's own spell tooltip.
ns:GetModule("Procs"):Watch(190319)
ns.RefreshAll()
ns.UI:Relayout()
local procFrame = rowFrameFor(190319)
check(procFrame ~= nil, "proc rows carry the spell ID as their tooltip key")
procFrame.scripts.OnEnter(procFrame)
check(hoverTip.spellID == 190319, "proc tooltip uses the real spell tooltip", hoverTip.spellID)
ns:GetModule("Procs"):Unwatch(190319)

--------------------------------------------------------------------------------
section("Pinned tooltips")
--------------------------------------------------------------------------------

local Tooltips = ns.Tooltips
Tooltips:UnpinAll()

-- Clicking the hover tooltip pins whatever is under the cursor.
local armorFrame = rowFrameFor("armor")
check(armorFrame == nil, "armor row hidden by default")
ns.StatsShown().armor = true
ns.RefreshAll()
ns.UI:Relayout()
armorFrame = rowFrameFor("armor")
check(armorFrame ~= nil, "armor row present once enabled")

armorFrame.scripts.OnEnter(armorFrame)
hoverTip.scripts.OnMouseDown(hoverTip)
check(Tooltips:IsPinned("stats", "armor"), "clicking the hover tooltip pins it")
check(not hoverTip.shown, "hover tooltip closes once pinned")

local pinned = _G.UpkeepPinnedTooltip1
check(pinned ~= nil and pinned.shown, "a pinned tooltip frame is shown")
dump = dumpOf(pinned)
check(dump:find("Armor=") ~= nil, "pinned tooltip shows the stat", dump)
check(dump:find("physical damage") ~= nil, "pinned tooltip keeps the explanation", dump)
check(dump:find("Click to keep this on screen") == nil, "pinned tooltip drops the pin hint", dump)

-- Armor can become secret while in combat (Patch 12.0+); an uncomparable
-- posBuff must only cost the optional "From buffs" line, not the rest of
-- the tooltip - this is the exact shape of a real reported bug where the
-- whole armor tooltip went blank in combat.
mock.armor.posBuff = "50" -- throws on comparison, exactly like a secret value would
mock.RunTickers()
local secretDump = dumpOf(pinned)
check(secretDump:find("Base=") ~= nil,
    "an uncomparable posBuff does not take down the rest of the armor tooltip", secretDump)
check(secretDump:find("Effective=") ~= nil, "effective armor still shows too", secretDump)
check(secretDump:find("Physical damage reduction") ~= nil, "the reduction line still shows too", secretDump)
mock.armor.posBuff = 0
mock.RunTickers()

-- Mirrors the mock's C_PaperDollInfo curve (wow_mock.lua), which in turn
-- mirrors Blizzard's real published armor formula (Stats.lua's
-- EstimateArmorConstant) - shared by every expected-reduction helper below.
local function RealArmorConstant(level)
    local k = 400 + 85 * level
    if level > 59 then k = k + 4.5 * (level - 59) end
    if level > 80 then k = k + 20 * (level - 80) end
    if level > 85 then k = k + 22 * (level - 85) end
    return k
end

-- Real armor mitigation caps at 75% regardless of level, most visible at
-- low target levels where the constant above is small.
local function RealArmorRatio(armor, level)
    local ratio = armor / (armor + RealArmorConstant(level))
    return ratio > 0.75 and 0.75 or ratio
end

-- Pinned content refreshes on its own so the numbers stay live. Change the
-- underlying value and the pin must pick it up without being re-opened.
local function expectedReduction(armor)
    return string.format("%.2f%%", RealArmorRatio(armor, 80) * 100)
end

check(dumpOf(pinned):find("Effective=4500") ~= nil, "pinned tooltip starts with the current armor")
check(dumpOf(pinned):find("Physical damage reduction=" .. expectedReduction(4500), 1, true) ~= nil,
    "pinned tooltip shows damage reduction for the current armor", dumpOf(pinned))
mock.armor.effective = 7777
mock.RunTickers()
check(dumpOf(pinned):find("Effective=7777") ~= nil, "pinned tooltip refreshes from its provider",
    dumpOf(pinned))
check(dumpOf(pinned):find("Physical damage reduction=" .. expectedReduction(7777), 1, true) ~= nil,
    "pinned tooltip's damage reduction refreshes along with the armor value", dumpOf(pinned))
mock.armor.effective = 4500

-- Once the player has a hostile target, the reduction figure comes from
-- GetArmorEffectivenessAgainstTarget instead of the same-level estimate.
local function expectedTargetReduction(armor)
    return string.format("%.2f%%", RealArmorRatio(armor, 1) * 100)
end

mock.target = { exists = true, hostile = true }
mock.RunTickers()
check(dumpOf(pinned):find("Physical damage reduction=" .. expectedTargetReduction(4500), 1, true) ~= nil,
    "armor tooltip switches to the target-specific reduction once you have a hostile target", dumpOf(pinned))
check(dumpOf(pinned):find("Against your current target") ~= nil,
    "the target-specific figure is labelled as such", dumpOf(pinned))

mock.target = { exists = true, hostile = false }
mock.RunTickers()
check(dumpOf(pinned):find("Physical damage reduction=" .. expectedReduction(4500), 1, true) ~= nil,
    "a friendly target falls back to the same-level estimate rather than using GetArmorEffectivenessAgainstTarget",
    dumpOf(pinned))

mock.target = { exists = false, hostile = false }
mock.RunTickers()

--------------------------------------------------------------------------------
-- Armor reduction manual estimate
--
-- The screenshot behind this bug showed Base/Effective rendering fine but no
-- reduction line at all: the live curve call failed (an unreadable
-- effective-armor value, in real play) and previously that just meant no
-- line. A manual estimate should fill in instead, clearly labelled so it is
-- never mistaken for the real number.
--------------------------------------------------------------------------------

local function expectedEstimate(armor, level)
    return string.format("%.2f%%", RealArmorRatio(armor, level) * 100)
end

local realGetArmorEffectiveness = C_PaperDollInfo.GetArmorEffectiveness
C_PaperDollInfo.GetArmorEffectiveness = function() error("blocked, exactly like a secret effective-armor value would be") end
mock.RunTickers()

local blockedDump = dumpOf(pinned)
check(blockedDump:find("Base=", 1, true) ~= nil,
    "base and effective still show when the live reduction call fails", blockedDump)
check(blockedDump:find("Physical damage reduction (estimated)=" .. expectedEstimate(4500, 80), 1, true) ~= nil,
    "a manual estimate fills in, clearly labelled, once the live figure is unreadable", blockedDump)
check(blockedDump:find("Live figure unavailable right now", 1, true) ~= nil,
    "the estimate explains it is not the live number", blockedDump)

C_PaperDollInfo.GetArmorEffectiveness = realGetArmorEffectiveness
mock.RunTickers()
check(dumpOf(pinned):find("Physical damage reduction=" .. expectedReduction(4500), 1, true) ~= nil,
    "the live figure returns once the API works again", dumpOf(pinned))

-- The estimate must not be trusted forever: if it ever disagrees with a
-- live result by more than a point (a future level squish or curve rework
-- would do exactly this, silently), it has to stop offering itself rather
-- than keep showing a confidently wrong number.
C_PaperDollInfo.GetArmorEffectiveness = function() return 0.5 end
mock.RunTickers()
check(dumpOf(pinned):find("Physical damage reduction=50.00%", 1, true) ~= nil,
    "sanity check: the deliberately-wrong mock curve is actually in effect", dumpOf(pinned))

C_PaperDollInfo.GetArmorEffectiveness = function() error("blocked, exactly like a secret effective-armor value would be") end
mock.RunTickers()
local mismatchedDump = dumpOf(pinned)
check(mismatchedDump:find("Physical damage reduction (estimated)", 1, true) == nil,
    "the estimate stops offering itself once it has disagreed with a live result", mismatchedDump)
check(mismatchedDump:find("Damage reduction unavailable right now", 1, true) ~= nil,
    "an honest unavailable note takes its place instead", mismatchedDump)

C_PaperDollInfo.GetArmorEffectiveness = realGetArmorEffectiveness
mock.RunTickers()

-- Hovering an already-pinned row should not double up.
armorFrame.scripts.OnEnter(armorFrame)
check(not hoverTip.shown, "hovering an already-pinned row does not reopen the hover tooltip")

-- Pinning the same thing twice is rejected.
local okDup, reasonDup = Tooltips:Pin("stats", "armor")
check(not okDup, "pinning the same row twice is rejected", reasonDup)

-- A second pin stacks below the first rather than covering it.
local okSecond = Tooltips:Pin("stats", "crit")
check(okSecond, "a second row can be pinned")
check(#Tooltips:ListPinned() == 2, "two pins tracked", #Tooltips:ListPinned())

-- Pins survive a reload: they are saved and restored by key.
check(ns.db.pinnedTooltips["stats:armor"] ~= nil, "pin saved to the database")
local savedPins = ns.db.pinnedTooltips
Tooltips:UnpinAll()
check(#Tooltips:ListPinned() == 0, "unpin all clears every pin")
check(next(savedPins) == nil, "unpinning clears the saved entries too")

ns.db.pinnedTooltips["stats:crit"] = { section = "stats", key = "crit" }
Tooltips:RestoreSaved()
check(Tooltips:IsPinned("stats", "crit"), "saved pins are restored")

-- Closing via the frame's own close button works.
local critPin
for _, frame in ipairs(mock.frames) do
    if frame.pinID == "stats:crit" then critPin = frame end
end
check(critPin ~= nil, "pinned frame carries its id")
critPin.closeButton.scripts.OnClick()
check(not Tooltips:IsPinned("stats", "crit"), "close button unpins")

-- Right-clicking a pin closes it; left-clicking does not.
Tooltips:Pin("stats", "crit")
critPin = nil
for _, frame in ipairs(mock.frames) do
    if frame.pinID == "stats:crit" then critPin = frame end
end
critPin.scripts.OnMouseUp(critPin, "LeftButton")
check(Tooltips:IsPinned("stats", "crit"), "left-clicking a pin does not close it")
critPin.scripts.OnMouseUp(critPin, "RightButton")
check(not Tooltips:IsPinned("stats", "crit"), "right-clicking a pin closes it")

-- Pinning with nothing hovered reports why rather than erroring.
Tooltips:HideHover()
local okNone, reasonNone = Tooltips:PinHovered()
check(not okNone, "pinning with nothing hovered is rejected", reasonNone)

-- The key binding entry point is defined and safe to call.
check(type(Upkeep_PinHoveredTooltip) == "function", "binding handler is a global function")
check(pcall(Upkeep_PinHoveredTooltip), "binding handler runs without a hovered row")
check(BINDING_NAME_UPKEEP_PIN_TOOLTIP ~= nil, "binding has a display name")

-- Resetting config must not leave orphaned pins on screen.
Tooltips:Pin("stats", "armor")
ns.ResetConfig()
check(#Tooltips:ListPinned() == 0, "reset all closes pinned tooltips")

ns.StatsShown().armor = false
ns.db.tooltips = true
ns.RefreshAll()
ns.UI:Relayout()

-- Disabling tooltips releases the mouse entirely.
ns.db.tooltips = false
ns.RefreshAll()
ns.UI:Relayout()
critFrame = rowFrameFor("crit")
check(critFrame == nil, "disabling tooltips clears tooltip keys from rows")

ns.db.tooltips = true
ns.RefreshAll()
ns.UI:Relayout()

--------------------------------------------------------------------------------
section("Layout")
--------------------------------------------------------------------------------

ns.UI:Relayout()
local frame = ns.UI.frame
check(frame:GetHeight() > 20, "frame height grows to fit its rows", frame:GetHeight())
check(frame:GetWidth() == ns.db.width, "frame width follows config", frame:GetWidth())

-- Shrinking the content must hide the leftover rows rather than leave stale text.
local before = frame:GetHeight()
ns.db.stats.enabled = false
ns.db.combat.enabled = false
ns.db.procs.enabled = false
ns.RefreshAll()
ns.UI:Relayout()
check(frame:GetHeight() < before, "frame shrinks when sections are disabled", frame:GetHeight())

ns.db.stats.enabled = true
ns.db.combat.enabled = true
ns.db.procs.enabled = true
ns.RefreshAll()

--------------------------------------------------------------------------------
section("Themes")
--------------------------------------------------------------------------------

check(ns.Colors ~= nil, "shared color palette exists")
check(ns.Colors.good[1] < 0.5 and ns.Colors.bad[1] > 0.5,
    "good/bad status colors are not just green vs. red",
    table.concat(ns.Colors.good, ",") .. " / " .. table.concat(ns.Colors.bad, ","))

check(#ns.THEME_ORDER == 3, "three built-in themes registered", #ns.THEME_ORDER)
for _, key in ipairs(ns.THEME_ORDER) do
    check(ns.THEMES[key] and ns.THEMES[key].label ~= nil, "theme '" .. key .. "' has a display label")
end

check(ns.db.theme == "minimal", "minimal is the default theme")
check(frame.backdrop.edgeFile == "Interface\\Buttons\\WHITE8X8", "minimal theme uses a flat hairline border")

-- Switching themes rebuilds the backdrop from the new preset.
ns.db.theme = "bordered"
ns.RefreshAll()
check(frame.backdrop.edgeFile == "Interface\\Tooltips\\UI-Tooltip-Border",
    "bordered theme swaps in the tooltip border texture", frame.backdrop.edgeFile)
check(frame.backdrop.edgeSize == 16, "bordered theme uses a wider edge to fit the texture", frame.backdrop.edgeSize)

-- Class-colored reads the player's actual class each time, not a fixed color.
ns.db.theme = "classcolor"
mock.class = "MAGE"
ns.RefreshAll()
local mageEdge = { unpack(frame.backdropBorderColor) }
check(mageEdge[3] and mageEdge[3] > 0.8, "class-colored border reflects the Mage class color (blue)", table.concat(mageEdge, ","))

mock.class = "WARRIOR"
ns.RefreshAll()
local warriorEdge = { unpack(frame.backdropBorderColor) }
check(warriorEdge[1] ~= mageEdge[1] or warriorEdge[3] ~= mageEdge[3],
    "class-colored border changes when the player's class does",
    table.concat(mageEdge, ",") .. " -> " .. table.concat(warriorEdge, ","))

-- An unrecognized class (or a client without C_ClassColor) falls back rather
-- than erroring, and a bad theme key falls back to minimal.
mock.class = "SOME_FUTURE_HERO_CLASS"
check(pcall(ns.RefreshAll), "an unrecognized class does not error the class-colored theme")

ns.db.theme = "not-a-real-theme"
check(pcall(ns.RefreshAll), "an unknown theme key does not error")
check(frame.backdrop.edgeFile == "Interface\\Buttons\\WHITE8X8", "an unknown theme key falls back to minimal")

ns.db.theme = "minimal"
mock.class = "MAGE"
ns.RefreshAll()

--------------------------------------------------------------------------------
section("Visibility")
--------------------------------------------------------------------------------

ns.db.hidden = false
ns.db.hideOutOfCombat = false
ns.UI:UpdateVisibility()
check(frame:IsShown(), "overlay visible by default")

local nowVisible = ns.UI:Toggle()
check(not nowVisible and not frame:IsShown(), "toggle hides the overlay")

-- A manual hide must survive combat, which is what a naive implementation
-- would clobber.
mock.inCombat = true
mock.Fire("PLAYER_REGEN_DISABLED")
check(not frame:IsShown(), "entering combat does not un-hide a manually hidden overlay")
mock.inCombat = false
mock.Fire("PLAYER_REGEN_ENABLED")

ns.UI:Toggle()
check(frame:IsShown(), "toggle shows it again")

ns.db.hideOutOfCombat = true
ns.UI:UpdateVisibility()
check(not frame:IsShown(), "hide-out-of-combat hides while resting")
mock.inCombat = true
ns.UI:UpdateVisibility()
check(frame:IsShown(), "hide-out-of-combat shows in combat")
mock.inCombat = false
ns.db.hideOutOfCombat = false
ns.UI:UpdateVisibility()

--------------------------------------------------------------------------------
section("Slash commands")
--------------------------------------------------------------------------------

local handler = SlashCmdList.UPKEEP

local function run(input)
    local silenced = _G.print
    _G.print = function() end
    local success, err = pcall(handler, input)
    _G.print = silenced
    return success, err
end

local commands = {
    "", "", "help", "lock", "unlock", "config", "scan", "dps",
    "scale 1.5", "width 240", "font 14", "stat", "stat crit",
    "watch", "watch 190319", "watch list", "unwatch 190319", "tooltips", "tooltips",
    "pin", "pin crit", "pin crit", "pins", "unpin crit", "unpin all", "pin bogus",
    "reset dps", "reset pos", "nonsense", "scale bogus", "watch bogus",
}

for _, command in ipairs(commands) do
    local success, err = run(command)
    check(success, "/up " .. (command == "" and "(toggle)" or command), err)
end

check(ns.db.scale == 1.5, "scale command applied", ns.db.scale)
check(ns.db.width == 240, "width command applied", ns.db.width)
check(ns.db.fontSize == 14, "font command applied", ns.db.fontSize)
check(ns.db.locked == false, "lock then unlock leaves it unlocked")

-- Out-of-range values must be rejected rather than applied.
run("scale 99")
check(ns.db.scale == 1.5, "out-of-range scale rejected", ns.db.scale)

run("reset all")
check(ns.db.scale == 1.0, "reset all restores defaults", ns.db.scale)

--------------------------------------------------------------------------------
section("Character panel")
--------------------------------------------------------------------------------

local charFrame = _G.UpkeepCharacterPanel
check(charFrame ~= nil, "character panel frame is created")
check(not charFrame:IsShown(), "character panel starts hidden")

local function DumpCharPanel()
    local out = {}
    for _, line in ipairs(charFrame.lines) do
        if line.left:IsShown() then
            out[#out + 1] = (line.left:GetText() or "") .. "=" .. (line.right:GetText() or "")
        end
    end
    return table.concat(out, " | ")
end

-- The mock, like everywhere else in this file, only fires a script when
-- told to - Show()/Hide() alone do not trigger OnShow/OnHide. The addon's
-- own OnConfigChanged checks PaperDollFrame:IsShown() directly (not just
-- reacting to the event), so the state and the script both have to change
-- together to accurately stand in for the real client opening the tab.
local function OpenPaperDoll()
    PaperDollFrame:Show()
    PaperDollFrame.scripts.OnShow(PaperDollFrame)
end

local function ClosePaperDoll()
    PaperDollFrame:Hide()
    PaperDollFrame.scripts.OnHide(PaperDollFrame)
end

-- Head and Chest are enchanted (with real descriptive text); Shoulder,
-- Feet, and Ring 2 are not. Off Hand is left empty (a two-handed weapon
-- equipped) and must be skipped rather than flagged. Waist and Neck are
-- equipped but cannot be enchanted this expansion, so they should never
-- appear in the enchant list at all. Ring 1 and Main Hand carry gems.
local LONG_ENCHANT_TEXT = "Increases your maximum health by a very large amount indeed"
mock.Equip(INVSLOT_HEAD, 1001, 500, 636, "+50 Versatility")
mock.Equip(INVSLOT_SHOULDER, 1002, 0, 620)
mock.Equip(INVSLOT_CHEST, 1003, 700, 639, LONG_ENCHANT_TEXT)
mock.Equip(INVSLOT_FEET, 1004, 0, 610)
mock.Equip(INVSLOT_FINGER1, 1005, 300, 630, nil, { "Deadly Amber", false })
mock.Equip(INVSLOT_FINGER2, 1006, 0, 623)
mock.Equip(INVSLOT_MAINHAND, 1007, 900, 645, nil, { "Quick Ruby", "Solid Sapphire" })
mock.Unequip(INVSLOT_OFFHAND)
mock.Equip(INVSLOT_NECK, 1008, 0, 636)
mock.Equip(INVSLOT_WAIST, 1009, 0, 636)

OpenPaperDoll()
check(charFrame:IsShown(), "showing the character panel tab shows the insights panel")

local charDump = DumpCharPanel()
check(charDump:find("Equipped=636.2", 1, true) ~= nil, "shows equipped item level", charDump)
check(charDump:find("Overall=639.5", 1, true) ~= nil, "shows overall item level", charDump)
check(charDump:find("Lowest slot=Feet (610)", 1, true) ~= nil,
    "identifies the lowest item level slot", charDump)

check(charDump:find("Head=+50 Versatility", 1, true) ~= nil,
    "an enchanted slot shows the enchant's actual name/effect text", charDump)
check(charDump:find("Shoulder=missing", 1, true) ~= nil, "an unenchanted slot reads as missing", charDump)
check(charDump:find("Ring 2=missing", 1, true) ~= nil, "ring enchant status is checked too", charDump)
check(charDump:find("Off Hand", 1, true) == nil, "an empty slot is not flagged at all", charDump)
check(charDump:find("Waist", 1, true) == nil,
    "a slot that cannot be enchanted this expansion is not listed", charDump)

check(charDump:find(LONG_ENCHANT_TEXT, 1, true) == nil,
    "a long enchant description is truncated rather than overflowing the panel", charDump)
check(charDump:find(LONG_ENCHANT_TEXT:sub(1, 15), 1, true) ~= nil,
    "the truncated text still starts with the real description", charDump)

check(charDump:find("Gems", 1, true) ~= nil, "a Gems section appears when something is socketed", charDump)
check(charDump:find("Ring 1=Deadly Amber", 1, true) ~= nil, "shows the gem socketed in a ring", charDump)
check(charDump:find("Ring 1=Prismatic Socket", 1, true) ~= nil,
    "a second, empty socket on the same item is reported too, not skipped", charDump)
check(charDump:find("Main Hand=Quick Ruby", 1, true) ~= nil, "shows the first gem socketed in a weapon", charDump)
check(charDump:find("Main Hand=Solid Sapphire", 1, true) ~= nil, "shows a second gem in the same slot too", charDump)

check(charDump:find("Crit=21.34%", 1, true) ~= nil, "stat context includes crit", charDump)
check(charDump:find("1009 rating", 1, true) ~= nil, "stat context includes the underlying rating", charDump)

-- Switching tabs (PaperDollFrame hides) takes the panel away with it.
ClosePaperDoll()
check(not charFrame:IsShown(), "hiding the character tab hides the insights panel")

-- Turning the feature off must not bring the panel back with the tab.
OpenPaperDoll()
ns.db.characterPanel.enabled = false
ns.RefreshAll()
check(not charFrame:IsShown(), "disabling the feature hides the panel even while the tab is open")

ns.db.characterPanel.enabled = true
ns.RefreshAll()
check(charFrame:IsShown(), "re-enabling the feature shows the panel again while the tab is open")

-- Gear changes refresh the panel live.
mock.Equip(INVSLOT_SHOULDER, 1002, 450, 620)
mock.Fire("PLAYER_EQUIPMENT_CHANGED")
charDump = DumpCharPanel()
check(charDump:find("Shoulder=enchanted", 1, true) ~= nil,
    "enchanting a slot updates the panel on the next equipment-changed event", charDump)

ClosePaperDoll()

--------------------------------------------------------------------------------
section("Options panel")
--------------------------------------------------------------------------------

local options = ns:GetModule("Options")
check(options.category ~= nil, "settings category registered")
check(pcall(ns.OpenOptions), "opening options does not error")

-- The theme dropdown is backed by a number (an index into THEME_ORDER), not
-- a string: a mismatched setting type is exactly what surfaces later as an
-- assertion failure inside Blizzard's own control-building code.
local themeSetting = options.category.settingsByVariable["UP_theme"]
check(themeSetting ~= nil, "theme dropdown setting is registered")
check(themeSetting and themeSetting.varType == "number", "theme setting is numeric, not string",
    themeSetting and themeSetting.varType)
check(themeSetting and #themeSetting.options == #ns.THEME_ORDER,
    "theme dropdown offers one option per registered theme")
check(themeSetting and themeSetting.options[2].label == ns.THEMES[ns.THEME_ORDER[2]].label,
    "theme dropdown options are labelled from the theme registry")

check(themeSetting.get() == 1, "theme setting reads back the current (default) theme as index 1", themeSetting.get())
themeSetting.set(2)
check(ns.db.theme == ns.THEME_ORDER[2], "picking a dropdown option sets the matching theme key", ns.db.theme)
check(frame.backdrop.edgeFile == ns.THEMES[ns.THEME_ORDER[2]].edgeTexture,
    "picking a theme from the dropdown actually re-themes the panel", frame.backdrop.edgeFile)
themeSetting.set(1)
check(ns.db.theme == "minimal", "resetting the dropdown back to option 1 restores minimal")

--------------------------------------------------------------------------------
section("Ticker safety")
--------------------------------------------------------------------------------

-- Everything should keep running for a while without throwing.
local survived = pcall(function()
    for _ = 1, 50 do
        mock.Advance(0.1)
        mock.RunTickers()
        mock.Tick(0.1)
    end
end)
check(survived, "50 ticker cycles run without error")

--------------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
