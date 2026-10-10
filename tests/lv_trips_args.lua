-- Run with: lua tests/lv_trips_args.lua (from the repository root)
-- tools/lv_trips/run.sh checks its arguments before it looks for the world, so a
-- bad one exits 2 with a message and no server starts; and the spot run's stage
-- choice (mod/lv_trips/stages.lua) is a pure function.
local function sh(command)
	local pipe = io.popen(command .. " 2>&1; echo \"exit=$?\"")
	local text = pipe:read("*a")
	pipe:close()
	return text
end

local function check(name, ok)
	if not ok then error("FAILED: " .. name, 2) end
end

local function run(args)
	return sh("sh tools/lv_trips/run.sh NoSuchWorld 0,0,0 args_test " .. args)
end

local function rejected(name, args, message)
	local out = run(args)
	check(name .. " exits 2", out:match("exit=2"))
	check(name .. " says why", out:find(message, 1, true))
end

local good = "--spot 1,2,3:4,5,6"
rejected("bad spot decimal", "--spot 1.2.3,1,1:4,5,6", "--spot wants")
rejected("spot letters", "--spot a,b,c:4,5,6", "--spot wants")
rejected("spot one triple", "--spot 1,2,3", "--spot wants")
rejected("goto double decimal", good .. " --goto 1.2.3,1,1", "--goto wants")
rejected("goto trailing dot", good .. " --goto 1.,1,1", "--goto wants")
rejected("goto without spot", "--goto 1,2,3", "need --spot")
rejected("build without spot", "--build tests/lv_trips_args.lua", "need --spot")
rejected("far without spot", "--far 20", "--far needs --spot")
rejected("far letters", good .. " --far soon", "--far wants")
rejected("jump with spot", good .. " --jump work:tavern", "--jump is its own mode")
rejected("jump with a number", "--jump 1:2", "--jump wants")
rejected("jump unknown stage", "--jump work:tavrn", "--jump wants")
rejected("jump without colon", "--jump work", "--jump wants")
rejected("jump with stages", "--jump work:tavern --stages home", "drop --stages")
rejected("jump with rounds", "--jump work:tavern --rounds 2", "drop --stages and --rounds")
rejected("settle letters", "--jump work:tavern --settle soon", "--settle wants")
rejected("watch negative", "--jump work:tavern --watch -5", "--watch wants")
rejected("lag two dots", "--jump work:tavern --lag 1.2.3", "--lag wants")
rejected("scatter empty", "--jump work:tavern --scatter ''", "--scatter wants")
rejected("lag with a newline", "--jump work:tavern --lag '5\nlv_trips_far = 9'", "--lag wants")
rejected("settle with a newline", "--jump work:tavern --settle '5\n6'", "--settle wants")
rejected("jump stage with a newline", "--jump 'work\nlv_x=1:tavern'", "--jump wants")
rejected("far with a newline", "--spot 1,2,3:4,5,6 --far '5\n6'", "--far wants")
rejected("radius letters", "--radius big", "--radius wants")
rejected("lag without jump", "--lag 5", "need --jump")
rejected("far still needs spot or jump", "--far 20", "--far needs --spot or --jump")
rejected("missing build file", good .. " --build no/such/file.lua", "does not exist")

-- Accepted numbers get past argument checks, to the missing world.
local ok = run(good .. " --goto -1.5,2,3.25 --far 20 --build tests/lv_trips_args.lua")
check("good arguments reach the world lookup", ok:find("no world NoSuchWorld", 1, true))
local jump = run("--jump work:tavern --far 60 --lag 4000 --scatter 8")
check("jump arguments reach the world lookup", jump:find("no world NoSuchWorld", 1, true))

local choose = dofile("tools/lv_trips/mod/lv_trips/stages.lua")
local stages = {{name = "home"}, {name = "work"}, {name = "night"}}
check("empty text is home", choose("", stages) == stages[1])
check("nil text is home", choose(nil, stages) == stages[1])
check("home,night picks home", choose("home,night", stages) == stages[1])
check("night,home picks night", choose("night,home", stages) == stages[3])
local stage, problem = choose("nigth", stages)
check("unknown name is an error", stage == nil and problem:find("unknown stage 'nigth'", 1, true))
check("unknown after a known one is still an error", choose("home,nigth", stages) == nil)
print("lv_trips_args: ok")
