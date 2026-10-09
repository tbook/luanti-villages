-- Run with: lua tests/lv_probe_args.lua (from the repository root)
-- tools/lv_probe/run.sh checks LV_PROBE_CENSUS (#217) before it builds a world, so a bad
-- value exits 2 with a message and no server starts.
local function sh(command)
	local pipe = io.popen(command .. " 2>&1; echo \"exit=$?\"")
	local text = pipe:read("*a")
	pipe:close()
	return text
end

local function check(name, ok)
	if not ok then error("FAILED: " .. name, 2) end
end

local function run(census, args)
	return sh("LV_PROBE_CENSUS='" .. census .. "' LUANTI=/nonexistent sh tools/lv_probe/run.sh 1 " .. args)
end

local function rejected(name, census, args, message)
	local out = run(census, args)
	check(name .. " exits 2", out:match("exit=2"))
	check(name .. " says why", out:find(message, 1, true))
end

rejected("letters", "abc", "--with-mod", "whole number of seconds")
rejected("negative", "-5", "--with-mod", "whole number of seconds")
rejected("decimal", "1.5", "--with-mod", "whole number of seconds")
rejected("newline injection", "30\nfixed_map_seed = 7", "--with-mod", "whole number of seconds")
rejected("census without the mod", "30", "", "needs --with-mod")

-- A valid value gets past the argument checks (the missing server binary is the next failure).
local ok = run("30", "--with-mod")
check("valid census is not an argument error", not ok:find("whole number", 1, true) and not ok:find("needs --with-mod", 1, true))
local off = run("0", "")
check("zero needs no mod", not off:find("needs --with-mod", 1, true))
print("lv_probe_args: ok")
