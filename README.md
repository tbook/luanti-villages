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
already-generated taverns are not refurnished. This is asset placement only;
there is no tavern keeper or dinner service yet (tracked in #35).

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
