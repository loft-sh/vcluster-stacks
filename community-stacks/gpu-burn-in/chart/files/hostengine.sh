# Sourced by the DCGM tests. Connects them to a DCGM host engine, and defines dcgm, which runs
# dcgmi against it.
#
# With DCGM_HOST set (telemetry on), the tests use the GPU Operator's standalone nvidia-dcgm, the
# same engine dcgm-exporter reads. Diagnostics and Fleet Observability telemetry then run through
# one engine, so the burn-in is visible on the GPU dashboards while it runs. DCGM profiling is
# paused for the test, because active diagnostics and load need the profiling module that the
# exporter's DCGM_FI_PROF_* metrics hold, and resumed afterwards; profiling metrics are missing
# from the dashboards while a test runs.
#
# Without DCGM_HOST, a host engine is started inside the pod, on the GPUs the pod was given.
dcgm() {
  if [ -n "${DCGM_HOST:-}" ]; then
    sub=$1
    shift
    dcgmi "$sub" --host "$DCGM_HOST" "$@"
  else
    dcgmi "$@"
  fi
}

start_hostengine() {
  if [ -z "${DCGM_HOST:-}" ]; then
    nv-hostengine >/dev/null 2>&1 || true
  fi
  # The standalone engine can still be starting after a fresh GPU Operator install.
  i=0
  until dcgm discovery -l >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || { echo "DCGM host engine ${DCGM_HOST:-in the pod} did not answer"; return 1; }
    sleep 1
  done
  dcgm discovery -l
  if [ -n "${DCGM_HOST:-}" ]; then
    echo "== using DCGM host engine $DCGM_HOST; pausing profiling metrics for the test"
    dcgm profile --pause || echo "WARNING: could not pause DCGM profiling; diagnostics may report the profiling module busy"
    trap resume_profiling EXIT
  fi
}

# Hands profiling back to dcgm-exporter. Tests that set their own EXIT trap call it there too.
resume_profiling() {
  [ -z "${DCGM_HOST:-}" ] || dcgm profile --resume >/dev/null 2>&1 || true
}
