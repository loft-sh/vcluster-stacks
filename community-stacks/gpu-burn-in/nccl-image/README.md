# gpu-burn-in-nccl image

A small image for the Stack's `nccl` step: the single-process `nccl-tests` binaries
(`all_reduce_perf`, `all_gather_perf`, `reduce_scatter_perf` and the rest) on a CUDA base image with
NCCL. [test-nccl.sh](../chart/files/test-nccl.sh) uses `/usr/local/bin/*_perf` when they exist, so
the step runs unchanged.

| | This image | `nvcr.io/nvidia/pytorch` (default) |
| --- | --- | --- |
| Size | A few hundred MB | About 11 GB |
| GPUs | Volta (V100) through Blackwell, from one image (CUDA 12.9) | 26.xx: Ampere and later; Volta needs 24.12 |
| Multi-node | Not yet: no MPI builds | MPI builds |

Built by [the image workflow](../../../.github/workflows/gpu-burn-in-nccl-image.yml) for linux/amd64
and linux/arm64 (Grace), each on a native runner, and published as
`ghcr.io/<repository owner>/gpu-burn-in-nccl`. Use it with `ncclImage:
ghcr.io/<owner>/gpu-burn-in-nccl:<tag>`.

It needs a driver that runs CUDA 12.9: 575 or newer, or 525 and newer through CUDA's minor-version
compatibility.
