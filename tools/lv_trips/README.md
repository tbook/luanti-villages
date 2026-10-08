# Trip probe

Runs villager trips on a copy of a real world and records, for each trip, what the engine's
pathfinder found, what the planner found, and whether the villager arrived. It exists so the
navigation epic (#157) can be judged against numbers. The baseline it produced is in
[`docs/trip-baseline.md`](../../docs/trip-baseline.md).

Needs Luanti 5.17 with VoxeLibre (`mineclone2`), `jq`, and macOS's `cp -c` (it falls back to a plain
copy). The probe is a world mod (`mod/lv_trips/`). It never changes how a trip is chosen or
followed.

**The real world is never touched.** `run.sh` clones the world into a scratch directory, edits only the
clone's `world.mt`, and runs the server there. `living_villages` is loaded from the checkout the
script is in (or `--mod-dir`); the other mods the world names (`mods/x`) come from the user mods
directory. See "Running the probe from a worktree" below.

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

## Running the probe from a worktree / for a PR

`run.sh` measures the checkout it lives in, not the copy in the user mods directory. From a
worktree, run the worktree's own script and the clone loads the worktree's `living_villages`
(`--mod-dir PATH` picks another checkout). The mod is copied into the clone's `worldmods/` and the
clone's `world.mt` has the user-directory entry switched off, so neither the real world nor the main
checkout is touched. The log shows which copy loaded:
`[lv_trips] living_villages loaded from <scratch>/world_<label>/worldmods/living_villages`.

Each run takes its own free port (starting at `LV_TRIPS_PORT`, default 30124, skipping any port a
running game or another probe holds) and its own scratch directory per checkout, so a running game
and runs from several worktrees do not collide. Results go to the worktree's own
`tools/lv_trips/results/`.

```sh
# in the worktree; start each in the background
tools/lv_trips/run.sh Testlandia 570,17,-2145 pr_B --rounds 1 &     # village B: every stage, one round
tools/lv_trips/run.sh Testlandia -235,15,-2130 pr_C --rounds 1 &    # village C
wait
tools/lv_trips/compare.sh tools/lv_trips/results/main_B.jsonl tools/lv_trips/results/pr_B.jsonl
tools/lv_trips/report.sh tools/lv_trips/results/pr_B.jsonl          # the full tables
```

Time: `--rounds 1 --stages church` took 3 minutes. Every stage for one round is roughly six times
that (an estimate, not measured); three rounds, the default and what the baseline used, take 30 to 70
minutes. Villages B and C can run at the same time.

For the "before", run the same command from a worktree of `origin/main` (or with `--mod-dir` pointing
at one) under another label such as `main_B`, so both runs use the same village, rounds and stages,
and copy its `.jsonl` into your worktree's `results/`. Don't set a one-round run against the
three-round numbers in [`docs/trip-baseline.md`](../../docs/trip-baseline.md): that file records one
point in time and `results/` is git-ignored, so its raw lines are not in the repository.
`compare.sh BEFORE.jsonl AFTER.jsonl` prints, for each stage and each natural-day kind, arrived over
trips, the stuck and no-route counts, and the change in the arrival rate. Trip counts differ between
runs because a villager that fails is sent again, so read the rate, and treat a difference of a few
trips as noise: routes shift with timing even on the same code.

The user directory (`worlds/`, `mods/`) is found through git, which needs git 2.31 or newer and a
`.git` directory in the main checkout; otherwise set `LUANTI_USER` to it.

`tools/lv_probe/run.sh` takes the same `--mod-dir` (it implies `--with-mod`) and has the same port and
scratch handling.

## One villager from one spot

To watch a single trip that went wrong, teleport the owner of a bed to a start and log it:

```sh
tools/lv_trips/run.sh Testlandia 570,17,-2145 spot --spot 599,17.5,-2137:590,20,-2177
```

`--spot SX,SY,SZ:BX,BY,BZ` (mode `spot`; `--rounds` is ignored) wakes the villager that
owns the bed at B, puts it at S at the `home` hour and leaves it to walk home. `--stages NAME` picks
another hour for the spot (the first name listed; an unknown name is an error): `night` (late evening, when every schedule says
home), `church` (a holiday service), `work`. The villagers' beds are logged as
`[lv_trips] villager ID bed=... jobsite=...` to choose B from. `--goto GX,GY,GZ` sends the villager
to G instead, and `--build FILE.lua` runs a Lua script on the clone first (it can place nodes, e.g. a
test staircase on a floating floor; keep the area within `--radius` and 40 nodes of the village
point's height). `--goto` and `--build` need `--spot`, and a bad number or a missing file is refused
before anything starts. `builds/stairs.lua` is the #64 staircase lanes, with Testlandia coordinates
(X=-2630, Z=240; village point `-2625,30,250`):

```sh
tools/lv_trips/run.sh Testlandia -2625,30,250 A1 --stages work --build tools/lv_trips/builds/stairs.lua \
    --spot -2629,40,236:-2648,10,249 --goto -2625,42,240
```

Known limit: `--goto` starts a trip with `gopath`, which does nothing if the villager is already
walking, and a bed trip at the home hour can win; the log says `--goto ... is not being walked` then
(use `--stages work` for a quiet hour). Every quarter second the
server log gets a line `[lv_trips] spot t=... pos=(...) v=(...) state=... order=... route=status/reason
target=... wp_left=N follow=bool final=...`: the villager's position and velocity, its mover state, the
bed route's status, the follower's current waypoint, the waypoints left and the planned final cell. The
trip is also written as a normal `trip` line. It runs until the trip ends or for 150 s, and the
other villagers carry on as they like, so a run can start with a route cancelled by something else
(look at the `route=` column). The log path is printed when the run starts.

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
