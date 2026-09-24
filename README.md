# Villages

Adds a visible sleeping pose and slow, bed-limited births to VoxeLibre
villagers while leaving VoxeLibre's trading, professions, and bed ownership
format in place. Install the repository as a directory named `villages` in
Luanti's mods directory (or a world's `worldmods` directory). Removing the mod
restores the game's default villager behavior; existing child villagers and bed
claims remain in the world.

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

For night-time bed trips, Villages first uses VoxeLibre's normal pathing and
then falls back to a bounded route planner that can follow ordinary stairs and
wooden doors. Iron doors remain impassable. The planner is currently used for
beds only; workstation and gathering travel will follow in later work.

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
