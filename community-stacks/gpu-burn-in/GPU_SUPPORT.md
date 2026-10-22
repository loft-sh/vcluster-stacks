# GPU support

The Stack's defaults suit GPUs from Ampere to Grace-Blackwell. Volta (V100) needs overrides,
because CUDA 13 dropped it, and Turing is outside the default NCCL image's support list. This page
covers each GPU generation: what works with the defaults, what to change, and what has been tested.

As of 2026-10-21, with the Stack's defaults:

| Component | Default |
| --- | --- |
| GPU Operator (`gpuOperatorVersion`) | `v26.3.3`, which installs driver `580.126.20` when it builds the driver |
| DCGM (`dcgmImage`) | `nvcr.io/nvidia/cloud-native/dcgm:4.5.3-1-ubuntu24.04`, with DCGM's CUDA 12 and CUDA 13 builds |
| NCCL (`ncclImage`) | `nvcr.io/nvidia/pytorch:26.09-py3`, CUDA 13.4.1 |

## Contents

- [Support by generation](#support-by-generation)
- [Volta (V100)](#volta-v100)
- [Turing (T4, Quadro RTX)](#turing-t4-quadro-rtx)
- [Workstation GPUs](#workstation-gpus)
- [Grace-Blackwell NVL72](#grace-blackwell-nvl72)
- [Tested](#tested)
- [Simulated GPUs](#simulated-gpus)
- [Sources](#sources)

## Support by generation

| Generation | Examples | Driver branches | Stack defaults | Overrides needed | MIG | NVLink |
| --- | --- | --- | --- | --- | --- | --- |
| Volta, CC 7.0 | V100 | R580 is the last, supported until June 2028 | NCCL image does not run; DCGM needs its CUDA 12 build | Yes, see [Volta](#volta-v100) | No | NVLink 2, within a server |
| Turing, CC 7.5 | T4, Quadro RTX | All current | Not on the NCCL image's support list; untested | Possibly | No | No |
| Ampere, CC 8.0 and 8.6 | A100, A30, A10 | All current | Yes | No | A100 and A30 | HGX NVSwitch, within a server |
| Ada, CC 8.9 | L40S, RTX Ada | All current | Yes. Workstation cards limit DCGM, see [below](#workstation-gpus) | No | No | No |
| Hopper, CC 9.0 | H100, H200 | All current | Yes | No | Yes | HGX NVSwitch, within a server |
| Blackwell, CC 10.0 and 10.3 | B200, B300 | All current | Yes | No | B200. HGX B300 is not on NVIDIA's MIG list | HGX NVSwitch, within a server |
| Grace-Blackwell | GB200, GB300 NVL72 | All current | Yes, one tray per tenant cluster | No | GB200. GB300 NVL72 is not on NVIDIA's MIG list | Multi-node NVLink across the rack, checked by `nvlinkFabric` |

The newest driver branches (R595, R610, R615) start at Turing. GPU Operator `v26.7` and later
default to driver 595, which has no Volta support.

## Volta (V100)

NVIDIA's CUDA 13 can't build code for compute capability below 7.5, and driver branch 580 is the
last to support Volta. Code built with CUDA 12 keeps running on a 580 driver. A V100 server needs
three things from the Stack:

| | What to set | Why |
| --- | --- | --- |
| **Driver** | `driverVersion` with a 580 driver the server's kernel can build, such as `"580.178.04"`. With the driver already on the server, set `driverPreinstalled: "true"` instead, and keep it on 580 or older | Newer branches don't support Volta, and GPU Operator v26.7 and later default to 595, so pin it. The default `580.126.20` does not build on kernel 7.0, such as Google Cloud's Ubuntu 24.04 kernel `7.0.0-1014-gcp`; `580.178.04` does |
| **NCCL** | `ncclImage: nvcr.io/nvidia/pytorch:24.12-py3` | The last NGC PyTorch release that supports Volta (CUDA 12.6.3). Later releases dropped Volta, and nccl-tests built with CUDA 13 leave out Volta |
| **DCGM** | Nothing: the default image passed level 2 on a V100 | NVIDIA says Volta on driver 580 needs DCGM's CUDA 12 build. The default image contains both builds and picked the right one. If diagnostics fail with an unsupported-device or kernel error on another setup, use an image with only the CUDA 12 build |

What works without changes:

- **Inventory and telemetry.** They read `nvidia-smi` and DCGM fields, which don't depend on CUDA.
- **The NVLink fabric check** skips V100s, which report no fabric. Inactive NVLink links still fail
  inventory.
- **The soak's NVLink error check** reads the replay, recovery and CRC counters, which
  Volta's NVLink 2 reports.

Verified on a Google Cloud V100 (see [Tested](#tested)): the overrides above, inventory, DCGM level
2, NCCL with one rank and the soak. Not verified: DCGM levels 3 and 4, whether DCGM's per-SKU
settings enable `targeted_stress` and `targeted_power` on V100, and the NVLink checks on a server
with several V100s. [example/gcp-v100/](example/gcp-v100/) has the run: the tenant cluster, a node
provider with a V100 node type, and the change the Google Cloud node template needs to attach the
GPU.

The NGC PyTorch 24.12 image is about 11 GB. On a Google Cloud `pd-standard` boot disk it took about
21 minutes to pull, most of the NCCL step; a `pd-balanced` or Hyperdisk boot disk is faster.

### Where to rent a V100

To test before using production servers. Availability changes; this is as of 2026-10-21.

| Provider | Status |
| --- | --- |
| Google Cloud | `nvidia-tesla-v100` on N1 VMs with 1, 2, 4 or 8 GPUs, in asia-east1-c, europe-west4-a/b/c, us-central1-a/b/c/f, us-east1-b and us-west1-a/b. No end-of-support date published |
| Oracle Cloud | VM.GPU3.1, VM.GPU3.2, VM.GPU3.4 and BM.GPU3.8 (V100 16 GB) are listed as current shapes. Capacity varies by region |
| Lambda, Paperspace | Both list V100 16 GB on their pricing pages |
| AWS | P3 and P3dn are previous-generation instances. Accounts that haven't used P3 recently report they can't launch them |
| Azure | NCv3 (V100) retired on 2025-09-30, except in a few government and sovereign regions |

## Turing (T4, Quadro RTX)

Drivers and CUDA 13 support Turing. The NGC PyTorch 26.xx releases list only Ampere, Ada, Hopper
and Blackwell, so the default NCCL image is untested on Turing, though nccl-tests built with CUDA 13
still include Turing code. If the NCCL step fails on a T4, try an older NCCL image as for Volta.

## Workstation GPUs

DCGM runs diagnostic level 1 on workstation and consumer GPUs, and higher levels only where it
explicitly supports a model. Quadro RTX cards are level 1 only.

The lab's RTX 2000 Ada ran level 2: `pcie` and `software` passed and `memory` was skipped. The soak
passed with DCGM's load tests. NCCL runs with one rank on a single GPU, which proves CUDA and NCCL
work, not bandwidth.

## Grace-Blackwell NVL72

Each GB200 or GB300 tray is tested on its own, with `nvlinkFabric: auto` checking its NVLink fabric
registration, health and clique. NVCRE's rack-wide tests need NVIDIA's DRA driver and IMEX, and
DCGM's multi-node NVLink tests arrive in DCGM 4.7, after the Stack's 4.5.3. See
[Rack-scale and multi-rack fabric](README.md#rack-scale-and-multi-rack-fabric) and
[NVCRE.md](NVCRE.md).

## Tested

| GPU | How | Result |
| --- | --- | --- |
| RTX 2000 Ada | Real GPU, passed through to a Metal3 server VM | Every step passed, with and without `telemetry` |
| V100 SXM2 16 GB, 1 per VM | Google Cloud `n1-standard-8`, driver 580.178.04, NCCL image NGC PyTorch 24.12, 2026-10-21 | Every step passed: DCGM level 2 (`memory`, `pcie`, `software`), NCCL with one rank, a 15-minute soak at 62 C peak and 316 W |
| B200, 8 per server | nvml-mock, no CUDA | Inventory, telemetry, the thermal, XID and ECC fault paths |
| GB300 tray | nvml-mock on a lab node | GPUs detected; the Stack has not run there yet |
| GB200, GB300, B200, H100, A100, L40S, T4 | Captured `nvidia-smi -q -x` from real nodes, published with nvml-mock | The NVLink fabric check judges each correctly |

## Simulated GPUs

nvml-mock ships profiles for A100, B200, GB200, GB300, H100, L40S and T4. Any other GPU, such as a
V100, can be simulated with a complete profile in the chart's `gpu.customConfig`. Start from the
closest built-in profile and set the name, `architecture: volta`, compute capability 7.0, memory,
PCI device ID, power limit and NVLink links. The most faithful profile comes from a real server's
`nvidia-smi -q -x`. nvml-mock has no CUDA, so it can't show whether the NCCL and DCGM load tests run
on a GPU.

## Sources

- [CUDA toolkit, driver and architecture matrix](https://docs.nvidia.com/datacenter/tesla/drivers/cuda-toolkit-driver-and-architecture-matrix.html)
  and [supported drivers and CUDA versions](https://docs.nvidia.com/datacenter/tesla/drivers/supported-drivers-and-cuda-toolkit-versions.html)
- [Navigating GPU architecture support (NVIDIA)](https://developer.nvidia.com/blog/navigating-gpu-architecture-support-a-guide-for-nvidia-cuda-developers/)
- [GPU Operator v26.3.3 default values](https://raw.githubusercontent.com/NVIDIA/gpu-operator/v26.3.3/deployments/gpu-operator/values.yaml),
  [release notes](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/release-notes.html)
  and [platform support](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/platform-support.html)
- [DCGM getting started: CUDA 12 build for Volta on driver 580](https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/getting-started.html),
  [feature overview](https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/feature-overview.html)
  and [diagnostics](https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/dcgm-diagnostics.html)
- [NGC PyTorch 26.09](https://docs.nvidia.com/deeplearning/frameworks/pytorch-release-notes/rel-26-09.html),
  [24.12](https://docs.nvidia.com/deeplearning/frameworks/pytorch-release-notes/rel-24-12.html) and
  the [framework support matrix](https://docs.nvidia.com/deeplearning/frameworks/support-matrix/index.html)
- [nccl-tests build architectures](https://github.com/NVIDIA/nccl-tests/blob/master/src/common.mk)
- [MIG supported GPUs](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-gpus.html)
- V100 availability: [Google Cloud GPU zones](https://docs.cloud.google.com/compute/docs/gpus/gpu-regions-zones),
  [Oracle compute shapes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm),
  [AWS previous-generation instances](https://docs.aws.amazon.com/ec2/latest/instancetypes/pg.html),
  [Azure NCv3 retirement](https://learn.microsoft.com/en-us/azure/virtual-machines/ncv3-retirement),
  [Lambda pricing](https://lambda.ai/pricing), [Paperspace pricing](https://www.paperspace.com/pricing)
