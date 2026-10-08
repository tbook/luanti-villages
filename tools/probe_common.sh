# Shared by tools/lv_trips/run.sh and tools/lv_probe/run.sh (source it, do not run it).
# Lets a probe run against any checkout of the mod, such as a git worktree, and lets
# runs from different worktrees go at once.
#
# Needs $repo_root (the checkout the calling script lives in) set before sourcing.

# The user directory (holding mods/ and worlds/). A worktree sits inside the main
# checkout, which sits inside the mods directory, so ask git where the main checkout is.
lv_user_dir() {
	if [ -n "${LUANTI_USER:-}" ]; then
		(cd "$LUANTI_USER" && pwd)
		return
	fi
	common=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2> /dev/null) || common=
	case $common in
		*/.git) main_root=$(dirname "$common") ;;
		*)
			# Old git (before 2.31), or a git dir that is not <checkout>/.git.
			if [ ! -d "$repo_root/../../worlds" ]; then
				echo "cannot find the user directory from $repo_root; set LUANTI_USER" >&2
				return 1
			fi
			main_root=$repo_root
			;;
	esac
	(cd "$(dirname "$main_root")/.." && pwd)
}

# lv_stage_mod SRC DEST: copy the mod (not its tools, tests, docs or git data) to DEST.
# A copy, not a link: the run keeps measuring the code it started with.
lv_stage_mod() {
	rm -rf "$2"
	mkdir -p "$2"
	rsync -a --exclude /.git --exclude /.claude --exclude /tools --exclude /tests --exclude /docs \
		--exclude /.github "$1"/ "$2"/
}

# lv_claim_port PREFERRED CLAIMDIR: print a port nobody is using. A running game
# (30000) or another probe is skipped. A claim file holding the owner's pid keeps
# parallel runs from taking the same port; claims of dead pids are reused.
lv_claim_port() {
	port=$1
	claims=$2
	mkdir -p "$claims"
	tries=0
	while [ $tries -lt 200 ]; do
		if [ -f "$claims/$port" ]; then
			owner=$(cat "$claims/$port" 2> /dev/null) || owner=
			# An empty file is never left by a claim (they are linked in whole), so it is stale too.
			if [ -z "$owner" ] || ! kill -0 "$owner" 2> /dev/null; then
				rm -f "$claims/$port"
			fi
		fi
		if ! lsof -nP -iUDP:"$port" > /dev/null 2>&1 && ! lsof -nP -iTCP:"$port" > /dev/null 2>&1; then
			# Write the pid to a temp file, then link it into place: the claim appears
			# whole, and ln fails if another run got there first.
			tmp=$claims/.tmp.$$
			echo $$ > "$tmp"
			if ln "$tmp" "$claims/$port" 2> /dev/null; then
				rm -f "$tmp"
				echo "$port"
				return 0
			fi
			rm -f "$tmp"
		fi
		port=$((port + 1))
		tries=$((tries + 1))
	done
	echo "no free port found" >&2
	return 1
}

# lv_release_port PORT CLAIMDIR
lv_release_port() {
	rm -f "$2/$1"
}
