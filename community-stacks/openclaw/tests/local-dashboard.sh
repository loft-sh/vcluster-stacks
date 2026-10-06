#!/usr/bin/env bash
# NODEPORT MODE ONLY. In the default port-forward mode you do not need this script:
#   kubectl -n openclaw port-forward svc/openclaw 28789:80   then open the dashboard-link output.
#
# In nodeport mode, open the OpenClaw dashboard from your machine WITHOUT public exposure:
#
#   TENANT_KUBECONFIG=<tenant cluster kubeconfig> ./tests/local-dashboard.sh
#   then open the URL it prints (http://127.0.0.1:<nodePort>/). Ctrl-C stops everything.
#
# How: a kubectl port-forward to the gateway, plus a tiny local proxy (local-dashboard.mjs) that
# adds the headers the gateway requires from a trusted proxy. The local port is the NodePort so
# the browser origin is one the gateway already allows. Needs node 18+ on this machine.
set -euo pipefail

K="${TENANT_KUBECONFIG:?set TENANT_KUBECONFIG to the tenant cluster kubeconfig}"
NS="${NS:-openclaw}"
GW_PORT="${GW_PORT:-30790}"
cd "$(dirname "$0")"

NODE_PORT=$(kubectl --kubeconfig "$K" -n "$NS" get svc openclaw -o jsonpath='{.spec.ports[0].nodePort}')
OPERATOR=$(kubectl --kubeconfig "$K" -n "$NS" get configmap openclaw-bootstrap -o jsonpath='{.data.nginx\.conf}' \
  | sed -n 's/.*X-Forwarded-User "\([^"]*\)".*/\1/p' | head -1)
CLIENT_IP=$(curl -4 -s -m 5 ifconfig.me 2>/dev/null || true)

for p in "$NODE_PORT" "$GW_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "local port $p is in use" >&2; exit 1; fi
done

kubectl --kubeconfig "$K" -n "$NS" port-forward deploy/openclaw "$GW_PORT:18789" >/dev/null 2>&1 &
PF=$!
# Kill both children on exit or Ctrl-C (no `exec`: it would drop this trap and leave the
# port-forward running).
trap 'kill $PF ${PROXY:-} 2>/dev/null || true' EXIT INT TERM
for _ in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$GW_PORT/healthz" && break; sleep 0.5; done
curl -sf "http://127.0.0.1:$GW_PORT/healthz" >/dev/null || { echo "port-forward to the gateway failed" >&2; exit 1; }

LOCAL_PORT="$NODE_PORT" GATEWAY_PORT="$GW_PORT" OPERATOR_USER="${OPERATOR:-operator@openclaw.local}" \
  CLIENT_IP="${CLIENT_IP:-198.51.100.7}" node ./local-dashboard.mjs &
PROXY=$!
wait $PROXY
