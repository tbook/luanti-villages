# Villager trip baseline (#160)

How villager trips succeed and fail today, measured before the navigation epic (#157) changes
anything. The probe is [`tools/lv_trips`](../tools/lv_trips/README.md); this is what it found on
2026-10-06, on `main` at 766765d (after #159). Rerun it after each navigation change and compare.

## What was run

Three Testlandia villages, each as a throwaway clone (the real world was not touched):

| Label | Centre | Villagers | Beds | Jobsites | Notes |
|-------|--------|-----------|------|----------|-------|
| B | 570,17,-2145 | 9 | 9 | 8 | has a church |
| C | -235,15,-2130 | 12 | 12 | 1 | steep, 7 to 29 high; no church service started |
| D | -630,14,-790 | 6 | 0 | 1 | no beds, so no home trips |

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
| work (jobsite) | 185 | 173 | 2 | 3 | 7 |
| home (bed) | 84 | 53 | 12 | 10 | 9 |
| bell | 61 | 43 | 10 | 6 | 2 |
| church | 10 | 8 | 1 | 1 | 0 |
| tavern | 73 | 13 | 14 | 19 | 27 |
| holiday tavern | 56 | 4 | 11 | 21 | 20 |

Natural days (B and C, trips of 3 nodes or more): bed 41 of 54 arrived, jobsite 4 of 7, church and
bell walks 47 of 84, tavern **0 of 27** (4 with no route, the rest abandoned after retries).

The tavern is the outlier. Its failures are mostly `stair planner reached its search limit after 4096
nodes` from 14 to 33 nodes away. This is the same family as #156 ("no route after 24 nodes") and is for #161 to diagnose;
the stock tavern in #159's tests did not reproduce it, so look at these villages' real nodes.

## The three questions

**Does the engine succeed where the planner fails, and the other way round?** Over 1008 matched
pairs (the same villager, start and target in an A round and a B round): both found a route in 486, the
engine's route with headroom alone in 402, the planner's alone in 27, neither in 93. The planner's
losses are its search limit: 256 of 620 planner searches (41%) stopped at 4096 nodes without a route.
So the planner is a fallback for the cases the engine's route fails the headroom check on, and not yet
a replacement; #162 and #163 start from this gap.

**How often does a good route still end in a stuck villager?** Of the 278 variant A trips where a route
was started (legacy mover, engine route or planner), 237 arrived (85%). By route source over all
rounds: the legacy mover 203 of 229 (89%), the planner's route 136 of 164 (83%). Of 87 stuck trips, 31
were still in `gowp` and 37 had a door within two nodes. 28 trips needed the planner to take over after
the legacy mover stalled. So roughly one trip in six or seven with a route still fails to arrive, and a
follower that handles doors and stalls (#164) has real room to help. Church and bell trips never use
the planner; their stuck rates are 1 of 10 and 10 of 61.

**What does a planner search cost?** From the B rounds (620 searches), in wall milliseconds:

| | p50 | p90 | p99 | max |
|--|----:|----:|----:|----:|
| planner search | 7.3 | 58 | 100 | 183 |
| nodes searched | 108 | 4096 | 4096 | 4096 |
| engine `find_path`, all candidates of one trip | 0 | 25 | 65 | 403 |

A search that hits the limit costs 60 to 100 ms, so a time-sliced planner (#162) needs a budget of
about 100 ms per search, spread over several ticks, to match what runs today. A larger node limit
would raise the 41% limit rate but cost more than that.

## Caveats

* Starts are teleports beside another villager's bed or jobsite, not where a villager would be
  at that hour. Villagers all walk at once, so some failures are queueing at doors (the point of #121).
* Three servers ran at once, so the millisecond figures are a little high.
* 17 villagers died of falls and 2 on sweet berry bushes during the runs. They are listed as
  `damage` lines and the villagers are skipped from the next round.
* `superseded` counts trips the villager abandoned for another; they are neither successes nor failures
  and are excluded from the percentages above.
* Only Testlandia (stock villages) was measured. The player-built cases in Creative and Home still need
  a run before the epic's later tickets lean on these numbers.

## Rerun

```sh
tools/lv_trips/run.sh Testlandia -235,15,-2130 C
tools/lv_trips/run.sh Testlandia 570,17,-2145 B
tools/lv_trips/run.sh Testlandia -630,14,-790 D
tools/lv_trips/run.sh Testlandia 570,17,-2145 days_B --mode day
tools/lv_trips/report.sh
```
