#!/usr/bin/env bash
# Records a gpu-burn-in result on the server's inventory record: the "external automation" half of
# the qualification flow. A sample, not a controller: run it once per qualification, after the
# Stack has finished.
#
#   record-qualification.sh --tenant-kubeconfig tenant.kubeconfig [--node rack-a-u12] \
#     [--machine metal3-dc1.rack-a-u12 [--platform-context vcluster-platform_management]] \
#     [--bmh rack-a-u12 --bmh-namespace metal3-system --metal3-context spark-cluster] \
#     [--netbox-device rack-a-u12 --netbox-admit-tag vcluster-sync --netbox-qualified-tag gpu-qualified] \
#     [--create-report [--report-machine metal3-dc1.rack-a-u12 | --provider metal3-dc1] \
#       [--report-context vcluster-platform_loft-cluster]] \
#     [--apply]
#
# Without --apply it prints what it would change and changes nothing.
#
# A run that tested several nodes reports a verdict per node. --node picks the server's, by its
# node name (the host name); it defaults to --bmh, or to the only node. Run the script once per
# server.
#
# Reads ConfigMap gpu-burn-in/gpu-burn-in-report from the tenant cluster (get a kubeconfig with
# `vcluster platform connect vcluster <name> --project <project> --print`), or from --report-file,
# a copy saved with --save-report. Save one before you delete the tenant cluster.
#
# The label is <domain>/result=passed|failed, with annotations under the same domain for the
# profile, time, failed tests, summary and report URI. The domain is $LABEL_DOMAIN, by default
# gpu-qualification.example.com; use one your organization owns. Never a vcluster.com or loft.sh
# domain: newer Platform builds keep labels in those domains out of NodeType selection.
#
# Where it is written:
#   --machine   the vCluster Platform Machine, on the management API. Provider-neutral (Metal3 and
#               NICo), and needs no credentials for the cluster that runs Metal3. NodeTypes select
#               on Machine labels from Platform v5.0.0-alpha.5; before that, Metal3 NodeTypes read
#               only BareMetalHost labels, so use --bmh there.
#   --bmh       the Metal3 BareMetalHost, on the cluster that runs Metal3. Works on any build. From
#               v5.0.0-alpha.5 the Platform copies these labels to the Machine.
# Both survive the release of the server: the Metal3 provider's teardown removes only its own
# project and NodeClaim labels. A label alone does not stop allocation: require it in the
# selector of every production NodeType, for example
#     bareMetalHosts:
#       selector:
#         matchLabels:
#           gpu-qualification.example.com/result: passed
# and give the qualification NodeType a selector that excludes passed hosts.
#
# QualificationReport (optional, --create-report): the same provider-neutral record of the run that
# the gpu-burn-in-recorder controller writes, so a run recorded by hand still shows in the history
# and on dashboards. It names the Platform Machine: --report-machine, --machine, or
# <--provider>.<--bmh>. --report-machine alone records only the report, with no label. It is created
# on the cluster that runs vCluster Platform (--report-context, default the current context), where
# the CRD from recorder/chart/crds/ must be installed. Topology (site, location and rack, or
# $TOPOLOGY as name=machine-label pairs) and the inventory URL are read from the Machine there when
# it can be. The script does not prune old reports.
#
# NetBox (optional, NETBOX_URL and NETBOX_TOKEN in the environment): on a failure, sets the device
# status to failed and removes --netbox-admit-tag, the tag the Metal3 provider's NetBox import
# selects devices by (spec.metal3.netBox.tag). The import then orphans the server and removes it
# once it is released. On a pass, adds --netbox-qualified-tag, which must already exist in NetBox.
# Either way it adds a journal entry with the summary. NETBOX_TOKEN is the token alone, without
# "Token" or "Bearer". Token permissions and the whole flow: recorder/README.md, section NetBox.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;/^set -euo/d'; exit "${1:-0}"; }

tenant_kubeconfig="" report_file="" save_report="" node=""
machine="" platform_context=""
bmh="" bmh_namespace="metal3-system" metal3_context=""
nb_device="" nb_admit_tag="" nb_qualified_tag="" apply=false
create_report=false provider="" report_context="" report_machine=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --tenant-kubeconfig) tenant_kubeconfig=$2; shift 2 ;;
    --report-file) report_file=$2; shift 2 ;;
    --save-report) save_report=$2; shift 2 ;;
    --node) node=$2; shift 2 ;;
    --machine) machine=$2; shift 2 ;;
    --platform-context) platform_context=$2; shift 2 ;;
    --bmh) bmh=$2; shift 2 ;;
    --bmh-namespace) bmh_namespace=$2; shift 2 ;;
    --metal3-context) metal3_context=$2; shift 2 ;;
    --netbox-device) nb_device=$2; shift 2 ;;
    --netbox-admit-tag) nb_admit_tag=$2; shift 2 ;;
    --netbox-qualified-tag) nb_qualified_tag=$2; shift 2 ;;
    --create-report) create_report=true; shift ;;
    --provider) provider=$2; shift 2 ;;
    --report-machine) report_machine=$2; shift 2 ;;
    --report-context) report_context=$2; shift 2 ;;
    --apply) apply=true; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done
domain=${LABEL_DOMAIN:-gpu-qualification.example.com}
case $domain in
  vcluster.com|*.vcluster.com|loft.sh|*.loft.sh)
    echo "LABEL_DOMAIN $domain: NodeType selection ignores labels in vcluster.com and loft.sh domains" >&2; exit 1 ;;
esac
for tool in kubectl jq; do command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 2; }; done

run() {
  if $apply; then "$@"; else printf 'would run:'; printf ' %q' "$@"; echo; fi
}

# --- Read the report ----------------------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ -n "$report_file" ]]; then
  cp "$report_file" "$tmp/report.json"
elif [[ -n "$tenant_kubeconfig" ]]; then
  kubectl --kubeconfig "$tenant_kubeconfig" -n gpu-burn-in get configmap gpu-burn-in-report \
    -o jsonpath='{.data.report\.json}' >"$tmp/report.json"
else
  echo "need --tenant-kubeconfig or --report-file" >&2
  exit 1
fi
[[ -s "$tmp/report.json" ]] || { echo "no report found; has the report task run?" >&2; exit 1; }
[[ -z "$save_report" ]] || cp "$tmp/report.json" "$save_report"

# A report with nodes[] (one per node tested) is narrowed to this server's node: its verdict, its
# tests, and the host inventory only when the report's host is that node.
if [[ $(jq '.nodes // [] | length' "$tmp/report.json") -gt 0 ]]; then
  [[ -n "$node" ]] || node=$bmh
  if [[ -z "$node" ]]; then
    [[ $(jq '.nodes | length' "$tmp/report.json") -eq 1 ]] || {
      echo "the run tested several nodes; pick one with --node: $(jq -r '[.nodes[].name] | join(", ")' "$tmp/report.json")" >&2
      exit 1
    }
    node=$(jq -r '.nodes[0].name' "$tmp/report.json")
  fi
  jq --arg n "$node" '
    ([.nodes[] | select(.name == $n)][0]) as $e |
    if $e == null then empty else
      .result = $e.result | .failedTests = $e.failedTests | .summary = $e.summary |
      .tests = [.tests[] | select((.node // "") == "" or .node == $n)] |
      if .host.name != $n then .host = {name: $n} | .gpus = [] | .detectedGPUs = 0 else . end
    end' "$tmp/report.json" >"$tmp/node.json"
  [[ -s "$tmp/node.json" ]] || {
    echo "the report has no result for node $node: $(jq -r '[.nodes[].name] | join(", ")' "$tmp/report.json")" >&2
    exit 1
  }
  mv "$tmp/node.json" "$tmp/report.json"
fi

result=$(jq -r .result "$tmp/report.json")
profile=$(jq -r .profile "$tmp/report.json")
failed=$(jq -r '.failedTests | join(",")' "$tmp/report.json")
summary=$(jq -r .summary "$tmp/report.json")
uri=$(jq -r '.reportURI // ""' "$tmp/report.json")
finished=$(jq -r '[.tests[].finishedAt | select(. != "")] | max // ""' "$tmp/report.json")
host=$(jq -r .host.name "$tmp/report.json")
echo "report: $result on $host (asset $(jq -r '.assetID // "unset"' "$tmp/report.json"), profile $profile)"
echo "  $summary"
case $result in passed|failed) ;; *) echo "unexpected result '$result'" >&2; exit 1 ;; esac

# --- QualificationReport ------------------------------------------------------------------------
# First, as the controller does: the report is the history.
if $create_report; then
  [[ -n "$report_machine" ]] || report_machine=$machine
  if [[ -z "$report_machine" ]]; then
    [[ -n "$provider" && -n "$bmh" ]] || { echo "--create-report needs --report-machine, --machine, or --provider with --bmh" >&2; exit 1; }
    report_machine=$provider.$bmh
  fi
  [[ -n "$provider" ]] || provider=${report_machine%%.*}
  # Stable per report: recording the same report twice creates it once.
  digest=$( (sha256sum 2>/dev/null || shasum -a 256) <"$tmp/report.json" | cut -c1-8)
  # Topology and inventory URL, as the controller records them, from the Platform's Machine.
  kr=(kubectl)
  [[ -z "$report_context" ]] || kr=(kubectl --context "$report_context")
  "${kr[@]}" get machines.storage.loft.sh "$report_machine" -o json >"$tmp/machine.json" 2>/dev/null || echo '{}' >"$tmp/machine.json"
  topology=${TOPOLOGY:-site=netbox.vcluster.com/site,location=netbox.vcluster.com/location,rack=netbox.vcluster.com/rack}
  jq --arg map "$topology" '
    (.metadata.labels // {}) as $l |
    {topology: ([$map | split(",")[] | select(contains("=")) | split("=") | {key: .[0], value: $l[.[1]]}
                 | select(.value != null and .value != "")] | from_entries),
     inventoryURL: (.metadata.annotations["netbox.vcluster.com/url"] // "")}' "$tmp/machine.json" >"$tmp/placement.json"
  jq --arg machine "$report_machine" --arg provider "$provider" --arg digest "$digest" \
    --slurpfile placement "$tmp/placement.json" '
    def tolabel: gsub("[^A-Za-z0-9._-]+"; "-") | ltrimstr("-") | rtrimstr("-") | .[0:63];
    def nonempty: with_entries(select(.value != null and .value != ""));
    ([.tests[]?.finishedAt | select(. != null and . != "")] | max) as $finished |
    {apiVersion: "qualification.vcluster-stacks.io/v1alpha1", kind: "QualificationReport",
     metadata: {
       name: (($machine | ascii_downcase) + "-" + $digest),
       labels: {"qualification.vcluster-stacks.io/machine": ($machine | tolabel),
                "qualification.vcluster-stacks.io/result": .result,
                "qualification.vcluster-stacks.io/provider": ($provider | tolabel),
                "qualification.vcluster-stacks.io/profile": ((.profile // "") | tolabel),
                "qualification.vcluster-stacks.io/source-kind": "Stack"}},
     spec: ({machineRef: $machine, providerRef: $provider, assetID: .assetID,
             inventoryURL: $placement[0].inventoryURL,
             topology: (if ($placement[0].topology | length) > 0 then $placement[0].topology else null end),
             source: {kind: "Stack", name: "record-qualification.sh"},
             profile: .profile, result: .result, failedTests: (.failedTests // []), summary: .summary,
             startedAt: .startedAt, finishedAt: $finished, reportURI: .reportURI,
             hardware: ({node: .host.name, gpuCount: .detectedGPUs, expectedGPUs: .expectedGPUs,
                         gpuModel: ([.gpus[]?.name] | unique | join(",")),
                         driver: ([.gpus[]?.driver | select(. != null and . != "")][0]),
                         gpus: [.gpus[]? | {index, uuid, name, serial}],
                         dmi: (.host.dmi // {})} | nonempty),
             tests: [.tests[]? | {name: .test, status, summary, startedAt, finishedAt}
                     + (if (.metrics // {}) == {} then {} else {metrics} end) | nonempty]}
            | nonempty)}' "$tmp/report.json" >"$tmp/qualificationreport.json"
  k=(kubectl)
  [[ -z "$report_context" ]] || k=(kubectl --context "$report_context")
  name=$(jq -r .metadata.name "$tmp/qualificationreport.json")
  if "${k[@]}" get qualificationreports.qualification.vcluster-stacks.io "$name" >/dev/null 2>&1; then
    echo "QualificationReport $name already exists"
  elif $apply; then
    "${k[@]}" create -f "$tmp/qualificationreport.json"
  else
    echo "would create QualificationReport $name:"
    jq . "$tmp/qualificationreport.json"
  fi
fi

# --- Machine and BareMetalHost ------------------------------------------------------------------
# record KUBECTL_ARGS... RESOURCE NAME: the label, then the annotations.
record() {
  local name=${*: -1} resource=${*: -2:1}
  local k=("${@:1:$#-2}")
  run "${k[@]}" label "$resource" "$name" --overwrite "$domain/result=$result"
  # Annotation values are free text; keep the summary short enough to read in kubectl describe.
  run "${k[@]}" annotate "$resource" "$name" --overwrite \
    "$domain/profile=$profile" \
    "$domain/finished-at=$finished" \
    "$domain/failed-tests=$failed" \
    "$domain/summary=${summary:0:1000}" \
    "$domain/report=$uri"
}
if [[ -n "$machine" ]]; then
  k=(kubectl)
  [[ -z "$platform_context" ]] || k=(kubectl --context "$platform_context")
  "${k[@]}" get machines.management.loft.sh "$machine" >/dev/null
  record "${k[@]}" machines.management.loft.sh "$machine"
fi
if [[ -n "$bmh" ]]; then
  k=(kubectl -n "$bmh_namespace")
  [[ -z "$metal3_context" ]] || k=(kubectl --context "$metal3_context" -n "$bmh_namespace")
  "${k[@]}" get baremetalhost "$bmh" >/dev/null
  record "${k[@]}" baremetalhost "$bmh"
fi

# --- NetBox -------------------------------------------------------------------------------------
if [[ -n "$nb_device" ]]; then
  : "${NETBOX_URL:?set NETBOX_URL}" "${NETBOX_TOKEN:?set NETBOX_TOKEN}"
  # NetBox 4.5 v2 tokens (nbt_...) use Bearer; v1 tokens use Token.
  if [[ "$NETBOX_TOKEN" == nbt_* ]]; then auth="Bearer $NETBOX_TOKEN"; else auth="Token $NETBOX_TOKEN"; fi
  nb() { curl -fsS -H "Authorization: $auth" -H 'Content-Type: application/json' -H 'Accept: application/json' "$@"; }
  api=${NETBOX_URL%/}/api
  device=$(nb "$api/dcim/devices/?name=$(jq -rn --arg n "$nb_device" '$n | @uri')" | jq '.results[0] // empty')
  [[ -n "$device" ]] || { echo "NetBox device $nb_device not found" >&2; exit 1; }
  id=$(jq -r .id <<<"$device")
  tags=$(jq '[.tags[].slug]' <<<"$device")

  if [[ $result == failed ]]; then
    [[ -z "$nb_admit_tag" ]] || tags=$(jq --arg t "$nb_admit_tag" 'map(select(. != $t))' <<<"$tags")
    patch=$(jq -n --argjson tags "$tags" '{status: "failed", tags: ($tags | map({slug: .}))}')
    kind=danger
  else
    [[ -z "$nb_qualified_tag" ]] || tags=$(jq --arg t "$nb_qualified_tag" '. + [$t] | unique' <<<"$tags")
    patch=$(jq -n --argjson tags "$tags" '{tags: ($tags | map({slug: .}))}')
    kind=success
  fi
  journal=$(jq -n --argjson id "$id" --arg kind "$kind" \
    --arg text "GPU qualification $result ($profile)${failed:+: $failed}. $summary${uri:+ Report: $uri}" \
    '{assigned_object_type: "dcim.device", assigned_object_id: $id, kind: $kind, comments: $text}')
  run nb -X PATCH "$api/dcim/devices/$id/" -d "$patch"
  run nb -X POST "$api/extras/journal-entries/" -d "$journal"
fi

$apply || echo "dry run: nothing changed. Re-run with --apply."
