#!/bin/sh
# One line per village from probe results (#144), for picking catalog cases and
# for the before-and-after numbers in a PR. Needs jq.
#
#   tools/lv_probe/report.sh [results/SEED.jsonl ...]   (default: every file in results/)
here=$(cd "$(dirname "$0")" && pwd)
[ $# -gt 0 ] || set -- "$here"/results/*.jsonl
jq -r '
	def n: if . == null then "-" else tostring end;
	[ .seed, "\(.chunk.x),\(.chunk.z)", .outcome,
	  (.biome | n), (.total_buildings | n),
	  (if .church then "C" else "-" end) + (if .tavern then "T" else "-" end),
	  (.floors.range | n), (.floors.neighbor_diff | n),
	  (.natural.heights.range | n), (.natural.pit_depth | n),
	  (.natural.fill_cut.fill | n), (.natural.fill_cut.cut | n),
	  (.natural.canopy_cover | n), (.natural.trunk_nodes | n),
	  (.after.steps.largest | n), (.after.steps.over_one | n),
	  (.after.traps.columns | n), (.after.orphan_leaves | n),
	  ([.structures[]? | select(.name != "mineshaft" and .name != "geode") | "\(.name | sub("_overworld$"; ""))@\(.distance // "?")"] | join("+") | if . == "" then "-" else . end),
	  ((.timing_ms.plan + .timing_ms.terraform + .timing_ms.paths + (.timing_ms.place_total // 0)) | if . == null then "-" else (. | round | tostring) end)
	] | @tsv' "$@" 2> /dev/null | {
	printf 'seed\tchunk\toutcome\tbiome\tbldg\tCT\tfloor\tnbr\tterr\tpit\tfill\tcut\tcanopy\ttrunks\tstep\tsteps>1\ttraps\torphans\tstructures\tms\n'
	cat
} | column -t -s "$(printf '\t')"
