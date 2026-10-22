# build_report RESULTS_JSON HOST_JSON: the qualification report on stdout. Sourced by report.sh,
# and by tests/evaluate-test.sh against fixtures. Needs only jq.
#
# RESULTS_JSON is an array of result ConfigMap data maps; details.json is a JSON string in each.
# A test can have one result per node.
#
# nodes[] gives each node its own verdict, from the tests that ran on it. A test with no node (a
# missing result) counts against every node. With one server, its entry matches the run's verdict.
build_report() {
  jq -n --slurpfile results "$1" --slurpfile host "$2" \
    --arg tests "$TESTS" --arg assetID "$ASSET_ID" --arg profile "$PROFILE" \
    --argjson expected "$EXPECTED_GPUS" '
    ($results[0] | group_by(.test) | map({key: .[0].test, value: .}) | from_entries) as $by |
    [$tests | split(",")[] | select(length > 0)] as $want |
    [$want[] as $t | ($by[$t] // [{test: $t, status: "missing", summary: "no result recorded"}])[] |
      {test: .test, status: .status, summary: .summary, node: (.node // ""),
       startedAt: (.startedAt // ""), finishedAt: (.finishedAt // ""),
       details: ((.["details.json"] // "{}") | fromjson? // {})} | .metrics = (.details.metrics // {})] as $tests |
    def failing: select(.status != "passed" and .status != "disabled");
    def distinct: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    def verdict($f): if ($f | length) == 0 then "passed" else "failed" end;
    def summarize($ts): [$ts[] | failing] as $bad |
      if ($bad | length) == 0
      then "qualified: \([$ts[] | select(.status == "passed") | .test] | join(", "))"
      else [$bad[] | "\(.test) \(.status): \(.summary)"] | join("; ") end;
    [$tests[] | failing | .test] | distinct as $failed |
    ([$tests[].node | select(. != "")] + [$host[0].name // "" | select(. != "")] | unique) as $names |
    ([$tests[] | select(.test == "inventory") | .details][0] // {}) as $inv |
    {schema: "gpu-burn-in.vcluster.com/v1",
     result: verdict($failed),
     failedTests: $failed,
     summary: summarize($tests),
     assetID: (if $assetID != "" then $assetID else null end),
     profile: $profile,
     host: ($host[0] + {dmi: ($inv.dmi // {})}),
     expectedGPUs: $expected,
     detectedGPUs: ($inv.gpuCount // 0),
     gpus: ($inv.gpus // []),
     startedAt: ([$tests[].startedAt | select(. != "")] | min // ""),
     tests: $tests,
     nodes: [$names[] as $n | [$tests[] | select(.node == $n or .node == "")] as $mine |
       [$mine[] | failing | .test] | distinct as $f |
       {name: $n, result: verdict($f), failedTests: $f, summary: summarize($mine)}]}'
}
