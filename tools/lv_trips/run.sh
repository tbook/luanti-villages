#!/bin/sh
# Run the trip probe (#160) on a throwaway copy of a real world and publish its
# result lines. The real world is only read: it is cloned into the work
# directory and every edit is made to the clone.
#
#   tools/lv_trips/run.sh WORLD X,Y,Z LABEL [--mode trials|day] [--rounds N]
#                         [--stages home,work,...] [--radius R] [--speed S]
#                         [--mod-dir PATH] [--spot SX,SY,SZ:BX,BY,BZ]
#                         [--goto GX,GY,GZ] [--build FILE.lua]
#
# WORLD is a directory name under the user's worlds directory, X,Y,Z a point in
# the village (a villager's position will do) and LABEL names the run and its
# result file. living_villages is loaded from --mod-dir (default: the checkout
# this script is in, so a run from a worktree measures that worktree). It is
# copied into the clone and the user-directory copy is not used.
# Other mods the world names come from the user mods directory.
#
# Environment: LUANTI (server binary), LUANTI_USER (user directory holding
# worlds/ and mods/; found through git by default), LV_TRIPS_WORK (scratch
# directory, default $TMPDIR/lv_trips/<checkout>), LV_TRIPS_RESULTS,
# LV_TRIPS_PORT (first port to try; the run takes a free one and never one that
# a running game holds), LV_TRIPS_LIMIT (seconds).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
. "$here/../probe_common.sh"
user_dir=$(lv_user_dir)
worlds=$user_dir/worlds
luanti=${LUANTI:-/Applications/luanti.app/Contents/MacOS/luanti}
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
spot=
goto=
build=
mode_given=
mod_dir=$repo_root
while [ $# -gt 0 ]; do
	case $1 in
		--mode) mode=$2; mode_given=1; shift 2 ;;
		--rounds) rounds=$2; shift 2 ;;
		--stages) stages=$2; shift 2 ;;
		--radius) radius=$2; shift 2 ;;
		--speed) speed=$2; shift 2 ;;
		--spot)
			case $2 in
				*[!0-9.,:-]* | '') echo "--spot wants SX,SY,SZ:BX,BY,BZ (numbers), not '$2'" >&2; exit 2 ;;
			esac
			if ! printf %s "$2" | grep -Eq '^-?[0-9.]+(,-?[0-9.]+){2}:-?[0-9.]+(,-?[0-9.]+){2}$'; then
				echo "--spot wants SX,SY,SZ:BX,BY,BZ, not '$2'" >&2; exit 2
			fi
			spot=$(printf %s "$2" | tr ':' ';'); shift 2 ;;
		--goto)
			if ! printf %s "$2" | grep -Eq '^-?[0-9.]+(,-?[0-9.]+){2}$'; then
				echo "--goto wants GX,GY,GZ, not '$2'" >&2; exit 2
			fi
			goto=$(printf %s "$2" | tr ',' ';'); shift 2 ;;
		--build) build=$2; shift 2 ;;
		--mod-dir) mod_dir=$2; shift 2 ;;
		*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done

if [ -n "$spot" ]; then
	if [ -n "$mode_given" ]; then echo "--spot is its own mode; drop --mode" >&2; exit 2; fi
	mode=spot
fi
mod_dir=$(cd "$mod_dir" && pwd)
if [ ! -f "$mod_dir/mod.conf" ] || [ ! -f "$mod_dir/init.lua" ]; then
	echo "$mod_dir is not the living_villages mod" >&2
	exit 2
fi
if [ ! -d "$worlds/$source_world" ]; then
	echo "no world $source_world under $worlds" >&2
	exit 2
fi
# One scratch directory per checkout, so runs from different worktrees cannot collide.
tag=$(basename "$mod_dir")-$(printf %s "$mod_dir" | cksum | cut -d' ' -f1)
work=${LV_TRIPS_WORK:-${TMPDIR:-/tmp}/lv_trips/$tag}

world=$work/world_$label
rm -rf "$world"
mkdir -p "$work" "$results"
cp -cR "$worlds/$source_world" "$world" 2> /dev/null || cp -R "$worlds/$source_world" "$world"
mkdir -p "$world/worldmods"
cp -R "$here/mod/lv_trips" "$world/worldmods/lv_trips"
if [ -n "$build" ]; then cp "$build" "$world/worldmods/lv_trips/build.lua"; fi
lv_stage_mod "$mod_dir" "$world/worldmods/living_villages"
rm -f "$world/lv_trips.jsonl" "$world/lv_trips.done"
# Mods named by a path (mods/x) load by name; the bare name is what the game needs.
sed -i '' -e 's|^\(load_mod_[A-Za-z0-9_]*\) *= *mods/.*|\1 = true|' "$world/world.mt"
# living_villages: switching off the world's entry for the user mods directory lets the
# staged copy in worldmods load instead (a bare "= true" loads the user-directory one).
# The "loaded from" line in the log shows which copy a run used.
sed -i '' -e '/^load_mod_living_villages/d' "$world/world.mt"
echo >> "$world/world.mt"
echo "load_mod_living_villages = false" >> "$world/world.mt"

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
lv_trips_spot = $spot
lv_trips_goto = $goto
EOT

ports=${TMPDIR:-/tmp}/lv_ports
port=$(lv_claim_port "${LV_TRIPS_PORT:-30124}" "$ports")
server=
# On exit or Ctrl-C stop the server too, so it does not keep the port and the scratch world.
trap 'if [ -n "$server" ]; then kill "$server" 2> /dev/null || true; fi; lv_release_port "$port" "$ports"' EXIT
trap 'exit 130' INT TERM
log=$work/lv_trips_$label.log
: > "$log"
echo "mod: $mod_dir  port: $port  log: $log"
"$luanti" --server --world "$world" --gameid mineclone2 --config "$conf" \
	--port "$port" --logfile "$log" > /dev/null 2>&1 &
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
