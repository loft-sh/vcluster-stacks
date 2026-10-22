#!/bin/sh
# Tools image. The last step. Fails its Job when the report's result is not passed, so the Argo CD
# Application goes Degraded and the Stack fails with this message. The report task has already
# captured its outputs by then, so the result stays readable from the StackInstance.
set -eu
. /scripts/lib.sh

if [ "$RESULT" = "passed" ]; then
  log "GPU qualification passed"
  exit 0
fi
log "GPU qualification ${RESULT:-unknown}: ${FAILED_TESTS:-no failed tests recorded}. See configmap $REPORT_NAME in this namespace." >&2
exit 1
