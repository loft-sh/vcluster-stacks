#!/bin/sh
# Tools image. Waits for the device plugin to advertise nvidia.com/gpu, which proves the driver,
# toolkit and device plugin work, then records how many GPUs are allocatable. The Stack passes
# that count to every GPU test, and inventory compares it with nvidia-smi. The tests themselves
# request no GPUs (they use the NVIDIA runtime class), so a server with an unhealthy GPU runs its
# tests and fails inventory instead of leaving pods Pending until a timeout.
#
# Fewer GPUs than expectedGPUs is not a failure here; inventory judges the count. No GPU at all
# within READY_WAIT_SECONDS is.
set -eu
. /scripts/lib.sh

now >"$WORK/started"
: >"$WORK/log.txt"
deadline=$(($(date +%s) + READY_WAIT_SECONDS))

# "<node> <allocatable>" for every node that advertises at least one GPU.
gpu_nodes() {
  kubectl get nodes -o json |
    jq -r '.items[] | [.metadata.name, (.status.allocatable["nvidia.com/gpu"] // "0")] | select(.[1] != "0") | join(" ")'
}

count=0 node=""
while :; do
  nodes=$(gpu_nodes || true)
  count=$(echo "$nodes" | awk '{ s += $2 } END { print s + 0 }')
  node=$(echo "$nodes" | awk 'NR == 1 { print $1 }')
  if [ "$count" -gt 0 ]; then
    # The device plugin registers all GPUs at once, but give a late count a moment to settle.
    stable=0
    while [ "$count" -lt "$EXPECTED_GPUS" ] && [ "$stable" -lt 12 ] && [ "$(date +%s)" -lt "$deadline" ]; do
      sleep 10
      stable=$((stable + 1))
      count=$(gpu_nodes | awk '{ s += $2 } END { print s + 0 }')
    done
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || break
  log "waiting for allocatable nvidia.com/gpu" | tee -a "$WORK/log.txt"
  sleep 10
done
now >"$WORK/finished"

nodes=$(gpu_nodes || true)
echo "$nodes" >>"$WORK/log.txt"
if [ "$(echo "$nodes" | grep -c .)" -gt 1 ]; then
  log "more than one GPU node; this Stack qualifies one server per tenant cluster" | tee -a "$WORK/log.txt"
fi
# The same metrics contract as the GPU tests (evaluate.sh), so reports carry allocatable_gpus.
jq -n --argjson count "$count" --arg node "$node" --argjson expected "$EXPECTED_GPUS" \
  '{allocatable: $count, expected: $expected, node: $node, metrics: {allocatable_gpus: $count}}' >"$WORK/details.json"

if [ "$count" -gt 0 ]; then
  write_result passed "$count allocatable nvidia.com/gpu on $node" "$WORK/details.json" \
    --from-literal=gpus="$count" --from-literal=gpuNode="$node"
else
  # gpus stays 1 so later steps still render a valid request; stopOnFailure skips them.
  write_result failed "no nvidia.com/gpu advertised within ${READY_WAIT_SECONDS}s: check the driver, toolkit and device plugin pods" \
    "$WORK/details.json" --from-literal=gpus=1 --from-literal=gpuNode=""
fi
