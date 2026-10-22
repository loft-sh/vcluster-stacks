#!/bin/sh
# NGC PyTorch image. nccl-tests all_reduce, all_gather and reduce_scatter across every GPU the pod
# was given, with correctness checking. The NGC image ships the MPI builds (*_perf_mpi), one rank
# per GPU; a single-process build (*_perf) is used instead when the image has one.
set -u
cd "$WORK"
n=$(nvidia-smi -L | wc -l)
[ "$n" -gt 0 ] || { echo "no GPUs visible"; exit 1; }
echo "$n" >nccl-gpus

for op in all_reduce all_gather reduce_scatter; do
  if [ -x "/usr/local/bin/${op}_perf" ]; then
    set -- "/usr/local/bin/${op}_perf" -g "$n"
  else
    set -- mpirun --allow-run-as-root --oversubscribe --bind-to none -np "$n" "/usr/local/bin/${op}_perf_mpi" -g 1
  fi
  echo "== $op: $* -b 8 -e $NCCL_MAX_BYTES -f 2 -c 1 -w 5 -n 20"
  rc=0
  "$@" -b 8 -e "$NCCL_MAX_BYTES" -f 2 -c 1 -w 5 -n 20 >"nccl-$op.txt" 2>&1 || rc=$?
  echo "$rc" >"nccl-$op.rc"
  cat "nccl-$op.txt"
done
