# Villages

Adds a visible sleeping pose to VoxeLibre villagers while leaving VoxeLibre's
trading, professions, and existing bed claims in place. Clone this repository
into Luanti's mods directory. Removing the mod restores the game's default
villager behavior; it does not change saved bed ownership.

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
