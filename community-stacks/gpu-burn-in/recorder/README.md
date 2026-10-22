# gpu-burn-in-recorder

A controller that records [gpu-burn-in](../README.md) results on the servers they qualified. Install
it once on the cluster that runs vCluster Platform. Each finished run then leaves a result label on
the server's inventory record, and NodeType selectors can use that label to keep failed servers
away from customers.

It replaces running [record-qualification.sh](../automation/record-qualification.sh) by hand after
each qualification. Both are optional, and `record-qualification.sh --create-report` writes the same
QualificationReport, so hand-recorded runs appear in the same history and metrics. See the
[comparison](../README.md#qualify-and-quarantine-servers).

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Install](#install)
- [Configure](#configure)
- [NetBox](#netbox)
- [Per-run parameters](#per-run-parameters)
- [QualificationReport](#qualificationreport)
- [GPU Burn-In dashboards](#gpu-burn-in-dashboards)
- [Verify](#verify)
- [Permissions](#permissions)
- [Build](#build)
- [Run from a workstation](#run-from-a-workstation)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Tested](#tested)

## What it does

The controller watches StackInstances of the `gpu-burn-in` StackTemplate. For each one:

1. **It waits for the report.** The `report` task must be Healthy, and its outputs must be
   captured in the instance's outputs Secret, `stack-outputs-<instance>`, in the project namespace.
2. **It finds the server the run tested.** The tenant cluster's NodeClaims lead to the inventory
   Machines whose `machines.vcluster.com/node-claim` annotation names one of them. The run needs no
   `assetID`, and the controller cannot record on the wrong server. When the report gives a verdict
   per node (`nodes` in `report.json`), each Machine gets its own: the node whose name is the
   Machine's host name, which is the Machine's name after `<provider>.` on Metal3 and its display
   name on NICo. A Machine the report has no node for is not recorded, with a `NoNodeResult`
   event.

   When no Machine holds the NodeClaims, as for a cloud VM from a Terraform provider, the run is
   recorded as a report only: a QualificationReport per node, labeled
   `qualification.vcluster-stacks.io/no-inventory: "true"`, with a `ReportOnly` event. Steps 3 and 5
   are skipped; step 6 still runs.
3. **It updates NetBox, if the run asks.** The device comes from the Machine's
   `netbox.vcluster.com/url` annotation. On a failure, the device status becomes `failed` and the
   admit tag is removed; on a pass, the qualified tag is added. Either way, a journal entry gets
   the summary.
4. **It creates a QualificationReport**, one per run. See [QualificationReport](#qualificationreport).
5. **It writes the record.** That's the label `<domain>/result=passed|failed`, plus annotations with
   the profile, finish time, failed tests, summary, report URI and the run. It writes them to the
   Platform Machine or to the Metal3 BareMetalHost.
6. **It deletes the tenant cluster, if the run asks.** That returns the server to its node provider,
   which wipes it.

The record survives the teardown. The Metal3 provider removes only its own project and NodeClaim
labels when it releases a host.

Each run is recorded once. The `<domain>/run` annotation on the target names the StackInstance and
its UID, and the controller skips a target that already carries it. NetBox is written before the
target, so a run that fails partway is retried until the target records it. A retry can add a
second NetBox journal entry.

The controller must see the run before the tenant cluster is deleted, because the NodeClaim, and
the Machine's annotation naming it, go away with the tenant cluster. With `releaseServer`, the
controller does the deletion itself, after recording.

## QualificationReport

Every recorded run also becomes a `QualificationReport`
(`qualification.vcluster-stacks.io/v1alpha1`). It's a cluster-scoped record of one qualification
of one machine, kept beside the vCluster Platform Machine it names. The CRD is in
[chart/crds/](chart/crds/qualificationreports.yaml).

`record-qualification.sh --create-report` writes the same report for a run recorded by hand, with
`source.name: record-qualification.sh`. The report doesn't depend on how the tests ran. The gpu-burn-in Stack fills it through this
controller, and NICo Machine Validation or another test suite could fill the same fields with no
tenant cluster at all. That makes it the one source for dashboards, gating and reporting across
providers. [NICO.md](NICO.md) covers NICo: what its machine validation does, running the Stack on
NICo machines, and a proposed NICo source for these reports.

```bash
kubectl get qualificationreports
NAME                                                     MACHINE                                         RESULT   FAILED   PROFILE          SOURCE   FINISHED
metal3-us-va-blacksburg-dc1.rack-b-u18-xlarge-b5f29a6f   metal3-us-va-blacksburg-dc1.rack-b-u18-xlarge   passed   []       nvml-mock-pass   Stack    16s
```

| Field | Content |
| --- | --- |
| `spec.machineRef`, `providerRef`, `assetID`, `inventoryURL` | The machine qualified, and its inventory page (the Machine's NetBox device). For a server without a Machine, `<provider>.<node>` and no inventory page |
| `spec.topology` | Where it is: `site`, `location` and `rack` by default, from the Machine's labels |
| `spec.source` | What ran it: `kind` (`Stack`, `NICoValidation`, `vMetalAgent`, `Other`) and, for a Stack, the StackInstance and template |
| `spec.result`, `failedTests`, `summary`, `profile` | The verdict and the thresholds it was judged against. For a run over several nodes, this machine's own verdict |
| `spec.group` | The tenant cluster, `<namespace>/<name>`, when the run tested more than one node. Reports of one run share it |
| `spec.startedAt`, `finishedAt`, `reportURI` | When, and where the full report is stored |
| `spec.hardware` | Node, GPU model, count, expected count, driver, each GPU's UUID and serial, and DMI |
| `spec.tests[]` | Each test's name, status, summary, times and `metrics` |

The spec is a record. The API server rejects any change to it, and the labels
`qualification.vcluster-stacks.io/machine`, `/result`, `/provider`, `/profile`, `/source-kind`
and, for a run over several nodes, `/group`, and for a server without a Machine,
`/no-inventory`,
make reports easy to select.

The controller keeps at most `keepReports` (5) reports per machine and drops reports finished more
than `maxReportAge` (90 days) ago. It always keeps a machine's latest report, whatever its age,
because that report is the machine's current state, which gates and dashboards read. At about 4 KB a
report, 10,000 machines with 5 reports each is about 200 MB in the Platform cluster's etcd; lower
`keepReports` for very large fleets. Long-term history belongs in the S3 copy of each report, and
long-term trends in Prometheus. It
reads the full report from the report task's `reportjson` output; a Stack without that output
gives a report without hardware and tests.

Each test that ran, passed or failed, carries `metrics`: a flat set of named numbers, the same names
whatever ran the test. Disabled, skipped and errored tests carry none.

| Test | Metrics |
| --- | --- |
| `gpuready` | `allocatable_gpus` |
| `inventory` | `gpus`, `allocatable_gpus`, `uncorrected_ecc_errors`, `inactive_nvlinks`, `fabric_unhealthy_gpus` (with fabric data) |
| `dcgmdiag` | `level`, `failed_tests`, `skipped_tests`, `warned_tests` |
| `nccl` | `all_reduce_bus_bandwidth_gbps`, `all_gather_bus_bandwidth_gbps`, `reduce_scatter_bus_bandwidth_gbps`, `gpus` |
| `soak` | `peak_temp_c`, `peak_power_w`, `gpus_with_xid`, `throttle_samples`, `samples`, `cycles`, `minutes`, `nvlink_errors` and `gpus_with_nvlink_errors` (when the driver reports the counters) |

### Metrics

The controller computes Prometheus metrics from the reports on every scrape, at `:8080/metrics`.
The chart creates a Service for this, and with `metrics.serviceMonitor.enabled` a ServiceMonitor.

Every per-machine metric describes the machine's latest report and carries the same identity
labels: `machine`, `provider`, `profile`, `gpu_model`, and the topology names (`site`, `location`,
`rack` by default). Any panel can group or filter by them without a join. Series grow with
machines, not history: about 20 per machine, so roughly 200,000 at 10,000 machines.

| Metric | Extra labels | Value |
| --- | --- | --- |
| `gpu_qualification_result` | `source`, `result` | 1 |
| `gpu_qualification_passed` | | 1 passed, 0 not |
| `gpu_qualification_finished_timestamp_seconds` | | Finish time |
| `gpu_qualification_gpus` | `kind` (`found`, `expected`) | GPU count |
| `gpu_qualification_test_status` | `test`, `status` | 1 |
| `gpu_qualification_test_metric` | `test`, `metric` | The measurement |
| `gpu_qualification_failure_info` | `result`, `failed_tests`, `summary` (first 200 characters), `report`, `inventory_url` | 1, for machines whose latest report did not pass |
| `gpu_qualification_consecutive_failures` | | How many newest kept reports in a row did not pass |
| `gpu_qualification_reports` | only `machine`, `result` | Reports kept, the history |

`failure_info` puts text in labels, which is bounded here: it exists only for failing machines.

For example, servers that are not qualified: `gpu_qualification_passed == 0`. Failing servers by
rack: `count by (site, rack) (gpu_qualification_failure_info)`. Peak soak temperature at p95 per
GPU model: `quantile by (gpu_model) (0.95, gpu_qualification_test_metric{test="soak",metric="peak_temp_c"})`.

The topology names are a chart value. Each maps a metric label to the Machine label it is read
from:

```yaml
topology:
  site: netbox.vcluster.com/site
  location: netbox.vcluster.com/location
  rack: netbox.vcluster.com/rack
  power_domain: example.com/power-domain   # any Machine label
```

The defaults are what vCluster Platform's NetBox import puts on every Machine. Missing labels stay
empty. The dashboards use `site`, `location` and `rack`.

### GPU Burn-In dashboards

The chart installs three Grafana dashboards, as one ConfigMap labeled `grafana_dashboard: "1"` in
`vcluster-platform`, where vCluster Platform's bundled Grafana loads them. They are built to read
the same at 10 servers or 10,000: only the Failures dashboard lists servers one by one, and only
failing ones.

| Dashboard | uid | Shows |
| --- | --- | --- |
| GPU Burn-In | `gpu-burn-in` | Fleet aggregates: qualified, not qualified, pass rate, qualified in 24h, stale servers; pass rate by GPU model and site; the racks with the most failures and the tests that fail most; soak temperature and NCCL bandwidth distributions per GPU model, with the 20 hottest and slowest servers; the 20 servers with inactive NVLinks, an unhealthy NVLink fabric or NVLink errors in the soak |
| GPU Burn-In: Failures | `gpu-burn-in-failures` | One row per not-qualified server: why, failed tests, rack, how many failures in a row, ECC, XID, temperature, inactive NVLinks, unhealthy fabric and NVLink errors, with links to the server dashboard and the inventory; failures by rack, test and GPU model, over time |
| GPU Burn-In: Server | `gpu-burn-in-server` | One machine: result, placement, why it did not pass, every test and measurement, and its history, including NVLink and fabric errors |

All three filter by provider, profile, GPU model, site and rack.

For another Grafana, set `dashboard.namespace` and `dashboard.labels` to what its dashboard
sidecar watches, or import the files in `chart/dashboards/`.

vCluster Platform's Grafana lists one Prometheus datasource per cluster and tenant cluster, named
by generated UUID. The chart finds the right one at install and hides the selector. It prefers the
control plane datasource of `metrics.fleetObservability.cluster` (`ds-controlplane-<cluster>`),
where the pushed series land, then Fleet Observability's. Set `dashboard.datasourceUID` to choose
one yourself. The ConfigMap's `gpu-burn-in.vcluster-stacks.io/datasource` annotation shows which
was used, or `selectable` when none was found, as with `helm template`.

The dashboard queries `gpu_qualification_*` metrics, so they must reach the Prometheus behind that
Grafana. With Fleet Observability, nothing scrapes the Platform cluster's workloads, so the chart
can push them itself with `metrics.fleetObservability.enabled`. A collector sidecar scrapes the
controller and writes to the Fleet gateway with a cluster's metrics-writer key, the way Fleet
Observability's own collectors do:

```bash
# The key is Secret otel-otlp-auth in namespace observability on the Platform cluster. Copy it to
# the recorder's namespace; refresh the copy if the key is rotated.
kubectl -n observability get secret otel-otlp-auth -o json \
  | jq '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: "gpu-burn-in-recorder"}}' \
  | kubectl apply -f -
helm upgrade gpu-burn-in-recorder community-stacks/gpu-burn-in/recorder/chart \
  -n gpu-burn-in-recorder --reset-then-reuse-values \
  --set metrics.fleetObservability.enabled=true \
  --set metrics.fleetObservability.endpoint=https://otel.<platform host> \
  --set metrics.fleetObservability.cluster=<platform cluster name>
```

With a Prometheus Operator, set `metrics.serviceMonitor.enabled` instead. To change the
dashboards, edit [dashboards/gen_gpu_burn_in.py](dashboards/gen_gpu_burn_in.py) and rerun it;
`../test-manifests.sh` fails when the committed JSON is stale or queries a metric the recorder
doesn't serve.

## Requirements

- vCluster Platform 4.12.2 or later, which stores Stack outputs in the outputs Secret.
- The gpu-burn-in Stack from this repository, with the `recordResult`, `netboxUpdate` and
  `releaseServer` parameters.
- For a label and NetBox: servers from a node provider with an inventory, such as Metal3 or
  NICo, so each server has a Machine. A KubeVirt or cloud node has no Machine; the controller
  records its run as a QualificationReport only (see [What it does](#what-it-does)).
- For the `machine` target to gate NodeTypes: vCluster Platform v5.0.0-alpha.5 or later. Earlier
  builds, such as the 4.13 alphas, accept the label, but their Metal3 NodeTypes select on
  BareMetalHost labels only, so use `bmh` there.
- For the `bmh` target: access to the cluster that runs Metal3. See
  [Configure](#configure).

## Install

From the repository root, on the vCluster Platform cluster:

```bash
# vCluster Platform v5.0.0-alpha.5 or later:
helm upgrade --install gpu-burn-in-recorder community-stacks/gpu-burn-in/recorder/chart \
  --namespace gpu-burn-in-recorder --create-namespace \
  --set labelDomain=gpu-qualification.example.com \
  --set image.tag=gpu-burn-in
```

Before 5.0, record on the BareMetalHost. If the Metal3 provider's `clusterRef` names the
Platform cluster itself, set `localCluster` to its Platform name. For any other cluster, store a
kubeconfig in a Secret whose key is the cluster's Platform name:

```bash
kubectl create namespace gpu-burn-in-recorder
kubectl -n gpu-burn-in-recorder create secret generic recorder-clusters \
  --from-file=spark-cluster=spark-cluster.kubeconfig
helm upgrade --install gpu-burn-in-recorder community-stacks/gpu-burn-in/recorder/chart \
  --namespace gpu-burn-in-recorder \
  --set labelDomain=gpu-qualification.example.com \
  --set image.tag=gpu-burn-in \
  --set target=bmh --set localCluster=loft-cluster \
  --set clusterKubeconfigs.existingSecret=recorder-clusters
```

Start with `--set dryRun=true`. The controller then logs every write it would make, including the
tenant cluster deletion, and makes none.

The image is `ghcr.io/loft-demos/gpu-burn-in-recorder`, built by
[the image workflow](../../../.github/workflows/gpu-burn-in-recorder-image.yml). Until a release
tag publishes the chart's `appVersion`, set `--set image.tag=gpu-burn-in` (the branch's latest
build) or `--set image.tag=sha-<short sha>`.

## Configure

Chart values hold the settings shared by every run.

| Value | Default | Purpose |
| --- | --- | --- |
| `labelDomain` | `gpu-qualification.example.com` | Domain of the label and annotations. Use one your organization owns. `vcluster.com` and `loft.sh` domains are refused: newer Platform builds keep labels in those domains out of NodeType selection |
| `target` | `machine` | `machine` writes the Platform Machine; `bmh` writes the Metal3 BareMetalHost |
| `templates` | `[gpu-burn-in]` | StackTemplates whose instances are recorded |
| `localCluster` | empty | `bmh` only. Platform name of the cluster the controller runs in. Hosts on it are written with the controller's own credentials, and the chart grants it `baremetalhosts` access |
| `clusterKubeconfigs.existingSecret` | empty | `bmh` only. Secret with one kubeconfig per other Platform cluster, keyed by cluster name |
| `netbox.tokenSecret.name`, `.key` | empty, `token` | Secret with the NetBox API token. Without it, runs that set `netboxUpdate` skip NetBox. See [NetBox](#netbox) |
| `netbox.admitTag` | empty | Tag removed from a device that fails: the NetBox import's `tag`, which brings the device into vCluster Platform |
| `netbox.qualifiedTag` | empty | Tag added to a device that passes. It must already exist in NetBox |
| `keepReports`, `maxReportAge` | `5`, `2160h` | Report retention per machine. The latest is always kept. `0` turns a limit off |
| `topology` | NetBox `site`, `location`, `rack` | Topology names recorded in reports and added to metrics, each from a Machine label |
| `metrics.service.enabled`, `metrics.serviceMonitor.enabled` | `true`, `false` | Service and ServiceMonitor for `/metrics` |
| `metrics.fleetObservability.*` | off | Push the metrics to the Fleet gateway: `enabled`, `endpoint`, `cluster`, `authSecret`. See [GPU Burn-In dashboards](#gpu-burn-in-dashboards) |
| `dashboard.enabled`, `.namespace`, `.labels` | `true`, `vcluster-platform`, `grafana_dashboard: "1"` | The GPU Burn-In dashboard ConfigMap |
| `dashboard.datasourceUID` | found at install | The Prometheus datasource the dashboard queries |
| `dryRun` | `false` | Log writes instead of making them |
| `rbac.releaseServer` | `true` | Grant delete on VirtualClusterInstances, for runs that set `releaseServer` |
| `replicas`, `leaderElection` | `1`, `false` | More than one replica needs leader election |
| `logLevel` | `info` | `debug` logs every reconcile |

**Kubeconfigs need a static credential.** A cluster connected to the Platform through its agent,
with `networkPeer: true`, has no stored kubeconfig the controller could reuse. A kubeconfig from
`vcluster platform connect cluster` authenticates through the `vcluster` CLI, which the image does
not have. Use a token instead. A Platform access key works through the cluster proxy, with server
`https://<platform host>/kubernetes/cluster/<cluster>`. So does a ServiceAccount token on that
cluster. Either needs `get` and `patch` on `baremetalhosts.metal3.io` in the provider's namespace.
The `machine` target needs none of this.

## NetBox

With NetBox, a failed server leaves vCluster Platform instead of only carrying a label. This works
for servers that a Metal3 provider's NetBox import (`spec.metal3.netBox`) brought in. The import
puts the device's page on each Machine, in the `netbox.vcluster.com/url` annotation, and that's
the device the controller updates. NICo providers have no NetBox import.

For each run that sets `netboxUpdate: "true"`, the controller changes the device:

| Result | Device status | Tags | Journal entry |
| --- | --- | --- | --- |
| `failed` | `failed` | Removes `netbox.admitTag` | `danger`, with the failed tests and summary |
| `passed` | Unchanged | Adds `netbox.qualifiedTag` | `success`, with the summary |

### What happens to a failed server

1. The controller removes the admit tag. The import notices and marks the Machine
   `SourceAttached=False`, reason `Orphaned`. It keeps the Machine and the BareMetalHost while the
   tenant cluster holds the server.
2. When the tenant cluster is deleted, by `releaseServer` or by hand, the server is free. The import
   then removes its BareMetalHost and Machine, so no NodeType can select it.
3. After the repair, set the device status back to `active` and add the admit tag again. The import
   creates the host again without a result label, so only the qualification NodeType selects it
   until it passes.

All three steps are verified in the lab. The host and Machine were gone about two minutes after the
tenant cluster was deleted, and came back without a result label once the device was active and
tagged again; see [Tested](#tested). The QualificationReports for the
machine stay through all of this, so the dashboards keep its
history.

### Set it up

1. **Find the admit tag.** It's the tag the import selects devices by:

   ```bash
   kubectl get nodeproviders.management.loft.sh <provider> -o jsonpath='{.spec.metal3.netBox.tag}'
   ```

2. **Create a NetBox API token.** Use a v1 token. A v2 token (`nbt_...`) is keyed by NetBox's
   `API_TOKEN_PEPPERS` setting, so it stops working if that setting is regenerated or the database
   moves to another NetBox. Give the token these permissions:
   - DCIM > Device: view and change
   - Extras > Journal entry: add
   - Extras > Tag: view

   If you set **Allowed IPs**, include the addresses the controller's traffic leaves from, usually
   the nodes of the cluster it runs on, plus any workstation that runs `record-qualification.sh`.
   If NetBox is behind a proxy that hides the client address, the first request fails with a 403
   that names the address NetBox saw.

3. **Create the qualified tag** in NetBox, for example `gpu-qualified`. NetBox rejects a tag that
   doesn't exist.

4. **Store the token in a Secret.** Store the token alone. NetBox shows a new v2 token as a whole
   header, `Bearer nbt_<key>.<secret>`: copy only what follows `Bearer `. Don't add `Token` or
   `Bearer`, because the controller adds the scheme itself.

   ```bash
   read -rs NETBOX_TOKEN && echo
   kubectl -n gpu-burn-in-recorder create secret generic gpu-burn-in-recorder-netbox \
     --from-literal=token="$NETBOX_TOKEN"
   unset NETBOX_TOKEN
   ```

5. **Point the controller at it:**

   ```bash
   helm upgrade gpu-burn-in-recorder community-stacks/gpu-burn-in/recorder/chart \
     -n gpu-burn-in-recorder --reset-then-reuse-values \
     --set netbox.tokenSecret.name=gpu-burn-in-recorder-netbox \
     --set netbox.admitTag=<the import's tag> \
     --set netbox.qualifiedTag=gpu-qualified
   ```

   The startup log line then says `"netbox":true`.

6. **Turn it on per run** with `netboxUpdate: "true"`. Start with a failing run while the tenant
   cluster is kept (`releaseServer: "false"`). The device changes, and the server stays until you
   delete the tenant cluster.

### Check it

- The controller logs `updated NetBox device` with the device URL before `recorded qualification
  result`.
- The device's journal has the entry, and a failed device has lost the admit tag.
- The Machine's `SourceAttached` condition is `False` with reason `Orphaned` after a failure:

  ```bash
  kubectl get machines.management.loft.sh <machine> \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
  ```

A NetBox error stops the run from being recorded at all, so no label is written either. The
controller retries, so a fixed token or permission lets it catch up. A retry after a later step
fails can add a second journal entry.

## Per-run parameters

Three Stack parameters choose what happens to each run. They're set on the tenant cluster
template or the StackInstance. A parameter the instance leaves unset takes the StackTemplate
default.

| Parameter | Default | Effect |
| --- | --- | --- |
| `recordResult` | `true` | Record the result. `false` makes the controller ignore the run |
| `netboxUpdate` | `false` | Also update the NetBox device |
| `releaseServer` | `false` | Delete the tenant cluster once the result is recorded |

## Verify

Watch the controller's decisions:

```bash
kubectl -n gpu-burn-in-recorder logs deploy/gpu-burn-in-recorder -f
```

Each record produces a `Recorded` event on the StackInstance. A run with no inventory Machine gets a
`NoMachine` warning, and a failed write gets `RecordFailed`:

```bash
kubectl -n <project-namespace> get events --field-selector involvedObject.name=<stack-instance>
```

Then read the record:

```bash
# machine target
kubectl get machines.management.loft.sh <provider>.<host> --show-labels
# bmh target, on the cluster that runs Metal3
kubectl -n metal3-system get bmh <host> \
  -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}{"\n"}'
```

## Permissions

The chart's ClusterRole gives the controller only what it uses:

| Access | Why |
| --- | --- |
| `get`, `list`, `watch` StackInstances, StackTemplates, NodeClaims, Machines and NodeProviders (`storage.loft.sh`) | The run, its parameter defaults, the claim, the server and its provider |
| `get`, `list`, `watch`, `create`, `delete` QualificationReports | Create one per run, prune past `keepReports`, compute metrics |
| `get` Secrets | The run's outputs Secret, by name. The controller never lists Secrets |
| `get`, `patch` Machines (`management.loft.sh`) | `machine` target |
| `get`, `patch` BareMetalHosts (`metal3.io`) | `bmh` target with `localCluster` |
| `delete` VirtualClusterInstances (`management.loft.sh`) | `rbac.releaseServer` |
| `create`, `patch` Events | Recorded, NoMachine and RecordFailed events |

Secrets `get` is cluster-wide, because Stack outputs Secrets live in every project namespace.

Writes go through the management API, which authorizes the controller's ServiceAccount. That has not
been verified in-cluster yet; see [Tested](#tested).

## Build

[.github/workflows/gpu-burn-in-recorder-image.yml](../../../.github/workflows/gpu-burn-in-recorder-image.yml)
tests the controller and publishes `ghcr.io/<repository owner>/gpu-burn-in-recorder` for
`linux/amd64` and `linux/arm64`. It runs on every push to `main` or `gpu-burn-in` that changes
`recorder/`, and on demand. Pull requests build the image without publishing it. It tags:

| Tag | Published for |
| --- | --- |
| `sha-<short sha>` | Every build |
| `main`, `gpu-burn-in` | The latest build of that branch |
| `<version>` and `latest` | A git tag `gpu-burn-in-recorder-v<version>`, for example `gpu-burn-in-recorder-v0.1.0` |

The first push creates the package as private. Make it public in the package's settings, or give the
chart an `imagePullSecret`.

To build locally:

```bash
cd community-stacks/gpu-burn-in/recorder
docker build -t <registry>/gpu-burn-in-recorder:dev .
```

The image is a static binary on `gcr.io/distroless/static:nonroot`, running as UID 65532 with a
read-only root filesystem.

## Run from a workstation

The controller runs anywhere it can reach the Platform cluster, which is useful for a dry run before
you install it:

```bash
cd community-stacks/gpu-burn-in/recorder
KUBECONFIG=<kubeconfig for the Platform cluster> go run . --dry-run \
  --target=bmh --local-cluster=loft-cluster --cluster-kubeconfig-dir=<dir> \
  --label-domain=gpu-qualification.example.com \
  --metrics-bind-address=0 --health-probe-bind-address=:18081
```

Here a kubeconfig that authenticates through the `vcluster` CLI works, because the CLI is on your
machine. `--cluster-kubeconfig-dir` holds one kubeconfig file per other cluster, named after the
cluster. Run `go run . --help` for every flag.

## Troubleshooting

- **Nothing recorded, no event.** The `report` task is not Healthy yet, the run sets
  `recordResult: false`, or the StackInstance's template is not in `templates`. With
  `logLevel: debug`, the controller logs every reconcile.
- **`NoMachine` warning.** No inventory Machine holds a NodeClaim of the run's tenant cluster.
  Either the server is not from an inventory provider, or the tenant cluster was deleted before the
  controller saw the finished run.
- **`RecordFailed ... Forbidden` on a Machine.** The Platform build does not let users label
  Machines. Use `target: bmh`.
- **`RecordFailed ... no kubeconfig directory configured` or `cluster <name>: open ...`.** The Metal3
  provider's `clusterRef` names a cluster with no kubeconfig in `clusterKubeconfigs.existingSecret`,
  and it is not `localCluster`.
- **`label domain ... ignores labels in vcluster.com and loft.sh domains`.** Choose another
  `labelDomain`.
- **`netboxUpdate is set, but the controller has no NetBox token`.** `netbox.tokenSecret.name` is
  unset, or the startup log says `"netbox":false`.
- **`netboxUpdate is set, but the Machine has no NetBox device`.** The Machine has no
  `netbox.vcluster.com/url` annotation: the server didn't come from a NetBox import.
- **`RecordFailed ... NetBox: ... 403`.** The token lacks a permission from [Set it up](#set-it-up),
  or Allowed IPs leaves out the address NetBox sees. A `400` naming a tag means the qualified tag
  doesn't exist in NetBox.
- **The tenant cluster was not deleted.** Check that the run sets `releaseServer: true` and that
  `rbac.releaseServer` is on.

## Development

```bash
cd community-stacks/gpu-burn-in/recorder
gofmt -l . && go vet ./... && go test ./...
helm lint chart
```

The unit tests run the reconciler against a fake API server and a fake NetBox, covering:

- Both targets.
- Waiting for the report and for captured outputs.
- Per-run parameters against StackTemplate defaults.
- Dry run.
- NetBox tag handling.
- Recording each run only once.

`../test-manifests.sh` runs these and also lints and renders the chart.

The controller uses unstructured objects for Platform and Metal3 types, so it does not depend on a
particular Platform API module version.

## Tested

**2026-10-20, vCluster Platform 4.13.0-alpha.19:** run from a workstation against a live gpu-burn-in
run on an RTX 2000 Ada, with `target: bmh`:

- **Dry run:** within seconds of the report being captured, it found the right server. It went from
  NodeClaim `gpu-burn-in-rtx2000-qm92s` to Machine
  `metal3-us-va-blacksburg-dc1.rack-c-u12-xlarge-gpu`, then to BareMetalHost
  `metal3-system/rack-c-u12-xlarge-gpu` on `spark-cluster`, without an `assetID`.
- **For real:** it wrote `result=passed` and the annotations to that BareMetalHost, once.
- **Two more runs:** an RTX run with telemetry and an nvml-mock run with an injected uncorrectable
  ECC error. It recorded `passed` and `failed: inventory,soak` on their BareMetalHosts and, with
  `releaseServer: true`, deleted both tenant clusters.

**QualificationReport, 2026-10-20:** a passing nvml-mock run produced report
`metal3-us-va-blacksburg-dc1.rack-b-u18-xlarge-b5f29a6f`. It had full hardware (8 x NVIDIA B200,
driver 580.65.06, DMI) from the `reportjson` output, and each test's status and metrics. `/metrics`
served the series computed from it, for example `gpu_qualification_passed` 1 and soak
`peak_temp_c` 73.

**In-cluster, 2026-10-20 and 2026-10-21:** from image `sha-a6c8deb` in namespace
`gpu-burn-in-recorder` on the Platform cluster, with `target: bmh`. It recorded thermal, XID and
RTX runs with topology from NetBox. Its ServiceAccount was allowed to delete the tenant clusters
through the management API (`releaseServer`).

**NetBox, 2026-10-21:** a failing nvml-mock run (`expectedGPUs: 9` on 8 simulated B200 GPUs) with
`netboxUpdate: true`, `releaseServer: false`, admit tag `vcluster-sync` and a v1 token. Within a
second of the report being captured, the controller:

- set device 2 to `failed` and removed `vcluster-sync`;
- added a `danger` journal entry: `GPU qualification failed (nvml-mock-netbox): inventory,soak.
  inventory failed: 8 of 9 GPUs; ...`;
- wrote `result=failed` on the BareMetalHost and created the QualificationReport.

The import then marked the Machine `SourceAttached=False`, `Orphaned`, kept because a NodeClaim
held it. Deleting the tenant cluster then released the server: the BareMetalHost was deprovisioned
and deleted about a minute later, and the Machine a minute after that. The machine's five
QualificationReports stayed. After device 2 was set back to `active` and tagged `vcluster-sync`, the
import created the BareMetalHost and Machine again, with no result label and `SourceAttached=True`,
and the host went through inspection.

**Report only, 2026-10-21:** a Google Cloud N1 VM with one V100 from a Terraform node provider,
run from a workstation. The tenant cluster had no Machine, so the controller created
QualificationReport `auto-nodes-gcp-gpu.gpu-burn-in-v100-3-67f318a1-001-2ce21d34` (`passed`, every
test with its metrics) labeled `no-inventory: "true"`, wrote no label, and with `releaseServer: true`
deleted the tenant cluster, which deleted the VM.

Not tested yet:

- The `machine` target from the controller. A label written by hand to a Machine on
  4.13.0-alpha.19 was accepted, and the chart grants the controller `patch` on Machines.
