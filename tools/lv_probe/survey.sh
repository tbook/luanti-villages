#!/bin/sh
# Visit the 14 predicted village sites nearest the origin (within 2400 nodes) on
# each seed from FIRST to LAST, five seeds at a time, then print the village
# yield (#144). The baseline in docs/village-test-seeds.md is seeds 2001 to 2030.
#
#   tools/lv_probe/survey.sh FIRST LAST [--with-mod]
#
# Sites on one world are visited in sequence, so the terrain around a later site
# may already have been touched by an earlier one; use run_cases.sh for repeatable
# single villages and this for yield. Takes about 15 minutes for 30 seeds.
# Exits nonzero, without a summary, if any seed failed.
here=$(cd "$(dirname "$0")" && pwd)
results=${LV_PROBE_RESULTS:-$here/results}
first=${1:?usage: survey.sh FIRST LAST [--with-mod]}
last=${2:?usage: survey.sh FIRST LAST [--with-mod]}
shift 2
suffix=
[ "$1" = "--with-mod" ] && suffix=-mod
n=0
failed=0
pids=
seed=$first
while [ "$seed" -le "$last" ]; do
	LV_PROBE_PORT=$((30700 + n)) "$here/run.sh" "$seed" --sites 14 --radius 2400 "$@" > /dev/null &
	pids="$pids $!"
	n=$((n + 1))
	if [ $((n % 5)) -eq 0 ]; then
		for pid in $pids; do wait "$pid" || failed=1; done
		pids=
	fi
	seed=$((seed + 1))
done
for pid in $pids; do wait "$pid" || failed=1; done
if [ "$failed" = 1 ]; then
	echo "survey: at least one seed failed; no summary" >&2
	exit 1
fi
set --
seed=$first
while [ "$seed" -le "$last" ]; do
	set -- "$@" "$results/$seed$suffix.jsonl"
	seed=$((seed + 1))
done
"$here/yield.sh" "$@"
