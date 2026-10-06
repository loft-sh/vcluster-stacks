# OpenClaw Community Stack

This Stack installs a self-hosted [OpenClaw](https://openclaw.ai) agent on a tenant cluster. The
Stack contains:

- The OpenClaw gateway with [lossless-claw](https://www.npmjs.com/package/@martian-engineering/lossless-claw)
  (LCM, lossless context management) as the context engine.
- A model that [vLLM](https://docs.vllm.ai) serves on the tenant's GPU, or any OpenAI-compatible
  endpoint.
- A configurable persona.
- Telegram, configured from the install form.
- A canary that reports if the agent can answer now.

You reach the dashboard with one `kubectl port-forward` (default), through an Ingress, or over a
NodePort that one CIDR can reach.

The files in this directory are the source manifests, the examples and the checks for the
`openclaw` StackTemplate.

## Architecture

The `openclaw` StackTemplate has five App tasks. Two chains of tasks join at the end:

```
vllm (01) ---> modelready (02) ---+
                                   +---> canary (05)
persona (03) ---> openclaw (04) ---+
```

| Task | App | Function | Helm wait / task timeout |
| --- | --- | --- | --- |
| `vllm` | `openclaw-step-01-vllm`, or `openclaw-step-01-vllm-skip` when `modelBackend` is `external` | Deploys vLLM on the GPU node: Deployment, Service and model cache volume. The skip App creates only a marker ConfigMap. | no (the gate waits) / 15m |
| `modelready` | `openclaw-step-02-model-ready` | Runs a hook Job. The Job waits until the model endpoint answers, sends one tool-calling request and records the result in ConfigMap `vllm-model`. | 30m / 60m |
| `persona` | `openclaw-step-03-persona` | Renders SOUL.md, IDENTITY.md and USER.md into ConfigMap `openclaw-persona`. Applies the files to a running gateway with `kubectl exec`. | 10m / 25m |
| `openclaw` | `openclaw-step-04-gateway` | Deploys the gateway, lossless-claw, the state volume and the entry point for the selected access mode. The task needs only the model Service to exist. The dashboard is available while the model downloads. | 15m / 40m |
| `canary` | `openclaw-step-05-canary` | Deploys a pod that is Ready only when a chat completion and the gateway's `/readyz` succeed. The check repeats continuously. | 10m / 25m |

All resources deploy into the namespace `openclaw` of the destination. A stack can read task
outputs only from namespaces that its Apps deploy into. For a referenced App, that namespace is
fixed on the App. Install the stack one time per destination.

### Model backends

Parameter `modelBackend` selects the backend:

- `vllm` (default). Step 1 runs vLLM with the model from `model`. vLLM serves the model as
  `servedModelName`. Model-specific flags (parsers, speculative decoding, chat template kwargs) go
  in `vllmExtraArgs`. GPU-specific switches go in `vllmEnv`. To change the model, change
  parameters only. See [Tested model profiles](#tested-model-profiles).
- `external`. The tenant needs no GPU. OpenClaw, the readiness gate and the canary use
  `externalBaseUrl` with `externalApiKey`. The stack ignores the vLLM parameters. Set
  `servedModelName` to the model id that the endpoint expects. Set `modelVision`,
  `modelReasoning` and `thinkingFormat` to the values that the endpoint supports. The key is a
  `password` parameter. In the tenant cluster the key is stored only in Secrets. It is never
  written to a ConfigMap or a log.

In both modes OpenClaw registers the model under the provider id `vllm`. Sessions continue to
resolve `vllm/<model>` after a backend change.

To test the external backend on a tenant without a GPU, use `example/external-llama-cpp.yaml`. It
runs llama.cpp with a small Qwen3 model on CPU as an OpenAI-compatible endpoint with an API key and
tool calling. It is slow. The first chat turn can exceed the gateway's provider timeout of 300 s
while the model reads the OpenClaw prompt. Use it to test the integration, not as an agent.

### Access modes

Parameter `accessMode` selects the mode.

**`port-forward` (default).** No proxy, no NodePort, no IP allowlist. Access to the tenant
cluster with `kubectl` is the access control. Install the stack, wait for Healthy, run the
`dashboardCommand` output, then open the `dashboardLink` output:

```bash
kubectl -n openclaw port-forward svc/openclaw 28789:80
# then open the dashboardLink output: http://localhost:28789/#token=<token>
```

The Control UI reads the token from the URL fragment, so the link opens the chat directly. The
browser connects from loopback, so OpenClaw approves the device automatically. `dashboardLink` is
a plain output on the stack card, so you can copy it. Each user who can read the stack outputs
and can port-forward can open the dashboard. `dashboardToken` is the same secret in masked form.
The seed step generates the token one time, keeps it on the state volume (`.gateway-token`) and
copies it into Secret `openclaw-gateway-token`. Use a local port other than 18789, because a
local OpenClaw installation uses that port. `localPort` changes only the published command and
the permitted browser origins.

**`ingress`.** For clusters with an ingress controller. The stack creates an Ingress for
`ingressHost` with class `ingressClassName`, TLS from `ingressTlsSecret` and the
`ingressAnnotations`. The Ingress sends traffic to an nginx sidecar. The sidecar is the trusted
proxy of the gateway. The gateway keeps token authentication:

```
browser --> Ingress controller (TLS) --> nginx sidecar :8080 --> gateway 127.0.0.1:18789
```

Open `dashboardUrl` and paste the `dashboardToken` output one time. The browser does not connect
from loopback, so OpenClaw asks for one device approval per browser. This approval is the second
factor after the token:

```bash
kubectl -n openclaw exec deploy/openclaw -c gateway -- sh -c 'TMPDIR=/tmp/oc openclaw devices list'
kubectl -n openclaw exec deploy/openclaw -c gateway -- sh -c 'TMPDIR=/tmp/oc openclaw devices approve <requestId>'
```

In this mode `dashboardLink` does not contain the token. The host is public. A plain-text output
with the token would let each user who can read the outputs log in from any location. Restrict
the Ingress with annotations, for example a source-range allowlist or an authentication proxy.
Without a TLS Secret the token travels unencrypted. As in nodeport mode, a `kubectl port-forward`
does not reach the dashboard: the gateway refuses a proxied client with a loopback address.

The location of the ingress controller depends on the tenant type:

- Shared-nodes tenant cluster from the Platform's default template: the controller runs on the
  control plane cluster. The template syncs IngressClasses from the host and Ingresses to the
  host. A controller inside such a tenant loses its IngressClass to that sync.
- Private-nodes tenant cluster: the controller runs inside the tenant.

On a GKE control plane cluster, always set `ingressClassName`. The GCE add-on claims an Ingress
without a class. The published scheme follows `ingressTlsSecret` (`ingressScheme: auto`). Set
`ingressScheme: https` when TLS terminates before the Ingress without a Secret, for example with
managed certificates, a cloud load balancer or Cloudflare. `openclaw devices list` shows paired
browsers with the address of the ingress controller, because the sidecar overwrites
`X-Forwarded-For`.

**`nodeport`.** For access over the network without `kubectl`, from one permitted CIDR, on
clusters without an ingress controller or a LoadBalancer:

```
browser --> NodePort (externalTrafficPolicy: Local, real client IP kept)
        --> nginx sidecar :8080   allow <allowedCidr> and 127.0.0.1, deny all
        --> gateway 127.0.0.1:18789 (loopback only; nothing else can reach it)
```

OpenClaw runs in `trusted-proxy` authentication mode. nginx is the only path to the gateway.
nginx adds `X-Forwarded-User: <operatorUser>` to each request. OpenClaw maps this identity to
`operator.admin` and approves browsers with this identity automatically. From the permitted CIDR
the URL opens the dashboard directly. **The IP allowlist is the only access control.** Each user
behind that address is the operator. Set `allowedCidr`. An empty allowlist denies all users. The
node that runs OpenClaw needs a public IP and a firewall rule that permits your CIDR to the
NodePort. `dashboardReachability` reports what the pod found: `public` when the node has a public
address, `internal` when it does not. A port-forward does not reach the dashboard in this mode.
OpenClaw refuses a proxied client with a loopback address (`403 proxy_attribution_required`).
`tests/local-dashboard.sh` works around this for local tests.

A change of the access mode re-syncs the `openclaw` task and rolls the pod one time. The state
volume (chats, memory, persona) does not change.

### Persona

Six parameters in the section *Persona* become three files in the agent workspace
`/home/node/.openclaw/workspace`. OpenClaw reads these files on each turn:

| Parameter | File | Notes |
| --- | --- | --- |
| `agentName`, `agentEmoji` | `IDENTITY.md` and the identity in the OpenClaw config | The name and emoji that the model uses and the dashboard shows. A change rolls the pod one time. |
| `agentSoul` | `SOUL.md` | Prefilled with a friendly general personality. Change it as you want. |
| `userName` | `USER.md` | How the agent addresses you. |
| `userProfile` | `USER.md`, Profile section | One fact per line. Stored as plain text in the Platform. OpenClaw injects a maximum of 4,000 characters. |
| `userTimezone` | `USER.md` and `agents.defaults.userTimezone` | Dates in the system prompt and in message envelopes. |

The persona task renders the files into the `openclaw-persona` ConfigMap with a content hash. On
a new install, the seed step of the gateway pod copies the files into the workspace before
OpenClaw starts. OpenClaw then skips its first-run identity setup. When you change the parameters
later, the task runs again and writes the files into the running pod. The agent uses them on its
next turn. No restart is necessary. The task rewrites the files only when the hash changes.
Changes that the agent makes to USER.md or IDENTITY.md stay until you change the template values.
The output `personaVersion` is the hash.

### Canary

The Platform decides the status of a stack task when the task deploys. It does not check the
status again. Only Argo CD tasks get continuous health checks. After a GPU reclaim, or when an
external key expires, the stack card continues to show Healthy. The `canary` task gives the live
signal. The canary pod is Ready only when a real chat completion against the model endpoint and
the gateway's `/readyz` both succeed. The check repeats every 60 s. For an external endpoint it
repeats every 300 s, because each check uses tokens. After three failed checks the pod is
NotReady. After one successful check it is Ready again.

```bash
kubectl -n openclaw get deploy stack-canary       # READY 1/1 = the agent can answer now
kubectl -n openclaw logs deploy/stack-canary      # one line per check, with completion latency
```

The workloads view of the tenant cluster in the Platform UI shows the same state. Use the canary
for alerts. At install time the canary is also a gate: the task becomes Healthy only when both
checks pass.

### Telegram

The stack renders the `telegramBotToken` parameter into Secret `openclaw-channels`. Only the seed
step mounts this Secret. The seed step writes the token to the state volume as `telegram-token`
(mode 0600) and references it as `tokenFile` in the channel config. This happens before the
gateway starts the first time, so the bot is live when the stack is Healthy. `telegramAllowFrom`
pre-authorizes numeric user IDs and makes them command owners. These users need no pairing code.
All other users get a pairing code that you approve one time. The output `telegramBot` shows
`@yourbot`, `invalid token: ...`, `unreachable` (no egress to api.telegram.org) or
`not configured`. Each channel and sender gets its own session (`dmScope`). This keeps replies
fast. See [Telegram setup](#telegram-setup).

### Where the data lives

- **Model cache** (`modelCache`, vLLM backend only):
  - `pvc` (default): PersistentVolumeClaim `vllm-cache` with size `modelCacheSize` in StorageClass
    `modelCacheStorageClass`. Use a network-attached StorageClass. A node-local StorageClass such
    as `local-path` binds the claim to the node where it was created. After a Spot reclaim, the
    scheduler cannot place the new vLLM pod until you delete the PVC manually. The claim has
    `helm.sh/resource-policy: keep`.
  - `hostPath`: directory `modelCachePath` on the node that runs vLLM. The cache follows the pod
    to any GPU node and survives pod restarts. It is lost with the node. This costs a new
    download of some minutes, not data. The namespace must permit hostPath volumes (Pod Security
    level `privileged`). Use this mode on private-nodes tenants where `local-path` is the only
    StorageClass.
  - `emptyDir`: no persistence. Each pod start downloads the model again.
- **OpenClaw state** (`openclaw-state`: chats, LCM database, workspace, plugins): a PVC with size
  `stateSize` in StorageClass `storageClass`. It has `helm.sh/resource-policy: keep`, so a failed
  redeploy or a stack delete does not remove it. On a node-local StorageClass the PVC is bound to
  the node where the pod first started. Set `requireCpuNode: "true"` and give the tenant a non-GPU
  node that is always on. OpenClaw and its data then stay up while the GPU is off. Decide this
  before the first install. To change it later, scale the Deployment to 0, delete the state PVC
  and let a re-sync create it again. For durability, add a backup (the state is less than 100 MB)
  or a network-disk CSI driver.

vLLM runs as root in its image. In the vLLM backend the `openclaw` namespace needs at least the
`baseline` Pod Security level. The gateway, the hooks and the canary run as non-root with a
read-only root filesystem and no capabilities.

## Requirements

- vCluster Platform 4.12 or later (native Stacks API, App tasks only, no Argo CD). Tested on
  4.13.0-alpha.21.
- vLLM backend: a node with NVIDIA GPUs. The device plugin must be installed, and `gpuCount`
  GPUs must be allocatable as `nvidia.com/gpu`. The vLLM pod tolerates the `nvidia.com/gpu`
  taint. Set `runtimeClassName` if the NVIDIA runtime is not the default runtime of the node. Disk
  for the model cache as described above (about 60 GB for the default model). Host RAM of
  `vllmMemoryRequest`. Egress to Hugging Face (weights) and Docker Hub (vLLM image).
- External backend: egress from the tenant cluster to `externalBaseUrl`. No GPU.
- Always: a StorageClass for the state volume (the tenant default, or `storageClass`). Egress to
  ghcr.io (OpenClaw image) and the npm registry (lossless-claw). For Telegram, egress to
  api.telegram.org. For `requireCpuNode: "true"`, a non-GPU node that is always on.
- `accessMode: ingress`: an ingress controller that the tenant can use, and a DNS name for it.
  The controller runs on the control plane cluster for shared-nodes tenants, and inside the tenant
  for private-nodes tenants.
- `accessMode: nodeport`: a node with a public IP, and a firewall rule for your CIDR.
- One install per destination. The namespace `openclaw`, the Service names and the NodePort are
  fixed. A second agent needs a second tenant cluster.

## Files

<details>
<summary>Every file in this directory</summary>

| Path | Purpose |
| --- | --- |
| [`stacktemplate.yaml`](stacktemplate.yaml) | The `openclaw` StackTemplate: parameters, five tasks, published outputs. |
| [`apps/01-vllm.yaml`](apps/01-vllm.yaml) | `openclaw-step-01-vllm`: vLLM Deployment, Service and model cache. |
| [`apps/01-vllm-skip.yaml`](apps/01-vllm-skip.yaml) | `openclaw-step-01-vllm-skip`: selected for `modelBackend: external`. Installs no model server. |
| [`apps/02-model-ready.yaml`](apps/02-model-ready.yaml) | `openclaw-step-02-model-ready`: hook Job that waits for the model and checks tool calling. |
| [`apps/03-persona.yaml`](apps/03-persona.yaml) | `openclaw-step-03-persona`: SOUL.md, IDENTITY.md and USER.md from the parameters. |
| [`apps/04-gateway.yaml`](apps/04-gateway.yaml) | `openclaw-step-04-gateway`: OpenClaw, lossless-claw, state volume, and the port-forward, Ingress or NodePort entry point. |
| [`apps/05-canary.yaml`](apps/05-canary.yaml) | `openclaw-step-05-canary`: pod that is Ready only when a completion and the gateway `/readyz` succeed. |
| [`virtualclustertemplate.yaml`](virtualclustertemplate.yaml) | `openclaw-agent` VirtualClusterTemplate: creates a tenant cluster and installs the stack through `deploy.stacks`. |
| [`example/stackinstance.yaml`](example/stackinstance.yaml) | Default install (vLLM, port-forward). |
| [`example/stackinstance-ingress.yaml`](example/stackinstance-ingress.yaml) | Dashboard behind an Ingress with TLS. |
| [`example/stackinstance-nodeport.yaml`](example/stackinstance-nodeport.yaml) | Dashboard on a NodePort for one permitted CIDR. |
| [`example/stackinstance-external.yaml`](example/stackinstance-external.yaml) | No GPU: OpenClaw with an external OpenAI-compatible endpoint. |
| [`example/stackinstance-private-nodes.yaml`](example/stackinstance-private-nodes.yaml) | The tested private-nodes shape: hostPath model cache, OpenClaw on the CPU node. |
| [`example/external-llama-cpp.yaml`](example/external-llama-cpp.yaml) | A CPU-only OpenAI-compatible endpoint (llama.cpp, Qwen3-1.7B) to test the external backend without a GPU. |
| [`test-manifests.sh`](test-manifests.sh) | Static checks: template, Apps, examples, Helm renders, no committed secrets. |
| [`tests/smoke.sh`](tests/smoke.sh) | End-to-end checks of a deployed stack through port-forwards. |
| [`tests/local-dashboard.sh`](tests/local-dashboard.sh), [`tests/local-dashboard.mjs`](tests/local-dashboard.mjs) | nodeport mode only: opens the dashboard locally without public exposure. |

</details>

## Configure parameters

No parameter is required. Each parameter has a default. You can change each parameter per
instance.

<details>
<summary>All parameters (one table)</summary>

| Parameter | Section | Type | Default | Description |
| --- | --- | --- | --- | --- |
| `modelBackend` | Model | `vllm`, `external` | `vllm` | Run the model on the tenant's GPUs, or use an existing OpenAI-compatible endpoint. |
| `model` | Model | string | `Qwen/Qwen3.8-27B` | Hugging Face model id to serve (vLLM). |
| `servedModelName` | Model | string | `qwen3.8-27b` | The model id that OpenClaw requests: the vLLM served name, or the model name of the external endpoint. |
| `maxModelLen` | Model | number | `262144` | Context length: vLLM `--max-model-len` and the OpenClaw `contextWindow`. |
| `maxTokens` | Model | number | `16384` | Maximum output tokens per turn. |
| `modelVision` | Model | boolean | `true` | Declare the model image-capable, so that photos sent in chat reach it. |
| `modelReasoning` | Model | boolean | `true` | Declare the model reasoning-capable (enables the `/think` levels). |
| `thinkingFormat` | Model | `qwen-chat-template`, `qwen`, `together`, `none` | `qwen-chat-template` | How OpenClaw switches thinking on and off for this endpoint. |
| `gpuMemoryUtilization` | Model | string | `0.90` | Fraction of VRAM for weights plus KV cache (vLLM). |
| `gpuCount` | Model | number 1..8 | `1` | GPUs for the vLLM pod. Above 1, vLLM runs tensor parallel. |
| `maxNumSeqs` | Model | number | `8` | vLLM `--max-num-seqs`. |
| `maxNumBatchedTokens` | Model | number | `8192` | vLLM `--max-num-batched-tokens`. |
| `vllmExtraArgs` | Model | multiline | Qwen3.8 parser, MTP and chat-template flags | One vLLM argument per line: the model profile. |
| `vllmEnv` | Model | multiline | `VLLM_USE_FLASHINFER_SAMPLER=0` | `KEY=VALUE` per line for the vLLM container (GPU-specific switches). |
| `hfToken` | Model | password | empty | Hugging Face token for gated models. |
| `externalBaseUrl` | Model | string | empty | OpenAI-compatible base URL that ends in `/v1` (external backend). |
| `externalApiKey` | Model | password | empty | Bearer token for the external endpoint. |
| `accessMode` | Access | `port-forward`, `nodeport`, `ingress` | `port-forward` | How you reach the dashboard. |
| `localPort` | Access | number | `28789` | Local port in the published port-forward command and the permitted origins. |
| `ingressClassName` | Access | string | empty | IngressClass. Empty uses the cluster default. |
| `ingressHost` | Access | string | empty | DNS name of the Ingress. Required in ingress mode. |
| `ingressTlsSecret` | Access | string | empty | TLS Secret for the Ingress. Empty serves plain HTTP. |
| `ingressAnnotations` | Access | multiline | empty | `key:value` per line, added to the Ingress. |
| `ingressScheme` | Access | `auto`, `http`, `https` | `auto` | Scheme of the published URL and the browser origins. `auto` follows `ingressTlsSecret`. |
| `allowedCidr` | Access | string | empty | The only permitted network in nodeport mode. |
| `operatorUser` | Access | string | `operator@openclaw.local` | Identity that the proxy sets for permitted requests in nodeport mode. |
| `nodePort` | Access | number 30000..32767 | `30789` | The NodePort in nodeport mode. |
| `telegramBotToken` | Channels | password | empty | Telegram bot token from @BotFather. |
| `telegramAllowFrom` | Channels | string | empty | Comma-separated Telegram user IDs that can DM without pairing. |
| `dmScope` | Channels | `per-channel-peer`, `main`, `per-peer`, `per-account-channel-peer` | `per-channel-peer` | How channel DMs map to sessions. |
| `agentName` | Persona | string | `Claw` | The name of the agent. |
| `agentEmoji` | Persona | string | 🦀 | The emoji of the agent. |
| `agentSoul` | Persona | multiline | a friendly generalist | SOUL.md, as written. |
| `userName` | Persona | string | `Operator` | How the agent addresses you. |
| `userProfile` | Persona | multiline | placeholder lines | One fact per line for USER.md. |
| `userTimezone` | Persona | string | empty | IANA timezone, for example `Europe/Berlin`. |
| `vllmCpuRequest` | Resources | string | `8` | CPU request of the vLLM pod. |
| `vllmMemoryRequest` | Resources | string | `32Gi` | Memory request of the vLLM pod. |
| `vllmShmSize` | Resources | string | `16Gi` | `/dev/shm` for the vLLM workers. |
| `modelCache` | Storage | `pvc`, `hostPath`, `emptyDir` | `pvc` | Where the model weights are stored. |
| `modelCacheSize` | Storage | string | `150Gi` | PVC request or emptyDir limit for the cache. |
| `modelCacheStorageClass` | Storage | string | empty | StorageClass of the cache PVC. Empty uses the tenant default. |
| `modelCachePath` | Storage | string | `/var/lib/openclaw/vllm-cache` | hostPath directory for the cache. |
| `storageClass` | Storage | string | empty | StorageClass of the state volume. Empty uses the tenant default. |
| `stateSize` | Storage | string | `20Gi` | Size of the state volume. |
| `requireCpuNode` | Scheduling | boolean | `false` | Schedule OpenClaw only on nodes without `nvidia.com/gpu.present=true`. |
| `runtimeClassName` | Scheduling | string | empty | RuntimeClass of the vLLM pod, for example `nvidia`. |
| `vllmImage` | Versions | string | `vllm/vllm-openai:v0.30.0` | vLLM image. |
| `openclawImage` | Versions | string | `ghcr.io/openclaw/openclaw:2026.9.6` | OpenClaw image. |
| `proxyImage` | Versions | string | `nginxinc/nginx-unprivileged:1.27-alpine` | Sidecar image for nodeport and ingress mode. |
| `losslessClawVersion` | Versions | string | `1.1.0` | npm version of `@martian-engineering/lossless-claw`. |

</details>

Each task passes each parameter that its App declares. A task that omits a parameter sends an
empty value, not the App default. When a stack has `password` parameters, the Platform UI hides
task error text. Read it from the child AppInstance in the project namespace:
`kubectl -n p-<project> get appinstance <name> -o jsonpath='{.status.message}'`.

### Tested model profiles

The defaults are a profile that was tested end to end. To run a different model, change the
values of the row. No other part of the stack knows the model.

| Profile | `model` | `servedModelName` | `maxModelLen` | `modelVision` | `thinkingFormat` | `vllmExtraArgs` | `vllmEnv` | GPU | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen3.8-27B BF16 (default) | `Qwen/Qwen3.8-27B` | `qwen3.8-27b` | `262144` | `true` | `qwen-chat-template` | `--tool-call-parser qwen3_xml`, `--reasoning-parser qwen3`, `--enable-prefix-caching`, `--mamba-cache-mode align`, `--speculative-config {"method":"mtp","num_speculative_tokens":2}`, `--default-chat-template-kwargs {"reasoning_effort":"medium"}` | `VLLM_USE_FLASHINFER_SAMPLER=0` | 1x 96 GB (RTX PRO 6000 Blackwell), `gpuMemoryUtilization` 0.90 | tested 2026-09-27 |
| Qwen3.8-27B FP8 | `Qwen/Qwen3.8-27B-FP8` | `qwen3.8-27b-fp8` | `262144` | `true` | `qwen-chat-template` | same as above | same as above | about 29 GiB of weights; about two times faster, more KV room | described, not tested |

Notes on the tested profile: weights 51.0 GiB plus 30.7 GiB of KV cache at 0.90 on a 96 GB card.
Above 0.95 that card runs out of memory. The vision encoder uses about 1 GB. For text only, set
`modelVision: "false"` and add a `--language-model-only` line to `vllmExtraArgs`. The line
`VLLM_USE_FLASHINFER_SAMPLER=0` avoids a FlashInfer sampler compile failure on sm_120 (RTX PRO
6000, RTX 50xx). It has no effect on other GPUs. Larger MoE models need 4-bit quantization or
have unstable kernels on sm_120. No chat model creates images. Image creation needs a tool, and
OpenClaw refuses to send a file that is not a valid image.

### Telegram setup

1. In Telegram, open `@BotFather`. Send `/newbot`, select a name and a username, and copy the
   token.
2. Optional: ask `@userinfobot` for your numeric user ID.
3. Install the stack with `telegramBotToken` set. Set `telegramAllowFrom` to skip the pairing
   step. No other step is necessary.

First DM: the agent answers a listed user ID immediately. Listed users can use slash commands
(command owner). Other users get a pairing code. Approve it with
`kubectl -n openclaw exec deploy/openclaw -c gateway -- sh -c 'TMPDIR=/tmp/oc openclaw pairing approve telegram <code>'`.
Do not paste a token into the agent chat. OpenClaw masks credentials before the agent sees them,
and the agent would save the mask. With an empty parameter you can add a channel manually: run
`openclaw channels add --channel telegram --token <token>` through `kubectl exec`, then restart
the pod. The channel survives restarts. A later change of the token or the allowlist rolls the
gateway pod one time. The Platform stores the token as a parameter in plain text at rest, like
`hfToken` and `externalApiKey`. The tenant stores it on the state volume.

## Install

All commands below go to the Platform **management API**, not to a cluster. Get a kubeconfig with
`vcluster platform connect management`. Or use a kubeconfig with the server
`https://<platform>/kubernetes/management` and a Platform access key.

```bash
# 1. Apps and template together: the template references the Apps by name.
kubectl apply -f community-stacks/openclaw/apps/ -f community-stacks/openclaw/stacktemplate.yaml
# Optional: the tenant cluster template that installs the stack through deploy.stacks.
kubectl apply -f community-stacks/openclaw/virtualclustertemplate.yaml

# 2. One instance per tenant cluster, in the project namespace that owns it.
kubectl apply -n p-default -f community-stacks/openclaw/example/stackinstance.yaml   # set destination.virtualCluster.name first

# 3. Watch. About 15-20 min on a new tenant with the default model: 8.7 GB vLLM image, 56 GB of
#    weights, model load. Some minutes with an external backend.
kubectl -n p-default get stackinstance openclaw \
  -o jsonpath='{.status.phase}{"\n"}{range .status.tasks[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

UI: **tenant cluster > Stacks > Install Stack > "OpenClaw agent (vLLM or external model,
lossless-claw)"**. Or create a tenant cluster from the **OpenClaw agent tenant** template under
**Tenant Clusters > New Tenant Cluster**. That template asks only for the persona, Telegram and
access values, and installs the stack into the new cluster. In that template the tenant cluster
shares the nodes of the control plane cluster. The GPU request goes to a GPU node of that cluster.
The template cannot create GPUs.

## Verify

Watch the StackInstance until each task is Healthy (command above). Then read the outputs on the
tenant cluster page > **Stacks** > stack card > **Outputs**, or with:

```bash
kubectl get --raw /apis/management.loft.sh/v1/namespaces/p-default/stackinstances/openclaw/outputs | jq
# With a kubeconfig whose server is https://<platform>/kubernetes/management, repeat that path:
kubectl get --raw /kubernetes/management/apis/management.loft.sh/v1/namespaces/p-default/stackinstances/openclaw/outputs | jq
```

| Output | Meaning |
| --- | --- |
| `dashboardCommand` | The `kubectl port-forward` command to run (port-forward mode; `n/a` in other modes). |
| `dashboardLink` | Dashboard URL. Contains the token only in port-forward mode. |
| `dashboardToken` | The gateway token, masked. A placeholder in nodeport mode. |
| `dashboardUrl` | The dashboard URL without the token. |
| `dashboardReachability` | `port-forward`, `ingress`, or in nodeport mode `public` or `internal`. |
| `dashboardNodePort` | The configured NodePort. Meaningful only in nodeport mode. |
| `telegramBot` | `@yourbot` when the Telegram token works, a reason when it does not, `not configured` without a token. |
| `modelId` | The model id after the endpoint answered. |
| `modelToolCalling` | `ok` if the model returned a tool call in the readiness check, `missing` if not. |
| `personaVersion` | Hash of the applied persona files. |

The Platform captures the outputs when a task becomes Healthy. It captures them again each time
the task becomes Healthy again. To force a new capture:
`kubectl -n p-default annotate stackinstance openclaw platform.vcluster.com/stack-retry=openclaw`.

In the tenant cluster:

```bash
kubectl -n openclaw get pods                       # vllm (vLLM backend), openclaw, stack-canary
kubectl -n openclaw get deploy stack-canary        # READY 1/1 = the agent can answer now
TENANT_KUBECONFIG=<tenant kubeconfig> MGMT_KUBECONFIG=<mgmt kubeconfig> ./community-stacks/openclaw/tests/smoke.sh
```

The smoke test checks the model endpoint (served model, tool call; skipped for an external
backend), the dashboard for the selected access mode, the persona files and marker, and the
canary. It prints the outputs. The local ports default to 18000 (vLLM) and 18080 (OpenClaw).
Change them with `VLLM_LOCAL_PORT` and `OC_LOCAL_PORT`. Set `PROJECT_NS` if your project is not
`default`.

## Upgrade

- **Parameters.** Change them on the StackInstance in the UI or with `kubectl edit`. Persona text
  reaches the running agent without a restart. Changes to the access mode, Telegram, model
  settings and images roll the gateway pod one time. The state volume does not change.
- **Versions.** `vllmImage`, `openclawImage`, `proxyImage` and `losslessClawVersion` are
  parameters. The defaults are pinned in the template and in the Apps with `# renovate:`
  comments. The repository's `renovate.json` knows this format, so one dependency update changes
  both.
- **Another model.** Change `model`, `servedModelName`, `maxModelLen`, `vllmExtraArgs`,
  `thinkingFormat` and `modelVision` together (see the profiles). vLLM downloads the new model
  into the cache.
- **Another backend.** A change of `modelBackend` re-syncs the tasks `vllm`, `modelready`,
  `openclaw` and `canary`. The `vllm` task can stay Pending when the old child AppInstance blocks
  it. Then delete that AppInstance in the project namespace, or set `prunePolicy: Prune`.
- **Template and App changes.** Apply the template and the Apps together:
  `kubectl apply -f community-stacks/openclaw/stacktemplate.yaml -f community-stacks/openclaw/apps/`. A change to an App that a running stack
  references re-syncs that task immediately, with the parameters that the instance has at that
  moment. A parameter that exists only in the new template arrives empty if you apply the App
  first. A re-sync does not interrupt a deploy that is still running.
- **`requireCpuNode`.** To change it on a node-local StorageClass: scale the Deployment to 0,
  delete the `openclaw-state` PVC and let a re-sync create it again. The chat history is lost.
- **Tenant clusters from a VirtualClusterTemplate.** A parameter change on an existing tenant
  cluster (for example the GPU node count) does not render the template again when the template
  has no versions. The instance shows `TemplateSynced: False, "Instance is out of date"`. Set
  `spec.templateRef.syncOnce: true` on the VirtualClusterInstance, or use the update action in
  the UI. The Platform then syncs the instance one time.

### Migration from the pre-standardization layout

For instances that were created before the Apps were renumbered (persona was step 04, the gateway
was step 03) and before the outputs were renamed:

1. Set `modelCache: hostPath` on the existing StackInstance. The new default is `pvc`. With `pvc`
   the stack creates a claim and downloads the weights again, and the hostPath data stays unused.
2. Run `kubectl apply -f community-stacks/openclaw/stacktemplate.yaml -f community-stacks/openclaw/apps/`. The tasks `persona` and `openclaw` re-sync
   to the renamed Apps. The rendered resources keep their names, so the Helm releases upgrade in
   place. Expect one roll of the gateway (new env var, new managed keys), the canary and vLLM
   (env list).
3. Wait for Healthy. Then delete the two old Apps:
   `kubectl delete app openclaw-step-03-openclaw openclaw-step-04-persona`. If you delete them
   first, both tasks stay Pending without a message.
4. The published outputs are camelCase (`dashboardLink`, not `dashboard-link`). Update tools that
   read them. No template parameter was renamed. New parameters default to the previous behavior.

## Remove

```bash
kubectl -n p-default delete stackinstance openclaw
```

The Stack deletes its child AppInstances. The AppInstances uninstall the Helm releases.
`prunePolicy: Prune` in the examples applies when a template update removes a task. It does not
apply when you delete the StackInstance. These resources remain by design:

- The `openclaw-state` PVC (chats, LCM database, workspace) and, in `pvc` mode, the `vllm-cache`
  PVC. Both have `helm.sh/resource-policy: keep`. Delete them manually to free the disk.
- The hostPath model cache directory on the GPU node (`modelCachePath`), in `hostPath` mode.
- Secret `openclaw-gateway-token`. The seed step creates it with `kubectl`, not Helm.
- The completed hook Jobs `model-ready-<release>` and `persona-<release>`, and the gate's
  `model-ready-<release>` Secret. Helm replaces hooks with the `before-hook-creation` policy on
  the next run. It does not delete them on uninstall.
- Resources that you created manually next to the stack, for example a TLS Secret for ingress
  mode.
- The `openclaw` namespace.

When no instance references them, remove the Apps and templates from the Platform:

```bash
kubectl delete apps,stacktemplates,virtualclustertemplates -l app.kubernetes.io/part-of=openclaw-stack
```

## Known limitations

- One install per destination. The namespace `openclaw`, the Service names and the NodePort are
  fixed. A `namespace` parameter is not possible with referenced Apps. A stack can read task
  outputs only from the fixed `defaultNamespace` of an App.
- vLLM and the gateway run with one replica each (one set of GPUs, one RWO state volume).
- The stack card is not live. The canary is. Set alerts on `stack-canary`.
- In nodeport mode the IP allowlist is the only access control. In ingress mode the access control
  is the token plus one device approval. Add an allowlist or an authentication proxy with
  `ingressAnnotations`.
- NVIDIA only. The resource name `nvidia.com/gpu`, the taint and the `nvidia.com/gpu.present`
  label are fixed. Other accelerators need a copy of the template.
- Channels: the install form configures only Telegram. Add other channels manually.
- A node-local StorageClass binds volumes to a node. See "Where the data lives".
- With `password` parameters in the template, the Platform UI hides task error text. The child
  AppInstance shows only the generic Helm line (`post-upgrade hooks failed`). The diagnosis of the
  gate is in the log of its hook Job in the tenant: `kubectl -n openclaw logs job/<model-ready-...>`.
- A slow external endpoint (a CPU-only model) can exceed the fixed provider timeout of 300 s on
  the first chat turn. The canary can report NotReady for one interval when its ping waits behind
  a long turn.
- The stack uses App tasks only, not Argo CD Application tasks. It needs only the `apps` feature
  of the Platform. It does not get continuous health evaluation from Argo CD. The canary exists
  for this reason.
- `thinkingFormat` is a closed list of options (`qwen-chat-template`, `qwen`, `together`, `none`),
  taken from the OpenClaw documentation of `compat.thinkingFormat`. When OpenClaw adds a format,
  the template must be updated before you can select it.
- Not tested end to end: an Internet client in nodeport mode (the tested tenants had no public
  node IP), nodeport on shared-nodes tenants, cert-manager and ACME certificates, and
  `ingressScheme: https` with a managed certificate.

## Troubleshooting

- **Task outputs are read from the namespace of the App.** A stack reads outputs only from
  namespaces that its Apps deploy into. For this reason each App here uses `openclaw`, and the
  gate is a small hook Job of its own, not a shared App.
- **`wait: false` on the vLLM task.** The vLLM Deployment needs 10 to 20 min to become Ready. The
  gate task waits for it, and prints the vLLM pod state and log tail on failure.
- **30 min per deploy.** The Platform limits one Helm operation to 30 min, so the gate deadline is
  28 min. A slower first download fails the task one time. The AppInstance retries and succeeds
  with the cached weights.
- **A task shows Failed for some minutes after a redeploy.** A deploy whose pod cannot be
  scheduled fails on its `wait` timeout. The task becomes Failed, and the AppInstance retries
  automatically after 1, 5 and 15 min. The task becomes Healthy when a retry succeeds. No action is
  necessary.
- **The gateway probes are `exec` probes.** In nodeport and ingress mode OpenClaw binds loopback,
  so the kubelet cannot probe it over the pod IP. The proxy probe is `tcpSocket`, because the
  allowlist would deny an HTTP probe from the node IP. `/healthz` and `/readyz` are open to
  in-cluster callers for the canary.
- **Unknown keys stop the gateway.** OpenClaw does not start on an unknown config key. The managed
  keys are in `apps/04-gateway.yaml` (`openclaw.managed`). The seed script deep-merges them into
  `openclaw.json` on each start and replaces `gateway.auth` as a whole. UI edits to other keys
  survive, and a mode change leaves no old auth keys.
- **The state PVC is mounted at `/home/node`, not at `/home/node/.openclaw`.** The root directory
  of a new volume is owned by root (`fsGroup` does not change the owner on local-path).
  `openclaw plugins install` changes the mode of the state directory, which fails with `EPERM` on
  a directory that it does not own. One level up, the seed container creates `.openclaw` as uid
  1000.
- **OpenClaw needs a private temp directory.** A Kubernetes `emptyDir` at `/tmp` is world-writable
  without the sticky bit. The secure-temp check of OpenClaw rejects it. The seed container creates
  `/tmp/oc` (mode 0700), and each OpenClaw container uses it as `TMPDIR`.
- **A Service named `vllm` breaks vLLM.** Kubernetes injects `VLLM_PORT=tcp://...` service-link
  env vars into pods in the namespace, and `VLLM_PORT` is a real vLLM setting. All pods set
  `enableServiceLinks: false`.
- **A failed deploy uninstalls the release before the retry, PVCs included.** Only PVCs with
  `helm.sh/resource-policy: keep` survive. The state and cache PVCs have it.
- **A node-local PVC binds its pod to a dead node.** After a Spot reclaim, a `local-path` PVC
  still points to the old node. The replacement pod stays Pending. The scheduler event says only
  "Insufficient nvidia.com/gpu". Use `modelCache: hostPath` on such tenants.
- **Device pairing is automatic for the proxied identity (nodeport mode).** OpenClaw normally asks
  for one approval per browser after authentication. The stack sets
  `gateway.auth.trustedProxy.deviceAutoApprove` with `operator.admin`. The OpenClaw audit reports
  this as CRITICAL. Here it is intended: the allowlist is the access control.
- **"Another Gateway owner lease is still active for this state directory."** OpenClaw keeps a
  gateway-owner lease in `state/openclaw.sqlite` (table `state_leases`, 5 min TTL). On SIGTERM it
  drains in-flight turns for up to about 5 min. The Deployment sets
  `terminationGracePeriodSeconds: 330`, so a normal restart releases the lease. After a killed
  pod, the next gateway restarts repeatedly until the TTL expires. Then it recovers automatically.
- **The persona hook and a rolling gateway.** Each template change runs the persona hook Job
  again (Helm post-upgrade), often while the gateway pod rolls. The hook ignores pods that
  terminate, waits for a Ready pod and retries the exec.
- **Names with outputs contain only letters and digits** (`modelready`, not `model-ready`).
- **`403 proxy_attribution_required` over a port-forward** in nodeport or ingress mode is
  expected. The gateway refuses a proxied client with a loopback address. Use the published URL,
  or `tests/local-dashboard.sh` in nodeport mode.
- **The IngressClass disappears inside the tenant.** A tenant whose template syncs IngressClasses
  from the host deletes each IngressClass that has no twin on the host. Run the ingress controller
  on the control plane cluster for such tenants.
- **An App change did not roll the pod.** A change to an App re-syncs the task (a new Helm
  revision). The pod rolls only when the rendered pod template is different. A new parameter
  whose default keeps the output identical is a no-op upgrade.
- **The canary stays NotReady with two or three pods.** The canary Deployment rolls when the model
  key changes. A replacement pod that cannot pass its check keeps the old pod until a working key
  arrives. The Deployment converges automatically.

## Test changes

From the repository root, run the static checks (bash 4 or later, python3 with PyYAML, helm, git):

```bash
./community-stacks/openclaw/test-manifests.sh
```

The checks assert the catalog conventions and the invariants of this stack:

- App names and step numbers agree with the files and the task graph.
- Each task passes exactly the parameters that its App declares.
- Defaults match their validation. Output namespaces equal the `defaultNamespace` of the Apps.
- Timeouts nest correctly.
- Each App renders with Helm in each branch, and `managed.json` is valid JSON.
- The examples apply without edits.
- No secret or site-specific value is tracked.

Server-side validation against a non-production Platform:

```bash
vcluster platform connect management
kubectl apply --server-side --dry-run=server --validate=strict \
  -f community-stacks/openclaw/apps/ -f community-stacks/openclaw/stacktemplate.yaml -f community-stacks/openclaw/virtualclustertemplate.yaml
kubectl apply --server-side --dry-run=server --validate=strict -n p-default \
  -f community-stacks/openclaw/example/stackinstance.yaml
```

CI runs the static checks and validates every Platform manifest in this directory with a
server-side dry run against vCluster Platform. After a deploy, run `tests/smoke.sh` (see Verify).

For general Stack authoring and catalog contribution requirements, see the
[repository README](../../README.md#build-a-custom-stack) and
[contribution checklist](../../README.md#contribute-a-stack).

## License

[Apache License 2.0](../../LICENSE).
