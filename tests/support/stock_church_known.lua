-- Cases tests/stock_church.lua knows fail, as patterns over its case names. Each
-- says why; a fix removes its rule.
return {
	{
		match = "^church r%d+ slope up .-outside the church",
		reason = "church.lua back_places never checks that a standing place is inside the church. "
			.. "Where the ground outside is raised to floor height (slope up), the open ground "
			.. "behind the back wall qualifies, and ranks first for being farthest from the pulpit.",
	},
}
