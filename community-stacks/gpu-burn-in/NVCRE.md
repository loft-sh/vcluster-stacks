# NVCRE integration plan

Integrate NVIDIA Cluster Readiness Engine (NVCRE) as an optional step of this Stack, and keep
everything else. NVCRE adds what the Stack can't do: NCCL across many nodes, NVLink domains and
whole racks, bisection down to suspect nodes, and training workloads. It has no long soak, no
inventory checks, no per-machine record and no quarantine; it stops at evidence by design. The
Stack's own tests, the recorder, QualificationReports, NodeType gating, NetBox and the dashboards
stay as they are, and NVCRE's results flow through them.

Status: phase 1 is built and unit-tested. Phases 2 and 3 are a plan. Facts about NVCRE are from
v0.8.1 (2026-10-20, `nvcre.nvidia.com/v1alpha1`).

## Contents

- [What each side does](#what-each-side-does)
- [Phase 1: per-node results](#phase-1-per-node-results)
- [Phase 2: an nvcre step](#phase-2-an-nvcre-step)
- [Phase 3: rack-scale qualification](#phase-3-rack-scale-qualification)
- [Test plan](#test-plan)
- [Risks](#risks)
- [Not planned](#not-planned)
- [Open questions](#open-questions)

## What each side does

| | This Stack | NVCRE |
| --- | --- | --- |
| Inventory: count, model, ECC, NVLink state | Yes | No |
| DCGM diagnostics | Levels 1 to 4 | Level 4 only, one Job per node |
| NCCL | One server | Many nodes, by node, by NVLink domain or the whole cluster, plus bisection |
| Long soak with temperature and XID checks | Up to 24 hours | No. The longest stress is DCGM level 4 |
| Training workloads | No | NeMo Nemotron 8B and 56B |
| Per-machine record, gating, NetBox, dashboards | Yes, through the recorder | No |

## Phase 1: per-node results

Built. Before it, a run had one verdict, and the recorder wrote it on every Machine the tenant
cluster held. That's right for one server, and wrong once NVCRE names the one bad node out of eight.

- **Report contract.** The report step's `report.json`, published as `reportjson`, has `nodes[]`:
  each node's name, result, failed tests and summary, from the tests that ran on it. A test can
  have one result per node, and a test with no result counts against every node. With one server
  there is one entry, matching the run's verdict. A report without `nodes[]`, from an older Stack,
  keeps its old meaning: one verdict for every node.
- **Recorder.** Each Machine gets its own entry's verdict, report, label and NetBox update. It
  matches the node named as the Machine's host name: the Machine's name after `<provider>.` on
  Metal3, its `spec.displayName` on NICo. A Machine with no entry is not recorded, and gets a
  `NoNodeResult` event.
- **QualificationReport.** Each machine still gets its own report. A run over several nodes sets
  `spec.group` and the `qualification.vcluster-stacks.io/group` label to the tenant cluster, so
  one run's reports can be read together. A report of another node than the run's host carries
  only its node name under `hardware`, because the host inventory describes the host.
- **`record-qualification.sh`.** `--node` picks one server's verdict from a report over several
  nodes; it defaults to `--bmh`, or to the only node.

The Stack's steps still run once, on one server: the step results that produce `nodes[]` per node
come with phase 3.

## Phase 2: an nvcre step

An opt-in step after `soak` and before `report`, in a tenant cluster that holds one server or many.

**What it does:**

1. Installs NVCRE from its Helm chart, pinned to a tested version, through an Argo CD template
   like the GPU Operator's. NVCRE installs Kubeflow Trainer itself.
2. Creates one `Certification` per run: every GPU node as the target, the categories and
   thresholds from the Stack parameters. A Certification's spec can't change, so a re-run is a new
   one.
3. Waits for it to finish, within the step's timeout.
4. Reads the results NVCRE itself publishes: each category's `succeededNodesRef` and
   `failedNodesRef` ConfigMaps (`succeeded-nodes.csv.gz`, and `failed-nodes.json.gz` with a
   reason per node). NVSentinel reads the same ConfigMaps, which makes them the stable contract.
5. Writes `gpu-burn-in-result-nvcre` in the existing result format, with per-node outcomes and
   NCCL bus bandwidth as `metrics`.

**Mapping NVCRE's outcomes:**

| NVCRE | Step result for that node |
| --- | --- |
| In `succeededNodes` for every category | `passed` |
| `HardwareFailureDetected` or `ThresholdViolation` | `failed` |
| `WorkloadFailed` on some nodes | `failed`, with NVCRE's message in the summary |
| `WorkloadFailed` on every node, or the Certification itself failed | `error`: more likely the tooling than the hardware |
| Excluded by NVCRE (cordoned, mixed architecture, too few GPUs) | `error` |

**New Stack parameters:**

| Parameter | Default | Purpose |
| --- | --- | --- |
| `runNVCRE` | `false` | Turn the step on |
| `nvcreVersion` | a tested release | The NVCRE chart version |
| `nvcreCategories` | `communication/nccl-all-reduce` | Categories as `domain/variant`, comma-separated |
| `nvcreTestScale` | `full-scale` | `intra-node`, `intra-rack`, `full-scale` or `diagnose` |
| `nvcreBusBandwidthGBps` | empty | Minimum NCCL bus bandwidth. NVCRE ships no thresholds, so without one NCCL passes at any bandwidth. The step refuses to pass without it unless `nvcreAllowNoThreshold` is set |

`dcgm-level4` needs the standalone DCGM host engine, which `telemetry: true` already sets up.

## Phase 3: rack-scale qualification

One tenant cluster for a whole rack or NVLink domain, so NVCRE can test the fabric between servers.

- **Claiming the rack.** A `nodeCount` parameter, and a qualification NodeType that selects the
  rack, for example by `netbox.vcluster.com/rack`.
- **The Stack's own steps per node.** Today each step runs once, and the stop-on-failure gate reads
  every result in the namespace. Both become per node: one Job per node and step, results keyed
  by node, and a failed node skips only its own later steps.
- **NVL72.** Install NVIDIA's DRA driver for GPUs, which NVCRE needs for ComputeDomains, and use
  `nvcreTestScale: intra-rack` or `diagnose`.
- **The rack's verdict.** Each machine is recorded on its own (phase 1). The rack passes when
  every machine does, read from the reports' shared `spec.group`.

## Test plan

The lab has one real GPU and simulated ones, so it can prove the plumbing, not NCCL performance.

| Test | Where | Proves |
| --- | --- | --- |
| Per-node results with two servers, one failing | Unit tests | Phase 1, done: `TestRecordsEachNodeOwnVerdict` (Metal3 and NICo naming, a Machine with no node) and the two-node cases in `tests/evaluate-test.sh` |
| Per-node results end to end with two simulated servers | nvml-mock | Phase 1 on a live run. Needs the phase 3 per-node steps, and a second simulated host |
| nvcre step, `nccl-all-reduce` | nvml-mock | The step's install, wait and result reading. With no CUDA, NVCRE reports `WorkloadFailed` on every node, which must come out as `error` |
| nvcre step, `nccl-loopback` and `dcgm-level4` | RTX 2000 Ada | A real pass on one GPU, or DCGM skips recorded as such |
| Multi-node NCCL with thresholds, `diagnose`, NVL72 | Real multi-GPU servers | Not possible in the lab |

The step's result reading also gets fixture tests, like `tests/evaluate-test.sh`, built from
captured NVCRE ConfigMaps.

## Risks

- **Churn.** `v1alpha1`, with weekly minor releases. Pin the version and test before moving it.
- **Platform detection.** NVCRE picks per-platform settings from each node's provider ID.
  Manually joined private nodes carry `vcluster://`, which counts as on-prem. A `metal3://`
  provider ID picks up settings for Mistral's GB300 systems, which NVCRE's docs warn about on x86
  HGX. Check what our private nodes carry before trusting its NCCL settings.
- **Resource defaults.** The training entries request DGX-class CPU and memory by default. Smaller
  servers need overrides.
- **NGC.** The images need an NGC key.

## Not planned

- **Replacing the Stack's tests with NVCRE.** It has no inventory checks, no soak and no
  temperature or XID judgment.
- **Quarantine through NVSentinel.** NVSentinel's taints live on Kubernetes nodes, which go away
  with the tenant cluster. The label, NetBox and the QualificationReport are the durable record.
  NVSentinel can still run beside the Stack.

## Open questions

- Which provider ID our private nodes carry on Metal3 and NICo.
- Whether NVCRE's `dcgm-level4` and `nccl-loopback` run usefully on a single RTX 2000 Ada.
- Where NCCL bus bandwidth is best read from: the `BandwidthMeasurement` resources or the CLI's
  `--results-file` JSON.
- Whether NVSentinel's lifecycle manager, which runs NVCRE on newly joined nodes, should drive
  phase 3 instead of a Stack step.
