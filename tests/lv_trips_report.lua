-- Run with: lua tests/lv_trips_report.lua
-- tools/lv_trips/report.sh turns the trip probe's result lines (#160) into the
-- baseline tables. Feed it a few hand-made lines and check what it counts and
-- what it leaves out.
local function sh(command)
	local pipe = io.popen(command .. " 2>&1")
	local text = pipe:read("*a")
	pipe:close()
	return text
end

if not sh("command -v jq"):match("jq") then
	print("skipped: jq is not installed")
	return
end

local function check(name, ok)
	if not ok then error("FAILED: " .. name, 2) end
end

local lines = {
	-- home: an arrived legacy trip, a stuck planner trip, and a bed trip that was superseded
	'{"type":"trip","stage":"home","variant":"A","round":1,"villager":"a","kind":"bed","outcome":"arrived","mode":"legacy","distance":10,"target":{"x":1,"y":1,"z":1},"calls":[{"engine_calls":2,"engine_found":1,"engine_headroom":1,"engine_ms":4,"ms":5,"route":{}}]}',
	'{"type":"trip","stage":"home","variant":"A","round":1,"villager":"b","kind":"bed","outcome":"stuck","mode":"planner","distance":12,"target":{"x":2,"y":1,"z":1},"calls":[{"engine_calls":3,"engine_found":0,"engine_headroom":0,"engine_ms":8,"ms":9,"route":{}}],"stuck":{"feet":"air","head":"air","state":"gowp","doors":[]}}',
	'{"type":"trip","stage":"home","variant":"A","round":1,"villager":"c","kind":"bed","outcome":"superseded","distance":5,"target":{"x":3,"y":1,"z":1},"calls":[]}',
	-- the same trip as villager a, with the engine silenced: the planner finds it
	'{"type":"trip","stage":"home","variant":"B","round":1,"villager":"a","kind":"bed","outcome":"arrived","mode":"planner","distance":10,"target":{"x":1,"y":1,"z":1},"calls":[{"engine_calls":0,"engine_found":0,"engine_headroom":0,"engine_ms":0,"ms":3,"route":{"planner_status":"found","planner_searched":50}}]}',
	-- a retry of villager a's trips from another spot, in both variants, is not another pair
	'{"type":"trip","stage":"home","variant":"A","round":1,"villager":"a","kind":"bed","outcome":"arrived","distance":4,"start":{"x":5,"y":1,"z":1},"target":{"x":1,"y":1,"z":1},"calls":[{"engine_calls":1,"engine_found":0,"engine_headroom":0,"engine_ms":1,"ms":1,"route":{}}]}',
	'{"type":"trip","stage":"home","variant":"B","round":1,"villager":"a","kind":"bed","outcome":"arrived","distance":4,"start":{"x":5,"y":1,"z":1},"target":{"x":1,"y":1,"z":1},"calls":[{"engine_calls":0,"engine_found":0,"engine_headroom":0,"engine_ms":0,"ms":1,"route":{}}]}',
	-- the same villager and target in another run is not paired with this run's
	'{"type":"trip","label":"other","stage":"home","variant":"B","round":1,"villager":"a","kind":"bed","outcome":"arrived","distance":10,"target":{"x":1,"y":1,"z":1},"calls":[]}',
	-- a job trip made during the home stage is not a bed trip
	'{"type":"trip","stage":"home","variant":"A","round":1,"villager":"d","kind":"jobsite","outcome":"arrived","distance":9,"target":{"x":4,"y":1,"z":1},"calls":[]}',
	-- the bell's wander legs are not trips; its one real walk is
	'{"type":"trip","stage":"bell","variant":"A","round":1,"villager":"a","kind":"bell","outcome":"arrived","distance":1.5,"target":{"x":5,"y":1,"z":1},"calls":[]}',
	'{"type":"trip","stage":"bell","variant":"A","round":1,"villager":"b","kind":"bell","outcome":"arrived","distance":20,"target":{"x":6,"y":1,"z":1},"calls":[]}',
	'{"type":"damage","reason":"fall","damage":3}',
}

local path = os.tmpname()
local file = assert(io.open(path, "w"))
file:write(table.concat(lines, "\n"), "\n")
file:close()
local report = sh("sh tools/lv_trips/report.sh " .. path)
os.remove(path)

check("home A counts its four bed trips", report:match("home\tA\ttrips 4\tarrived 2\tstuck 1\tno_route 0\tsuperseded 1"))
check("home B counts its trips", report:match("home\tB\ttrips 3\tarrived 3"))
check("the job trip is left out", not report:match("jobsite"))
check("only the real bell walk counts", report:match("bell\tA\ttrips 1\tarrived 1"))
check("pairing sees the planner find what the engine did", report:match("paired 1\tboth 1\tengine only 0\tplanner only 0\tneither 0"))
check("a stuck trip is listed", report:match("1\tair\tair\tgowp"))
check("damage is counted by reason", report:match("fall\t1"))
print("lv_trips_report: ok")
