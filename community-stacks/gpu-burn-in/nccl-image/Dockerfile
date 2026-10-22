# nccl-tests for the gpu-burn-in nccl step: the single-process *_perf binaries, which test-nccl.sh
# prefers, on a CUDA base image with NCCL. A few hundred MB instead of the 10+ GB NGC PyTorch image.
#
# CUDA 12.9 is the last toolkit that builds for Volta, so one image covers Volta (V100) through
# Blackwell. It needs a driver that runs CUDA 12.9: 575 or newer, or 525 and newer through CUDA's
# minor-version compatibility.

# renovate: datasource=docker depName=nvidia/cuda
ARG CUDA_VERSION=12.9.1
# renovate: datasource=github-tags depName=NVIDIA/nccl-tests
ARG NCCL_TESTS_VERSION=v2.21.1
ARG NCCL_VERSION=2.32.3-1+cuda12.9
# Volta, Turing, Ampere, Ada, Hopper, Blackwell (B200, B300) and Blackwell RTX, plus PTX for newer GPUs.
ARG NVCC_GENCODE="-gencode=arch=compute_70,code=sm_70 -gencode=arch=compute_75,code=sm_75 \
  -gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_86,code=sm_86 \
  -gencode=arch=compute_89,code=sm_89 -gencode=arch=compute_90,code=sm_90 \
  -gencode=arch=compute_100,code=sm_100 -gencode=arch=compute_103,code=sm_103 \
  -gencode=arch=compute_120,code=sm_120 -gencode=arch=compute_120,code=compute_120"

FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS build
ARG NCCL_TESTS_VERSION
ARG NCCL_VERSION
ARG NVCC_GENCODE
RUN apt-get update && apt-get install -y --no-install-recommends --allow-change-held-packages \
      git ca-certificates "libnccl2=${NCCL_VERSION}" "libnccl-dev=${NCCL_VERSION}" \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${NCCL_TESTS_VERSION}" https://github.com/NVIDIA/nccl-tests.git /src \
    && make -C /src -j"$(nproc)" NVCC_GENCODE="${NVCC_GENCODE}"

FROM nvidia/cuda:${CUDA_VERSION}-base-ubuntu24.04
ARG NCCL_VERSION
ARG NCCL_TESTS_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends --allow-change-held-packages \
      "libnccl2=${NCCL_VERSION}" \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/*_perf /usr/local/bin/
LABEL org.opencontainers.image.title="gpu-burn-in-nccl" \
      org.opencontainers.image.description="nccl-tests ${NCCL_TESTS_VERSION} on CUDA, for the gpu-burn-in Stack" \
      org.opencontainers.image.source="https://github.com/NVIDIA/nccl-tests"
