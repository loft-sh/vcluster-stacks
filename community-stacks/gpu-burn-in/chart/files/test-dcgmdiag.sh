#!/bin/sh
# DCGM image. dcgmi diag at the configured level (1 quick, 2 medium, 3 long, 4 extended), then any
# extra named tests such as nvbandwidth or pulse_test. JSON results are judged by evaluate.sh.
set -u
cd "$WORK"
. /scripts/hostengine.sh
start_hostengine || exit 1

echo "== dcgmi diag -r $DCGM_DIAG_LEVEL"
rc=0
dcgm diag -r "$DCGM_DIAG_LEVEL" -j >dcgm-diag.json 2>dcgm-diag.err || rc=$?
echo "$rc" >dcgm-diag.rc
cat dcgm-diag.err
echo "dcgmi diag -r $DCGM_DIAG_LEVEL exited $rc"

if [ -n "$DCGM_EXTRA_TESTS" ]; then
  echo "== dcgmi diag -r $DCGM_EXTRA_TESTS"
  rc=0
  dcgm diag -r "$DCGM_EXTRA_TESTS" -j >dcgm-extra.json 2>dcgm-extra.err || rc=$?
  echo "$rc" >dcgm-extra.rc
  cat dcgm-extra.err
  echo "dcgmi diag -r $DCGM_EXTRA_TESTS exited $rc"
fi
