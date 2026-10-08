# Trip probe

Runs villager trips on a copy of a real world and records, for each trip, what the engine's
pathfinder found, what the planner found, and whether the villager arrived. It exists so the
navigation epic (#157) can be judged against numbers. The baseline it produced is in
[`docs/trip-baseline.md`](../../docs/trip-baseline.md).

Needs Luanti 5.17 with VoxeLibre (`mineclone2`), `jq`, and macOS's `cp -c` (it falls back to a plain
copy). The probe is a world mod (`mod/lv_trips/`). It never changes how a trip is chosen or
followed.

**The real world is never touched.** `run.sh` clones the world into a scratch directory, edits only the
clone's `world.mt`, and runs the server there. Mods that the world names by path (`mods/x`) are
loaded from the user mods directory, so a run measures the branch that is checked out.

## Run it

```sh
tools/lv_trips/run.sh Testlandia -235,15,-2130 C                  # trials: every stage, 3 rounds
tools/lv_trips/run.sh Testlandia -235,15,-2130 C --rounds 1 --stages home,work
tools/lv_trips/run.sh Testlandia 570,17,-2145 B --mode day       # a normal day, then a holiday
tools/lv_trips/report.sh                                          # tables for everything in results/
```

The second argument is any point in the village (a villager's position will do; the probe loads
`--radius` nodes around it, 64 by default). Several runs can go at once if each has its own
`LV_TRIPS_PORT`. A trial run takes 30 to 70 minutes, a day run about 45. Results land in
`tools/lv_trips/results/<label>.jsonl` (git-ignored); a run that stops early leaves
`<label>.partial.jsonl`.

To find where a world's villagers are without playing it, read the saved entities straight out
of `map.sqlite` (see the notes on inspecting world saves); it is slow on a big world.

## What a trial does

Time is frozen at each stage's hour and the moon is made to say holiday or not. For each round
every villager is teleported beside another villager's bed (work stage) or jobsite (the other
stages), a different one each round, and then left to do what it does at that hour. Stages are
`home` (bed), `work` (jobsite), `tavern`, `church`, `bell` and `holiday_tavern`.

* **Variant A** is the mod as it is: the planner chooses the route and the follower walks it.
* **Variant B** made `core.find_path` find nothing, so every trip took the planner. Since #165 the
  engine's pathfinder is never asked, so B would repeat A and is no longer run. Results from
  before #165 (`pl163_*`, `fl164*`) still have it.

All villagers walk at once, as in play, so doors and corridors are shared. A round ends when
every trip has ended, after 150 s, whichever is first.

`--mode day` teleports nothing: it runs one normal day and one holiday at `--speed` (default 72)
and records the trips that happen.

## Result lines

One JSON object per line. `type` is `village` (what was found), `trip`, `round`, `damage` (a
villager hurt, with the reason) or `done`. A trip has `stage`, `variant`, `round`, `villager`, `kind`
(bed, jobsite, tavern, church, bell, ...), `start`, `target`, `distance`, `rise`, `mode`
(`planner` once a route got going; before #165 also `legacy` or `engine`), and `outcome`:

| outcome | meaning |
|---------|---------|
| `arrived` | the arrival callback ran |
| `no_route` | no route started, with the reason in `final_route.reason` |
| `stuck` | a route started or the mover was running, and it did not arrive; `stuck` holds the nodes at the feet, the doors within two nodes, and how long it had not moved |
| `superseded` | the villager was sent somewhere else first |

`calls` holds each `gopath` call: how many `core.find_path` calls it made, how long they took
(`engine_ms`), how many found a route and how many of those pass the headroom check, and the
planner's report (`planner_status`, `planner_searched`) when it ran. `ms` is the whole call.

`tests/lv_trips_report.lua` covers `report.sh` with a few hand-made lines.
