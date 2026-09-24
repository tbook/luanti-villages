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

## Interpretation

- `mode legacy`: VoxeLibre's native mover owns the route.
- `mode engine`: Villages is using engine-generated waypoints directly.
- `mode planner`: Villages' bounded stair/door planner owns the route.
- `last` and `progress`: identify a physical collision or doorway where movement
  stopped.
- `search limit`: the map layout exceeded the bounded fallback search; it is
  distinct from a destination proven unreachable inside that search.
