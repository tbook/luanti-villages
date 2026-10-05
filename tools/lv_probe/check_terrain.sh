#!/bin/sh
# Headless check for #143: on a fresh throwaway world, village_terrain's height
# read of an ungenerated area is refused, and after village_terrain.emerge it
# succeeds. Prints the [lv_terrain_check] lines; exits 1 unless both hold.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mod_root=$(cd "$here/../.." && pwd)
luanti=${LUANTI:-/Applications/luanti.app/Contents/MacOS/luanti}
work=${LV_PROBE_WORK:-${TMPDIR:-/tmp}/lv_probe}
world=$work/world_terrain_check
rm -rf "$world"
mkdir -p "$world/worldmods"
cp -R "$here/mod/lv_terrain_check" "$world/worldmods/lv_terrain_check"
cp "$mod_root/village_terrain.lua" "$world/worldmods/lv_terrain_check/"
printf 'gameid = mineclone2\nworld_name = lv_terrain_check\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\n' > "$world/world.mt"
conf=$work/lv_terrain_check.conf
printf 'fixed_map_seed = 2026\nmg_name = v7\nnum_emerge_threads = 1\nserver_announce = false\n' > "$conf"
log=$work/lv_terrain_check.log
: > "$log"
"$luanti" --server --world "$world" --gameid mineclone2 --config "$conf" \
	--port "${LV_PROBE_PORT:-30124}" --logfile "$log" > /dev/null 2>&1 &
server=$!
waited=0
while kill -0 "$server" 2> /dev/null; do
	sleep 2
	waited=$((waited + 2))
	if [ "$waited" -gt "${LV_PROBE_LIMIT:-300}" ]; then kill -INT "$server" 2> /dev/null || true; break; fi
done
wait "$server" 2> /dev/null || true
grep -h "lv_terrain_check\]" "$log" | sed 's/^[^[]*//'
grep -q "before emerge: refused" "$log" && grep -q "after emerge: read" "$log"
