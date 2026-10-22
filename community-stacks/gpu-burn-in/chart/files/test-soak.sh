#!/bin/sh
# DCGM image. Sustained load for SOAK_MINUTES while dcgmi dmon samples temperature, power,
# utilization, XID and clock event reasons every 5 seconds. NVLink error counters are read before
# and after, so errors the load caused show as growth.
#
# SOAK_LOAD=dcgm alternates DCGM targeted_stress and targeted_power in cycles of up to 20 minutes.
# SOAK_LOAD=none applies no load and only records telemetry: what a simulated GPU (nvml-mock),
# which has no CUDA, supports.
set -u
cd "$WORK"
. /scripts/hostengine.sh
start_hostengine || exit 1

nvidia-smi nvlink -e >nvlink-errors-start.txt 2>&1 || true

# 150 GPU temp, 155 power, 203 GPU util, 230 last XID, 112 clock event (throttle) reasons.
dcgm dmon -e 150,155,203,230,112 -d 5000 >dmon.txt 2>&1 &
dmon=$!
trap 'kill "$dmon" 2>/dev/null; resume_profiling' EXIT

end=$(($(date +%s) + SOAK_MINUTES * 60))
cycle=0
while :; do
  left=$((end - $(date +%s)))
  [ "$left" -ge 60 ] || break
  if [ "$SOAK_LOAD" != "dcgm" ]; then
    sleep "$left"
    break
  fi
  # Each cycle runs both tests back to back, half the cycle each.
  half=$((left > 1200 ? 600 : left / 2))
  cycle=$((cycle + 1))
  echo "== cycle $cycle: targeted_stress and targeted_power, ${half}s each, ${left}s left"
  rc=0
  dcgm diag -r targeted_stress,targeted_power \
    -p "targeted_stress.test_duration=$half;targeted_power.test_duration=$half" -j \
    >"soak-$cycle.json" 2>"soak-$cycle.err" || rc=$?
  echo "$rc" >"soak-$cycle.rc"
  cat "soak-$cycle.err"
  echo "cycle $cycle exited $rc"
done
echo "$cycle" >soak-cycles
kill "$dmon" 2>/dev/null
wait "$dmon" 2>/dev/null
nvidia-smi nvlink -e >nvlink-errors-end.txt 2>&1 || true
echo "== dmon (last 40 samples)"
tail -n 40 dmon.txt
