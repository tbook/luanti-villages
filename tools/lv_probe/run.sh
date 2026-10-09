#!/bin/sh
# Generate the predicted village sites of one world seed on a throwaway world
# and print the probe's metrics (#144). The real worlds are never touched.
#
#   tools/lv_probe/run.sh SEED [--sites N] [--radius R] [--chunk X,Z] [--with-mod]
#
# --chunk visits only the village site at that chunk minp (as listed in the
# catalog) instead of the nearest N.
# --with-mod also loads living_villages, for the "after" numbers; without it the
# run is vanilla VoxeLibre, the baseline. The mod comes from the checkout this
# script is in (so a worktree measures itself), or from --mod-dir PATH, which
# implies --with-mod. It is copied into the throwaway world; the user mods
# directory only supplies the mods it depends on.
#
# Environment: LUANTI (server binary), LUANTI_USER (user directory with mods/;
# found through git by default), LV_PROBE_WORK (scratch directory, default
# $TMPDIR/lv_probe/<checkout>), LV_PROBE_RESULTS (where the jsonl is copied,
# default tools/lv_probe/results/), LV_PROBE_PORT (first port to try; a free one
# is used, never one a running game holds), LV_PROBE_LIMIT (seconds before giving up).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
. "$here/../probe_common.sh"
mods_dir=$(lv_user_dir)/mods
luanti=${LUANTI:-/Applications/luanti.app/Contents/MacOS/luanti}
results=${LV_PROBE_RESULTS:-$here/results}

seed=${1:?usage: run.sh SEED [--sites N] [--radius R] [--chunk X,Z] [--with-mod] [--mod-dir PATH]}
shift
sites=8
radius=1200
with_mod=0
chunk=
mod_dir=$repo_root
while [ $# -gt 0 ]; do
	case $1 in
		--mod-dir) mod_dir=$2; with_mod=1; shift 2 ;;
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
mod_dir=$(cd "$mod_dir" && pwd)
# One scratch directory per checkout, so runs from different worktrees cannot collide.
tag=$(basename "$mod_dir")-$(printf %s "$mod_dir" | cksum | cut -d' ' -f1)
work=${LV_PROBE_WORK:-${TMPDIR:-/tmp}/lv_probe/$tag}
world=$work/world_$label
rm -rf "$world"
rm -f "$results/$label.jsonl"
mkdir -p "$world/worldmods" "$results"
cp -R "$here/mod/lv_probe" "$world/worldmods/lv_probe"
cp "$mod_dir/village_index.lua" "$world/worldmods/lv_probe/village_index.lua"
# The mod under test is a copy in worldmods, which loads without a world.mt entry; the
# user-directory copy is never enabled.
if [ "$with_mod" = 1 ]; then lv_stage_mod "$mod_dir" "$world/worldmods/living_villages"; fi

{
	echo "gameid = mineclone2"
	echo "world_name = lv_probe_$label"
	echo "backend = sqlite3"
	echo "player_backend = sqlite3"
	echo "auth_backend = sqlite3"
	echo "mod_storage_backend = sqlite3"
	if [ "$with_mod" = 1 ]; then
		# Whatever living_villages needs from the user mods directory.
		queue="living_villages"
		seen=
		while [ -n "$queue" ]; do
			mod=${queue%% *}
			rest=${queue#"$mod"}
			queue=${rest# }
			case " $seen " in *" $mod "*) continue ;; esac
			seen="$seen $mod"
			if [ "$mod" = living_villages ]; then conf=$mod_dir/mod.conf; else
				echo "load_mod_$mod = true"
				conf=$mods_dir/$mod/mod.conf
			fi
			for dep in $(sed -n 's/^\(optional_\)\{0,1\}depends *= *//p' "$conf" | tr ',' ' '); do
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
lv_probe_census = ${LV_PROBE_CENSUS:-0}
EOT

ports=${TMPDIR:-/tmp}/lv_ports
port=$(lv_claim_port "${LV_PROBE_PORT:-30123}" "$ports")
server=
# On exit or Ctrl-C stop the server too, so it does not keep the port and the scratch world.
trap 'if [ -n "$server" ]; then kill "$server" 2> /dev/null || true; fi; lv_release_port "$port" "$ports"' EXIT
trap 'exit 130' INT TERM
log=$work/lv_probe_$label.log
: > "$log"
"$luanti" --server --world "$world" --gameid mineclone2 --config "$conf" \
	--port "$port" --logfile "$log" > /dev/null 2>&1 &
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
status=0
wait "$server" 2> /dev/null || status=$?
grep -h "\[lv_probe\]\|ERROR\[" "$log" | sed 's/^[^[]*//' || true

# Publish only a run that finished: the probe writes the marker after its last site.
if [ ! -f "$world/lv_probe.done" ] || [ ! -f "$world/lv_probe.jsonl" ]; then
	echo "run $label did not finish (server status $status); see $log" >&2
	exit 1
fi
cp "$world/lv_probe.jsonl" "$results/$label.jsonl"
