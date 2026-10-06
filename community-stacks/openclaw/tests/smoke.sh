#!/usr/bin/env bash
# Smoke test for a deployed OpenClaw stack, run from your machine through port-forwards.
#
#   TENANT_KUBECONFIG=<tenant cluster kubeconfig> ./tests/smoke.sh
#   MGMT_KUBECONFIG=<mgmt kubeconfig> to also print the stack's published outputs.
#
# Checks: the model endpoint lists the model and returns a tool call (skipped for an external
# backend, whose key never leaves the cluster); OpenClaw answers /healthz and behaves as the access
# mode says (dashboard over port-forward, or the expected refusals in nodeport and ingress mode);
# persona files and marker; canary Ready.
set -euo pipefail

K="${TENANT_KUBECONFIG:?set TENANT_KUBECONFIG to the tenant cluster kubeconfig}"
NS="${NS:-openclaw}"
# Local ports for the port-forwards. Avoid 18789: a locally installed OpenClaw listens there.
VLLM_LOCAL_PORT="${VLLM_LOCAL_PORT:-18000}"
OC_LOCAL_PORT="${OC_LOCAL_PORT:-18080}"
kc() { kubectl --kubeconfig "$K" -n "$NS" "$@"; }
pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

pf() { # svc localport remoteport
  kc port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 &
  pids+=($!)
  for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$2/" && return 0; sleep 0.5; done
  echo "port-forward to $1 did not come up" >&2; return 1
}

MODEL="${MODEL:-$(kc get configmap vllm-model -o jsonpath='{.data.id}' 2>/dev/null || true)}"
[ -n "$MODEL" ] || { echo "the model-ready gate has not recorded a model yet; set MODEL to override" >&2; exit 1; }

if kc get configmap vllm-skipped >/dev/null 2>&1; then
  echo "== model: external backend ($(kc get configmap vllm-skipped -o jsonpath='{.data.externalBaseUrl}')), skipping the in-cluster checks"
  echo "ok: model-ready recorded model $MODEL, tool calling: $(kc get configmap vllm-model -o jsonpath='{.data.toolcalls}')"
else
  echo "== vLLM"
  pf vllm "$VLLM_LOCAL_PORT" 8000
  curl -sf http://127.0.0.1:$VLLM_LOCAL_PORT/v1/models | jq -e --arg m "$MODEL" '.data[] | select(.id==$m) | .id' >/dev/null \
    && echo "ok: model $MODEL is served"
  body=$(jq -cn --arg m "$MODEL" '{model:$m, temperature:0, max_tokens:512,
    messages:[{role:"user",content:"What is the weather in Paris right now? You must use the get_weather tool."}],
    tools:[{type:"function",function:{name:"get_weather",description:"Current weather for a city",
      parameters:{type:"object",properties:{city:{type:"string"}},required:["city"]}}}]}')
  resp=$(curl -s -m 300 -X POST http://127.0.0.1:$VLLM_LOCAL_PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$body")
  name=$(printf '%s' "$resp" | jq -r '.choices[0].message.tool_calls[0].function.name // empty')
  if [ "$name" = "get_weather" ]; then
    echo "ok: tool call returned ($(printf '%s' "$resp" | jq -c '.choices[0].message.tool_calls[0].function.arguments'))"
  else
    echo "FAIL: no tool call. Response head:"; printf '%s\n' "$resp" | head -c 600; echo; exit 1
  fi
fi

REACH=$(kc get configmap openclaw-endpoint -o jsonpath='{.data.reachability}')
POD=$(kc get pods -l app=openclaw --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
pf openclaw "$OC_LOCAL_PORT" 80
curl -sf http://127.0.0.1:$OC_LOCAL_PORT/healthz | jq -e '.ok==true' >/dev/null && echo "ok: /healthz ok=true"
case "$REACH" in
  port-forward)
    echo "== OpenClaw in port-forward mode (token auth, no proxy)"
    code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$OC_LOCAL_PORT/)
    [ "$code" = "200" ] && echo "ok: dashboard served over port-forward (HTTP 200)" || { echo "FAIL: dashboard HTTP $code"; exit 1; }
    tok=$(kc get secret openclaw-gateway-token -o jsonpath='{.data.token}' | base64 -d)
    [ ${#tok} -eq 64 ] && echo "ok: gateway token present in Secret (64 hex chars)" || { echo "FAIL: token missing/short"; exit 1; }
    ;;
  ingress)
    echo "== OpenClaw in ingress mode (token auth behind the proxy sidecar)"
    host=$(kc get ingress openclaw -o jsonpath='{.spec.rules[0].host}')
    url=$(kc get configmap openclaw-endpoint -o jsonpath='{.data.url}')
    [ -n "$host" ] && echo "ok: Ingress for $host exists (address: $(kc get ingress openclaw -o jsonpath='{.status.loadBalancer.ingress[*].ip}{.status.loadBalancer.ingress[*].hostname}'))" || { echo "FAIL: no Ingress"; exit 1; }
    # Through the sidecar a port-forwarded client is attributed to loopback, which the gateway refuses.
    body=$(curl -s http://127.0.0.1:$OC_LOCAL_PORT/)
    printf '%s' "$body" | jq -e '.error.type=="proxy_attribution_required"' >/dev/null \
      && echo "ok: loopback client refused by the gateway (expected over port-forward)" \
      || { echo "FAIL: unexpected dashboard response over port-forward: $(printf '%s' "$body" | head -c 200)"; exit 1; }
    tok=$(kc get secret openclaw-gateway-token -o jsonpath='{.data.token}' | base64 -d)
    [ ${#tok} -eq 64 ] && echo "ok: gateway token present in Secret (64 hex chars)" || { echo "FAIL: token missing/short"; exit 1; }
    # From this machine, when the host resolves: the Ingress path end to end (TLS not verified, the
    # certificate may be self-signed). A warning, not a failure: the Ingress may be reachable only
    # from certain networks.
    if getent hosts "$host" >/dev/null 2>&1; then
      code=$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "${url}healthz" || true)
      [ "$code" = "200" ] && echo "ok: ${url}healthz answers 200 through the Ingress" || echo "WARN: ${url}healthz answered HTTP '$code' from this machine"
    else
      echo "skip: $host does not resolve from this machine"
    fi
    echo "note: open $url in a browser, paste the dashboardToken output, approve the device once"
    ;;
  public|internal)
    echo "== OpenClaw in nodeport mode (loopback is allowed by nginx)"
    # The dashboard itself is NOT reachable over a port-forward in nodeport mode: OpenClaw refuses
    # a proxy that attributes the client to a loopback address (proxy_attribution_required).
    body=$(curl -s http://127.0.0.1:$OC_LOCAL_PORT/)
    printf '%s' "$body" | jq -e '.error.type=="proxy_attribution_required"' >/dev/null \
      && echo "ok: loopback client refused by the gateway (expected over port-forward)" \
      || { echo "FAIL: unexpected dashboard response over port-forward: $(printf '%s' "$body" | head -c 200)"; exit 1; }
    OPERATOR=$(kc get configmap openclaw-bootstrap -o jsonpath='{.data.nginx\.conf}' | sed -n 's/.*X-Forwarded-User "\([^"]*\)".*/\1/p' | head -1)
    NODE_PORT=$(kc get svc openclaw -o jsonpath='{.spec.ports[0].nodePort}')
    code=$(kc exec "$POD" -c gateway -- node -e "
fetch('http://127.0.0.1:18789/',{headers:{'x-forwarded-user':'${OPERATOR:-operator@openclaw.local}','x-forwarded-proto':'http','x-forwarded-host':'node:${NODE_PORT:-30789}','x-forwarded-for':'198.51.100.7'}}).then(r=>{console.log(r.status)})" 2>/dev/null | tail -1)
    [ "$code" = "200" ] && echo "ok: dashboard served for an attributed external client" || { echo "FAIL: attributed request got HTTP '$code'"; exit 1; }
    echo "== allowlist: a pod inside the cluster must be refused"
    code=$(kc run smoke-deny-$RANDOM --rm -i --restart=Never --quiet \
      --image=curlimages/curl:8.10.1 -- -s -o /dev/null -w '%{http_code}' "http://openclaw.$NS.svc/" 2>/dev/null | tail -c 3)
    [ "$code" = "403" ] && echo "ok: in-cluster source refused with 403" || { echo "FAIL: expected 403, got '$code'"; exit 1; }
    # The real NodePort path on the node that runs the pod (externalTrafficPolicy: Local).
    HOST_IP=$(kc get pod "$POD" -o jsonpath='{.status.hostIP}')
    codes=$(kc run smoke-np-$RANDOM --rm -i --restart=Never --quiet \
      --image=curlimages/curl:8.10.1 -- -s -o /dev/null -w '%{http_code} ' "http://$HOST_IP:$NODE_PORT/healthz" "http://$HOST_IP:$NODE_PORT/" 2>/dev/null | tail -c 8)
    [ "$(echo $codes)" = "200 403" ] && echo "ok: NodePort $HOST_IP:$NODE_PORT serves /healthz (200) and refuses / (403)" || { echo "FAIL: NodePort probe returned '$codes', expected '200 403'"; exit 1; }
    ;;
  *)
    echo "FAIL: unexpected reachability '$REACH' in configmap openclaw-endpoint"; exit 1 ;;
esac

echo "== persona files in the workspace"
WS=/home/node/.openclaw/workspace
for f in SOUL.md IDENTITY.md USER.md; do
  kc exec "$POD" -c gateway -- test -s "$WS/$f" \
    && echo "ok: $f present" || { echo "FAIL: $WS/$f missing or empty"; exit 1; }
done
agent=$(kc exec "$POD" -c gateway -- sed -n 's/^- \*\*Name:\*\* //p' "$WS/IDENTITY.md")
user=$(kc exec "$POD" -c gateway -- sed -n 's/^- Name: //p' "$WS/USER.md")
echo "ok: agent '$agent', user '$user'"
kc exec "$POD" -c gateway -- test ! -e "$WS/BOOTSTRAP.md" \
  && echo "ok: no BOOTSTRAP.md (first-run ritual skipped)" || echo "WARN: BOOTSTRAP.md exists"
want=$(kc get configmap openclaw-persona -o jsonpath='{.data.sha}')
have=$(kc exec "$POD" -c gateway -- cat /home/node/.openclaw/.stack-persona-sha)
[ "$want" = "$have" ] && echo "ok: persona marker matches the stack version" || { echo "FAIL: marker $have != $want"; exit 1; }

echo "== canary (live model + gateway check)"
ready=$(kc get deploy stack-canary -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
last=$(kc logs deploy/stack-canary --tail=1 2>/dev/null || true)
[ "${ready:-0}" = "1" ] && echo "ok: canary Ready ($last)" || { echo "FAIL: canary not Ready ($last)"; exit 1; }

echo "== telegram"
echo "telegramBot: $(kc get configmap openclaw-endpoint -o jsonpath='{.data.telegramBot}')"

if [ -n "${MGMT_KUBECONFIG:-}" ]; then
  echo "== stack outputs"
  # `kubectl get --raw` replaces the whole request path, so a kubeconfig whose server carries a
  # path (https://<platform>/kubernetes/management) needs that prefix repeated here.
  server=$(kubectl --kubeconfig "$MGMT_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  prefix=$(printf '%s' "$server" | sed -E 's#^[a-z]+://[^/]+##')
  kubectl --kubeconfig "$MGMT_KUBECONFIG" get --raw "$prefix/apis/management.loft.sh/v1/namespaces/${PROJECT_NS:-p-default}/stackinstances/${STACK:-openclaw}/outputs" \
    | jq -r '.outputs[] | "\(.name)\t\(.state)\t\(.value // .message // "")"'
fi
echo "all checks passed"
