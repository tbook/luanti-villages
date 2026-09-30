# Living Villages

Living Villages gives VoxeLibre villagers daily lives. Villagers sleep in their beds, have children
when there's room, fish, keep taverns, and meet for dinner in the evening. The mod keeps
VoxeLibre's own trading, professions, and bed-ownership format, so removing it returns the
game's default villager behavior. Child villagers, bed claims, and placed furniture stay in the
world.

## Features

### Sleep and births

- Villagers lie visibly in their claimed beds at night.
- A village can have a child when a valid bed is unclaimed, as long as two nearby adults own
  beds and no nearby adult is without one. Automatic births are limited to about one every two
  game days in a local area.
- Breeding with food also needs a free bed, but doesn't wait for the birth timer.
- Beds owned by players don't count. Spawn eggs and curing zombie villagers work as before.

### Fishermen

- An unemployed villager that has a bed but can't reach a workstation becomes a fisherman
  when there's enough water near its bed. It doesn't need a barrel, but claiming a barrel still
  works the normal way.
- A fisherman keeps the profession for life, even if its water or barrel goes away later.
- During work hours it walks to a spot at the water's edge and casts, waits, and reels in.
  Fishing produces no items. Instead it restocks the fisherman's locked trades within its
  current tier.

### Getting around

For trips to a bed, workstation, farm plot, or fishing spot, villagers first use VoxeLibre's
normal pathfinding. If that fails, they fall back to a limited route planner that can use
ordinary stairs and wooden doors. Iron doors still block them.

### Taverns and dinner

- **Furniture:** newly generated taverns get two tables with plates and chairs. The furniture
  is added to the installed VoxeLibre version's own tavern layout when the tavern generates.
  Taverns that already exist aren't refurnished.
- **Keepers:** an unemployed adult that claims a free jukebox becomes a tavern keeper. The
  jukebox can be a tavern's or one a player placed. A keeper wears a brown apron and sells
  bread, baked potatoes, cooked fish, mushroom stew, and pumpkin pie through the ordinary
  trade window. More of its menu unlocks as players trade with it. A keeper opens the tavern at
  14:00, stays until 18:30, and is the last villager in the village to go to sleep.
  - VoxeLibre can't register new professions, so a keeper is a butcher underneath.
  - A keeper that loses its jukebox after trading keeps its menu and looks for another
    jukebox, not a smoker.
- **Evening visit:** from 15:30, every adult walks to the nearest tavern within 48 nodes of its
  bed and stays until 17:30. An adult that hasn't arrived by 17:00 goes home instead.
  - If a tavern has no keeper, the first villager to reach it takes the job and leaves its old
    one, unless a player has traded with it.
- **Seating:** guests each take a free chair that faces a table. This works in any tavern,
  including ones players built. Guests never take a chair a player is sitting in, and they get
  up if a player takes their chair. When no seat is free, a guest stands inside.
- **Dinner:** while the keeper is at its jukebox, it serves each seated guest one meal from its
  menu each evening. The meal appears on the plate at the guest's table, and the plate empties
  as the guest eats. The meal is only for show and can't be taken. A keeper never serves on a
  plate that holds a player's item, and a tavern with no keeper on duty serves no meals.

## Requirements

- [VoxeLibre](https://content.luanti.org/packages/wuzzy/mineclone2/) 0.92.3. Other versions
  may work but haven't been tested.
- These VoxeLibre mods, all included in the game: `mobs_mc`, `mcl_beds`, `mcl_villages`,
  `mcl_decor`, and `mcl_itemframes`.
- Optional: `doc_identifier` (the Lookup Tool) and `mcl_fishing`.

## Installation

Put this repository in a directory named `living_villages` inside Luanti's `mods` directory, or
inside a world's `worldmods` directory. Then enable it for your world.

## Admin and testing tools

- **Inspecting villagers:** players with the `server` or `debug` privilege can use VoxeLibre's
  Lookup Tool on a villager to see its AI, bed, workstation, path, fishing, tavern, meal, and
  birth-timing state. Using the tool on a bed or workstation shows which villager owns it. The
  tool works normally on everything else.
- **`/living_villages_goto`** (requires `teleport`): teleports you above the nearest tavern
  that has generated in this world. If no tavern is known yet, it goes to the nearest untried
  spot where VoxeLibre will try to generate a village, predicted from the world seed. Once the
  village has generated, run the command again to reach its tavern, or to move on to the next
  site.
  - `/living_villages_goto any` goes to the nearest known village.
  - `/living_villages_goto new` skips known taverns and tries another site.
  - Each village is logged to `debug.txt` as it generates.
- [`docs/navigation-scenarios.md`](docs/navigation-scenarios.md) has repeatable in-game test
  scenarios for pathfinding and fishing.

## Development

The tests are plain Lua 5.1 scripts that stub the engine, and CI runs them on every push:

```sh
for t in tests/*.lua; do lua5.1 "$t"; done
```

[`AGENTS.md`](AGENTS.md) has a map of the code and the project's conventions.

## License

The code is licensed under GPL-3.0; see [`LICENSE`](LICENSE). The sleeping position, bed
occupancy, pose, and wake-up behavior are adapted from Mineclonia's `mobs_mc/villager.lua`.
The model and textures come from Mineclonia; see [`LICENSE-media.md`](LICENSE-media.md) for
their licenses and credits.
