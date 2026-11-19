# Radar Community Stack

<img src="https://radarhq.io/radar/icon.svg" alt="Radar logo" width="72" align="right" />

This Stack installs [Radar](https://github.com/skyhook-io/radar), an open source (Apache 2.0)
Kubernetes UI for humans and AI agents, in a tenant cluster or a control plane cluster.

kubectl answers one question at a time. Radar shows the whole cluster: how resources connect,
what is failing and why, what changed and when, and the traffic between services. AI agents such
as Claude Code, Codex and Cursor get the same view through Radar's built-in MCP server.

The Stack has one task, which installs the public Radar Helm chart with its default settings. A
tenant cluster template is included that installs Radar in every tenant cluster created from it.
Nothing leaves the cluster unless you paste in Radar Cloud settings.

> [!IMPORTANT]
> This Stack is not marked `vcluster.com/certified`, and vCluster Platform does not bundle it.

![Radar's topology view](https://github.com/skyhook-io/radar/raw/main/docs/screenshots/topology-view.png)

## Contents

- [What you get](#what-you-get)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Files](#files)
- [Configure parameters](#configure-parameters)
- [Install](#install)
- [Verify](#verify)
- [Connect to Radar Cloud](#connect-to-radar-cloud)
- [Security and access](#security-and-access)
- [Upgrade](#upgrade)
- [Remove](#remove)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Test changes](#test-changes)
- [Support](#support)

## What you get

On each cluster, free and open source:

- **Find and fix failures:** failing workloads folded to their cause, with the resources each one
  affects, then the logs, events, YAML and related resources one click away.
- **For AI agents:** a built-in MCP server gives Claude Code, Codex, Cursor and other agents
  Radar's view of the cluster instead of raw kubectl output.
- **Live topology:** how workloads, Services and Ingresses connect, updated as the cluster
  changes.
- **Events and change history:** Kubernetes events and resource changes, with a diff of each
  change.
- **GitOps:** Flux and Argo CD sync state and drift.
- **Network traffic:** which services talk to each other, read from Cilium Hubble where the
  cluster runs it.
- **Metrics, cost, backups and certificates:** read from Prometheus, OpenCost, Velero and
  cert-manager where the cluster runs them.
- **[Checks](https://radarhq.io/docs/features/cluster-audit):** best-practice checks for
  security, reliability and efficiency, and an
  [upgrade impact](https://radarhq.io/docs/features/upgrade-impact) report before you move to a
  new Kubernetes version.

Two views are off in this install, because they need permissions the chart does not grant by
default. To turn one on, add its value to the `radarValues` parameter:

| View | Chart value | What it grants Radar |
| --- | --- | --- |
| Helm releases: values, history and diffs between revisions | `rbac.secrets: true` | Read access to every Secret in the cluster, where Helm stores its releases. Radar then also lists Secrets in its resource browser. |
| [Who can do what](https://radarhq.io/docs/features/access-control) through RBAC | `rbac.viewRBAC: true` | Read access to Roles, ClusterRoles and their bindings. |

## Architecture

| Task | Type | Template | Timeout | Function |
| --- | --- | --- | --- | --- |
| `radar` | `app` | `radar-stack-radar` | `12m0s` | Installs the `radar` Helm chart, version `1.20.3`, from `oci://ghcr.io/skyhook-io/charts` into the `radar` namespace. |

The chart creates one Deployment, one Service named `radar` on port `9280`, a ServiceAccount, and
the ClusterRoles and ClusterRoleBindings Radar reads the cluster with.

The Stack reports `Healthy` when the Radar pod is ready. With Radar Cloud settings, `Healthy`
does not mean the cluster reached Radar Cloud. See
[Connect to Radar Cloud](#connect-to-radar-cloud).

## Requirements

- vCluster Platform 4.12 or later. The tenant cluster template also needs vCluster 0.37 or later
  for `deploy.stacks`.
- The destination can pull `ghcr.io/skyhook-io/radar` and reach `ghcr.io` for the chart.
- With Radar Cloud settings: outbound HTTPS from the destination to the Radar Cloud address.

## Files

| File | What it is |
| --- | --- |
| `apps/01-radar.yaml` | The App that installs the chart. |
| `stacktemplate.yaml` | The `radar` StackTemplate. |
| `virtualclustertemplate.yaml` | The `radar-tenant` tenant cluster template. |
| `example/stackinstance.yaml` | Installs Radar in an existing tenant cluster. |
| `example/stackinstance-control-plane-cluster.yaml` | Installs Radar in a control plane cluster. |
| `example/tenant-cluster-with-radar.yaml` | A tenant cluster created from `radar-tenant`. |
| `test-manifests.sh` | Static checks. |

## Configure parameters

Both parameters are optional. Radar needs no input.

StackTemplate `radar`:

| Parameter | Label in the UI | Default | Description |
| --- | --- | --- | --- |
| `radarValues` | Radar settings | empty | Radar Helm chart values, as YAML. They are merged over the chart defaults. Empty means Radar runs with the defaults, only inside the cluster. |
| `clusterName` | Cluster name in Radar Cloud | empty | Used only when `radarValues` connects Radar to Radar Cloud and does not set `cloud.clusterName` itself. Empty lets Radar pick a name. |

Tenant cluster template `radar-tenant`:

| Parameter | Label in the UI | Default | Description |
| --- | --- | --- | --- |
| `radarValues` | Radar settings | empty | The same settings, for every tenant cluster created from the template. Each one gets its tenant cluster's name as `clusterName`. |

`radarValues` takes any value from the
[Radar Helm chart](https://github.com/skyhook-io/radar/blob/v1.20.3/deploy/helm/radar/values.yaml),
except `fullnameOverride`. The Stack sets that to `radar`, so the Service is always
`radar/radar`.

The chart version is not a parameter. The Platform does not template an App's chart version, so
it is fixed in `apps/01-radar.yaml`.

## Install

Connect `kubectl` to the Platform management API, then apply the App and the StackTemplate:

```bash
vcluster platform connect management
kubectl apply -f apps/
kubectl apply -f stacktemplate.yaml
```

Then choose one:

```bash
# Radar in one existing tenant cluster. Set the project namespace and the cluster name first.
kubectl apply -n p-default -f example/stackinstance.yaml

# Radar in every tenant cluster created from a template.
kubectl apply -f virtualclustertemplate.yaml
kubectl apply -n p-default -f example/tenant-cluster-with-radar.yaml
```

You can also install it from the Platform UI: open a tenant cluster, then **Stacks**, then
**Install Stack**, and pick **Radar**.

## Verify

```bash
kubectl get stackinstance radar -n p-default \
  -o jsonpath='{.status.phase}{"\n"}{range .status.tasks[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

Open Radar from the destination cluster:

```bash
kubectl -n radar port-forward svc/radar 9280:9280
# then open http://localhost:9280
```

## Connect to Radar Cloud

This step is optional. Radar Cloud shows every connected cluster in one place, with alerts, AI
investigations and history across all of them. It has a free plan that needs no credit card. See
[Radar Cloud pricing](https://radarhq.io/pricing).

**[Connect your tenant clusters to Radar Cloud](https://app.radarhq.io/partners/vcluster?utm_source=vcluster&utm_medium=marketplace&utm_campaign=vcluster-stacks)**

The connect page creates an enrollment key and gives you a block of settings with the key filled
in. Paste the block into **Radar settings** when you install the Stack, or into `radarValues` on
a StackInstance:

```yaml
spec:
  parameters:
    clusterName: my-tenant-cluster
    radarValues: |
      cloud:
        enabled: true
        hubURL: "https://api.radarhq.io"
        enrollment:
          key: "<enrollment key>"
      rbac:
        helm: true
        secrets: true
        podExec: true
        portForward: true
        metrics: true
```

To connect every new tenant cluster, paste the same block into **Radar settings** of the
`radar-tenant` tenant cluster template.

A connected cluster opens an outbound connection to Radar Cloud, and you open it from Radar Cloud
instead of a port-forward. Check that it joined:

```bash
kubectl -n radar logs deploy/radar | grep '\[cloud\]'
```

No outbound access, or an air-gapped site? Run
[Radar Cloud on your own infrastructure](https://radarhq.io/docs/cloud/self-hosted). Its connect
page gives you the same block with its own address.

## Security and access

- **No login by default.** The Stack does not expose Radar outside the cluster. Whoever can
  port-forward to the `radar` Service can open it. To put a login in front of it, see
  [Radar authentication](https://radarhq.io/docs/configuration/authentication).
- **Read-only by default.** With no settings, Radar reads one Secret, Hubble's client
  certificate `hubble-relay-client-certs`, and no other. It does not open a shell in a pod or
  change Helm releases.
- **Radar Cloud settings widen what Radar can do.** Connecting to Radar Cloud gives Radar read
  access to every Secret in the cluster, whichever `rbac` lines the block has. The `rbac` lines
  add opening a shell in a pod, port-forwarding and changing Helm releases, each done as the
  person signed in to Radar Cloud and checked against that person's own permissions. The block
  binds Radar Cloud's owner, member and viewer roles to the Kubernetes `admin`, `edit` and
  `view` ClusterRoles. Remove `podExec`, `portForward` or `helm` to leave that feature off.
- **Your enrollment key is readable in the project.** See
  [Known limitations](#known-limitations).

## Upgrade

Change `version` in `apps/01-radar.yaml` and apply the file. StackTemplates and Apps have no
revisions: every StackInstance that references them picks the change up on its next
reconciliation. A version that does not exist marks every install `Degraded` until you fix the
file. Running Radar pods are not touched while it is broken.

## Remove

```bash
kubectl delete stackinstance radar -n p-default
```

This removes the Helm release and everything the chart created, including the ClusterRoles and
ClusterRoleBindings. The empty `radar` namespace stays. Delete it yourself if you want it gone.
A cluster that joined Radar Cloud stays listed there as disconnected. Remove it on the Clusters
page in Radar Cloud.

## Known limitations

- The enrollment key sits in `radarValues`, and the Platform stores it in the StackInstance, in
  the AppInstance and in the Helm release values. Anyone who can read StackInstances in the
  project can read it. A tenant cluster created from the template also keeps it in its
  VirtualClusterInstance.
- Settings that are not valid YAML are accepted when you apply the StackInstance. The task then
  fails with "Radar settings are not valid YAML". An already running Radar keeps running.
- Events and change history are kept in memory, up to 10,000 events, and are lost when the Radar
  pod restarts.
- One StackInstance installs Radar in one cluster. Use the tenant cluster template to cover
  every new tenant cluster.

## Troubleshooting

**A task failed.** The task message on the StackInstance carries the error. See [Verify](#verify).
The AppInstance in the project namespace has it too:

```bash
kubectl get appinstances -n p-default \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.message}{"\n"}{end}'
```

**Radar is `Healthy` but the cluster is not in Radar Cloud.** The Radar log says why it was
refused. See [Connect to Radar Cloud](#connect-to-radar-cloud).

## Test changes

```bash
./test-manifests.sh
```

Tested on vCluster Platform 4.12.6 with vCluster 0.37.7.

## Support

Radar is open source: ask questions and report issues on
[GitHub](https://github.com/skyhook-io/radar/issues).

- [Radar documentation](https://radarhq.io/docs)
- [Radar on GitHub](https://github.com/skyhook-io/radar)
- [Radar community](https://radarhq.io/community)
