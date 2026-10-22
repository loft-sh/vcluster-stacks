#!/bin/sh
# DCGM image. Records what the driver reports about every GPU the pod was given, the topology,
# NVLink state and the server's DMI identity. Judged by evaluate.sh.
set -u
cd "$WORK"

echo "== nvidia-smi -L"
nvidia-smi -L || exit 1

nvidia-smi --query-gpu=index,uuid,name,serial,pci.bus_id,memory.total,driver_version,vbios_version,ecc.errors.uncorrected.volatile.total,temperature.gpu \
  --format=csv,noheader,nounits >gpus.csv || exit 1
echo "== GPUs (index, uuid, name, serial, bus, memory MiB, driver, vbios, uncorrected ECC, temp C)"
cat gpus.csv

echo "== nvidia-smi topo -m"
nvidia-smi topo -m >topo.txt 2>&1 || true
cat topo.txt

echo "== nvidia-smi nvlink -s"
nvidia-smi nvlink -s >nvlink.txt 2>&1 || true
cat nvlink.txt

for f in sys_vendor product_name product_serial board_serial; do
  printf '%s=%s\n' "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo unknown)"
done >dmi.txt
echo "== DMI"
cat dmi.txt

nvidia-smi -q >nvidia-smi-q.txt 2>&1 || true
# The XML form carries the NVLink fabric block per GPU: registration, clique and health.
nvidia-smi -q -x >nvidia-smi-q.xml 2>/dev/null || true
