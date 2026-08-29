# StatOverlay

A lightweight World of Warcraft overlay for **Retail (The War Within)** that puts your
character stats, live combat numbers, and active procs in one small movable panel.

No external libraries — it uses only the Blizzard API, so there is nothing to install
alongside it.

```
┌─────────────────────────┐
│ Stats                   │
│ Item Level        636.2 │
│ Agility            8500 │
│ Crit             21.34% │
│ Haste            14.77% │
│ Mastery          31.02% │
│ Versatility       7.60% │
│                         │
│ Combat                  │
│ DPS               10.0K │
│ HPS               2.00K │
│ Time              0:24  │
│                         │
│ Procs                   │
│ [] Trinket Proc    8.4s │
│ [] Combustion      2:00 │
└─────────────────────────┘
```

## Install

1. Copy the **`StatOverlay`** folder (not the repository root) into:
   - Windows: `World of Warcraft\_retail_\Interface\AddOns\`
   - macOS: `World of Warcraft/_retail_/Interface/AddOns/`
2. Restart the game, or run `/reload` if it is already running.
3. Make sure **StatOverlay** is ticked in the AddOns list on the character select screen.

The folder name must stay `StatOverlay` so it matches `StatOverlay.toc`.

## Usage

Drag the panel to move it (while unlocked), then `/so lock` to fix it in place.
Locking also lets mouse clicks pass through, so it will not get in the way in combat.

### Commands

| Command | What it does |
| --- | --- |
| `/so` | Show or hide the overlay |
| `/so lock` / `/so unlock` | Lock or unlock dragging |
| `/so config` | Open the options panel |
| `/so scale <0.5-2>` | Set the overlay scale |
| `/so width <120-320>` | Set the overlay width |
| `/so font <8-20>` | Set the font size |
| `/so stat` | List stat rows and whether each is shown |
| `/so stat <name>` | Toggle a stat row for this character, e.g. `/so stat haste` |
| `/so tooltips` | Toggle hover tooltips |
| `/so dps` | Print a summary of the last fight |
| `/so watch <spellID>` | Track a spell's proc and cooldown |
| `/so unwatch <spellID>` | Stop tracking a spell |
| `/so watch list` | Show tracked spells |
| `/so scan` | List your current buffs with their spell IDs |
| `/so reset dps` | Clear combat totals |
| `/so reset pos` | Move the overlay back to the centre |
| `/so reset all` | Restore every setting to default |

Everything is also available under **Options → AddOns → StatOverlay**.

## What it shows

### Stats

Item level, your spec's primary stat, and the secondary ratings. Crit follows your
spec: Intellect specs get the best spell-school crit, everyone else gets melee crit,
matching what the character sheet reports. Stamina, health, leech, avoidance, speed,
and armor are available but off by default — turn on whatever you care about.

**Which stats show is per character**, so your tank can display armor and avoidance
while your mage shows haste and mastery. If you used an earlier version where this
was account-wide, your existing choice is copied onto each character the first time
it logs in, so nothing resets underneath you.

### Tooltips

Hovering any row explains what it is and shows the numbers behind it — for a
secondary stat, the combat rating you have and how much of the percentage that
rating is buying you; for your primary stat, base versus what gear and buffs added;
for versatility, both the damage done and the damage reduction halves. Proc rows
show the game's own spell tooltip.

Rows pass clicks through even while accepting hover, so tooltips do not cost you the
click-through that makes a locked overlay unobtrusive. Turn them off with
`/so tooltips` if you would rather the overlay ignore the mouse entirely.

### Combat

DPS, HPS, damage taken, and fight duration, parsed from the combat log:

- **Overhealing is excluded** from HPS, so the number reflects healing that landed.
- **Pet and guardian damage** is counted towards your DPS (toggleable).
- Each pull starts a fresh segment. A separate session total keeps accumulating
  until you run `/so reset dps`.
- The fight clock only advances while you are actually in combat.

### Procs

Two sources feed this list:

- **Auto-detect** (on by default) surfaces any buff on you shorter than 60 seconds,
  which covers most trinket, talent, and set-bonus procs with no configuration.
  The duration cap is what keeps flasks, food, and raid buffs out of the list.
- **Watched spells** are ones you add by ID with `/so watch`. These stay on the list
  whether the proc is up, on cooldown, or ready, so you can use it as a cooldown
  tracker too. The 1.5s global cooldown is deliberately never shown as a cooldown.

To find a spell ID, get the buff on you and run `/so scan`.

## Configuration storage

- `StatOverlayDB` — display settings (scale, width, opacity, tooltips, section
  toggles), shared across all characters.
- `StatOverlayCharDB` — which stats are shown and the proc watch list, per
  character, since both are class- and role-specific.

`/so reset all` restores display settings and this character's stat rows. It leaves
the watch list alone: that is curated data, not a setting.

## Development

The addon is plain Lua with no build step. Source layout:

```
StatOverlay/
  StatOverlay.toc      load order and metadata
  Core/Init.lua        namespace, module registry, event bus
  Core/Config.lua      saved-variable defaults
  Core/Options.lua     Settings API panel
  Core/Commands.lua    slash commands
  UI/Overlay.lua       the frame and row-layout engine
  Modules/Stats.lua    character stats
  Modules/Combat.lua   combat log metrics
  Modules/Procs.lua    proc and cooldown tracking
```

Modules are plain tables registered with `ns:NewModule(name)`. Core calls `OnInit`
after saved variables load, `OnEnable` at `PLAYER_LOGIN`, and `OnConfigChanged`
whenever settings change. Modules never touch frames — they hand the UI a list of
rows via `ns.UI:SetSection(id, rows, tooltipProvider)` and the layout is rebuilt once
per frame.

Tooltips follow the same rule: a row carries a `tooltipKey`, and its section carries
a provider that turns that key into displayable data. Nothing is built until the
mouse is actually over a row, which matters because stats refresh on `UNIT_AURA` and
that fires constantly in combat.

### Tests

There is a mock of the WoW API so the addon can be loaded and driven outside the
game. It catches load-order mistakes, nil API calls, and combat-log parsing bugs:

```sh
lua5.1 tests/run.lua      # 115 checks
```

Syntax-check everything (WoW runs Lua 5.1):

```sh
find StatOverlay -name '*.lua' -exec luac5.1 -p {} +
```

The mock is deliberately strict about event names: registering an event it does not
know about fails the test rather than being silently skipped, which is what would
happen in game.

## Game version

`## Interface: 110200` in the `.toc` targets The War Within. When a patch bumps the
interface number, update that line or the addon shows as out of date. The current
value is shown by `/dump select(4, GetBuildInfo())` in game.

Retail API calls that moved namespaces (`C_Spell`, `C_SpecializationInfo`,
`C_UnitAuras`) are accessed through fallbacks to the old globals, so the addon
degrades rather than erroring if a call is not where it expects.

## Known limitations

- Absorbed damage (`SPELL_ABSORBED`) is not counted towards damage taken.
- DPS is damage divided by time in combat, not by active time, so it will read lower
  than meters that discount idle periods.
- Auto-detected procs are filtered purely by duration, so a short buff that is not a
  proc can appear. Turn auto-detect off and use an explicit watch list to be precise.
