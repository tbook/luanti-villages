#!/bin/sh
# Generate every case in cases.txt on its own fresh world, five at a time, and
# print the table (#144). Pass --with-mod for the numbers with living_villages.
#
#   tools/lv_probe/run_cases.sh [--with-mod]
#
# Results go to tools/lv_probe/results/<seed>@<x>_<z>[-mod].jsonl. Takes a few minutes.
# Exits nonzero, without a table, if any run failed.
here=$(cd "$(dirname "$0")" && pwd)
results=${LV_PROBE_RESULTS:-$here/results}
suffix=
[ "$1" = "--with-mod" ] && suffix=-mod
n=0
failed=0
pids=
while IFS="	" read -r name seed chunk; do
	case $name in ""|"#"*) continue ;; esac
	LV_PROBE_PORT=$((30300 + n)) "$here/run.sh" "$seed" --chunk "$chunk" "$@" > /dev/null &
	pids="$pids $!"
	n=$((n + 1))
	if [ $((n % 5)) -eq 0 ]; then
		for pid in $pids; do wait "$pid" || failed=1; done
		pids=
	fi
done < "$here/cases.txt"
for pid in $pids; do wait "$pid" || failed=1; done
if [ "$failed" = 1 ]; then
	echo "run_cases: at least one case failed; no table" >&2
	exit 1
fi
set --
while IFS="	" read -r name seed chunk; do
	case $name in ""|"#"*) continue ;; esac
	set -- "$@" "$results/$seed@$(echo "$chunk" | tr ',' '_')$suffix.jsonl"
done < "$here/cases.txt"
"$here/report.sh" "$@"
