# GPU burn-in tools compared

No open source tool we found does everything this Stack does: test a server, keep a record per
machine, gate scheduling on the result, and quarantine a failed server in the inventory. Most tools
do one or two of those. The closest fits combine with this Stack rather than replace it:

- **NVIDIA Cluster Readiness Engine (NVCRE)** tests across many nodes and racks.
- **NVSentinel** watches GPUs continuously and remediates.
- **NICo machine validation** checks a host before anyone can claim it.

As of 2026-10-21. These projects move fast, so check each one's current release before relying on
a detail here.

## Contents

- [What this Stack covers](#what-this-stack-covers)
- [Comparison](#comparison)
- [The closest fits](#the-closest-fits)
- [Other tools](#other-tools)
- [Using them together](#using-them-together)
- [Sources](#sources)

## What this Stack covers

- **Tests, on one server per tenant cluster:**
  - inventory: GPU count, model, ECC and NVLink state;
  - DCGM diagnostics, levels 1 to 4;
  - NCCL within the server;
  - a DCGM soak of up to 24 hours, judged on temperature and XID errors.
- **Results:**
  - a report per run;
  - a QualificationReport per machine, kept as history;
  - a label that NodeTypes can require;
  - optionally, NetBox status, tags and a journal entry, which take a failed server out of
    vCluster Platform;
  - Prometheus metrics and Grafana dashboards per machine, rack and site.
- **Not covered yet:** NCCL across servers, traffic across an NVLink domain that spans trays, the
  network between racks, and training workloads. Each NVL72 tray's NVLink fabric registration,
  health and clique are checked, but no test sends traffic between trays. See
  [Rack-scale and multi-rack fabric](README.md#rack-scale-and-multi-rack-fabric).
  [NVCRE.md](NVCRE.md) plans to add these through NVCRE. Only its first phase is built: the
  recorder and QualificationReports can keep a separate verdict for each node of a run.

## Comparison

| Tool | Source | Runs on | Tests | Across nodes | Result kept per machine | On failure |
| --- | --- | --- | --- | --- | --- | --- |
| **This Stack** | Apache-2.0 | vCluster Platform tenant clusters | Inventory with NVLink fabric checks, DCGM 1 to 4, NCCL in one server, 24-hour soak with NVLink error counts | Not yet; planned through NVCRE | QualificationReport, label, NetBox | Label gates NodeTypes; NetBox removes the server |
| **NVCRE** | NVIDIA, Apache-2.0 | Kubernetes operator | NCCL in five variants, DCGM level 4, NeMo training | Yes: per node, per NVLink domain, whole cluster, with bisection to suspect nodes | Per node, in ConfigMaps the Certification points to | Nothing, by design |
| **NVSentinel** | NVIDIA, Apache-2.0 | Kubernetes | Continuous GPU, log and NIC monitoring; checks before GPU pods start; validation of new nodes | Pre-start NCCL across nodes | Node conditions and events | Cordon, taint, drain, GPU reset or reboot |
| **NICo machine validation** | NVIDIA, part of NICo | Bare metal, before the OS a tenant gets | DCGM level 2 or 3, stress-ng, NVMe, site plugins | No | NICo's database and health reports | Host held back from allocation |
| **NVIDIA Mission Control** | NVIDIA, commercial | BCM and Slurm | Baseline tests for trays, racks and multiple racks (GB200), scheduled health checks | Yes | Reports | Automated repair listed as coming |
| **Google cluster-health-scanner** | Google, Apache-2.0 | GKE or Slurm | DCGM, NCCL, network, stragglers, a short training run | Yes | Node labels | Taint, when not a dry run |
| **AMD GPU Operator test runner** | AMD | Kubernetes | AMD GPU tests; burn-in recipes of 1 to 24 hours | RCCL in AMD's validation example | Events and labels | Taint |
| **OpenStack Ironic burn-in** | OpenStack, Apache-2.0 | Bare metal, before an OS | gpu-burn, stress-ng, fio, network pairs | Network pairs only | Logs | None |
| **AWS SageMaker HyperPod deep health checks** | AWS, managed | HyperPod clusters | DCGM level 4, EFA, stress-ng, NCCL | Yes | CloudWatch | Taint, reboot or replace |
| **Microsoft SuperBench** | Microsoft, open source | CLI over SSH | Micro and model benchmarks, with a validator that flags defective nodes | Yes | Per-node results | None |
| **IBM Autopilot** | IBM, Apache-2.0 | Kubernetes | PCIe, DCGM, GEMM, network | Network only | Labels, metrics | Label. Archived 2026-10-09 |
| **gpu-burn, gpu-fryer** | Open source | A binary or container | Sustained GPU load | No | None | None |

## The closest fits

### NVIDIA Cluster Readiness Engine

The strongest complement. NVCRE is a Kubernetes controller (`nvcre.nvidia.com/v1alpha1`). You
create a `Certification` naming target nodes and test categories, and it runs NCCL tests and NeMo
training across groups of nodes:

- per node;
- per NVLink domain, grouped by the `nvidia.com/gpu.clique` label, including NVL72 racks through
  ComputeDomains;
- across the whole cluster.

When a group fails, its `diagnose` mode splits the group and reruns the halves until it narrows the
fault to a few suspect nodes.

**Compared with this Stack:**
- **What NVCRE adds:** scale, meaning many nodes and whole racks, plus training workloads.
- **What it leaves out:**
  - The longest stress is DCGM level 4, about 20 minutes each of power and stress load.
  - It doesn't judge temperature or XID errors itself.
  - It ships no default pass thresholds.
  - It deliberately never cordons, taints or repairs: results stay as evidence for something else to
    act on.

That last point is the gap the recorder fills. [NVCRE.md](NVCRE.md) is a plan for running NVCRE as
an optional step of this Stack, with its per-node results recorded like the Stack's own.

### NVSentinel

NVSentinel does continuous fault detection and remediation in Kubernetes:
- **Detects** through monitors for DCGM, syslog and NICs.
- **Acts** through components that quarantine, drain and remediate nodes.
- **Checks recent versions added:**
  - checks injected into GPU pods before they start: DCGM, NCCL within the node, and NCCL across
    nodes;
  - a lifecycle manager that taints newly joined nodes, validates them, partly through NVCRE, and
    lifts the taint when they pass;
  - a monitor that turns failed NVCRE results into a node taint.

**Compared with this Stack:** NVSentinel acts on Kubernetes nodes, so its taints and conditions
disappear when a node leaves the cluster. This Stack's record is on the machine and in the
inventory, so it outlives the tenant cluster. The two fit together. NVSentinel can watch the
tenant clusters customers use, while this Stack qualifies servers before they get there.
vCluster Platform ships a built-in NVSentinel Argo CD template.

### NICo machine validation

NICo validates each host it manages in its own discovery OS, before the host is offered:
- **When:** when the host is first brought in, after every release, and on demand.
- **What:** DCGM level 2 or 3, stress-ng, an NVMe check, and site-defined plugin tests. No NCCL
  test and no soak.
- **On failure:** the host is held back from allocation until a new run passes.

**Compared with this Stack:** NICo catches a broken host earlier, and enforces the result itself.
This Stack tests later, on the OS image tenants run, with NCCL and a long soak.
[recorder/NICO.md](recorder/NICO.md) covers how the recorder could also record NICo's own results.

## Other tools

- **NVIDIA Mission Control** has one-click baseline validation for trays, racks and multiple racks
  on GB200, and scheduled health checks through Slurm. It's commercial and built on BCM and Slurm,
  not Kubernetes.
- **Google cluster-health-scanner** is the closest open source design to the recorder. It writes a
  result label per check on each node, and taints failed nodes unless it runs as a dry run. It's
  tied to GCP machine types.
- **AMD's GPU Operator test runner** runs scheduled or pre-start tests on AMD GPUs and taints
  unhealthy ones. AMD's cluster validation example gates each phase on the previous phase's
  result label, the same pattern as this Stack. It's the Kubernetes option for AMD GPUs.
- **OpenStack Ironic** has burn-in clean steps, including `burnin_gpu`, which runs gpu-burn before
  an OS is installed. Metal3 is built on Ironic but has no way to trigger them, and results go only
  to logs.
- **Cloud services:**
  - AWS HyperPod's deep health checks run DCGM level 4, EFA and NCCL checks, with automatic
    replacement.
  - The EKS node monitoring agent and auto repair act on GPU errors without running active tests.
  - Both are tied to AWS.
- **Slurm and SSH tools:**
  - Azure's AzNHC: node health checks with GPU, NVLink, NCCL and InfiniBand tests.
  - LBNL Node Health Check: the framework AzNHC builds on.
  - Microsoft SuperBench: benchmarks plus a validator that flags defective nodes.
  - These fit Slurm clusters, not Kubernetes.
- **IBM Autopilot** was the closest open source Kubernetes design: health checks per node, with
  results as labels and metrics. Its repository was archived on 2026-10-09.
- **Kubernetes remediation plumbing:** Medik8s Node Healthcheck and Cluster API MachineHealthCheck,
  with Metal3 remediation. They turn node conditions into reboots or reprovisioning. They don't
  test anything.
- **Load generators:**
  - gpu-burn: sustained GPU load.
  - gpu-fryer: also flags a GPU much slower than its peers.
  - Building blocks, with no orchestration or record.

## Using them together

| Stage | Tool |
| --- | --- |
| Before a host can be claimed | NICo machine validation, on NICo |
| Before a server joins tenant capacity | This Stack, recorded by the recorder |
| Across a rack or many servers | NVCRE, as a step of this Stack (planned) |
| While tenants use the servers | NVSentinel in their tenant clusters |

## Sources

- [NVCRE repository](https://github.com/NVIDIA/cluster-readiness-engine),
  [documentation](https://docs.nvidia.com/cluster-readiness-engine/) and
  [NVIDIA's introduction](https://developer.nvidia.com/blog/validate-gpu-cluster-readiness-before-ai-workloads-land/)
- [NVCRE on vCluster Private Nodes](https://www.vcluster.com/blog/nvidia-cluster-readiness-engine-vcluster-private-nodes)
- [NVSentinel](https://github.com/NVIDIA/NVSentinel) and its
  [preflight checks](https://docs.nvidia.com/nvsentinel/components/preflight.md)
- [NICo machine validation](https://docs.nvidia.com/infra-controller/documentation/provisioning-day-0/machine-validation)
- [NVIDIA Mission Control autonomous hardware recovery](https://docs.nvidia.com/mission-control/docs/nmc-software-installation-guide/2.3.1/nmc-ahr-installation.html)
- [Google cluster-health-scanner](https://github.com/GoogleCloudPlatform/cluster-health-scanner)
- [AMD cluster validation framework](https://rocm.blogs.amd.com/software-tools-optimization/cvf/README.html)
- [OpenStack Ironic hardware burn-in](https://docs.openstack.org/ironic/latest/admin/hardware-burn-in.html)
- [AWS SageMaker HyperPod deep health checks](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-eks-resiliency-deep-health-checks.html)
  and [EKS node health](https://docs.aws.amazon.com/eks/latest/userguide/node-health.html)
- [Azure AzNHC](https://github.com/Azure/azurehpc-health-checks)
- [Microsoft SuperBench](https://github.com/microsoft/superbenchmark)
- [IBM Autopilot](https://github.com/IBM/autopilot)
- [gpu-burn](https://github.com/wilicc/gpu-burn) and [gpu-fryer](https://github.com/huggingface/gpu-fryer)
