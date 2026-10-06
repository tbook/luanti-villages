#!/bin/sh
# Regenerates tests/fixtures/buildings/*.lua and node_defs.lua from the installed
# VoxeLibre, on a throwaway world with living_villages loaded (#159).
#
#   tools/extract_schematics/run.sh
#
# Environment: LUANTI (server binary), EXTRACT_PORT, EXTRACT_VERSION (the label
# written into the headers; default read from the game's mod.conf-less VERSION guess).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
mod_root=$(cd "$here/../.." && pwd)
mods_dir=$(dirname "$mod_root")
luanti=${LUANTI:-/Applications/luanti.app/Contents/MacOS/luanti}
work=${TMPDIR:-/tmp}/lv_extract
out=$mod_root/tests/fixtures/buildings
version=${EXTRACT_VERSION:-0.92.3}

rm -rf "$work"
mkdir -p "$work/world/worldmods" "$out"
cp -R "$here/mod/lv_extract" "$work/world/worldmods/lv_extract"
{
	echo "gameid = mineclone2"
	echo "world_name = lv_extract"
	echo "backend = sqlite3"
	echo "player_backend = sqlite3"
	echo "auth_backend = sqlite3"
	echo "mod_storage_backend = sqlite3"
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
} > "$work/world/world.mt"
cat > "$work/lv_extract.conf" <<EOT
mg_name = singlenode
server_announce = false
lv_extract_version = $version
EOT

"$luanti" --server --world "$work/world" --gameid mineclone2 --config "$work/lv_extract.conf" \
	--port "${EXTRACT_PORT:-30124}" --logfile "$work/lv_extract.log" > /dev/null 2>&1 || true
grep -h "\[lv_extract\]\|ERROR\[" "$work/lv_extract.log" | sed 's/^[^[]*//' || true
cp "$work"/world/fixtures/*.lua "$out"/
