#!/bin/sh
# Run the trip probe (#160) on a throwaway copy of a real world and publish its
# result lines. The real world is only read: it is cloned into the work
# directory and every edit is made to the clone.
#
#   tools/lv_trips/run.sh WORLD X,Y,Z LABEL [--mode trials|day] [--rounds N]
#                         [--stages home,work,...] [--radius R] [--speed S]
#
# WORLD is a directory name under the user's worlds directory, X,Y,Z a point in
# the village (a villager's position will do) and LABEL names the run and its
# result file. The mods the world uses are loaded from the user mods directory,
# so the run measures the branch that is checked out.
#
# Environment: LUANTI (server binary), LV_TRIPS_WORK (scratch directory, default
# $TMPDIR/lv_trips), LV_TRIPS_RESULTS, LV_TRIPS_PORT, LV_TRIPS_LIMIT (seconds).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
mod_root=$(cd "$here/../.." && pwd)
worlds=$(cd "$mod_root/../../worlds" && pwd)
luanti=${LUANTI:-/Applications/luanti.app/Contents/MacOS/luanti}
work=${LV_TRIPS_WORK:-${TMPDIR:-/tmp}/lv_trips}
results=${LV_TRIPS_RESULTS:-$here/results}

source_world=${1:?usage: run.sh WORLD X,Y,Z LABEL [options]}
center=${2:?usage: run.sh WORLD X,Y,Z LABEL [options]}
label=${3:?usage: run.sh WORLD X,Y,Z LABEL [options]}
shift 3
mode=trials
rounds=3
stages=
radius=64
speed=72
while [ $# -gt 0 ]; do
	case $1 in
		--mode) mode=$2; shift 2 ;;
		--rounds) rounds=$2; shift 2 ;;
		--stages) stages=$2; shift 2 ;;
		--radius) radius=$2; shift 2 ;;
		--speed) speed=$2; shift 2 ;;
		*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done

world=$work/world_$label
rm -rf "$world"
mkdir -p "$work" "$results"
cp -cR "$worlds/$source_world" "$world" 2> /dev/null || cp -R "$worlds/$source_world" "$world"
mkdir -p "$world/worldmods"
cp -R "$here/mod/lv_trips" "$world/worldmods/lv_trips"
rm -f "$world/lv_trips.jsonl" "$world/lv_trips.done"
# Mods named by a path (mods/x) load by name; the bare name is what the game needs.
sed -i '' -e 's|^\(load_mod_[A-Za-z0-9_]*\) *= *mods/.*|\1 = true|' "$world/world.mt"

time_speed=0
if [ "$mode" = day ]; then time_speed=$speed; fi
conf=$work/lv_trips_$label.conf
cat > "$conf" <<EOT
max_forceloaded_blocks = 4000
server_announce = false
enable_damage = false
time_speed = $time_speed
lv_trips_center = $center
lv_trips_radius = $radius
lv_trips_mode = $mode
lv_trips_rounds = $rounds
lv_trips_stages = $stages
lv_trips_speed = $speed
lv_trips_label = $label
EOT

log=$work/lv_trips_$label.log
: > "$log"
"$luanti" --server --world "$world" --gameid mineclone2 --config "$conf" \
	--port "${LV_TRIPS_PORT:-30124}" --logfile "$log" > /dev/null 2>&1 &
server=$!

waited=0
while kill -0 "$server" 2> /dev/null; do
	sleep 5
	waited=$((waited + 5))
	if [ "$waited" -gt "${LV_TRIPS_LIMIT:-5400}" ]; then
		echo "gave up after ${waited}s" >&2
		kill -INT "$server" 2> /dev/null || true
		break
	fi
done
status=0
wait "$server" 2> /dev/null || status=$?
grep -h "\[lv_trips\]\|ERROR\[" "$log" | sed 's/^[^[]*//' | tail -40 || true

if [ ! -f "$world/lv_trips.done" ] || [ ! -f "$world/lv_trips.jsonl" ]; then
	# Keep what was measured: a long run is worth reading even when it stopped early.
	[ -f "$world/lv_trips.jsonl" ] && cp "$world/lv_trips.jsonl" "$results/$label.partial.jsonl"
	echo "run $label did not finish (server status $status); see $log" >&2
	exit 1
fi
cp "$world/lv_trips.jsonl" "$results/$label.jsonl"
echo "wrote $results/$label.jsonl"
