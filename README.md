# Villages

Adds a visible sleeping pose and slow, bed-limited births to VoxeLibre
villagers while leaving VoxeLibre's trading, professions, and bed ownership
format in place. Install the repository as a directory named `villages` in
Luanti's mods directory (or a world's `worldmods` directory). The `mcl_decor`
mod is required for tavern furniture. Removing the mod restores the game's
default villager behavior; existing child villagers, bed claims, and placed
furniture remain in the world.

A village can produce a child when a valid bed is unclaimed, provided two
nearby adults own beds and no nearby adult is bedless.
Automatic births are limited to about one per two game days in a local area.
Food-triggered breeding also needs a free bed, but does not wait for the slow
birth timer. Player-owned beds do not count. Spawn eggs and zombie-villager
curing remain unchanged.

Administrators with the `server` or `debug` privilege can use VoxeLibre's
Lookup Tool on a villager to inspect its current AI, bed, jobsite, path,
fisherman, and birth-timing state. Using it on a bed or workstation shows
that node's pairing owner directly. Owner IDs are resolved to a nearby loaded
villager where possible. The tool retains its normal lookup behavior for all
other targets and players.

An unemployed, bedded villager with no reachable workstation becomes a
fisherman automatically once a large enough body of water is near its bed;
barrels are no longer required for this profession, though an existing or
newly claimed barrel still grants it the normal way. Once a villager becomes
a fisherman, whether by promotion or by barrel, it stays one for life: the
profession is never revoked, even if the water or barrel that first granted
it later becomes invalid. During work hours a fisherman walks to a stand at
the water's edge and runs a cast/wait/reel cycle there; fishing produces no
items and instead restocks the villager's locked trades within its current
tier, since VoxeLibre only restocks trades at a jobsite and a fallback
fisherman has none.

[`docs/navigation-scenarios.md`](docs/navigation-scenarios.md) provides
repeatable in-game scenarios for complex bed returns, first-job selection,
reloads, following, shared doors, bounded-search failures, and fishing.

For bed, jobsite, farm-plot, and fishing-spot trips, Villages first uses
VoxeLibre's normal pathing and then falls back to a bounded route planner
that can follow ordinary stairs and wooden doors. Iron doors remain
impassable.

Newly generated taverns have two tables with plates and chairs, furnished by
modifying the stock tavern's schematic in memory at generation time, so
furnishing tracks whatever the installed VoxeLibre's own tavern layout
currently is rather than a separately maintained copy. Existing,
already-generated taverns are not refurnished.

An unemployed adult villager claims any free jukebox (a tavern's, or one a
player placed) and becomes its tavern keeper: a brown-aproned villager that
sells bread, baked potatoes, cooked fish, mushroom stew and pumpkin pie
through the ordinary trade window, unlocking tiers as it is traded with. A
keeper opens the tavern at 14:00 and stays until 18:30, sleeping last in the
village. VoxeLibre cannot register new professions yet (#35), so a keeper is
a butcher underneath; a keeper that loses its jukebox after trading keeps its
menu and looks for another jukebox, never a smoker. Dinner service is not
built yet (#16), but from 15:30 every adult walks to the nearest tavern within
48 nodes of its bed and stays until 17:30; one not there by 17:00 goes home
instead. The first villager to reach a tavern with no keeper takes the job,
leaving its old one, unless a player has traded with it. The other guests
each take a free chair that faces a table, in any tavern including one a
player built, and sit until 17:30; a guest never takes a chair a player is
sitting in, gets up if a player takes its chair, and stands inside when no
seat is free.

For play testing, `/villages_goto` (requires `teleport`) teleports you above
the nearest tavern seen generating in this world. If none is known yet, it
goes to the nearest untried site where VoxeLibre will attempt a village,
predicted from the world seed; run it again once the village has generated
to reach its tavern, or to move on to the next site. `/villages_goto any`
goes to the nearest known village, and `/villages_goto new` skips known
taverns to try another site. Each village is logged to `debug.txt` as it
generates.

This initial port targets the installed VoxeLibre 0.92.3 (`mineclone2`).

## Attribution and licenses

The sleep-position, occupancy, pose, and wake-up behavior in `init.lua` is
adapted from Mineclonia's `mobs_mc/villager.lua`. This mod's Lua code is
licensed under GPL-3.0; see `LICENSE`.

`models/villages_villager.b3d` is Mineclonia's
`mobs_mc/models/mobs_mc_villager.b3d`, created by 22i and licensed under
GPL-3.0. Mineclonia's `mobs_mc/LICENSE-media.md` credits the model and links
to its Blender source.

The images in `textures/` are renamed copies of Mineclonia's villager base,
plains, profession, and tier-badge textures. Mineclonia's
`mobs_mc/LICENSE-media.md` lists textures not otherwise named there under the
MIT License. The source game and its attribution are available at
https://git.minetest.land/Mineclonia/Mineclonia.
