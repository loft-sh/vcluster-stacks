# Saturn Cloud Enterprise Certified Stack

This integration installs [Saturn Cloud Enterprise](https://saturncloud.io/docs/enterprise/kubernetes/) through a native vCluster Platform Stack. The Stack installs the `saturn-helm-operator`, which then installs the Saturn Cloud components. Once the components are running, Saturn Cloud is served at `https://app.<customerName>.saturnenterprise.io`.

The files in this directory are the source manifests for the `saturn-enterprise` StackTemplate and the `saturn-enterprise-tenant` VirtualClusterTemplate.

## Architecture

The `saturn-enterprise` StackTemplate has two App tasks:

- `helm` installs the `saturn-helm-operator` Helm chart, version `2026.06.01-1`, from `oci://ghcr.io/saturncloud/charts` into the `saturn-system` namespace of the destination the StackInstance selects: a tenant cluster or a control plane cluster. Helm waits up to 30 minutes for the release.
- `bash` runs after `helm` is healthy. It is a Job in the vCluster Platform image, which Platform provides as `__image__`, with a ClusterRole that can get, patch, and update nodes. It labels each node in `nodeNames` with `node.saturncloud.io/role=<nodeRole>` and, when `taintSystemNodes` is `true`, taints it with `node.saturncloud.io/role=<nodeRole>:NoSchedule`. The Job exits successfully when `nodeNames` and `nodeRole` are both empty, fails when only one of them is set, and waits up to 5 minutes for each node to exist.

The chart release contains:

- The operator Deployment in `saturn-system`.
- 14 CustomResourceDefinitions in the `charts.saturncloud.io` group.
- With `createNamespaces` set to `true`, the Namespaces `saturn`, `ingress`, `cert-manager`, `logging`, and `monitoring`.
- Nine component custom resources: `Atlas` in `saturn`; `Traefik`, `AuthServer`, and `SSHProxy` in `ingress`; `CertManager` and `HttpReqWebhook` in `cert-manager`; `Logging` in `logging`; `Monitoring` in `monitoring`; and `ClusterSetup` in `kube-system`.

The operator exchanges the bootstrap token for a long-lived token, stores it in cluster Secrets, and reconciles each custom resource into a Helm release. It reconciles every 2 minutes and gives each release up to 60 minutes.

The Stack reports `Healthy` as soon as the operator Deployment is ready and the `bash` Job completes. The Saturn Cloud components install afterwards and typically take 15 to 30 minutes.

The `helm` task sets the chart's `nodeScheduling.nodeSelector` only when `nodeNames` and `nodeRole` are both set, and `nodeScheduling.tolerations` only when `taintSystemNodes` is also `true`. Otherwise it sets both to `null`, which overrides the chart defaults that assume a `system` role.

The `saturn-enterprise-tenant` VirtualClusterTemplate creates a tenant cluster with the `loft.sh/stacks-sync: "true"` label and a `deploy.stacks` entry named `saturn` that references the `saturn-enterprise` StackTemplate. It derives `domain`, `baseUrl`, and `sshDomain` from `customerName`, so it asks for 11 values instead of 14.

## Requirements

- vCluster Platform 4.12 or later. The tenant cluster template also needs vCluster 0.37 or later for `deploy.stacks`.
- Kubernetes 1.28 or later in the destination.
- A Saturn Cloud Enterprise registration. The activation email contains the values for this Stack and a bootstrap token that is valid for 4 hours. Create the Stack within that window, or request a new token with `POST https://manager.saturnenterprise.io/v2/resend-setup`.
- Outbound HTTPS from the destination to `manager.saturnenterprise.io`, to `ghcr.io` for the chart, and to `public.ecr.aws` for the component images.
- A default StorageClass and support for `LoadBalancer` Services. The components include a PostgreSQL-backed API server, Traefik, and an SSH proxy.
- GPU nodes are not required to install. Add them afterwards.

Register with the organization name and email that Saturn Cloud should use. Use `k0rdent` as the cloud for an existing Kubernetes cluster:

```bash
curl -X POST https://manager.saturnenterprise.io/api/v2/customers/register \
  -H "Content-Type: application/json" \
  -d '{"name": "my-org", "email": "admin@example.com", "cloud": "k0rdent"}'
```

Saturn Cloud handles DNS and TLS for `<customerName>.saturnenterprise.io` through the bootstrap token. A custom domain or your own certificates require [support@saturncloud.io](mailto:support@saturncloud.io).

Install the Stack at most once per destination. The CRDs are cluster-scoped, and `ClusterSetup` targets `kube-system`.

## Files

| Path | Purpose |
| --- | --- |
| [`stacktemplate.yaml`](stacktemplate.yaml) | The `saturn-enterprise` StackTemplate with the `helm` and `bash` tasks. |
| [`virtualclustertemplate.yaml`](virtualclustertemplate.yaml) | The `saturn-enterprise-tenant` VirtualClusterTemplate. Creates a tenant cluster and installs the Stack into it. |
| [`apps/01-saturn-helm-operator.yaml`](apps/01-saturn-helm-operator.yaml) | The `saturn-step-01-helm-operator` App. Installs the `saturn-helm-operator` chart. |
| [`apps/02-node-scheduling.yaml`](apps/02-node-scheduling.yaml) | The `saturn-step-02-node-scheduling` App. Labels and optionally taints the system nodes. |

## Configure parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `clusterName` | string | | Required. Name of your cluster, for example `my-cluster`. |
| `cloudProvider` | string | | Required. Cloud provider of your cluster. Use `k0rdent` for an existing Kubernetes cluster. |
| `region` | string | | Required. Region of your cluster, for example `us-east-1`. |
| `availabilityZone` | string | | Availability zone of your cluster. Can match `region` when the cluster has no distinct zones. |
| `bootstrapToken` | password | | Bootstrap token from activation. Valid for 4 hours. |
| `domain` | string | | Domain from registration: `<customerName>.saturnenterprise.io`. |
| `adminEmail` | string | | Administrator email from registration, for example `admin@example.com`. |
| `customerName` | string | | Organization name from registration, for example `my-org`. |
| `baseUrl` | string | | Base URL from registration: `https://app.<customerName>.saturnenterprise.io`. |
| `sshDomain` | string | | SSH domain from registration: `ssh.<customerName>.saturnenterprise.io`. |
| `createNamespaces` | boolean | `true` | Create the `saturn`, `ingress`, `cert-manager`, `logging`, and `monitoring` namespaces. |
| `nodeNames` | multiline | | Comma-separated names of the nodes that run the Saturn Cloud system components. Leave empty to disable node scheduling. |
| `nodeRole` | string | | Value for the `node.saturncloud.io/role` label. Saturn Cloud's documentation uses `system`. |
| `taintSystemNodes` | boolean | `false` | Taint the system nodes with `NoSchedule` so only system pods land on them. |

Set `nodeNames` and `nodeRole` together, or leave both empty. The `bash` task fails when only one of them is set. Newline-separated node names also work.

The tenant cluster template exposes every parameter except `domain`, `baseUrl`, and `sshDomain`, which it derives from `customerName`. Its `nodeNames` parameter is a plain string.

## Install

Connect `kubectl` to the Platform management API, then apply the Apps, the StackTemplate, and the VirtualClusterTemplate in that order:

```bash
vcluster platform connect management
kubectl apply -f certified-stacks/saturn/apps/
kubectl apply -f certified-stacks/saturn/stacktemplate.yaml
kubectl apply -f certified-stacks/saturn/virtualclustertemplate.yaml
```

### Create a tenant cluster with Saturn Cloud

In the Platform UI, go to **Tenant Clusters**, click **New Tenant Cluster**, and select the **Saturn Cloud Enterprise tenant** template. Fill in the values from your activation email. Platform creates the tenant cluster and then a StackInstance in the project namespace. The StackInstance name combines the tenant cluster name and `saturn`, with a hash suffix when the result would exceed the Kubernetes name limit.

### Install into an existing cluster

Select the **Saturn Cloud Enterprise** template from **Stacks & Apps** in the Platform UI, or create a StackInstance in the project namespace that owns the destination. Set `destination` to your tenant cluster first. For a control plane cluster, use `destination.cluster.name` instead.

```yaml
apiVersion: management.loft.sh/v1
kind: StackInstance
metadata:
  name: saturn-enterprise
spec:
  displayName: Saturn Cloud Enterprise
  owner:
    user: admin
  destination:
    virtualCluster:
      name: my-tenant-cluster
  templateRef:
    name: saturn-enterprise
  parameters:
    clusterName: my-cluster
    cloudProvider: k0rdent
    region: us-east-1
    availabilityZone: us-east-1
    bootstrapToken: <token from activation>
    domain: my-org.saturnenterprise.io
    adminEmail: admin@example.com
    customerName: my-org
    baseUrl: https://app.my-org.saturnenterprise.io
    sshDomain: ssh.my-org.saturnenterprise.io
    createNamespaces: "true"
    nodeNames: ""
    nodeRole: ""
    taintSystemNodes: "false"
  prunePolicy: Prune
```

```bash
kubectl apply -n p-default -f stackinstance.yaml
```

Do not commit a StackInstance that contains a real bootstrap token.

The `helm` task waits up to 30 minutes for the operator release. The `bash` task waits up to 10 minutes for the node-scheduling Job.

## Verify

Watch the StackInstance until both tasks are healthy:

```bash
kubectl get stackinstance <name> -n p-default \
  -o jsonpath='{.status.phase}{"\n"}{range .status.tasks[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

Then, in the destination, check the operator and the component custom resources it manages:

```bash
kubectl get pods -n saturn-system
kubectl get atlas,authservers,certmanagers,clustersetups,httpreqwebhooks,loggings,monitorings,sshproxies,traefiks -A
```

The custom resources do not print a status column. Watch the component pods instead until they are running, which typically takes 15 to 30 minutes after the Stack is healthy:

```bash
kubectl get pods -n saturn
kubectl get pods -n ingress
```

When you use node scheduling, confirm the labels and taints:

```bash
kubectl get nodes -L node.saturncloud.io/role
```

Then open `https://app.<customerName>.saturnenterprise.io`.

## Upgrade

The chart version is pinned in [`apps/01-saturn-helm-operator.yaml`](apps/01-saturn-helm-operator.yaml) and is not a parameter. Change `version` there and apply the App again. The Stack reconciles and Helm upgrades the operator release. The CRDs ship in the chart's `crds/` directory, so Helm installs them once and does not upgrade them. Saturn Cloud's Kubernetes installation guide has no upgrade section. Check with Saturn Cloud before moving across releases.

## Remove

Delete the StackInstance. For a tenant cluster created from the template, remove the `deploy.stacks` entry or delete the tenant cluster, which deletes the StackInstances it manages.

```bash
kubectl delete stackinstance <name> -n p-default
```

The Stack deletes its Apps, which uninstalls the Helm release. Helm removes the operator, the component custom resources, and the Namespaces the chart created, together with everything in them.

Some resources remain after removal:

- The 14 `charts.saturncloud.io` CustomResourceDefinitions. Helm installs them from the chart's `crds/` directory and does not delete them.
- Cluster-scoped resources that the operator's component releases created, such as cert-manager CRDs and ClusterRoles. Deleting a Namespace does not remove them.
- The `node.saturncloud.io/role` labels and taints the `bash` task applied.
- PersistentVolumes with a `Retain` reclaim policy.
- The organization registration at `manager.saturnenterprise.io`.

Remove the node labels and taints manually when you do not plan to reinstall:

```bash
kubectl label node <node> node.saturncloud.io/role-
kubectl taint node <node> node.saturncloud.io/role-
```

Saturn Cloud's documentation does not cover uninstalling. Confirm the clean-up steps with [support@saturncloud.io](mailto:support@saturncloud.io) before you remove a production installation.

## Known limitations

- The Stack exposes only the parameters listed above. It does not expose the chart version or other Helm values. To customize the chart further, copy the StackTemplate as described in the [repository README](../../README.md#use-a-certified-stack).
- Node scheduling targets the nodes the destination can see. The tenant cluster template does not enable `sync.fromHost.nodes`, so a tenant cluster created from it sees a node only after one of its pods lands there, and the labels it applies stay inside the tenant cluster. The `bash` task can then time out waiting for a node, or label a node that the control plane cluster scheduler never sees. Leave `nodeNames` empty for tenant clusters created from the template. To label nodes from a tenant cluster, copy the template and set `sync.fromHost.nodes` to `enabled: true`, `selector.all: true`, and `syncBackChanges: true`. With `syncBackChanges`, `taintSystemNodes` taints control plane cluster nodes that other tenants may share.
- Stack health reflects the operator, not Saturn Cloud. The components install after the Stack is healthy.
- One installation per destination.
- A custom domain or your own TLS certificates require Saturn Cloud support.

## Test changes

This directory has no static checks yet. Validate the manifests with a server-side dry run against a non-production vCluster Platform:

```bash
vcluster platform connect management
kubectl apply --server-side --dry-run=server --validate=strict \
  -f certified-stacks/saturn/apps/ \
  -f certified-stacks/saturn/stacktemplate.yaml \
  -f certified-stacks/saturn/virtualclustertemplate.yaml
```

For general Stack authoring and catalog contribution requirements, see the [repository README](../../README.md#build-a-custom-stack) and [contribution checklist](../../README.md#contribute-a-stack).
