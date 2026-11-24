# NVSentinel Community Stack

This Stack adds [NVSentinel](https://github.com/NVIDIA/NVSentinel) to a cluster that already runs
the [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/).
NVSentinel watches GPU health through DCGM and the kernel log, and acts on a fault:

- By default it cordons the faulty GPU node.
- Optionally it drains the node, through pod eviction or, for Slurm nodes, through
  [Slinky](#drain-slurm-nodes-through-slinky).
- Optionally it reboots the drained node or resets the faulty GPU.

See [Fault handling](#fault-handling) for what each step does and needs.

The GPU Operator is a prerequisite, not part of the Stack. It can come from the
[NVIDIA GPU Operator Stack](../nvidia-gpu-operator/), from Helm, or from anything else. The Stack
reads how the GPU Operator exposes GPUs from the cluster and follows it.

NVSentinel itself is installed through Argo CD. A task that resolves the GPU driver mode, two
readiness gates and the Slinky drainer are vCluster Platform Apps. Their Jobs run the vCluster
Platform image the Platform already uses.

The files in this directory are the source manifests, an example and the checks for the
`nvsentinel` StackTemplate.

> [!IMPORTANT]
> This Stack is not marked `vcluster.com/certified`, and vCluster Platform does not bundle it.

## Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Fault handling](#fault-handling)
- [Files](#files)
- [Configure parameters](#configure-parameters)
- [Install](#install)
- [Verify](#verify)
- [Upgrade](#upgrade)
- [Remove](#remove)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Test changes](#test-changes)

## Architecture

```text
discover (00) ---> gpuready (01) --+--> dcgmready (01) ------+
                                   |                         +--> nvsentinel (03)
                                   +--> slinky-drainer (02) --+
```

Every task after `discover` also depends on `discover` directly, because it reads the resolved
mode from `discover`'s outputs. The diagram leaves those edges out.

| Task | Type | Template | `dependsOn` | Timeout | Function |
| --- | --- | --- | --- | --- | --- |
| `discover` | `app` | `nvsentinel-discover` | none | `6m0s` | Resolves `gpuDriverMode` to `device-plugin` or `dra` and publishes the DCGM names that mode uses. Checks the node selectors. |
| `gpuready` | `app` | `nvsentinel-gate` | `discover` | `28m0s` | Gate. Waits until one GPU is available on the GPU node selector. |
| `dcgmready` | `app` | `nvsentinel-gate` | `discover`, `gpuready` | `15m0s` | Gate. Waits for the DCGM DaemonSet (`nvidia-dcgm`, or `nvidia-dcgm-dra` with DRA) to finish rolling out on every GPU node. |
| `slinky-drainer` | `app` | `nvsentinel-slinky-drainer` | `discover`, `gpuready` | `12m0s` | Deploys NVSentinel's Slinky drainer. Renders nothing unless `cordon`, `drain` and `slinkyDrain` are all on. |
| `nvsentinel` | `argoCDApplication` | `nvsentinel-nvsentinel` | `discover`, `gpuready`, `dcgmready`, `slinky-drainer` | `20m0s` | Installs NVSentinel in the resolved mode, against the DCGM endpoint `discover` published. |

An `argoCDApplication` task is ready when its Application reports both `Synced` and `Healthy`. An
`app` task is ready when the Platform's Helm deploy finishes. The Apps set `wait: true`, so Helm
waits for the Job, or for the Slinky drainer's Deployment. A task that declares outputs is ready
only after it has captured them.

### GPU driver mode

The GPU Operator runs one of two mutually exclusive stacks, and NVSentinel must match it:

| | `device-plugin` | `dra` |
| --- | --- | --- |
| GPU Operator CR | `ClusterPolicy` | `GPUCluster` (experimental) |
| DCGM DaemonSet and Service | `nvidia-dcgm` | `nvidia-dcgm-dra` |
| What `gpuready` counts | `nvidia.com/gpu` in node allocatable | Devices of type `gpu` that driver `gpu.nvidia.com` publishes in ResourceSlices |
| NVSentinel | `global.gpuDraEnabled: false`. The metadata collector uses the `nvidia` RuntimeClass. | `global.gpuDraEnabled: true`. The metadata collector holds a DRA admin-access claim on the node's GPUs. Namespace `nvsentinel` is labeled `resource.kubernetes.io/admin-access=true`. |

A mismatch fails quietly. In DRA mode there is no `nvidia` RuntimeClass, so a device-plugin
NVSentinel never collects GPU metadata, and it watches a DCGM Service that does not exist.

`gpuDriverMode: auto`, the default, reads the mode from the cluster when `discover` runs:

- If the cluster has a `GPUCluster`, it uses `dra`.
- If it has a `ClusterPolicy`, it uses `device-plugin`.
- If it has both, `discover` fails, because the GPU Operator rejects that state.
- If it has neither, `discover` fails: there is no GPU Operator to follow.

Set `device-plugin` or `dra` explicitly to skip detection. Do that when the GPU Operator is
installed at the same time as this Stack, so its CR may not exist yet when `discover` runs. The
[cluster template](../nvidia-gpu-operator/virtualclustertemplate.yaml) of the NVIDIA GPU Operator
Stack does this.

`auto` decides once, when `discover` first runs. Change a parameter of the `discover` task, such
as `gpuDriverMode`, to make it decide again.

### DCGM endpoint

NVSentinel's GPU health monitor reads from the DCGM host engine. `discover` publishes its address:
the Service the GPU Operator creates for the resolved mode, in `gpuOperatorNamespace`, on
`dcgmPort`. With the defaults that is `nvidia-dcgm.gpu-operator.svc:5555`.

Set `gpuOperatorNamespace` when the GPU Operator runs elsewhere. Set `dcgmHost` when DCGM is not
the GPU Operator's at all. The Stack then cannot tell which DaemonSet serves it, so `dcgmready`
skips its rollout wait and only repeats the GPU count.

### The gates

NVSentinel started against a DCGM host engine that is not serving reports
`GpuDcgmConnectivityFailure`. Two gates hold it back until DCGM is up. Both run the same gate App,
a Job that polls the cluster, with different parameters.

`gpuready` waits until the scheduler sees one GPU on a node that matches the GPU node selector.
That proves a GPU node has joined and its driver works. `dcgmready` then runs `kubectl rollout
status` on the DCGM DaemonSet, which covers any number of GPU workers. It follows `gpuready`
because a DaemonSet that schedules no pods yet has already finished rolling out.

On a cluster where the GPU Operator is already healthy, both gates pass on their first check.
`gpuready` has a 1380 second budget for a cluster where GPU nodes are still joining.

The gate App is a copy of the [NVIDIA GPU Operator Stack's gate](../nvidia-gpu-operator/apps/02-gate.yaml)
under this Stack's names, so either Stack installs without the other.

### Node placement

| Components | Placement |
| --- | --- |
| NVSentinel's controllers (the chart's `global.systemNodeSelector`), such as the labeler and fault quarantine, and MongoDB | CPU node selector |
| NVSentinel health monitors, metadata collector, `platformConnector` | GPU node selector, with the `nvidia.com/gpu` taint toleration |
| `discover` and gate Jobs, Slinky drainer | CPU node selector |

CPU workloads select `workload.example.com/pool=<cpuNodePool>`, and GPU workloads select
`workload.example.com/pool=gpu-compute`. Those are the labels the
[NVIDIA GPU Operator Stack's NodeProfiles](../nvidia-gpu-operator/nodeprofiles.yaml) set. On
nodes with other labels, set `cpuNodeSelector` and `gpuNodeSelector` to comma-separated
`key=value` pairs, such as `foo.acme.corp/gpu-node=true`. Each replaces its pool label everywhere.
Use the same GPU selector as the GPU Operator, so NVSentinel's agents run where the GPUs are.

Both selectors take `key=value` pairs only, and `discover` fails on anything else. A bare key such
as `foo.acme.corp/gpu-node` is rejected, because the pod node selectors built from it would match
only an empty label value. For a label that has an empty value, write `foo.acme.corp/gpu-node=`.

See [Change the CPU node selector](#change-the-cpu-node-selector) before you change it on a
running Stack.

## Requirements

- vCluster Platform 4.12 or later.
- An Argo CD connector in the Platform, the Argo CD integration enabled on the cluster, and an
  Argo CD project that permits the chart source `oci://ghcr.io/nvidia/nvsentinel` and the
  destination namespace `nvsentinel`.
- The NVIDIA GPU Operator in the cluster, with DCGM enabled and at least one GPU node. See
  [GPU driver mode](#gpu-driver-mode) for installing both at the same time.
- CPU and GPU workers that match the [node selectors](#node-placement).
- cert-manager in the cluster, unless `cordon` is `false`. The Stack does not install it. See
  [Fault handling](#fault-handling).
- A default StorageClass in the cluster, or `mongodbStorageClass` naming one, unless `cordon` is
  `false`. NVSentinel's MongoDB store requests a 10Gi volume per replica, and without a
  StorageClass the volumes stay Pending.
- For `slinkyDrain`, the Slinky Slurm operator, and the namespace in `slinkyNamespace`.
- Network access from Argo CD and from the workers to these sources:

  | Source | Used by |
  | --- | --- |
  | `oci://ghcr.io/nvidia/nvsentinel`, `ghcr.io/nvidia` | NVSentinel chart and images, Slinky drainer image |
  | `docker.io/bitnamilegacy` | NVSentinel's MongoDB store and its helper images, when cordoning is on |
  | The vCluster Platform image, `ghcr.io/loft-sh/vcluster-platform` or your mirror | `discover` and gate Jobs |

## Fault handling

By default NVSentinel acts on a GPU fault by cordoning the node, so no new pods land on it. It does
not drain the node unless you set `drain`, and it does not reboot it unless you set
[`remediation`](#remediation): by default running pods stay where they are, and recovering
the node is left to you. When the fault clears, NVSentinel
uncordons the node, unless its [circuit breaker](#circuit-breaker) has tripped.

| Parameter | Default | Effect |
| --- | --- | --- |
| `cordon` | `true` | Runs NVSentinel's fault quarantine. `false` runs monitoring only: health events and node conditions, no cordon. A node that is already cordoned stays cordoned, see [Turn fault handling off](#turn-fault-handling-off). |
| `drain` | `false` | `true` also evicts pods from a node NVSentinel cordoned. No effect when `cordon` is `false`. See [Drain](#drain). |
| `drainMode` | `Immediate` | How the drain treats pods in user namespaces: `AllowCompletion`, `DeleteAfterTimeout` or `Immediate`. |
| `drainTimeoutMinutes` | `60` | With `DeleteAfterTimeout`, minutes after the fault at which remaining pods are force deleted. |
| `drainImmediateNamespaces` | empty | Comma-separated namespaces or globs whose pods are evicted at once, whatever the mode. |
| `remediation` | `none` | `reboot` or `gpu-reset` lets NVSentinel recover a drained node. See [Remediation](#remediation). |
| `slinkyDrain` | `false` | `true` drains the nodes matching `slinkyNodeSelector` through Slurm instead of evicting their pods. No effect unless `cordon` and `drain` are on. See [Drain Slurm nodes through Slinky](#drain-slurm-nodes-through-slinky). |
| `slinkyNodeSelector` | `nvidia.com/gpu.present=true` | Nodes that drain through Slurm. |
| `slinkyNamespace` | `slurm` | Namespace of the Slurm worker pods. |
| `dryRun` | `false` | `true` keeps quarantine and the drainer running but only logs the cordons and evictions they would make. |
| `mongodbReplicas` | `1` | Replicas of the MongoDB store that quarantine keeps its state in. |
| `mongodbStorageClass` | empty | StorageClass for the MongoDB volumes. Empty uses the cluster's default. Set it at install. |
| `circuitBreakerEnabled` | `true` | `false` turns the [circuit breaker](#circuit-breaker) off. |
| `circuitBreakerDuration` | `5m` | Window the breaker counts cordons in, as a Go duration. |
| `circuitBreakerPercentage` | `50` | Share of GPU nodes cordoned within the window that trips the breaker. |
| `circuitBreakerMaxNodes` | `0` | Cordons within the window that trip the breaker. `0` uses the percentage alone. |

Quarantine needs NVSentinel's MongoDB store, and the store gets its TLS certificates from
cert-manager. So with `cordon: true`, which is the default, **cert-manager must already
run in the cluster**. Without it the MongoDB certificates are never issued and the `nvsentinel`
task does not become healthy. The Stack does not install cert-manager.

The MongoDB store and fault quarantine run on the CPU pool. Each MongoDB replica requests 1 CPU
and 1.5Gi, and fault quarantine 250m. One replica fits the recommended 4 cpu / 8Gi CPU worker.
Three replicas survive the loss of one CPU worker, but each needs room on the CPU pool.

The MongoDB volumes use `mongodbStorageClass`, or the cluster's default StorageClass when
it is empty. Choose it before the first install. A StatefulSet's volume claims cannot change, so a
new value makes Argo CD's comparison fail (`ComparisonError` on the `mongodb` StatefulSet) and
NVSentinel stops updating. Moving to another StorageClass means deleting the StatefulSet and its
PVCs in `nvsentinel`, which discards quarantine's stored state.

### Circuit breaker

The circuit breaker keeps a fleet-wide problem, such as a bad driver rollout, from cordoning every
GPU node. It trips when the nodes cordoned within `circuitBreakerDuration` (default
`5m`) reach `ceil(GPU nodes × circuitBreakerPercentage / 100)`, or
`circuitBreakerMaxNodes` if that is lower and above `0`. **A tripped breaker halts all
event processing**, healthy events included: no further cordons, and no uncordon of nodes that
recover. It stays tripped until you [reset it](#reset-the-circuit-breaker). In dry run the breaker
never applies.

When it trips depends on the number of GPU nodes. On the smallest clusters, the first cordon trips it:

| GPU nodes | Default trips at | With `circuitBreakerPercentage: 100` |
| --- | --- | --- |
| 1 | 1st cordon | 1st cordon |
| 2 | 1st cordon | 2nd cordon |
| 4 | 2nd cordon | 4th cordon |
| 10 | 5th cordon | 10th cordon |

With one GPU node no threshold avoids it. `circuitBreakerEnabled: false` turns the
breaker off: NVSentinel then uncordons a recovered node on its own, but nothing limits how many
nodes it cordons, so keep it on for larger fleets. Turning it off does not reset it. Fault
quarantine reads the saved state when it starts, so a breaker turned back on is still tripped
until you reset it.

`circuitBreakerDuration` is a Go duration, such as `5m` or `1h`. Fault quarantine fails
to start on any other format while the breaker is on.

### Reset the circuit breaker

With the cluster's kubeconfig:

1. Check the breaker. `TRIPPED` means NVSentinel processes no events; `CLOSED` is normal.

   ```bash
   kubectl -n nvsentinel get cm circuit-breaker -o jsonpath='{.data.status}{"\n"}'
   ```

2. Find the cause before you reset. A breaker that tripped on several nodes at once usually points
   at something fleet-wide, such as a driver rollout, rather than at the GPUs.

3. Uncordon each node whose fault has cleared. A node is ready when none of its `Gpu*` or
   `SysLog*` conditions is `True`. Resetting the breaker does not uncordon anything.

   ```bash
   kubectl get node <node> -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{"\n"}{end}'
   kubectl uncordon <node>
   ```

4. Reset the breaker and restart fault quarantine, which reads the state only at startup.
   `cursor: CREATE` discards the events that piled up while the breaker was tripped, so stale
   events do not trip it again.

   ```bash
   kubectl -n nvsentinel patch cm circuit-breaker -p '{"data":{"status":"CLOSED","cursor":"CREATE"}}'
   kubectl -n nvsentinel rollout restart deploy fault-quarantine
   kubectl -n nvsentinel rollout status deploy fault-quarantine
   ```

After a [remediation](#remediation), keep the accumulated events instead: skip step 3, and in
step 4 set only `"status":"CLOSED"`, leaving the cursor at `RESUME`. Fault quarantine then
processes the recovery that arrived while it was tripped, and uncordons the node itself.

Upstream's
[circuit breaker runbook](https://github.com/NVIDIA/NVSentinel/blob/v1.32.0/docs/runbooks/circuit-breaker.md)
has the full procedure.

### Drain

With `drain: true`, the node drainer evicts pods in user namespaces from a cordoned
node. It skips DaemonSet pods and NVSentinel's system namespaces (`kube-system`, `gpu-operator`,
`nvsentinel` and a few more). `drainMode` sets how it treats the rest:

| Mode | Behavior |
| --- | --- |
| `Immediate` (default) | Evicts pods at once through the Eviction API, like `kubectl drain`, so PodDisruptionBudgets apply. A pod a budget keeps blocking holds the drain open, and the drainer retries until the budget allows it. Each eviction gives the pod 60 seconds to shut down, NVSentinel's `evictionTimeoutInSeconds`, in place of its own `terminationGracePeriodSeconds`; a pod still there after that is force deleted. |
| `AllowCompletion` | Waits for pods to finish on their own, with no time limit, and never evicts them. A Deployment's pods never finish, so the drain stays open until someone deletes them. |
| `DeleteAfterTimeout` | Waits for pods to finish, then force deletes those still running `drainTimeoutMinutes` after the fault was detected, without the Eviction API: budgets and graceful shutdown do not apply. The timer starts at the health event, not at the start of the drain. |

`drainImmediateNamespaces` evicts the listed namespaces at once whatever the mode, for
example a test namespace next to workloads that keep `AllowCompletion`. Remediation starts only
after the drain completes, so with `AllowCompletion` a node can wait for a reboot indefinitely.
The node stays cordoned after the drain, until the fault clears.

### Drain Slurm nodes through Slinky

Evicting the pods of a [Slinky](https://github.com/SlinkyProject/slurm-operator) Slurm worker
kills the jobs running in it, without Slurm knowing why. With `slinkyDrain: true`, on
top of `cordon` and `drain`, the nodes matching
`slinkyNodeSelector` drain through Slurm instead, with NVSentinel's
[Slinky drainer](https://github.com/NVIDIA/NVSentinel/tree/v1.32.0/plugins/slinky-drainer):

1. Fault quarantine cordons the node, as before.
2. The node drainer creates a `DrainRequest` for it, instead of evicting pods.
3. The Slinky drainer writes the fault into the node's `nodeset.slinky.slurm.net/node-cordon-reason`
   annotation. The Slinky operator puts the Slurm node in `DRAIN` because the node is cordoned,
   with that annotation as the reason, so Slurm schedules no new jobs there.
4. When every Ready Slurm worker pod on the node reports `DRAIN` with no allocated, mixed or
   completing jobs, the drainer deletes the pods in `slinkyNamespace` on that node
   and marks the `DrainRequest` complete.

When the fault clears and NVSentinel uncordons the node, the drainer removes its cordon reason
and deletes the `DrainRequest`. The NodeSet's replacement worker pod then starts on the node, but
the Slurm node stays `DOWN` with the reason `slurm-operator: Pod is terminating`: deleting the
old pod ran slurmd's default preStop hook, and Slurm does not return a node set down that way to
service on its own. Resume it once the node is healthy:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- scontrol update nodename=<slurm-node> state=resume
```

Requirements and behavior to know:

- **The Slinky Slurm operator must already run in the cluster.** The Stack does not install it.
  Slinky runs its operator in `slinky` and, by default, the Slurm cluster in `slurm`. The Slurm
  worker pods are what the drainer watches, so the default `slinkyNamespace` is `slurm`.
  That namespace must exist before you turn `slinkyDrain` on: the drainer's pod
  permissions are a Role in it, and the `slinky-drainer` task fails without it.
- **Matching nodes get no pod eviction.** The drainer deletes only pods in
  `slinkyNamespace`; any other pod stays on the node. The default selector,
  `nvidia.com/gpu.present=true`, matches every GPU node, because a default Slinky install runs its
  workers wherever they fit and labels no nodes. If some GPU nodes run other workloads, label the
  Slurm nodes and set the selector to that label. Nodes not matching it drain as
  `drainMode` says, see [Drain](#drain). The drain mode and
  `drainImmediateNamespaces` do not apply to matching nodes.
- **Every pod in `slinkyNamespace` on the node is deleted**, not just Slurm workers,
  with a 30 second grace period and without the Eviction API, so PodDisruptionBudgets do not
  apply. Do not run other workloads in that namespace.
- **The drain waits for running jobs, without a time limit.** NVSentinel v1.32.0 has no timeout
  for it. Until the jobs finish, the node stays cordoned and the Slurm node stays in `DRAIN`. If
  a drain does not finish, look at the jobs still running on that Slurm node.
- The drainer runs on the CPU pool, as one replica without leader election. Its CRD,
  `drainrequests.nvsentinel.nvidia.com`, is deleted when you turn `slinkyDrain` off.
  A `DrainRequest` that is still open blocks that deletion, see
  [Turn fault handling off](#turn-fault-handling-off).

Upstream ships the drainer as kustomize manifests only, so
[apps/02-slinky-drainer.yaml](apps/02-slinky-drainer.yaml) carries a copy of them from the
NVSentinel release in `version`. The image comes from the same release.

### Remediation

`remediation` decides what NVSentinel does to a node it cordoned and drained. It needs
`cordon` and `drain`, and has no effect without them.

| Value | What happens |
| --- | --- |
| `none` | Nothing. Recovering the node is left to you. |
| `reboot` | NVSentinel reboots the node. When the node is back and its GPUs are healthy, it uncordons it. |
| `gpu-reset` | For faults where NVSentinel recommends a GPU reset, it evicts only the pods using that GPU and tries to reset it. Faults that need a reboot, and resets that fail, end in a reboot after a full drain. |

NVSentinel's Janitor carries out the reboot with its generic provider: a privileged Job on the node
runs `reboot` on the host. It needs no cloud credentials and works on any node, but Pod Security
admission must allow privileged pods in the `nvsentinel` namespace. The provider cannot terminate nodes, so faults
that NVSentinel would answer with a replacement get no automatic action.

Before you turn it on:

- **Static node pools only.** In a dynamic pool, the autoscaler can delete the drained node while it
  reboots, and add a new one in its place.
- **A reboot takes several minutes.** On GCE with T4s and a driver the GPU Operator installs, a
  node went from fault to uncordoned in about 6.5 minutes: the reboot took about 3, and the GPU
  stack another 3. Until DCGM is back, NVSentinel reports `GpuDcgmConnectivityFailure` and keeps
  the node cordoned, with its state label at `remediation-failed`. That is expected, and clears
  with the GPU stack.
- **GPU reset needs hardware support.** Many cloud instances and other virtual machines with
  passed-through GPUs refuse to reset a GPU; GCE does. There every `gpu-reset` ends in a reboot,
  after the failed reset has already taken the node's GPU services down for a few minutes. Use
  `gpu-reset` on bare metal, and check `nvidia-smi --gpu-reset -i <uuid>` on an idle GPU first.
- **With the circuit breaker on, a rebooted node stays cordoned.** On clusters with one or two GPU
  nodes the first cordon trips the [circuit breaker](#circuit-breaker). NVSentinel still reboots
  the node, but then stops processing events, so the recovered node stays cordoned until you
  [reset the breaker](#reset-the-circuit-breaker). There, `circuitBreakerEnabled: false`
  lets the whole cycle run without you.
- **Known upstream issues** in v1.32.0: the node's `dgxc.nvidia.com/nvsentinel-state` label reads
  `remediation-succeeded` as soon as the reboot is requested, before the node goes down, and
  Janitor marks the reboot complete when the node is Ready, minutes before its GPUs are back.
  NVSentinel's own uncordon waits for the GPUs. A fault that clears on its own
  before the reboot gets the node uncordoned while the reboot is still pending.

### Turn fault handling off

Setting `cordon: false`, turning `slinkyDrain` off, or removing the Stack
does not release a node that is quarantined at that moment. The Stack cannot tell whether the
fault has cleared, so it leaves the node as it is. Check first:

```bash
kubectl get nodes -l dgxc.nvidia.com/nvsentinel-state
kubectl -n nvsentinel get drainrequests   # with Slinky drain on
```

If both are empty, there is nothing to clean up. Otherwise wait for NVSentinel to release the
nodes, or clean up by hand after the change:

1. **Open `DrainRequest`s, whenever Slinky drain went off.** Each keeps the drainer's finalizer,
   so it and the `drainrequests.nvsentinel.nvidia.com` CRD stay `Terminating`, and turning Slinky
   drain back on fails. Remove the finalizer:

   ```bash
   kubectl -n nvsentinel patch drainrequest <name> --type=merge -p '{"metadata":{"finalizers":null}}'
   ```

2. **Quarantined nodes, after `cordon: false` or removing the Stack.** Once a node's
   fault has cleared, which is when none of its `Gpu*` or `SysLog*` conditions is `True`,
   uncordon it and remove NVSentinel's state. Nothing updates those conditions once the Stack is
   removed, so read them before you remove it.

   ```bash
   kubectl uncordon <node>
   kubectl label node <node> dgxc.nvidia.com/nvsentinel-state-
   kubectl annotate node <node> quarantineHealthEvent- quarantineHealthEventIsCordoned- \
     quarantineHealthEventAppliedTaints- quarantineHealthEventAppliedLabels-
   ```

3. **Slurm nodes.** Remove the drainer's cordon reason, then resume the Slurm node as in
   [Drain Slurm nodes through Slinky](#drain-slurm-nodes-through-slinky):

   ```bash
   kubectl annotate node <node> nodeset.slinky.slurm.net/node-cordon-reason-
   ```

## Files

| File | Purpose |
| --- | --- |
| [stacktemplate.yaml](stacktemplate.yaml) | StackTemplate `nvsentinel`: five tasks, parameters and published outputs |
| [apps/00-discover.yaml](apps/00-discover.yaml) | App `nvsentinel-discover`, which resolves the GPU driver mode and the DCGM endpoint |
| [apps/01-gate.yaml](apps/01-gate.yaml) | App `nvsentinel-gate`, the readiness gate behind `gpuready` and `dcgmready` |
| [apps/02-slinky-drainer.yaml](apps/02-slinky-drainer.yaml) | App `nvsentinel-slinky-drainer`, NVSentinel's Slinky drainer |
| [apps/03-nvsentinel.yaml](apps/03-nvsentinel.yaml) | ArgoCDApplicationTemplate `nvsentinel-nvsentinel` |
| [example/stackinstance.yaml](example/stackinstance.yaml) | StackInstance for an existing cluster |
| [test-manifests.sh](test-manifests.sh) | Static and render checks |

The `apps/` file numbers are a topological order of the task graph. Every object carries the
label `app.kubernetes.io/part-of: nvsentinel-stack`.

## Configure parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `argoProject` | required | Argo CD project for the NVSentinel Application |
| `cpuNodePool` | `cpu-services` | Value of `workload.example.com/pool` on CPU workers |
| `cpuNodeSelector` | empty | Comma-separated `key=value` labels that select CPU workers instead of the pool label |
| `gpuNodeSelector` | empty | Comma-separated `key=value` labels that select GPU workers instead of `workload.example.com/pool=gpu-compute` |
| `gpuDriverMode` | `auto` | `auto` follows the GPU Operator in the cluster. `device-plugin` or `dra` skips detection. See [GPU driver mode](#gpu-driver-mode). |
| `gpuOperatorNamespace` | `gpu-operator` | Namespace the GPU Operator runs DCGM in |
| `dcgmHost` | empty | DCGM endpoint, when it is not the GPU Operator's Service. See [DCGM endpoint](#dcgm-endpoint). |
| `dcgmPort` | `5555` | DCGM host engine port |
| `driverPreinstalled` | `false` | `true` when the GPU node image has the NVIDIA driver. NVSentinel labels in preinstalled-driver mode, and the GPU reset Job finds `nvidia-smi` on the host. |
| `version` | `v1.32.0` | NVSentinel chart and image version, and the Slinky drainer image tag |

The fault handling parameters, from `cordon` to `circuitBreakerMaxNodes`, are listed under
[Fault handling](#fault-handling).

Parameters reach the tasks as strings, so quote booleans and numbers in a StackInstance:
`cordon: "false"`.

The templates are owned by the `loft-admins` team. Change `spec.owner` if your installation uses
another team.

## Install

All commands below go to the Platform **management API**, not to a cluster. Get a kubeconfig
with `vcluster platform connect management`.

```bash
# The ArgoCDApplicationTemplate, the Apps and the StackTemplate.
kubectl apply -f community-stacks/nvsentinel/apps/ \
  -f community-stacks/nvsentinel/stacktemplate.yaml
```

Check the [requirements](#requirements) on the cluster: the GPU Operator, cert-manager unless you
set `cordon: "false"`, and nodes that match the selectors. Then set
`destination.virtualCluster.name` in the example and apply it in the project namespace:

```bash
kubectl apply -n p-default -f community-stacks/nvsentinel/example/stackinstance.yaml
```

UI: **Stacks > Install Stack > "NVIDIA NVSentinel"** on the cluster.

The example sets `prunePolicy: Prune`. Without it, a later version of this Stack that removes a
task would leave that task's application running.

To create a new cluster with the GPU Operator and NVSentinel together, use the
[NVIDIA GPU Operator Stack's cluster template](../nvidia-gpu-operator/README.md#install), which
deploys both Stacks.

If the cluster still runs the NVSentinel that earlier versions of the NVIDIA GPU Operator Stack
installed, remove that one first. Follow
[Upgrade from a version that included NVSentinel](../nvidia-gpu-operator/README.md#upgrade-from-a-version-that-included-nvsentinel).
Two installations in the `nvsentinel` namespace would overwrite each other.

## Verify

Find the StackInstance and follow its tasks on the management API:

```bash
kubectl get stackinstances -A
kubectl -n <project-namespace> get stackinstance <name> \
  -o jsonpath='{.status.phase}{"\n"}{range .status.tasks[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

The phase moves through `Pending` and `Progressing` to `Healthy`, or `Degraded` when a task fails
or times out.

With the cluster's kubeconfig, check what `discover` resolved and where NVSentinel runs:

```bash
kubectl -n nvsentinel-stack get configmap nvsentinel-discovery \
  -o jsonpath='{.data.mode} ({.data.source}), DCGM at {.data.dcgmHost}:{.data.dcgmPort}{"\n"}'
kubectl -n nvsentinel-stack logs -l app.kubernetes.io/component=dcgmready --tail=-1
kubectl get pods -n nvsentinel -o wide
```

NVSentinel reports GPU health as node conditions. None of the `Gpu*` conditions should be `True`
on a healthy node, and `GpuDcgmConnectivityFailure` must be `False`:

```bash
kubectl get node <gpu-node> -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' | grep -i gpu
```

In DRA mode, also check the namespace label NVSentinel needs:

```bash
kubectl get namespace nvsentinel -L resource.kubernetes.io/admin-access
```

## Upgrade

- **Chart version.** Change `version`. Argo CD upgrades the release in place. Renovate tracks the
  default in this directory. The Slinky drainer's manifests are a copy of upstream's, so a version
  bump also needs them re-synced, see [Known limitations](#known-limitations).
- **Fault handling parameters.** Changing them reconfigures NVSentinel in place. Turning `cordon`
  on later adds MongoDB, and needs cert-manager. Read
  [Turn fault handling off](#turn-fault-handling-off) before turning it off.
- **Gate image.** The `discover` and gate Jobs follow the Platform image. A Platform upgrade
  changes it, with nothing to do here.
- **Re-running a gate.** The gate and `discover` Job names carry a hash of their settings and
  script. A Job spec is immutable, so a changed setting creates a new Job, which runs again.
- **Following a GPU driver mode switch.** `auto` does not notice a GPU Operator that changes mode
  later. After a switch, set `gpuDriverMode` to the new mode. NVSentinel then moves to the other
  DCGM Service and the other metadata collector setup.
- **GPU node selector.** Changing `gpuNodeSelector` moves NVSentinel's GPU agents. Label the GPU
  workers first, and keep the selector equal to the GPU Operator's.

### Change the CPU node selector

Changing `cpuNodePool` or `cpuNodeSelector` on a running Stack moves every CPU workload of this
Stack: the NVSentinel controllers, MongoDB, the `discover` and gate Jobs and, with `slinkyDrain`,
the Slinky drainer.

Deployments roll without downtime when a node matches the new selector. MongoDB does not: its
volume can be pinned to a node (local storage) or a zone (zonal disks), and a StatefulSet deletes
its pod before it schedules the new one. If no node matching the new selector can reach the volume,
NVSentinel's store stays down, and quarantine with it.

`discover` checks every bound volume in `nvsentinel` against the selector, and fails with `no
node matching the CPU node selector ... can reach PersistentVolume ...` if none can reach one. It
also fails on a selector that is not `key=value` pairs. **This reports the problem; it does not
prevent it.** When a parameter changes, the Stack re-syncs every affected task at once and does not
wait for `discover`, so MongoDB may already be moving when `discover` fails. Check the volume first,
as in step 2.

To move the CPU workloads to other nodes:

1. Label the target CPU workers with the new labels.
2. Keep a node MongoDB's volume is pinned to in the new selector, or plan to recreate the store:
   `kubectl -n nvsentinel get pvc` and `kubectl get pv <volume> -o jsonpath='{.spec.nodeAffinity}'`
   show where it is pinned.
3. Delete NVSentinel's completed MongoDB setup Job, if it is still there. Its name does not change
   with the selector and a Job spec is immutable, so Argo CD's server-side diff fails on it
   (`ComparisonError ... Job.batch "create-mongodb-database-..." is invalid: spec.template`) and
   NVSentinel keeps the old selector. The chart re-runs the Job on every sync and expires it 24
   hours after it finishes. [NVIDIA/NVSentinel#2381](https://github.com/NVIDIA/NVSentinel/pull/2381)
   proposes hashing the pod spec into the name, which makes this step unnecessary.

   ```bash
   kubectl -n nvsentinel delete job -l app.kubernetes.io/name=create-mongodb-database
   ```

4. Change the parameter, and wait for every task to be healthy again. Task health is not enough:
   Argo CD can report the NVSentinel Application as synced from an earlier comparison. Check that
   the workloads carry the new selector, for example
   `kubectl -n nvsentinel get deploy,sts -o custom-columns=NAME:.metadata.name,SELECTOR:.spec.template.spec.nodeSelector`.
5. Remove the old labels.

## Remove

Before you remove the Stack, check for quarantined nodes and open `DrainRequest`s, as described
in [Turn fault handling off](#turn-fault-handling-off). Removing the Stack releases neither.

```bash
kubectl -n <project-namespace> delete stackinstance <name>
```

The Platform deletes the NVSentinel Argo CD Application with cascade, so Argo CD prunes the
NVSentinel resources. It deletes the gate, `discover` and Slinky drainer AppInstances, which
uninstalls their Helm releases. That also deletes the `DrainRequest` CRD, unless a `DrainRequest`
is still open. These remain:

- The cordon, and NVSentinel's label and annotations, on every node NVSentinel had quarantined,
  and any open `DrainRequest` with its CRD.
- The namespace `nvsentinel`, which Argo CD creates through `CreateNamespace=true`, and
  `nvsentinel-stack`.
- NVSentinel's MongoDB volumes. The chart retains them (`whenDeleted: Retain`, and
  `helm.sh/resource-policy: keep`). Delete the PVCs in `nvsentinel` to free the storage.

The GPU Operator is not touched.

Removal has not been exercised end to end for this Stack.

When no instance references them, remove the templates from the Platform:

```bash
kubectl delete apps,argocdapplicationtemplates,stacktemplates -l app.kubernetes.io/part-of=nvsentinel-stack
```

## Known limitations

- NVSentinel drains nodes only with `drain`, and reboots or resets them only with `remediation`,
  through Janitor's generic provider. It never replaces nodes. Prometheus PodMonitor and
  ServiceMonitor creation is disabled.
- cert-manager is a prerequisite for the default configuration, not part of the Stack. So is the
  Slinky Slurm operator for `slinkyDrain`.
- The Slinky drainer's manifests are a copy of upstream's. A `version` bump needs them re-synced
  from that release's `plugins/slinky-drainer/config`.
- The Slinky drainer's `--drain-timeout` is not enforced upstream in v1.32.0, and the node drainer
  has no timeout for a Slinky drain either. A Slurm worker that never reports `DRAIN` holds the
  drain, and the node's cordon, until someone steps in.
- On clusters with one or two GPU nodes, the first cordon trips NVSentinel's
  [circuit breaker](#circuit-breaker).
- `auto` decides once, when `discover` first runs. It does not follow a GPU Operator that
  switches mode later, and it fails on a cluster where the GPU Operator is not installed yet.
- The gates are one-shot. They hold NVSentinel's first start, and do not notice a DCGM that goes
  away later. NVSentinel reports that itself, as `GpuDcgmConnectivityFailure`.
- With `dcgmHost` set, nothing waits for DCGM before NVSentinel starts.
- The namespaces `nvsentinel` and `nvsentinel-stack` are fixed in the templates.
- The gate App is a copy of the NVIDIA GPU Operator Stack's. A fix to one has to be made in both;
  the checks fail when the two check scripts differ.
- In DRA mode, the `gpuready` count includes every ResourceSlice of the `gpu.nvidia.com` driver.
  While the driver republishes a pool, an old slice can briefly be counted alongside the new one.

## Troubleshooting

- **`discover` failed with "there is no GPU Operator to follow".** `gpuDriverMode` is `auto` and
  the cluster has neither a `ClusterPolicy` nor a `GPUCluster`. Install the GPU Operator first, or
  set `gpuDriverMode` to the mode it will run in.
- **`discover` failed with "both a ClusterPolicy and a GPUCluster exist".** The cluster is in a
  state the GPU Operator rejects, usually after a switch from DRA. Delete the CR for the mode you
  do not use, or set `gpuDriverMode` explicitly.
- **`discover` failed with "is not a key=value label".** `cpuNodeSelector` or `gpuNodeSelector`
  holds a bare key. Write a label with an empty value as `key=`.
- **`discover` failed with "no node matching the CPU node selector".** The new selector would
  leave a volume in `nvsentinel`, MongoDB's, with no node to run on. See
  [Change the CPU node selector](#change-the-cpu-node-selector).
- **`discover` or a gate Job Pending.** No CPU worker matches the CPU node selector: the
  `cpuNodePool` label, or `cpuNodeSelector` when set.
- **`gpuready` stuck Progressing or failed.** Read the gate log,
  `kubectl -n nvsentinel-stack logs -l app.kubernetes.io/component=gpuready --tail=-1`. A count of
  0 means no GPU is available on the GPU node selector: `kubectl get nodes -l <selector>` shows
  what matches. If nodes match, the GPU Operator has not made their GPUs available yet.
- **`dcgmready` stuck waiting for the DaemonSet to exist.** The GPU Operator does not run DCGM in
  `gpuOperatorNamespace`, or runs in the other driver mode. Check
  `kubectl get daemonsets -A | grep dcgm` against what `discover` resolved.
- **Gate Job in `ImagePullBackOff`.** The CPU workers cannot pull the Platform image. In an
  air-gapped installation, the Platform's image mirror must be reachable from the cluster's
  workers as well.
- **A task stays Pending.** It waits on its `dependsOn` list. A `Degraded` task names its reason
  in `message`. Also check the Argo CD Application and the AppInstances in the project namespace.
- **`nvsentinel` stuck Progressing, MongoDB not starting.** Usually cert-manager is missing or
  has not issued the MongoDB certificates. Check `kubectl -n nvsentinel get certificates`, and
  that a default StorageClass bound the MongoDB PVC: `kubectl -n nvsentinel get pvc`. With one
  CPU worker, more than one MongoDB replica may not fit.
- **A GPU node is cordoned.** NVSentinel found a fault. `kubectl get node <name> -o yaml` shows the
  NVSentinel condition that is `True`, the `dgxc.nvidia.com/nvsentinel-state: quarantined` label
  and the `quarantineHealthEvent` annotation. NVSentinel uncordons the node when the fault clears,
  unless the circuit breaker has tripped.
- **A recovered node stays cordoned.** NVSentinel's circuit breaker has probably tripped:
  `kubectl -n nvsentinel get cm circuit-breaker -o jsonpath='{.data.status}'` prints `TRIPPED`.
  See [Reset the circuit breaker](#reset-the-circuit-breaker). It stays tripped after
  `circuitBreakerEnabled` is turned off and back on.
- **`fault-quarantine` crash-loops with "invalid circuit breaker duration".**
  `circuitBreakerDuration` is not a Go duration. Use a value such as `5m` or `1h`.
- **NVSentinel reports `GpuDcgmConnectivityFailure`.** NVSentinel cannot reach DCGM. Confirm that
  `dcgmready` ran and passed, and that the endpoint `discover` published is the DCGM the cluster
  runs.
- **NVSentinel `metadata-collector` cannot start in DRA mode.** Kubernetes admits its
  admin-access ResourceClaim only in a namespace labeled `resource.kubernetes.io/admin-access=true`.
  Argo CD sets the label through `managedNamespaceMetadata`. Check it with `kubectl get namespace
  nvsentinel --show-labels`.
- **NVSentinel resources keep changing back, or Argo CD reports a shared resource.** A second
  Argo CD Application manages the `nvsentinel` namespace, usually the one earlier versions of the
  NVIDIA GPU Operator Stack installed. See
  [Upgrade from a version that included NVSentinel](../nvidia-gpu-operator/README.md#upgrade-from-a-version-that-included-nvsentinel).
- **Chart or image download failures.** Check registry and repository access from Argo CD and
  the workers. Local rendering does not prove that the deployed cluster can pull artifacts.

## Test changes

From the repository root, run the static checks (bash 4 or later, python3 with PyYAML and helm):

```bash
./community-stacks/nvsentinel/test-manifests.sh
```

The checks render the graph five times: with the default parameters, with a variant that takes
the other branch of most conditionals, with both of those in DRA mode, and with reboot
remediation behind a `dcgmHost` override. They render StackTemplate tasks and the
ArgoCDApplicationTemplate with Helm's template engine. They render each App's manifests as the
chart the Platform builds, with only the parameters the task passes. They assert:

- Names carry the `nvsentinel` prefix and the `part-of` label, and match their files.
- Every `.Values` reference is a declared parameter. Every task passes only parameters that its
  template declares, and each task type matches its template's kind.
- Timeouts are in canonical Go duration form. App timeouts stay under the 30 minute cap, and
  each task timeout exceeds the App or Job deadline it waits on.
- Tasks with outputs have no hyphen, and the graph is acyclic. Every `.Outputs` reference reads
  a declared output of a dependency. `dcgmready` follows `gpuready`, and `nvsentinel` follows
  `slinky-drainer`.
- Only `discover` reads `gpuDriverMode`. Every other mode-dependent task takes
  `.Outputs.discover.mode`. `discover`'s outputs read keys its Job writes and its release does not
  declare.
- `discover` runs against a fake `kubectl`. It resolves `auto` from a `ClusterPolicy` or a
  `GPUCluster`, fails with neither and with both, and publishes the DCGM Service in
  `gpuOperatorNamespace` on `dcgmPort`, or `dcgmHost` with the rollout wait off. Its volume check
  passes for a volume a matching node can reach and with no volumes, and fails for a stranded
  volume. It fails on a bare key in either selector.
- `discover` and the gates run the Platform image on the CPU node selector. Both gates count one
  GPU on the GPU node selector, from the source the mode uses. `dcgmready` waits for the mode's
  DaemonSet in `gpuOperatorNamespace`, and for nothing when `dcgmHost` is set.
- The gate's check script is identical to the NVIDIA GPU Operator Stack's.
- The gate and `discover` Job names change with the selectors and with `gpuOperatorNamespace`.
- NVSentinel's DCGM endpoint is what `discover` resolved. Its CPU components carry the CPU node
  selector, and its GPU agents and `platformConnector` affinity the GPU node selector.
- The mode reaches NVSentinel: `gpuDraEnabled` (a YAML boolean), the Janitor reset Job's
  RuntimeClass and the namespace label.
- NVSentinel defaults to cordoning without draining (`cordon: true`, `dryRun: false`,
  `drain: false`). Fault quarantine and the MongoDB store follow `cordon`, the node drainer runs
  only with both `cordon` and `drain`, and remediation runs only with `remediation` on top of
  both, as described in [Remediation](#remediation). The `GPUReset` template reaches
  fault-remediation unrendered, and the reset Job's driver path follows `driverPreinstalled`.
  MongoDB runs on the CPU node selector with one server certificate per replica. The circuit
  breaker follows `circuitBreakerEnabled`, with the window, percentage and node cap from the
  parameters. The window default is a valid Go duration.
- Slinky drain is off by default. The Slinky drainer App renders nothing unless `cordon`, `drain`
  and `slinkyDrain` are all on, and `customDrain` follows the same switch. When on, the drainer
  runs the `version` image on the CPU node selector and watches `slinkyNamespace`, its drain
  template is left for the node drainer to render, and `customDrain` names the ConfigMap, CRD and
  completion condition the App deploys, with a non-empty node selector.
- The example sets `prunePolicy: Prune`.

The NVIDIA GPU Operator Stack's checks cover its cluster template, which deploys this Stack. CI
also runs a server-side dry run of every manifest against vCluster Platform.

### Tested

This Stack has not run on a cluster as a Stack of its own. The `discover` task's detection, the
`gpuOperatorNamespace` and `dcgmHost` parameters, a GPU Operator installed outside the NVIDIA GPU
Operator Stack, and removal are covered by the static checks only.

Its NVSentinel configuration was tested while it was still part of the NVIDIA GPU Operator Stack,
on a vCluster 0.37.6 cluster with private nodes on GCE (Kubernetes 1.36.6, vCluster Platform
4.12.5, Argo CD 3.6.1), with one CPU node and one GPU node with 2x T4:

- On 2026-11-10, in DRA mode and in dry-run monitoring, NVSentinel started with `gpuDraEnabled`.
  Argo CD labeled its namespace `resource.kubernetes.io/admin-access=true`, and the metadata
  collector's admin-access claim was allocated on both GPUs. The GPU health monitor read from
  `nvidia-dcgm-dra`, and `GpuDcgmConnectivityFailure` stayed `False`.
- The cordon defaults were tested on the same cluster, which already ran cert-manager. Applying
  them started MongoDB, with its certificates issued by cert-manager, and fault quarantine with
  `--dry-run=false`. A double-bit ECC error injected into GPU 0 through `dcgmi test --inject` was
  detected as `GpuMemWatch`, and the node was cordoned 22 seconds after the injection started. No
  pod was evicted. With one GPU node, the cordon tripped the circuit breaker 45 seconds later.
  After the fault cleared, the node stayed cordoned until it was uncordoned and the breaker reset
  by hand, as described in [Reset the circuit breaker](#reset-the-circuit-breaker).

## License

This Stack is part of this repository and is licensed under the
[Apache License 2.0](../../LICENSE).
