#!/bin/sh
# Init container, NVIDIA tool image. Runs test-$TEST.sh under a deadline and keeps its output in
# $WORK. Always exits 0: the publish container judges the outcome, so a failing GPU still produces
# a result instead of a failed pod.
set -u
cd "$WORK"
if [ -f skip ]; then
  echo "skipped: $(cat skip)"
  exit 0
fi
date -u '+%Y-%m-%dT%H:%M:%SZ' >started
rc=0
timeout "$RUN_TIMEOUT_SECONDS" sh "/scripts/test-$TEST.sh" >log.txt 2>&1 || rc=$?
echo "$rc" >rc
date -u '+%Y-%m-%dT%H:%M:%SZ' >finished
tail -n 100 log.txt
echo "test-$TEST.sh exited $rc"
exit 0
