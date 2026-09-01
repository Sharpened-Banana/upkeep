-- tests/run.lua
-- Loads StatOverlay against the mock API and drives it through a session.
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
    "UI\\Overlay.lua",
    "UI\\Tooltips.lua",
    "Modules\\Stats.lua",
    "Modules\\Combat.lua",
    "Modules\\Procs.lua",
    "Core\\Options.lua",
    "Core\\Commands.lua",
}

-- Keep addon chat output from drowning the test log.
local realPrint = print
local addonOutput = {}
_G.print = function(...)
    addonOutput[#addonOutput + 1] = table.concat({ mock and "" or "" }, "") .. tostring((select(1, ...)))
end

local ns = mock.LoadAddon("StatOverlay", FILES, "StatOverlay")

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

check(ns.name == "StatOverlay", "namespace carries the addon name")
check(ns.UI ~= nil, "UI module registered at load time")

mock.Fire("ADDON_LOADED", "SomeOtherAddon")
check(ns.db == nil, "ignores ADDON_LOADED for other addons")

mock.Fire("ADDON_LOADED", "StatOverlay")
check(ns.db ~= nil, "saved variables initialised")
check(ns.db.scale == 1.0, "defaults applied", ns.db and ns.db.scale)
check(ns.chardb ~= nil and type(ns.chardb.watch) == "table", "per-character watch list created")
check(ns.UI.frame ~= nil, "overlay frame built")
check(SlashCmdList.STATOVERLAY ~= nil, "slash command registered")

-- Defaults must not be shared by reference, or one character's settings would
-- leak into another's.
ns.chardb.statsShow.crit = false
check(ns.DEFAULTS.stats.enabled == true, "defaults are deep-copied, not referenced")
ns.chardb.statsShow.crit = true

mock.Fire("PLAYER_LOGIN")
check(ns.playerGUID == "Player-1234-ABCDEF", "player GUID cached on login")

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
local firstCharacter = StatOverlayCharDB
ns.StatsShown().speed = true
StatOverlayCharDB = nil
ns.InitConfig()
check(ns.chardb ~= firstCharacter, "a new character gets a fresh character DB")
check(ns.chardb.statsShow.speed == false, "second character does not inherit the first character's choices",
    ns.chardb.statsShow.speed)
check(firstCharacter.statsShow.speed == true, "first character keeps its own choice")

-- An upgrade from the account-wide layout carries the old choice across once.
StatOverlayDB.stats.show = { crit = false, armor = true, haste = false }
StatOverlayCharDB = nil
ns.InitConfig()
check(ns.chardb.statsShow.crit == false, "legacy account-wide choice migrated (crit off)", ns.chardb.statsShow.crit)
check(ns.chardb.statsShow.armor == true, "legacy account-wide choice migrated (armor on)", ns.chardb.statsShow.armor)
check(ns.chardb.migratedStatVisibility == true, "migration is marked done")

-- Migration must not run twice and undo later changes.
ns.chardb.statsShow.crit = true
ns.InitConfig()
check(ns.chardb.statsShow.crit == true, "migration does not re-run over later changes")

StatOverlayDB.stats.show = nil
StatOverlayCharDB = firstCharacter
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

local hoverTip = StatOverlayHoverTooltip
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

local pinned = _G.StatOverlayPinnedTooltip1
check(pinned ~= nil and pinned.shown, "a pinned tooltip frame is shown")
dump = dumpOf(pinned)
check(dump:find("Armor=") ~= nil, "pinned tooltip shows the stat", dump)
check(dump:find("physical damage") ~= nil, "pinned tooltip keeps the explanation", dump)
check(dump:find("Click to keep this on screen") == nil, "pinned tooltip drops the pin hint", dump)

-- Pinned content refreshes on its own so the numbers stay live. Change the
-- underlying value and the pin must pick it up without being re-opened.
local function expectedReduction(armor)
    return string.format("%.2f%%", (armor / (armor + 2500)) * 100)
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
check(type(StatOverlay_PinHoveredTooltip) == "function", "binding handler is a global function")
check(pcall(StatOverlay_PinHoveredTooltip), "binding handler runs without a hovered row")
check(BINDING_NAME_STATOVERLAY_PIN_TOOLTIP ~= nil, "binding has a display name")

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

local handler = SlashCmdList.STATOVERLAY

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
    check(success, "/so " .. (command == "" and "(toggle)" or command), err)
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
section("Options panel")
--------------------------------------------------------------------------------

local options = ns:GetModule("Options")
check(options.category ~= nil, "settings category registered")
check(pcall(ns.OpenOptions), "opening options does not error")

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
