#!/usr/bin/env bash
# End-to-end runs of the gpu-burn-in Stack on simulated GPUs (NVIDIA nvml-mock), with faults
# injected, against a live vCluster Platform. Each scenario creates a tenant cluster from
# virtualclustertemplate.yaml, waits for the Stack, reads the report and checks the verdict.
#
#   tests/nvml-mock-e2e.sh --project default --provider metal3 --argo-connector argocd \
#     [--node-type-property vcluster.com/accelerator --node-type-value b200] \
#     [--gpus 8] [--chart-repo https://github.com/<fork>/vcluster-stacks.git --chart-revision <branch>] \
#     [--scenario pass|missing-gpu|wrong-model|thermal|xid|all] [--keep]
#
# Prerequisites:
#   - kubectl pointed at the Platform management API (vcluster platform connect management). The
#     script prints the API server before it creates anything.
#   - apps/, stacktemplate.yaml and virtualclustertemplate.yaml applied, and the chart pushed to
#     --chart-repo at --chart-revision: Argo CD reads the chart from Git, not from this checkout.
#   - A node type whose servers join with nvml-mock as their driver, and labeled
#     nvidia.com/gpu.deploy.driver=false and nvidia.com/gpu.deploy.container-toolkit=false.
#   - bash 4 or later, the vcluster CLI and jq.
#
# What each scenario proves, and what it cannot (nvml-mock has no CUDA, so DCGM diagnostics and
# NCCL are disabled and the soak only records telemetry):
#   pass         every step, outputs and verdict on a healthy server            -> passed
#   missing-gpu  expectedGPUs one more than the server has; stop-on-failure     -> failed: inventory, later tests skipped
#   wrong-model  gpuModel that does not match the simulated GPUs                -> failed: inventory
#   thermal      nvml-mock-ctl temp --gpu 0 142 during the soak                 -> failed: soak (above maxGPUTempC)
#   xid          nvml-mock-ctl fail --mode ecc_uncorrectable --xid 48, soak     -> failed: soak (Xid 48)
# thermal follows a path verified with NVSentinel (DCGM reports the spike, capped at 95C). Whether
# DCGM field 230 (last XID) reflects an nvml-mock Xid has not been verified; xid is the scenario to
# run first if it matters.
#
# Each scenario provisions a server, so they take as long as the provider needs to boot one.
set -euo pipefail
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo "needs bash 4 or later (macOS /bin/bash is 3.2; brew install bash)" >&2; exit 2; }

project="" provider="" connector="" prop=vcluster.com/accelerator value=b200 gpus=8
chart_repo=https://github.com/loft-sh/vcluster-stacks.git chart_rev=main scenario=all keep=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --project) project=$2; shift 2 ;;
    --provider) provider=$2; shift 2 ;;
    --argo-connector) connector=$2; shift 2 ;;
    --node-type-property) prop=$2; shift 2 ;;
    --node-type-value) value=$2; shift 2 ;;
    --gpus) gpus=$2; shift 2 ;;
    --chart-repo) chart_repo=$2; shift 2 ;;
    --chart-revision) chart_rev=$2; shift 2 ;;
    --scenario) scenario=$2; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;/^set -euo/d'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$project" && -n "$provider" && -n "$connector" ]] || { echo "need --project, --provider and --argo-connector" >&2; exit 1; }
for tool in kubectl vcluster jq; do command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 2; }; done

ns=p-$project
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
log() { echo "$(date -u '+%H:%M:%S') $*"; }
echo "management API: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
kubectl get stacktemplate gpu-burn-in >/dev/null
kubectl get virtualclustertemplate gpu-burn-in-private-nodes >/dev/null

# scenario -> "parameter overrides (k=v,...)|fault|expected result|expected failed tests"
# With stopOnFailure, an inventory failure leaves the soak skipped, which also fails it; the DCGM
# and NCCL steps are disabled on nvml-mock and so never count.
declare -A plan=(
  [pass]="|none|passed|"
  [missing-gpu]="expectedGPUs=$((gpus + 1))|none|failed|inventory,soak"
  [wrong-model]="gpuModel=H100|none|failed|inventory,soak"
  [thermal]="soakMinutes=8|thermal|failed|soak"
  [xid]="soakMinutes=8|xid|failed|soak"
)
order=(pass missing-gpu wrong-model thermal xid)
[[ "$scenario" == all ]] || order=("$scenario")

stack_of() { # the StackInstance deploy.stacks created for tenant cluster $1
  kubectl -n "$ns" get stackinstances -o json |
    jq -r --arg vc "$1" '.items[] | select(.spec.destination.virtualCluster.name == $vc and .spec.templateRef.name == "gpu-burn-in") | .metadata.name' | head -1
}
task_phase() { kubectl -n "$ns" get stackinstance "$1" -o json | jq -r --arg t "$2" '.status.tasks[]? | select(.name == $t) | .phase'; }

# nvml-mock-ctl on the node: in the nvml-mock DaemonSet pod when there is one, else on the host
# (cloud-init installs) through a node debug pod.
mockctl() {
  local kc=$1 node=$2
  shift 2
  local pod
  pod=$(kubectl --kubeconfig "$kc" -n mokka get pods --field-selector "spec.nodeName=$node" -o name 2>/dev/null | head -1 || true)
  if [[ -n "$pod" ]]; then
    kubectl --kubeconfig "$kc" -n mokka exec "$pod" -c node-agent -- nvml-mock-ctl "$@"
  else
    kubectl --kubeconfig "$kc" debug "node/$node" --profile=sysadmin --image=busybox:1.37 -- chroot /host nvml-mock-ctl "$@" >/dev/null
    sleep 10
  fi
}

failures=0
for s in "${order[@]}"; do
  [[ -n "${plan[$s]:-}" ]] || { echo "unknown scenario $s" >&2; exit 1; }
  IFS='|' read -r overrides fault want want_failed <<<"${plan[$s]}"
  vc=burnin-mock-$s
  log "== $s: tenant cluster $vc, expecting $want${want_failed:+ ($want_failed)}"

  unset params
  declare -A params=(
    [argoConnector]=$connector [gpuNodeProvider]=$provider [nodeTypeProperty]=$prop
    [nodeTypeValue]=$value [chartRepoURL]=$chart_repo [chartRevision]=$chart_rev
    [expectedGPUs]=$gpus [gpuModel]=B200 [assetID]=$vc [profile]=nvml-mock
    [driverPreinstalled]=true [nvmlMock]=true [runDCGMDiag]=false [runNCCL]=false [soakMinutes]=3 [soakLoad]=none
  )
  IFS=, read -ra kvs <<<"$overrides"
  for kv in "${kvs[@]}"; do params[${kv%%=*}]=${kv#*=}; done
  parameters=$(for k in "${!params[@]}"; do printf '%s: %s\n' "$k" "$(jq -n --arg v "${params[$k]}" '$v')"; done | sort)

  cat >"$work/$s.yaml" <<EOF
apiVersion: management.loft.sh/v1
kind: VirtualClusterInstance
metadata:
  name: $vc
  namespace: $ns
  labels:
    app.kubernetes.io/part-of: gpu-burn-in-stack
spec:
  owner:
    user: admin
  templateRef:
    name: gpu-burn-in-private-nodes
  parameters: |
$(sed 's/^/    /' <<<"$parameters")
EOF
  kubectl apply -f "$work/$s.yaml" >/dev/null

  stack=""
  for _ in $(seq 120); do stack=$(stack_of "$vc"); [[ -n "$stack" ]] && break; sleep 10; done
  [[ -n "$stack" ]] || { log "FAIL $s: no StackInstance after 20 minutes"; failures=$((failures + 1)); continue; }
  log "StackInstance $stack"

  kc=$work/$vc.kubeconfig
  injected=false
  phase=""
  deadline=$(($(date +%s) + 90 * 60))
  while [[ $(date +%s) -lt $deadline ]]; do
    phase=$(kubectl -n "$ns" get stackinstance "$stack" -o jsonpath='{.status.phase}')
    [[ "$phase" == Healthy || "$phase" == Degraded ]] && break
    if [[ "$fault" != none && $injected == false && "$(task_phase "$stack" soak)" == Progressing ]]; then
      vcluster platform connect vcluster "$vc" --project "$project" --print >"$kc"
      node=$(kubectl --kubeconfig "$kc" get nodes -o jsonpath='{.items[0].metadata.name}')
      sleep 60 # let the soak collect normal samples first
      case $fault in
        thermal) mockctl "$kc" "$node" temp --gpu 0 142 ;;
        xid) mockctl "$kc" "$node" fail --gpu 0 --mode ecc_uncorrectable --xid 48 ;;
      esac
      injected=true
      log "injected $fault on $node GPU 0"
    fi
    sleep 20
  done
  log "Stack phase ${phase:-unknown}"
  kubectl -n "$ns" get stackinstance "$stack" -o json |
    jq -r '.status.tasks[]? | "  \(.name)\t\(.phase)\t\(.message // "")"'

  [[ -s "$kc" ]] || vcluster platform connect vcluster "$vc" --project "$project" --print >"$kc"
  report=$(kubectl --kubeconfig "$kc" -n gpu-burn-in get configmap gpu-burn-in-report -o json 2>/dev/null || echo '{}')
  result=$(jq -r '.data.result // "none"' <<<"$report")
  failed=$(jq -r '.data.failedTests // ""' <<<"$report")
  log "report: $result${failed:+ ($failed)}: $(jq -r '.data.summary // ""' <<<"$report")"
  if $injected; then mockctl "$kc" "$node" reset --gpu 0 || true; fi

  want_phase=Healthy
  [[ $want == passed ]] || want_phase=Degraded
  if [[ $result == "$want" && $failed == "$want_failed" && $phase == "$want_phase" ]]; then
    log "ok   $s"
    $keep || kubectl -n "$ns" delete virtualclusterinstance "$vc" --wait=false >/dev/null
  else
    log "FAIL $s: result $result ($failed), phase $phase; want $want ($want_failed), $want_phase. Kept $vc for debugging."
    failures=$((failures + 1))
  fi
done

[[ $failures -eq 0 ]] && log "all scenarios passed" || { log "$failures scenario(s) failed"; exit 1; }
