#!/bin/sh
# Generate the predicted village sites of one world seed on a throwaway world
# and print the probe's metrics (#144). The real worlds are never touched.
#
#   tools/lv_probe/run.sh SEED [--sites N] [--radius R] [--chunk X,Z] [--with-mod]
#
# --chunk visits only the village site at that chunk minp (as listed in the
# catalog) instead of the nearest N.
# --with-mod also loads living_villages from the user mods directory (the
# branch you have checked out), for the "after" numbers; without it the run is
# vanilla VoxeLibre, the baseline.
#
# Environment: LUANTI (server binary), LV_PROBE_WORK (scratch directory, default
# $TMPDIR/lv_probe), LV_PROBE_RESULTS (where the jsonl is copied, default
# tools/lv_probe/results/), LV_PROBE_PORT, LV_PROBE_LIMIT (seconds before giving up).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
mod_root=$(cd "$here/../.." && pwd)
mods_dir=$(dirname "$mod_root")
luanti=${LUANTI:-/Applications/luanti.app/Contents/MacOS/luanti}
work=${LV_PROBE_WORK:-${TMPDIR:-/tmp}/lv_probe}
results=${LV_PROBE_RESULTS:-$here/results}

seed=${1:?usage: run.sh SEED [--sites N] [--radius R] [--chunk X,Z] [--with-mod]}
shift
sites=8
radius=1200
with_mod=0
chunk=
while [ $# -gt 0 ]; do
	case $1 in
		--sites) sites=$2; shift 2 ;;
		--radius) radius=$2; shift 2 ;;
		--chunk) chunk=$2; shift 2 ;;
		--with-mod) with_mod=1; shift ;;
		*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done

label=$seed
if [ -n "$chunk" ]; then label=$seed@$(echo "$chunk" | tr ',' '_'); fi
if [ "$with_mod" = 1 ]; then label=$label-mod; fi
world=$work/world_$label
rm -rf "$world"
mkdir -p "$world/worldmods" "$results"
cp -R "$here/mod/lv_probe" "$world/worldmods/lv_probe"
cp "$mod_root/village_index.lua" "$world/worldmods/lv_probe/village_index.lua"

{
	echo "gameid = mineclone2"
	echo "world_name = lv_probe_$label"
	echo "backend = sqlite3"
	echo "player_backend = sqlite3"
	echo "auth_backend = sqlite3"
	echo "mod_storage_backend = sqlite3"
	if [ "$with_mod" = 1 ]; then
		# living_villages and whatever it needs from the user mods directory.
		queue="living_villages"
		seen=
		while [ -n "$queue" ]; do
			mod=${queue%% *}
			rest=${queue#"$mod"}
			queue=${rest# }
			case " $seen " in *" $mod "*) continue ;; esac
			seen="$seen $mod"
			echo "load_mod_$mod = true"
			for dep in $(sed -n 's/^\(optional_\)\{0,1\}depends *= *//p' "$mods_dir/$mod/mod.conf" | tr ',' ' '); do
				if [ -f "$mods_dir/$dep/mod.conf" ]; then queue="$queue $dep"; fi
			done
		done
	fi
} > "$world/world.mt"

# A world made from the menu with this seed gets v7 and the game's defaults.
conf=$work/lv_probe_$label.conf
cat > "$conf" <<EOT
fixed_map_seed = $seed
mg_name = v7
max_forceloaded_blocks = 4000
num_emerge_threads = 1
server_announce = false
enable_damage = false
lv_probe_sites = $sites
lv_probe_radius = $radius
lv_probe_chunk = $chunk
EOT

log=$work/lv_probe_$label.log
: > "$log"
"$luanti" --server --world "$world" --gameid mineclone2 --config "$conf" \
	--port "${LV_PROBE_PORT:-30123}" --logfile "$log" > /dev/null 2>&1 &
server=$!

# The probe asks the server to shut down when it has visited every site.
waited=0
while kill -0 "$server" 2> /dev/null; do
	sleep 5
	waited=$((waited + 5))
	if [ "$waited" -gt "${LV_PROBE_LIMIT:-3600}" ]; then
		echo "gave up after ${waited}s" >&2
		kill -INT "$server" 2> /dev/null || true
		break
	fi
done
wait "$server" 2> /dev/null || true

if [ -f "$world/lv_probe.jsonl" ]; then cp "$world/lv_probe.jsonl" "$results/$label.jsonl"; fi
grep -h "\[lv_probe\]\|ERROR\[" "$log" | sed 's/^[^[]*//' || true
