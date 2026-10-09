-- Which stage a --spot run uses (pure; tests/lv_trips_args.lua covers it).
-- `text` is lv_trips_stages ("home,night"); `stages` the list of stage tables.
-- The first name wins, an empty text means the first stage (home), and any name
-- that is not a stage is an error rather than a silent fall back to home.
local function choose(text, stages)
	local chosen
	for name in (text or ""):gmatch("[^,]+") do
		local found
		for _, candidate in ipairs(stages) do
			if candidate.name == name then found = candidate end
		end
		if not found then
			local known = {}
			for _, candidate in ipairs(stages) do table.insert(known, candidate.name) end
			return nil, "unknown stage '" .. name .. "' (known: " .. table.concat(known, ", ") .. ")"
		end
		chosen = chosen or found
	end
	return chosen or stages[1]
end

return choose
