#!/bin/sh
# Village yield from probe results (#144): what became of the sites VoxeLibre
# tried, and what the villages that got built contain. Needs jq.
#
#   tools/lv_probe/yield.sh results/2001.jsonl ...
jq -s -r '
	def pct(a; b): if b == 0 then "-" else "\((a * 1000 / b | round) / 10)%" end;
	(map(select(.outcome == "built"))) as $built
	| "sites tried:          \(length)",
	  "built:                \($built | length) (\(pct($built | length; length)))",
	  "plan failed:          \(map(select(.outcome == "plan_failed")) | length)",
	  "not built:            \(map(select(.outcome == "not_built")) | length)\(map(select(.outcome == "not_built") | .reason // "never tried") | group_by(.) | map("\(.[0]): \(length)") | if length > 0 then " (" + join(", ") + ")" else "" end)",
	  "buildings per village: \(($built | map(.total_buildings) | add) / ($built | length) * 10 | round / 10)",
	  "with a church:        \(pct($built | map(select(.church)) | length; $built | length))",
	  "with a tavern:        \(pct($built | map(select(.tavern)) | length; $built | length))",
	  "floor range (median): \($built | map(.floors.range) | sort | .[length / 2 | floor])",
	  "neighbor diff (median): \($built | map(.floors.neighbor_diff) | sort | .[length / 2 | floor])",
	  "largest step (median): \($built | map(.after.steps.largest) | sort | .[length / 2 | floor])",
	  "villages with a trap: \(pct($built | map(select(.after.traps.columns > 0)) | length; $built | length))"
' "$@"
