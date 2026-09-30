# Villager navigation scenarios

These manual scenarios complement the fast Lua tests. Run them in a disposable
world with the Villages mod and VoxeLibre loaded. Use the privileged Lookup Tool
on the villager after each step; the route line reports its ID, mode, age, last
progress position, and failure reason.

## 1. Multi-floor bed return

Build a two-floor house with a single stair flight, a landing, and a claimed bed
on the upper floor. Put the villager on the ground floor at least 12 nodes from
the bed, wait for night, and verify that it reaches the bed.

Expected result: the bed route first reports `mode legacy` or `mode engine`.
If the native mover gives up, it changes to `mode planner`, retains the same
destination, and reaches the bed. A failure must identify either legacy
pathfinding cancellation or a planner search limit/no-route outcome.

## 2. Path-distance jobsite selection

Place two unclaimed workstations for an unemployed villager. Make the nearer
one require a long corridor around a wall, and leave a short open route to the
farther one. Trigger a work period.

Expected result: the job-search route names the farther station's approach. The
villager claims that station after arrival; it must not choose solely by
straight-line distance.

## 3. Reload during a route

Start a bed or jobsite trip, confirm a travelling route in the Lookup Tool, then
leave the area until its mapblock unloads and return.

Expected result: the old route is canceled rather than resuming stale waypoints.
The next eligible schedule tick creates a new route ID. The old callback cannot
change the villager's order or claim state.

## 4. Following interrupts a trip

Start a bed/jobsite trip, then use the game's normal follow interaction before
arrival.

Expected result: the managed route disappears and the villager follows the
player. It must not switch back to `mode planner` or resume the old route while
following.

## 5. Shared wooden-door corridor

Build a one-node-wide corridor with a wooden door and send two villagers through
it in close succession. Optionally hold the door shut with a player to force a
stall.

Expected result: a passing villager opens the door and it is not closed on the
other villager. If no positional progress occurs for 20 seconds, diagnostics
show a replacement planner route or a retry with a concrete failure reason.

## 6. Bounded search exhaustion

Surround a destination with a large maze or otherwise force the fallback planner
to exhaust its bounded search without a valid approach.

Expected result: diagnostics show a retry whose reason includes `search limit`,
not a misleading generic cancellation. Removing the obstruction permits a fresh
route after the retry delay.

## 7. Separate upstairs rooms

Build two adjacent two-floor buildings with an exterior door between them. Put
a villager in an upstairs room of one building and its bed in the upstairs room
of the other. The only route should go downstairs, through the door, and up the
other stair.

Expected result: the villager follows that physical route. It must not attempt
to cross the separating wall or descend directly through a floor.

## 8. Downstairs bed behind a door

Put a villager upstairs with its bed downstairs, so the proper route reaches an
adjacent wooden door before descending. Leave the wall between the rooms solid.

Expected result: the villager uses the door and stairs. If the route cannot be
completed, it enters a bounded retry with a route reason instead of pushing at
the wall.

## 9. Low roof beside a taller room

Build a two-block-high room with a doorless opening into a neighboring room
whose floor is one block higher, so its own two-block interior sits entirely
above the first room's ceiling, and no other connection between the rooms.
Put the villager's bed in the raised room and the villager in the lower one,
next to the opening.

Expected result: the villager cannot physically clear that rise (it would
strike its head on the lower room's own ceiling before reaching the ledge), so
it must not attempt the jump. With no other route available, the trip enters
a bounded retry with a route reason instead of repeatedly walking into the
wall beneath the ledge.

Now add a proper stair connecting the two rooms elsewhere in the layout, still
leaving the low, doorless opening in place.

Expected result: the villager reaches the bed by the stair. It must not still
attempt, or get diverted toward, the blocked direct rise.

## 10. Bed just inside a door

Build a corridor with a wooden door, with the claimed bed one node past the
door rather than further down the corridor. Send the villager to bed from
well down the corridor.

Expected result: the villager opens the door, walks in, and reaches the bed.
The door closes behind it instead of being left standing open, even though
the bed is the very next node after the doorway.

## 11. Lakeside village with no workstations

Build a small village of bedded, unemployed villagers next to a lake at
least 3x3 in open span, with no workstation anywhere reachable. Wait through
a full day/night cycle.

Expected result: each unemployed, bedded villager promotes to fisherman
(the Lookup Tool's `Fisherman flag` turns `yes`) once its own promotion
check runs, and during the next work period each walks to its own stand at
the water's edge and starts a fishing session. Promotion is for life: the
`Fisherman flag` and profession must stay set even after the lake is later
drained or built over.

## 12. A lake filled in or frozen while a fisherman is using it

Send a fisherman to its stand and let it start a session (`Fishing session`
shows a phase other than `none`). While it is fishing, replace the water it
anchored on with a solid block, or otherwise make it stop reporting as
surface water (for example `mcl_weather`'s freeze, if installed).

Expected result: the session ends on the next tick (`Fishing session: none`,
`Fish target: none`), any bobber is removed, and the villager keeps its
fisherman profession. Once work time allows it again, the villager searches
for a new qualifying spot rather than retrying the invalidated one.

## 13. Two fishermen on one shoreline

Place two fishermen with beds close enough that their nearest qualifying
water is the same lake, close enough that they are likely to select
adjacent stands. Trigger a work period for both at once.

Expected result: each fisherman gets its own stand; a stand already occupied
by a loaded villager is skipped for another one rather than both villagers
converging on the same node. Two fishermen briefly milling about near the
shore while their stands settle is expected, not a bug. Neither should ever
report a route failure that names the other fisherman as an obstruction it
cannot route around.

## 14. Waking after a reload, a bed change, or a rebuilt bedside

Three variants, each checking where a villager stands up (#84). In every one,
watch it through the following morning rather than only checking that it is
still alive at dawn.

1. Let a villager fall asleep, leave the area until its mapblock unloads, and
   return before morning.
2. Let a villager sleep in one bed, then break that bed during the day so it
   claims a different one well across the village, and let it sleep again.
3. Let a villager fall asleep, then fill in the square it stepped into the bed
   from with a solid block before morning.

Expected result: the villager stands up beside the bed it actually slept in. It
must never be moved toward another bed's surroundings, and never end up inside
a solid node. In variants 1 and 3 it may simply stand up in the bed itself and
walk out; the debug log records `woke with no usable bed exit` for that case.
A villager that disappears here is a regression: check the log for a
`[living_villages] villager ... died` line, which names the cause.

## Interpretation

- `mode legacy`: VoxeLibre's native mover owns the route.
- `mode engine`: Villages is using engine-generated waypoints directly.
- `mode planner`: Villages' bounded stair/door planner owns the route.
- `last` and `progress`: identify a physical collision or doorway where movement
  stopped.
- `search limit`: the map layout exceeded the bounded fallback search; it is
  distinct from a destination proven unreachable inside that search.
