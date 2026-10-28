-- Predicate for the optional clone-only workstation ownership race in #318.
local fixture = {}

function fixture.is_pending(search, route)
	return search ~= nil and route ~= nil and search.route_id == route.id
		and route.status == "planning"
		and (search.state == "waiting" or search.state == "yielded")
end

function fixture.has_competitors(pending_count)
	return pending_count >= 2
end

return fixture
