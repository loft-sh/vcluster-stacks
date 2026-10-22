#!/bin/sh
# Unit tests for the pass/fail logic, with no cluster and no GPU:
#
#   ./community-stacks/gpu-burn-in/tests/evaluate-test.sh
#
# Each directory in fixtures/ holds what run.sh would leave in $WORK for one test, and a case.env
# with TEST, any setting overrides, the expected status (WANT), optionally a substring of the
# expected summary (WANT_SUMMARY), and optionally metrics the result must carry (WANT_METRIC). The
# fixtures are hand-written in the formats nvidia-smi, dcgmi diag -j, nccl-tests and dcgmi dmon
# print; refresh them from a real run when one is available.
#
# The report cases feed build_report result ConfigMaps and check the overall verdict.
#
# Needs sh, jq and awk. Exits 1 on failures.
set -u
here=$(cd "$(dirname "$0")" && pwd)
files=$here/../chart/files
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0 count=0

for case in "$here"/fixtures/*/; do
  name=$(basename "$case")
  count=$((count + 1))
  WORK=$tmp/$name
  cp -R "$case" "$WORK"
  (
    # The defaults the chart passes, then the case's overrides.
    EXPECTED_GPUS=8 GPU_MODEL=B300 FAIL_ON_SKIP=false DCGM_DIAG_LEVEL=3 DCGM_EXTRA_TESTS=""
    NCCL_MIN_BUS_BW=0 SOAK_MINUTES=60 SOAK_LOAD=dcgm MAX_GPU_TEMP_C=90 MAX_NVLINK_ERRORS=0 RUN_TIMEOUT_SECONDS=3600
    ENABLED=true NVLINK_FABRIC=auto WANT_SUMMARY="" WANT_METRIC=""
    . "$WORK/case.env"
    export WORK
    . "$files/evaluate.sh"
    evaluate
    got=$(jq -r .status "$WORK/result.json")
    summary=$(jq -r .summary "$WORK/result.json")
    if [ "$got" != "$WANT" ]; then
      echo "FAIL $name: status $got, want $WANT ($summary)"
      exit 1
    fi
    case "$summary" in
      *"$WANT_SUMMARY"*) ;;
      *) echo "FAIL $name: summary '$summary' does not contain '$WANT_SUMMARY'"; exit 1 ;;
    esac
    case "$got" in
      passed | failed) ;;
      *) if [ "$(jq '.details.metrics // {} | length' "$WORK/result.json")" != 0 ]; then
           echo "FAIL $name: a $got test carries metrics"; exit 1
         fi ;;
    esac
    # WANT_METRIC="name=value ..." checks the metrics contract the recorder publishes.
    for want in ${WANT_METRIC:-}; do
      got_m=$(jq -r --arg k "${want%%=*}" '.details.metrics[$k] // "absent"' "$WORK/result.json")
      if [ "$got_m" != "${want#*=}" ]; then
        echo "FAIL $name: metric ${want%%=*}=$got_m, want ${want#*=}"
        exit 1
      fi
    done
    echo "ok   $name: $got: $summary"
  ) || failures=$((failures + 1))
done

# --- build_report -----------------------------------------------------------------------------
. "$files/report-lib.sh"
TESTS=gpuready,inventory,dcgmdiag,nccl,soak ASSET_ID=bmh-b300-001 PROFILE=b300-burnin-v1 EXPECTED_GPUS=8
inv='{"gpuCount":8,"gpus":[{"index":0,"uuid":"GPU-0"}],"dmi":{"product_serial":"S123"}}'
echo '{"name":"b300-001","labels":{"vcluster.com/accelerator":"b300"},"providerID":""}' >"$tmp/host.json"

# report_case NAME WANT_RESULT WANT_FAILED STATUS_OF_EACH_TEST...
report_case() {
  name=$1 want=$2 want_failed=$3
  shift 3
  count=$((count + 1))
  printf '%s\n' "$@" | jq -R -s --arg inv "$inv" '
    [split("\n")[] | select(length > 0) | split("=") |
      {test: .[0], status: .[1], summary: "\(.[0]) \(.[1])",
       "details.json": (if .[0] == "inventory" then $inv else "{}" end)}]' >"$tmp/results.json"
  out=$(build_report "$tmp/results.json" "$tmp/host.json")
  got=$(echo "$out" | jq -r .result)
  failed=$(echo "$out" | jq -r '.failedTests | join(",")')
  # One server: one nodes[] entry, the host, with the run's own verdict.
  nodes=$(echo "$out" | jq -r '[.nodes[] | "\(.name)=\(.result)=\(.failedTests | join(","))"] | join(" ")')
  if [ "$got" = "$want" ] && [ "$failed" = "$want_failed" ] && [ "$nodes" = "b300-001=$want=$want_failed" ] &&
    [ "$(echo "$out" | jq -r '.detectedGPUs, .assetID, .host.dmi.product_serial' | tr '\n' ' ')" = "8 bmh-b300-001 S123 " ]; then
    echo "ok   report $name: $got${failed:+ ($failed)}"
  else
    echo "FAIL report $name: result $got failed '$failed' nodes '$nodes', want $want '$want_failed'"
    failures=$((failures + 1))
  fi
}
report_case all-passed passed "" gpuready=passed inventory=passed dcgmdiag=passed nccl=passed soak=passed
report_case nccl-disabled passed "" gpuready=passed inventory=passed dcgmdiag=passed nccl=disabled soak=passed
report_case inventory-failed failed inventory,dcgmdiag,nccl,soak gpuready=passed inventory=failed dcgmdiag=skipped nccl=skipped soak=skipped
report_case soak-error failed soak gpuready=passed inventory=passed dcgmdiag=passed nccl=passed soak=error
report_case result-missing failed soak gpuready=passed inventory=passed dcgmdiag=passed nccl=passed

# Two nodes: each gets the verdict of the tests that ran on it; a missing result counts against both.
# node_case NAME WANT_NODES TEST=STATUS@NODE...
node_case() {
  name=$1 want=$2
  shift 2
  count=$((count + 1))
  printf '%s\n' "$@" | jq -R -s '
    [split("\n")[] | select(length > 0) | capture("(?<test>[^=]+)=(?<status>[^@]+)@?(?<node>.*)") |
      {test, status, node, summary: "\(.test) \(.status)", "details.json": "{}"}]' >"$tmp/results.json"
  got=$(build_report "$tmp/results.json" "$tmp/host.json" |
    jq -r '[.nodes[] | "\(.name)=\(.result)=\(.failedTests | join(","))"] | join(" ")')
  if [ "$got" = "$want" ]; then
    echo "ok   nodes $name: $got"
  else
    echo "FAIL nodes $name: $got, want $want"
    failures=$((failures + 1))
  fi
}
echo '{"name":"","labels":{},"providerID":""}' >"$tmp/host.json"
TESTS=inventory,nccl
node_case one-bad-node "node-a=passed= node-b=failed=inventory" \
  inventory=passed@node-a inventory=failed@node-b nccl=passed@node-a nccl=passed@node-b
node_case missing-counts-for-all "node-a=failed=nccl node-b=failed=nccl" \
  inventory=passed@node-a inventory=passed@node-b

echo "$((count - failures))/$count passed"
[ "$failures" -eq 0 ]
