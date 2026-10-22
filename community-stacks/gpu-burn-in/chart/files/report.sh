#!/bin/sh
# Tools image. Collects every step's result ConfigMap into one qualification report, writes it to
# the gpu-burn-in-report ConfigMap (which the Stack publishes as outputs), and optionally copies it
# to S3. Exits 0 whatever the result: the verdict step turns a failed qualification into a failed
# Stack, after the outputs are captured.
#
# The server is qualified only when every expected step passed or was disabled. A missing result,
# a skipped step, an error and a failure all fail it.
set -eu
. /scripts/lib.sh
. /scripts/report-lib.sh

started=$(now)
kubectl get configmaps -l "$RESULT_LABEL=true" -o json | jq '[.items[].data]' >"$WORK/results.json"

node=$(jq -r '[.[] | select(.test == "gpuready") | .gpuNode][0] // ""' "$WORK/results.json")
[ -n "$node" ] || node=${NODE_NAME:-}
if [ -n "$node" ] && kubectl get node "$node" -o json >"$WORK/node.json" 2>/dev/null; then
  jq '{name: .metadata.name, labels: .metadata.labels, providerID: (.spec.providerID // "")}' "$WORK/node.json" >"$WORK/host.json"
else
  jq -n --arg n "$node" '{name: $n, labels: {}, providerID: ""}' >"$WORK/host.json"
fi

build_report "$WORK/results.json" "$WORK/host.json" >"$WORK/report.json"
result=$(jq -r .result "$WORK/report.json")
failed=$(jq -r '.failedTests | join(",")' "$WORK/report.json")
summary=$(jq -r .summary "$WORK/report.json")
log "$result${failed:+: $failed}"
jq -r '.tests[] | "  \(.test): \(.status): \(.summary)"' "$WORK/report.json"

uri=""
if [ -n "$REPORT_S3_URI" ]; then
  key="${REPORT_S3_URI%/}/$(jq -r '.assetID // .host.name' "$WORK/report.json")/$(date -u '+%Y%m%dT%H%M%SZ').json"
  if aws ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"} s3 cp "$WORK/report.json" "$key" --only-show-errors; then
    uri=$key
    log "uploaded $uri"
  else
    log "WARNING: upload to $key failed; the report is still in configmap $REPORT_NAME"
  fi
fi
jq --arg uri "$uri" '.reportURI = $uri' "$WORK/report.json" >"$WORK/report.tmp" && mv "$WORK/report.tmp" "$WORK/report.json"

write_configmap "$REPORT_NAME" '{"app.kubernetes.io/part-of":"gpu-burn-in-stack"}' \
  --from-literal=result="$result" \
  --from-literal=failedTests="$failed" \
  --from-literal=summary="$summary" \
  --from-literal=host="$(jq -r .host.name "$WORK/report.json")" \
  --from-literal=assetID="$(jq -r .assetID "$WORK/report.json")" \
  --from-literal=gpuCount="$(jq -r .detectedGPUs "$WORK/report.json")" \
  --from-literal=reportURI="$uri" \
  --from-literal=startedAt="$started" \
  --from-literal=finishedAt="$(now)" \
  --from-file=report.json="$WORK/report.json"
log "wrote configmap $REPORT_NAME"
