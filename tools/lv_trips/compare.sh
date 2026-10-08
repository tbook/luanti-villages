#!/bin/sh
# Compare two trip probe runs (#160) stage by stage: arrived / trips for each, and the
# change in the arrival rate. Use it for a PR's before and after, or against the
# baseline in docs/trip-baseline.md.
#
#   tools/lv_trips/compare.sh BEFORE.jsonl AFTER.jsonl
#   tools/lv_trips/compare.sh results/main_B.jsonl results/pr_B.jsonl
#
# Each side may be several files joined with commas (a.jsonl,b.jsonl) to total
# villages. Counts follow report.sh: only the trips a stage is about, variant A for
# trials, and natural days (trips of three nodes or more) by kind. Trips counts
# differ between runs (a failed villager is sent again), so read the rate too.
set -eu
[ $# -eq 2 ] || { echo "usage: compare.sh BEFORE.jsonl AFTER.jsonl" >&2; exit 2; }

rows() {
	# Split the comma-separated list into arguments without splitting on spaces in paths.
	old_ifs=$IFS
	IFS=,
	set -f
	set -- $1
	set +f
	IFS=$old_ifs
	jq -s -r '
	{home: "bed", work: "jobsite", tavern: "tavern", holiday_tavern: "tavern", church: "church", bell: "bell"} as $expected
	| def n(f): map(select(f)) | length;
	  ([.[] | select(.type == "trip" and .stage != null and .variant != "B" and .kind == $expected[.stage] and (.stage != "bell" or .distance >= 3))]
	   | group_by(.stage)[] | ["trials " + .[0].stage, length, n(.outcome == "arrived"), n(.outcome == "stuck"), n(.outcome == "no_route")]),
	  ([.[] | select(.type == "trip" and (.stage == "day" or .stage == "holiday_day") and .distance >= 3)]
	   | group_by([.stage, .kind])[] | ["" + .[0].stage + " " + .[0].kind, length, n(.outcome == "arrived"), n(.outcome == "stuck"), n(.outcome == "no_route")])
	| @tsv' "$@"
}

before=$(mktemp)
after=$(mktemp)
trap 'rm -f "$before" "$after"' EXIT
rows "$1" > "$before"
rows "$2" > "$after"

awk -F'\t' '
function rate(a, t) { return t > 0 ? sprintf("%.0f%%", 100 * a / t) : "-" }
FNR == NR { b[$1] = $2 "\t" $3 "\t" $4 "\t" $5; keys[$1] = 1; next }
{ a[$1] = $2 "\t" $3 "\t" $4 "\t" $5; keys[$1] = 1 }
END {
	printf "%-26s %-28s %-28s %s\n", "", "before (arr/trips stuck noroute)", "after", "rate change"
	for (k in keys) order[++n] = k
	# insertion sort for a stable, readable order
	for (i = 2; i <= n; i++) { v = order[i]; for (j = i - 1; j > 0 && order[j] > v; j--) order[j + 1] = order[j]; order[j + 1] = v }
	for (i = 1; i <= n; i++) {
		k = order[i]
		split(k in b ? b[k] : "0\t0\t0\t0", x, "\t")
		split(k in a ? a[k] : "0\t0\t0\t0", y, "\t")
		printf "%-26s %-28s %-28s %s -> %s\n", k, sprintf("%d/%d  %d  %d", x[2], x[1], x[3], x[4]), sprintf("%d/%d  %d  %d", y[2], y[1], y[3], y[4]), rate(x[2], x[1]), rate(y[2], y[1])
	}
}' "$before" "$after"
