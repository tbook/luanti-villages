# Market days (#281)

Engineering design for [#281](https://github.com/tbook/luanti-villages/issues/281).
This document records the agreed gameplay and divides implementation into small,
ordered tickets. It does not enable markets. Numerical placement and pacing
defaults below are initial engineering choices to verify in playtesting.

## Player experience

On holidays, the gathering after church becomes a market around the bell.
Every eligible trader tries to reserve a place for two adjacent tables. Sellers
stand between their tables and the bell, facing outward in cardinal directions.
Villagers without stalls wander and converse around the market. There is no
shopping simulation yet; players can still trade by clicking a seller normally.

Each profession has two representative goods. These need not match the seller's
actual offers. Tables, invisible frames, and goods use existing game nodes and
items, with ordinary digging, theft, and protection behavior. Sellers do not
repair or restock during the market. They remove goods and then tables shortly
before dinner, at slightly different times. Interrupted stalls are cleaned up.

No terrain editing, new furniture nodes, special carrying animations, carried
inventories, customer queues, profession changes, trade initialization, or
changes to the trading economy are needed.

### Schedule

Ordinary days remain as they are. Holiday hours become:

| Role | Hours | Activity |
|---|---|---|
| Ordinary adult | 05:30–07:00 | Putter |
| Ordinary adult | 07:00–10:30 | Church |
| Ordinary adult | 10:30–15:00 | Market |
| Ordinary adult | 15:00–17:30 | Tavern |
| Ordinary adult | 17:30–18:30 | Home |
| Ordinary adult | 18:30–05:30 | Sleep |
| Cleric | Before 10:30 | Existing pulpit/service schedule |
| Cleric | From 10:30 | Same market, tavern, home and sleep hours as ordinary adults |
| Keeper | 07:00–08:00 | Putter |
| Keeper | 08:00–14:30 | Free |
| Keeper | 14:30–18:30 | Staff tavern |
| Keeper | 18:30–19:00 | Home |
| Keeper | 19:00–07:00 | Sleep |

Keepers do not open market stalls. Children retain their existing behavior and
are not added to the gathering by this issue. Thunder continues to override the
schedule and sends everyone to bed. Missing/unreachable bells fall back to
puttering; an absent or full market is not a reason to change professions.

## Existing code and integration decisions

The design was checked against the installed VoxeLibre villager and mcl_mobs
sources, mcl_decor tables, mcl_itemframes, and the installed Luanti Lua API.

| Existing code | Use/change |
|---|---|
| `common.lua` | Move holiday tavern start to 15000 ticks and keeper staffing to 14500. Keep the internal stage name `bell`; the market is the new behavior of this stage. |
| `bell.lua` | Keep bell discovery, travel fallback, and browsing. Dispatch sellers through the market controller instead of also moving them as browsers. |
| `cells.lua`, `common.lua` | Use the existing standing-space and floor checks. Do not add another passability model. |
| `navigation.lua`, `follower.lua` | Use `gopath` and its queued planner/follower for the seller's walk. Do not implement another pathfinder. |
| `conversation.lua`, `wander.lua` | Existing browser movement and conversations. Add the market session to conversation's busy fields. |
| `far_trips.lua` | Preserve the existing `bell` errand and `_villages_bell` target so sellers are not sent home by vanilla's 50-node rule. |
| `music.lua` | Its independent holiday start is currently 15500. Move it to 15000; stop remains 17500. |
| `init.lua` | Load the new modules once and pass shared instances to `bell.install`. |
| `flock.lua` | Continue receiving the same bell module and helpers. A holiday seller is not doing a shepherd's work-stage grazing walk. |

Keeping `bell` and its existing `_villages_*` fields avoids a stage rename across
the mod, tests, diagnostics, and probes. Player-facing documentation calls the
period a market. The existing warning/fallback when VoxeLibre's `get_activity`
global is absent must remain intact.

Add three small modules, each loaded once rather than independently `dofile`d by
several consumers:

* `market_site.lua`: layout, bounded candidate search, and in-memory reservations.
* `market_props.lua`: ordinary prop placement, ownership metadata, packing, and
  independent orphan cleanup. Register callbacks at normal mod load time.
* `market.lua`: profession goods and the seller session controller. This module
  does not install a second independent movement wrapper; `bell.lua` calls it.

Load `market_props.lua` at the top level of `init.lua`, obtaining mod storage and
registering its LBM/ABM while the current mod is known. Its frame interaction
wrappers can be installed once in `register_on_mods_loaded`, after stock node
definitions are available. Pass this same instance into the seller controller
when installing bell behavior; do not load a second prop registry there.

The interface names below are a proposed internal contract. Keep equivalent
behavior if implementation exposes fewer helpers; do not build a generic event
or activity framework for this feature.

## Stall geometry and reservations

Use two `mcl_decor:table_wooden` nodes and two
`mcl_itemframes:invisible_frame` nodes immediately above them. Frame orientation
is floor-mounted (`core.dir_to_wallmounted({x=0, y=-1, z=0})`), as for a plate.
Let `T` be the first table cell, `N` the outward cardinal direction, and `R` the
cardinal direction to its right. The second table is `T + R`. The seller stands
at `T - N`, facing `N`.

Viewed from above, with the bell toward the bottom:

```text
                 outward / customers
                  .  .  .  .       front clearance
                  .  T  T  .       two tables
                  .  S  .  .       seller and rear clearance
                  .  .  .  .       second rear clearance
                       bell
```

The inclusive rectangle is side offsets -1..2 and outward offsets -2..1,
relative to `T`. It covers 16 ground columns: one block clear at either end and
in front, and two behind. Validate the whole rectangle at one node level with
body clearance for standing villagers and safe supporting floor. Only table
and frame destinations must be strictly air; do not erase grass, carpet, snow,
or other existing nodes to place props. No writes to the ground layer.

Initial search defaults:

* Table-pair midpoint 4–12 nodes horizontally from the bell's ground center.
  The surrounding clearance may extend up to 14 nodes from that center.
* Try bell-center height and one node above/below, using actual standing
  positions from the existing cell helpers. Reject unsupported/uneven patches;
  do not require support for every slab or stair configuration.
* Orient outward along the dominant horizontal axis from bell to table-pair
  midpoint; break diagonal ties consistently. Recheck orientation using the
  midpoint after constructing the two-table layout.
* At most 48 sampled horizontal candidates per attempt. Examine at most four
  candidates per villager tick; hold still during this short search. No world
  scans on every tick after the attempt ends, no forced loading/emerging.
* Reject protected prop destinations using `core.is_protected(pos, "")`,
  unloaded nodes, and layouts whose table destinations would intersect a player
  or another villager at placement time. Keep normal game protection enabled.

Reserve the two table columns and the seller column exclusively, including the
head space. An exclusive column cannot overlap another stall's clearance
rectangle, and a new clearance rectangle cannot contain another stall's
exclusive columns. Clearance rectangles may overlap each other: aisles can be
shared. Scope these checks by height as well as X/Z. These symmetric rules
prevent tables or sellers from occupying someone else's required aisle.

Candidate validation plus reservation is one synchronous operation with no
yield between the final conflict check and insertion. Reservations are held by
villager id plus a session token, renewed while searching/walking/selling, and
released on every exit. Use a ten-real-second expiry as a fallback for missed
callbacks. Two traders therefore cannot both choose the same stall. There is
no fairness, profession ordering, or global village packing algorithm.

Suggested site operations: `begin_search(center, owner)`,
`step_search(search)` (pending/found/exhausted), `renew(reservation)`,
`release(reservation)`, and `valid(layout, reservation)` for arrival rechecks.
Site search only chooses a geometrically suitable patch; the normal route
planner establishes reachability.

## Representative goods

Use a fixed pair for each supported profession, one item per frame. Fixed pairs
are enough for the first release; there is no need for a random goods catalog.
Candidate pairs below use the installed game's names; implementation must
check `core.registered_items` and test all 13 professions. If one item is
unavailable, use the other in both frames. If neither exists, browse and log a
single reason for the attempt. Unknown professions browse too.

| Profession | First item | Second item |
|---|---|---|
| farmer | `mcl_farming:bread` | `mcl_core:apple` |
| fisherman | `mcl_fishing:fish_cooked` | `mcl_fishing:salmon_cooked` |
| fletcher | `mcl_bows:arrow` | `mcl_bows:bow` |
| shepherd | `mcl_wool:white` | `mcl_tools:shears` |
| librarian | `mcl_books:book` | `mcl_books:bookshelf` |
| cartographer | `mcl_maps:empty_map` | `mcl_itemframes:frame` |
| armorer | `mcl_armor:helmet_iron` | `mcl_armor:boots_iron` |
| leatherworker | `mcl_armor:helmet_leather` | `mcl_armor:boots_leather` |
| butcher | `mcl_mobitems:cooked_porkchop` | `mcl_mobitems:cooked_chicken` |
| weapon_smith | `mcl_tools:axe_iron` | `mcl_tools:sword_iron` |
| tool_smith | `mcl_tools:pick_stone` | `mcl_tools:shovel_stone` |
| cleric | `mesecons:redstone` | `mcl_core:lapis` |
| mason | `mcl_core:brick` | `mcl_core:stonebrick` |

Use the settled profession after the existing role wrappers have run; in
particular, do not read the fisherman's transient vanilla demotion as a lasting
profession change. Do not read or modify `_trades`, trade tiers, job claims,
or player trading inventories.

## Prop ownership and cleanup

Ordinary nodes keep the implementation and removal-of-mod behavior simple, but
need durable ownership tags. A node name alone is never proof of ownership.

Each of the four placed nodes carries namespaced metadata containing a schema
version, unique stall token, villager id, creation day, and its table/frame role
and paired position. Generate tokens from a monotonically increasing mod-storage
counter, advancing it before placement. Do not reuse tokens for a reloaded
seller. A normal dug-and-replaced node has no tag and must be left alone even if
its name and position are identical to the original.

The runtime prop registry maps a token to its layout, seller ObjectRef, day,
packing deadline, and renewed lease. It is deliberately not serialized. All
cleanup paths use the same idempotent ownership checks. They must also reject
metadata whose node name/role does not match an expected market prop.

### Placement and normal packing

1. Recheck all destinations, reservation, clearance, protection, and occupants
   after the seller arrives. Do not overwrite anything if this recheck fails.
2. Create the runtime record, place/tag the tables and empty frames, then put
   one item in each frame's `main` inventory and call
   `mcl_itemframes.update_entity`. Use node APIs that run construction callbacks;
   do not use a schematic or VoxelManip for these four nodes.
3. If placement partially fails, remove only props already created with this
   token. No deferred callback may finish an abandoned placement.
4. At packing, empty generated stock before removing frames: the stock frame's
   destructor otherwise drops it. Call `mcl_itemframes.remove_entity` as needed,
   remove owned frames, then remove owned tables. Removing tables does not
   create table item drops; normal player digging still does.

Use a one-second packing interval between clearing frames and removing tables,
while the seller remains at its position. Abort cleanup can remove everything
immediately. Cleanup never replenishes missing nodes or inventories.

### Player changes

Wrap the existing invisible frame's `on_rightclick` and `on_rotate` callbacks
once, preserving arguments, return values, and normal protection checks. For a
tagged market frame, a permitted player interaction marks its inventory as
player-touched **before** delegating. This marker persists in node metadata.
These callbacks are the upstream inventory mutation paths; direct metadata
inventory moves are denied by the stock frame.

On cleanup, a player-touched frame's remaining stack is dropped intact at the
frame position before its inventory is cleared. An untouched generated stack
is simply cleared. This preserves a player's inserted item, including an item
identical to the original stock, without implementing item provenance. A stolen
item stays with its thief. Untagged player replacement frames are never removed.

If removing an owned table would remove support from an unowned replacement
node above it, relinquish that table: clear only its market tags and leave it
as ordinary player furniture. Likewise, if the node above is unloaded, defer
the support decision until it can be inspected. A player's deliberate additions
may therefore leave ordinary furniture; untouched abandoned stalls must vanish.
Do not delete player metadata or inventories while relinquishing ownership.

Do not add callback wrappers for unrelated tables/frames or intercept normal
villager trade formspecs. Compatible mods that directly rewrite inventories or
preserve ownership metadata while moving nodes are outside this first release.

### Cleanup without a running seller

Install both callbacks against exactly the stock table and invisible-frame
names, returning immediately when the market ownership tag is absent:

* An LBM with `run_at_every_load = true` checks props whenever their mapblock
  activates. It removes stale tagged props when no matching live runtime record
  exists, or that record is no longer valid. A valid current seller's props
  survive neighboring block activation; do not remove every tagged node blindly.
* An ABM with interval 5 seconds, chance 1, and `catch_up = false` runs the same
  check in active blocks. It handles removed sellers, expired leases, missed
  callbacks, time jumps, and props kept active after their seller has gone.

A runtime record is valid only for the matching current holiday/day and market
window, a live eligible seller still owning that session, an unexpired lease,
and a deadline not yet passed (allow the one-second packing phase). Thunder,
following a player, a changed profession, removal of the bell, and leaving the
seller position invalidate the session. A missing bell node in an unloaded
block is unknown, not evidence of removal.

Also clean up directly on `on_die`, `on_deactivate`, and departure from the
market stage. Chain existing callbacks, including the fisherman's deactivate
wrapper. Invalidate the runtime token before cleaning its loaded nodes.
Unavailable nodes are left for the LBM/ABM; never force-load the village for
cleanup. Cleanup operates per node/pair and must work when a stall crosses a
mapblock boundary or only a frame survives.

After a server restart the registry is empty, so old props are stale even if
the restart happens during the same market. No owner-activation grace period
or saved stall reconstruction is needed. LBMs run on **block activation**, not
every map read: inaccessible inactive blocks are cleaned when activated, rather
than proactively emerging terrain. With the mod disabled its cleanup cannot
run; remaining props are ordinary game nodes, not unknown nodes.

To prevent unloading and reloading a seller from generating repeated loot,
persist one new villager field: `_villages_market_stock_day`. Set it immediately
before the first prop writes, after successful arrival validation. A villager
that has already stocked this holiday browses after a reload or interruption.
An unloaded seller that had only been walking may try again. This is a small
guard against accidental restocking, not an inventory or economic simulation;
it also makes a partial setup failure consume that day's setup opportunity.

## Seller controller and movement ownership

Eligibility: an adult with `_id`, a supported profession/goods pair, not a
keeper, not following a player, and not already stocked today. Do not require
the player to have traded with it. Use the existing bell chosen from the bed
(or current position when bedless), not a second village lookup.

Suggested `market.tick(self, bell_session, dtime)` results are `browse`,
`walking`, and `holding`. Only `holding` asks bell's wrapper to return false and
skip mcl_mobs' subsequent state movement. A `walking` seller still needs the
normal follower updates. Searching, selling, and packing return `holding`;
reserve and start the walk before returning `walking`. Expose
`market.leave(self, reason)` for all exits.

| State | Behavior | Exit |
|---|---|---|
| No session | Check eligibility and once-per-activation attempt flag | Search, or browse |
| Searching | Examine bounded candidates; stand still; reserve first valid patch | Walk, or browse when exhausted |
| Walking | Renew reservation, use `gopath` to seller cell; no props yet | Sell on confirmed arrival; browse on failure/timeout |
| Selling | Renew reservation/prop lease; hold standing pose and outward yaw | Pack at deadline; abort on interruption |
| Packing | Clear goods/frames, wait one second, remove tables and release | Browse until tavern stage |
| Browsing | Use existing bell travel, wander and conversations | Normal stage handoff |

Arrival must be confirmed from the actual position and standing space, not
solely an asynchronous callback. Revalidate stage/session before acting on any
late callback. A failed or blocked route gets the existing navigation retries;
after those fail, browse rather than implementing another retry policy or
trying different stalls all afternoon. Reuse bell's distance-based walking
deadline and pause its accounting during player trading or an unrelated route.

Stop only routes and wander legs owned by this session. A new tavern route or
vanilla job-search route must survive market cleanup. In particular, invalidate
a pending market goto route as well as stopping a moving follower; otherwise a
queued result can start walking after the seller has given up. Use the existing
goto route identity/field checks from navigation, not an unconditional clear of
all route fields. If necessary, add a small cancellation helper with a focused
regression test; do not redesign navigation.

In `bell.lua`, acquire/validate the bell session as today, then dispatch the
seller before browser `join` starts a route. Successful sellers have no browser
wander anchor. Browser code runs only for a `browse` result. For `holding`, set
`order = "stand"`, zero horizontal walking velocity using existing mob helpers,
clear the seller's own wander leg, set standing animation/yaw, and return false
after role wrappers have run. Do not teleport a displaced seller back: abort
the stall if pushed more than one node from its selling position.

Market departure cleanup must happen before invoking inner wrappers that may
start the tavern/home route, as bell cleanup already does. Add transient market
fields to the serialization exclusion/activation reset list in the same style
as bell/church. Keep `_villages_market_stock_day` saved. Store no ObjectRefs,
reservations, arrival callbacks, or prop handles in saved state.

Initial pacing defaults:

* Choose a packing start once per seller at 14:45–14:55 game time. Frames clear
  first; tables disappear one real second later. At 15:00 force immediate final
  cleanup, even if the server skipped the chosen packing time.
* Do not begin setup after 14:30. A walker arriving after that cutoff browses.
* Do not restart an attempt after exhaustion, route failure, packing, robbery,
  or interruption in the same activation. Releasing a failed reservation lets
  later traders use that space.
* Increase the browser gathering radius from 4 to 14 during this holiday
  period, so visitors can reach the fronts of stalls. Retain short checked
  wander legs and conversations; no purposeful browsing targets yet.

These are constants initially, not new settings. Randomness is selected once
per session, never rerolled each tick. Track/log only state transitions and a
single fallback reason per attempt, with the usual `[living_villages]` prefix.

## Implementation tickets

Create child issues under #281 from these descriptions. Each ticket gets one
feature branch and PR, using its actual child issue number. Land in the order
below. Every ticket includes its own tests and must leave the existing suite
passing; do not postpone correctness tests to the final playtest ticket.
The early modules remain uninstalled until ticket 7, so incomplete cleanup
cannot create stalls in players' worlds.

### 1. Adjust holiday market and tavern hours

**Depends on:** none. **Files:** `common.lua`, `music.lua`, matching tests.

Move holiday guest tavern start to 15000 and keeper staffing to 14500. Leave
the stage named `bell` and all ordinary-day boundaries unchanged. Move holiday
music start to 15000 and fix stale timing comments in the touched code. Do not
add stalls or change gathering radius yet.

**Acceptance:** schedule tests cover both sides of 10:30, 14:30, 15:00, 17:30,
18:30 and 19:00 for worker/cleric/keeper; holiday detection across noon,
thunder, skip-tavern behavior and ordinary schedules still work. Update actual
holiday handoff expectations in `tests/bell.lua`, `tests/tavern.lua`, and
`tests/keeper.lua`; do not merely replace every occurrence of an old timestamp.
Music starts at 15:00, not during setup, and ends at 17:30.

### 2. Define and validate a two-table market layout

**Depends on:** none. **Files:** new `market_site.lua`, `tests/market_site.lua`.

Implement the cardinal layout descriptor, outward orientation, and read-only
site validation. Descriptor includes table/frame destinations, seller cell,
outward direction, exclusive columns and clearance columns. Accept injected
world/occupancy/protection readers for tests, or stub engine readers as existing
tests do. No reservations, searches, props, or entity wrappers in this ticket.

**Acceptance:** all four orientations and diagonal ties; exact clearance sizes;
safe floor/body space; uneven or unloaded patches; protected destinations;
preexisting grass/carpet/frame/table at write positions; player/villager at a
table destination; valid path-height floor. No map writes or terrain edits.

### 3. Add bounded stall search and reservations

**Depends on:** 2. **Files:** `market_site.lua`, its tests.

Implement incremental candidate search and synchronous conflict reservation,
with the defaults and symmetric aisle rules above. Expose renew/release and
expiry, and an arrival revalidation operation. Keep random generation
controllable in tests. Do not add pathfinding to the site module.

**Acceptance:** competing traders never reserve overlapping exclusive/aisle
space, including from opposite orientations; empty shared aisles are allowed;
different floors do not block each other incorrectly; exhaustion is bounded;
no more than four candidates are examined per step; release/expiry allows a
later trader to reserve; stale owner release cannot release a newer token;
arrival fails safely if the world changed.

### 4. Place and pack ordinary market props safely

**Depends on:** 2. **Files:** new `market_props.lua`, `tests/market_props.lua`.

Implement unique tokens, four tagged stock nodes, frame population/display,
partial-setup rollback, idempotent packing, and tagged-frame interaction
wrappers. Implement direct cleanup here, including preservation of player
items/replacements and support handling. Do not install this module in the
running mod yet; tests load it directly. Leave orphan callback registration to
the next ticket.

**Acceptance:** setup creates exactly two tables/two populated frames; failed
preflight writes nothing; partial failure removes only that token; untouched
packing produces no generated goods/table drops; theft does not restock;
same-name replacement nodes survive; player-inserted stacks retain metadata
when dropped during packing, including identical-name stock replacements;
untagged supported replacement nodes retain their support. All callbacks behave
normally for untagged frames and protected interactions. Repeated cleanup is
harmless. Tests must model stock destructor drops, not stub them away.

### 5. Recover orphaned props across unloads and restarts

**Depends on:** 4. **Files:** `market_props.lua`, its tests.

Add the runtime record/lease check and shared LBM/ABM cleanup entry point.
Test independent cleanup with no active villager controller. Verify callbacks
can be registered during normal load, without new custom nodes or world scans.
The module still remains uninstalled in `init.lua`.

**Acceptance:** fresh runtime registry plus persisted metadata removes old
props; an active current stall survives checks; stale day, expired lease,
removed seller, thunder, packing deadline and a clock jump clean up; ordinary
tables/frames are untouched. Exercise table/frame nodes split across blocks,
each block returning first, missing tables, missing frames, and unavailable
support checks. No forced loading, duplicate inventory drops, or permanent
runtime record leaks. Test LBM invocation before and after seller activation.

### 6. Implement the seller session controller without enabling it

**Depends on:** 3, 5. **Files:** new `market.lua`, `tests/market.lua`.

Add all profession goods, eligibility, state transitions, walking/arrival
validation, standing behavior, packing deadlines, and saved stock-day guard.
Use injected/shared site and prop modules plus the existing gopath API. Expose
`tick` and `leave`; test directly with a stub villager. No `init.lua` wiring or
second movement wrapper. If a navigation cancellation helper is needed, keep
that change small and include its regression test in this PR.

**Acceptance:** every supported profession tries without `_trades`; missing
goods degrade safely; child/keeper/unemployed/nitwit/unknown professions browse;
search/walk failure falls back once; props appear only after confirmed arrival;
trade pauses walking timeout; stolen/missing props are not repaired; displaced
seller aborts; late arrivals skip setup; packing timing is chosen once and
finishes by stage end; all exits release leases/reservations; pending callbacks
cannot resurrect an abandoned walk. Stock-day survives save/load, transient
state does not, and reloading an opened seller does not generate another set.

### 7. Integrate sellers with bell gathering and lifecycle hooks

**Depends on:** 1, 6. **Files:** `init.lua`, `bell.lua`, `conversation.lua`,
matching tests, `README.md`, `AGENTS.md` code map.

Load shared modules once, dispatch sellers and browsers through one bell
session, expand visitor radius, and add cleanup to stage departure, activation,
deactivation, and death while preserving existing wrapper chains. Exclude
sellers from conversations. Add brief player documentation and module map.
This is the first ticket that enables stalls in normal gameplay.

**Acceptance:** church-to-market and market-to-tavern handoffs work; sellers
never receive browser routes/anchors and browsers still converse; tavern/home
routes and unrelated job-search routes survive cleanup; trading with a seller
works normally; missing/dug/unreachable bells degrade to existing fallbacks;
far-from-bed sellers retain their errand; fisherman deactivate cleanup and
shepherd bell discovery still work. Verify the missing-`get_activity` warning
and fallback are preserved. Run the full Lua tests and syntax checks.

### 8. Add a reproducible market playtest and tune defaults

**Depends on:** 7. **Files:** a small fixture under `tools/lv_trips/builds/`
if the existing harness supports it cleanly, a scenario in
`docs/navigation-scenarios.md`, and only constants/tests justified by results.

Provide a repeatable way to observe a market in a spacious village and a
crowded/sloped one, plus a setup crossing mapblock boundaries. Use real game
frames/tables; stub tests cannot verify their visual placement or engine
activation/callback ordering. Reuse existing trip tooling where practical;
do not expand it into a new market simulation framework.

**Acceptance:** record seller count, placed stalls, fallback reasons, successful
walks, and props remaining after closing/revisiting. Check that sellers face
outward, players can reach them from the front, ordinary trading works, and
visitors circulate visibly. Rob a stall, insert a player item, replace a table
and a frame, unload the seller while props stay active, unload the whole area,
restart during market hours, revisit on an ordinary day, and trigger thunder.
Untouched market props must leave no week-long remnants, stolen goods must not
reappear on reload, and player replacements/items must survive. Observe setup
cost in a village with many traders; tune search batch/radii only on evidence.

## Validation and review boundaries

For each implementation PR, run the matching standalone Lua 5.1 tests and the
repository's required full test/syntax checks. Reuse fixtures; do not add tests
that only repeat a constant assignment. No runtime tests are necessary for this
design-only document.

Review tickets 4–5 for node ownership, inventory handling and real callback
semantics before enabling ticket 7. Review ticket 7 for movement ownership and
late queued routes. These are focused checks of two concrete failure modes,
not reasons to make the feature larger. Ticket 8 settles the initial numerical
defaults; deliberate shoppers, trade-accurate displays, optimal stall packing,
and ordinary-day bell gatherings remain separate future work.
