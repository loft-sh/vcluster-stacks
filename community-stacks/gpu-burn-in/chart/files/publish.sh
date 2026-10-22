#!/bin/sh
# Main container of a GPU test, tools image. Judges what run.sh left in $WORK and writes the
# result ConfigMap. Exits 0 for every verdict, including failed: the report and verdict steps
# decide what a failure means for the Stack.
set -eu
. /scripts/lib.sh
. /scripts/evaluate.sh

evaluate
status=$(jq -r .status "$WORK/result.json")
summary=$(jq -r .summary "$WORK/result.json")
jq .details "$WORK/result.json" >"$WORK/details.json"
write_result "$status" "$summary" "$WORK/details.json"
