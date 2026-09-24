# Villages

Extends VoxeLibre villagers with sleeping, bed-limited births, work travel,
and tavern life. Install the repository as a directory named `villages` in
Luanti's mods directory (or a world's `worldmods` directory). The `mcl_decor`
mod is required for tavern furniture. Removing Villages restores the game's
default villager behavior; existing children, bed claims, and placed furniture
remain in the world.

A village can produce a child when a valid bed is unclaimed, provided two
nearby adults own beds and no nearby adult is bedless.
Automatic births are limited to about one per two game days in a local area.
Food-triggered breeding also needs a free bed, but does not wait for the slow
birth timer. Player-owned beds do not count. Spawn eggs and zombie-villager
curing remain unchanged.

Administrators with the `server` or `debug` privilege can use VoxeLibre's
Lookup Tool on a villager to inspect its current AI, bed, jobsite, path, and
birth-timing state. Using it on a bed or workstation shows that node's pairing
owner directly. Owner IDs are resolved to a nearby loaded villager where
possible. The tool retains its normal lookup behavior for all other targets
and players.

For destination trips, Villages first uses VoxeLibre's normal pathing and
then falls back to a bounded route planner that can follow ordinary stairs and
wooden doors. Iron doors remain impassable.

Newly generated taverns have two tables with plates and chairs. Existing
generated taverns are not refurnished automatically. The tavern keeper is a
new villager profession that claims the existing jukebox. Villagers visit a
staffed tavern once each evening; the keeper serves visual meals, and diners
return home after the dinner window. Players can sneak-click an on-duty keeper
to order a meal, sit at an empty table, and pay when food appears on the plate.
Ordinary click opens the keeper's takeaway trades. Unserved orders expire
without charge.

The profession and extended evening schedule require the VoxeLibre extension
described in [`upstream/README.md`](upstream/README.md). Stock VoxeLibre does
not yet expose that API. Villages loads its existing features and furnished
taverns without it, but keeper and dinner service remain disabled.

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

`schematics/tavern_furnished.mts` is a modification of VoxeLibre's
`mcl_villages` tavern schematic. Its original schematic is credited to
MysticTempest in VoxeLibre's `mcl_villages/README.txt` and is licensed
CC BY-SA 4.0; this modified schematic is also CC BY-SA 4.0.
