# Villager trip baseline (#160)

How villager trips succeed and fail today, measured before the navigation epic (#157) changes
anything. The probe is [`tools/lv_trips`](../tools/lv_trips/README.md); this is what it found on
2026-10-06, on `main` at 766765d (after #159). Rerun it after each navigation change and compare.

## What was run

Three Testlandia villages, each as a throwaway clone (the real world was not touched):

| Label | Centre | Villagers | Beds | Jobsites | Notes |
|-------|--------|-----------|------|----------|-------|
| B | 570,17,-2145 | 9 | 9 | 8 | has a church |
| C | -235,15,-2130 | 12 | 12 | 2 | steep, 7 to 29 high |
| D | -630,14,-790 | 6 | 6 | 1 | |

Trials: 6 stages, 3 rounds each, variant A (as today) and for bed, jobsite and tavern trips also
variant B (engine silenced, planner only). Days: villages B and C, one normal day and one holiday
at 72x. Creative and Home (the player-built worlds) were not run yet. Village A (1050,-2150) was not
run either.

The counts below are trip records, not distinct trips: a villager that is sent somewhere, fails and
is sent again makes several. Only the kind of trip a stage is about is counted (bed at home, jobsite at
work, and so on) and the bell's wander legs under three nodes are left out.

## Outcomes (trials, variant A, the mod as it is)

| Stage | Trips | Arrived | Stuck | No route | Superseded |
|-------|------:|--------:|------:|---------:|-----------:|
| work (jobsite) | 236 | 222 | 4 | 1 | 9 |
| home (bed) | 113 | 95 | 3 | 9 | 6 |
| bell | 66 | 59 | 2 | 5 | 0 |
| church | 15 | 7 | 4 | 4 | 0 |
| tavern | 85 | 11 | 11 | 21 | 42 |
| holiday tavern | 62 | 4 | 8 | 17 | 33 |

Natural days (B and C, trips of 3 nodes or more): bed 41 of 54 arrived, jobsite 4 of 7, church and
bell walks 47 of 84, tavern **0 of 27** (4 with no route, the rest abandoned after retries).

The tavern is the outlier in both. Its failures are mostly `stair planner reached its search limit after
4096 nodes` from 14 to 33 nodes away. This is the same family as #156 ("no route after 24 nodes") and is
for #161 to diagnose; the stock tavern in #159's tests did not reproduce it, so look at these villages'
real nodes. Church trips fail too often for the few there are (7 of 15), and only village B has a church
service.

## The three questions

**Does the engine succeed where the planner fails, and the other way round?** Over 126 matched pairs
(one per villager, round, start and target: the first A trip's engine route against the first B trip's
planner route): both found a route in 26, the engine's route with headroom alone in 94, the planner's
alone in 5, neither in 1. The planner's losses are its search limit: 369 of 757 planner searches (49%)
stopped at 4096 nodes without a route. So the planner is a fallback for the cases where the engine's
route fails the headroom check, and not yet a replacement; #162 and #163 start from this gap.

**How often does a good route still end in a stuck villager?** Of the 364 variant A trips where a
route was started (legacy mover, engine route or planner), 330 arrived (91%). By route source over
all rounds: the legacy mover 274 of 300 (91%), the planner's route 120 of 131 (92%). Of the 35 trips
that ended stuck, 19 had the villager standing still with the mover gone, 5 were still in `gowp`, and
only 6 had a door within two nodes. 11 trips needed the planner to take over after the legacy mover
stalled. So roughly one trip in eleven with a route still fails to arrive, mostly because the
mover gave up rather than because of a door. That is a smaller gap than the route one above, so #164
matters less to the arrival rate than #161 to #163 do. Church and bell trips never use the planner.

**What does a planner search cost?** From the B rounds (757 searches), in wall milliseconds:

| | p50 | p90 | p99 | max |
|--|----:|----:|----:|----:|
| planner search | 5 | 76 | 120 | 259 |
| nodes searched | 1448 | 4096 | 4096 | 4096 |
| engine `find_path`, all candidates of one trip | 0 | 27 | 86 | 115 |

A search that hits the limit costs 75 to 120 ms, so a time-sliced planner (#162) needs a budget of
about 120 ms per search, spread over several ticks, to match what runs today. A larger node limit
would lower the 49% limit rate but cost more than that.

## Caveats

* Starts are teleports beside another villager's bed or jobsite, not where a villager would be
  at that hour. Villagers all walk at once, so some failures are queueing at doors (the point of #121).
* Three servers ran at once, so the millisecond figures are a little high.
* The runs logged 84 fall damage events (steep village C and D most) and one berry bush. Each is a
  `damage` line; a villager that died is skipped from the next round. Seated and eating villagers are stood up before each round, with an
  11 s wait for their chair and plate holds to lapse.
* `superseded` counts trips the villager abandoned for another; they are neither successes nor failures
  and are excluded from the percentages above.
* Only Testlandia (stock villages) was measured. The player-built cases in Creative and Home still need
  a run before the epic's later tickets lean on these numbers.

## After #163 and #164

Same villages (Testlandia B, C, D), same trials. `pl163` is main with the planner choosing routes (#163),
`fl164c` adds the follower (#164) with the rise fix below.

| | #163 | #164 |
|--|--:|--:|
| routes that started and arrived | 326 of 370 (88%) | 310 of 346 (90%) |
| stuck with a route | 33 | 30 |
| median s per node, trips of 10+ nodes | 1.11 | 1.21 (p75 1.37 -> 1.84) |

The first #164 build (`fl164b`) arrived only 65% (219 of 335) and left 70 villagers in `gowp`, jumping
in place against a one-block step. Vanilla's `do_jump` runs on every server step, and
it fired first, from a standstill, so the jump had no forward speed; the follower's own jump waited for the
fall speed to be near zero, which it never is on the tick a villager lands. The follower now jumps with
forward speed on that tick, and counts bobbing in place as no progress.

Trips of under 3 nodes in the work stage fell from 651 to 27: a villager already beside its jobsite used to
"arrive" at every poll from vanilla's 1.8-block rule, and now only a walk to the planned cell counts.
Trips of 3+ nodes also fell (about 277 to 149) and more home trips end `superseded`; I did not find why, and
the totals depend on timing in the probe, so treat them as unexplained rather than as a regression.

## Rerun

```sh
tools/lv_trips/run.sh Testlandia -235,15,-2130 C
tools/lv_trips/run.sh Testlandia 570,17,-2145 B
tools/lv_trips/run.sh Testlandia -630,14,-790 D
tools/lv_trips/run.sh Testlandia 570,17,-2145 days_B --mode day
tools/lv_trips/report.sh
```
