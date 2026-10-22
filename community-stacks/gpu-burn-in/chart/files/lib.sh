# Shared helpers for the tools-image containers (alpine/k8s: sh, kubectl, jq, awk, aws).
# Sourced, not run.

log() { echo "$(date -u '+%H:%M:%S') [$TEST] $*"; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

RESULT_LABEL=gpu-burn-in.vcluster.com/result
REPORT_NAME=gpu-burn-in-report

# write_configmap NAME LABEL_JSON [kubectl create configmap args...]
# Server-side apply, so a large log does not land in a last-applied annotation (256KiB cap).
write_configmap() {
  name=$1 labels=$2
  shift 2
  kubectl create configmap "$name" --dry-run=client -o json "$@" |
    jq --argjson labels "$labels" '.metadata.labels = $labels' |
    kubectl apply --server-side --force-conflicts --field-manager=gpu-burn-in -f - >/dev/null
}

# write_result STATUS SUMMARY DETAILS_JSON_FILE [extra --from-literal args...]
# One ConfigMap per step, gpu-burn-in-result-<test>. The report reads them by label.
write_result() {
  status=$1 summary=$2 details=$3
  shift 3
  logfile=$WORK/log.txt
  [ -f "$logfile" ] || : >"$logfile"
  # A ConfigMap holds at most 1MiB. Keep the end of the log, where failures are.
  tail -c 262144 "$logfile" >"$WORK/log.tail"
  write_configmap "gpu-burn-in-result-$TEST" \
    "{\"$RESULT_LABEL\":\"true\",\"app.kubernetes.io/part-of\":\"gpu-burn-in-stack\"}" \
    --from-literal=test="$TEST" \
    --from-literal=status="$status" \
    --from-literal=summary="$summary" \
    --from-literal=node="${NODE_NAME:-}" \
    --from-literal=startedAt="$(cat "$WORK/started" 2>/dev/null || now)" \
    --from-literal=finishedAt="$(cat "$WORK/finished" 2>/dev/null || now)" \
    --from-file=details.json="$details" \
    --from-file=log="$WORK/log.tail" \
    "$@"
  log "$status: $summary"
}
