# Proposal: public registration API for villager professions and scheduled activities

## Problem

VoxeLibre's regular villager already owns the machinery needed for a jobsite,
profession-specific trades, persistence, and daily activity. Those extension
points are currently private to `mobs_mc/villager.lua`. A content mod that adds
a profession therefore has to copy or replace internal tables, which is brittle
across releases and can desynchronize jobsite discovery from trade behavior.

The immediate use case is a tavern keeper in the external `villages` mod: it
would claim a jukebox, use ordinary trades for takeaway meals, and keep the
tavern staffed during a short evening activity. The request is intentionally
more general than that feature so other content mods can add a small, native
villager role without patching internals.

## Proposed API

```lua
mobs_mc.register_villager_profession(id, definition)
mobs_mc.register_villager_activity_modifier(function(tod) ... end)
```

`register_villager_profession` would accept the same data already used for a
built-in profession:

```lua
mobs_mc.register_villager_profession("example:innkeeper", {
	name = S("Innkeeper"),
	texture = "example_innkeeper.png",
	jobsite = "example:counter",
	trades = { -- existing tiered villager-trade format
		-- ...
	},
})
```

The registration would reject duplicate IDs, append the ID to native profession
selection, and rebuild the native jobsite-search list. This keeps normal
claiming, trade locking, save/load, and profession-loss behavior authoritative
in `mobs_mc`.

An activity modifier receives game time in the existing 0–23999 tick range and
returns either an activity string or `nil`. Modifiers run in registration order;
the first non-`nil` activity wins. Thunderstorms remain higher priority and
continue to send villagers to sleep. Returning `nil` leaves the default schedule
untouched.

```lua
mobs_mc.register_villager_activity_modifier(function(tod)
	if tod >= 15000 and tod < 18500 then
		return "example:dinner"
	end
end)
```

The external mod remains responsible for interpreting its custom activity;
VoxeLibre only selects it as part of the normal scheduling decision.

## Scope and compatibility

- This does not alter built-in professions, their trade data, or the default
  schedule when no extension is registered.
- It does not expose or require direct mutation of `professions`,
  `profession_names`, or `jobsites`.
- Existing villagers retain their saved profession and jobsite state. Registered
  professions participate in the same save/load paths as built-in ones.
- A later API could grow more hooks if there are concrete needs, but this
  proposal deliberately does not add generic callbacks around every villager
  behavior.

## Implementation sketch and validation

There is a small implementation patch against current master, together with a
consumer implementation and tests, here:

https://github.com/tbook/luanti-villages/pull/38

The proposed patch only adds the two registration functions, refreshes the
existing jobsite list after profession registration, and consults registered
activity modifiers after the existing thunderstorm check.

Before preparing a VoxeLibre PR, I would appreciate feedback on:

1. Whether these APIs belong on `mobs_mc` and whether their names fit existing
   public API conventions.
2. Whether a first-non-`nil` activity modifier is the right composition model,
   or whether one schedule provider should be allowed instead.
3. Any invariants required for third-party profession IDs, textures, jobsite
   selectors, or trade definitions.
4. The preferred tests and documentation location for an eventual patch.
