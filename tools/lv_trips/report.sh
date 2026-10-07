#!/bin/sh
# Summarize trip probe results (#160): outcomes by stage and variant, how the
# engine's routes compare with the planner's, how often a route that started
# still failed, and what the searches cost. Reads results/*.jsonl, or the
# files named on the command line.
#
#   tools/lv_trips/report.sh [results/*.jsonl]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
if [ $# -eq 0 ]; then set -- "$here"/results/*.jsonl; fi

# A stage measures one kind of trip: home the bed, work the jobsite, the
# taverns the jukebox, church and bell their own. Other trips made in the
# same frozen stage are dropped, as are the bell's wander legs (anything under
# three nodes), which are not trips to anywhere.
jq -s -r '
def pct($p): sort | if length == 0 then null else .[((length * $p) | floor | if . >= length then length - 1 else . end)] end;
def r1: if . == null then "-" else (. * 10 | round / 10 | tostring) end;
def n(f): map(select(f)) | length;
def started: (.started // false) or (.outcome == "arrived") or (.mode != null);
def engine_ok: any(.calls[]?; .engine_headroom > 0);
def planner_ok: any(.calls[]?; .route.planner_status == "found") or (.mode == "planner");
{home: "bed", work: "jobsite", tavern: "tavern", holiday_tavern: "tavern", church: "church", bell: "bell"} as $expected
| [.[] | select(.type == "trip" and .stage != null and .kind == $expected[.stage] and (.stage != "bell" or .distance >= 3))] as $trips
| "== Outcomes by stage and variant (A = as today, B = engine silenced so the planner routes)",
  ($trips | group_by([.stage, .variant]) | .[] |
    "\(.[0].stage)\t\(.[0].variant)\ttrips \(length)\tarrived \(n(.outcome == "arrived"))\tstuck \(n(.outcome == "stuck"))\tno_route \(n(.outcome == "no_route"))\tsuperseded \(n(.outcome == "superseded"))"),
  "",
  "== Route source on arrival or start (mode)",
  ($trips | group_by([.stage, .variant]) | .[] |
    "\(.[0].stage)\t\(.[0].variant)\t" + ([.[] | .mode // "none"] | group_by(.) | map("\(.[0]) \(length)") | join(", "))),
  "",
  "== Did a route that started get there? (trips whose mode is set)",
  ($trips | map(select(.mode != null)) | group_by(.mode)[] |
    "mode \(.[0].mode)\tstarted \(length)\tarrived \(n(.outcome == "arrived"))\tstuck \(n(.outcome == "stuck"))\trecovered by planner \(n(.recovered_by_planner == true))"),
  "",
  "== Engine against planner, same start and target (A round engine route with headroom vs B round planner route)",
  ([$trips[] | select(.variant == "A")] as $a | [$trips[] | select(.variant == "B")] as $b
   | [ $a[] as $x | ($b[] | select(.stage == $x.stage and .round == $x.round and .villager == $x.villager and .target == $x.target)) as $y
       | {engine: ($x | engine_ok), planner: ($y | planner_ok), stage: $x.stage} ]
   | "paired \(length)\tboth \(n(.engine and .planner))\tengine only \(n(.engine and (.planner | not)))\tplanner only \(n((.engine | not) and .planner))\tneither \(n((.engine | not) and (.planner | not)))"),
  "",
  "== Cost (ms per call; planner from B rounds, engine from every round)",
  ([$trips[] | select(.variant == "B") | .calls[]? | select(.route.planner_searched != null and .ms > 0)] as $p
   | "planner searches \($p | length)\tms p50 \($p | map(.ms) | pct(0.5) | r1)  p90 \($p | map(.ms) | pct(0.9) | r1)  p99 \($p | map(.ms) | pct(0.99) | r1)  max \($p | map(.ms) | max | r1)\tnodes p50 \($p | map(.route.planner_searched) | pct(0.5))  p90 \($p | map(.route.planner_searched) | pct(0.9))  p99 \($p | map(.route.planner_searched) | pct(0.99))\tsearch_limit \($p | n(.route.planner_status == "search_limit"))"),
  ([$trips[] | .calls[]? | select(.engine_calls > 0)] as $e
   | "engine calls \([$e[] | .engine_calls] | add)\tper-gopath ms p50 \($e | map(.engine_ms) | pct(0.5) | r1)  p90 \($e | map(.engine_ms) | pct(0.9) | r1)  p99 \($e | map(.engine_ms) | pct(0.99) | r1)  max \($e | map(.engine_ms) | max | r1)"),
  "",
  "== Where trips stuck (feet node / head node / state)",
  ($trips | map(select(.outcome == "stuck")) | group_by([.stuck.feet, .stuck.head, .stuck.state])[] |
    "\(length)\t\(.[0].stuck.feet)\t\(.[0].stuck.head)\t\(.[0].stuck.state)\tdoors near \(.[0].stuck.doors | length)"),
  "",
  "== Natural days (observed, nothing forced): trips of three nodes or more by kind",
  ([.[] | select(.type == "trip" and (.stage == "day" or .stage == "holiday_day") and .distance >= 3)]
   | group_by([.stage, .kind])[] |
    "\(.[0].stage)\t\(.[0].kind)\ttrips \(length)\tarrived \(n(.outcome == "arrived"))\tstuck \(n(.outcome == "stuck"))\tno_route \(n(.outcome == "no_route"))\tsuperseded \(n(.outcome == "superseded"))"),
  "",
  "== Deaths and damage",
  ([.[] | select(.type == "damage")] | group_by(.reason)[] | "\(.[0].reason)\t\(length)")
' "$@"
