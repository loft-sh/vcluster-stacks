# Starter stack

Deploy two ConfigMaps into an existing cluster to learn Stack parameters,
dependencies, and output handoff. This example requires no external chart,
credentials, GPU, or application image.

## Requirements

- vCluster Platform 4.12 or later with the Apps feature available.
- An existing cluster in a Platform project, and a user or team with permission
  to create StackTemplates, create StackInstances in that project, and deploy Apps
  into the destination.
- `vcluster` and `kubectl`, with access to the Platform management API and the
  destination cluster. Python 3 with PyYAML for the static checks.

## Quick start

Run from this folder. Edit `example/stackinstance.yaml` first: replace
`p-default`, `admin`, and `development` with your project namespace, authorized
owner, and existing cluster name. The destination cluster must be in that project.
The example contains no secret values.

```bash
vcluster platform connect management
kubectl apply -f stacktemplate.yaml
kubectl apply -f example/stackinstance.yaml
kubectl get stackinstance starter-stack -n <project-namespace> \
  -o jsonpath='{.status.phase}{"\n"}{range .status.tasks[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

Repeat the last command until the Stack and both tasks report `Healthy`.
Then connect to the **destination cluster**, using its kubeconfig or
`vcluster connect <cluster-name> --driver platform --project <project-name>`,
and check the data:

```bash
kubectl get configmap starter-backend -n stack-starter -o jsonpath='{.data.greeting}{"\n"}'
kubectl get configmap starter-frontend -n stack-starter -o jsonpath='{.data.backendGreeting}{"\n"}'
```

Both values should be `Hello from my first Stack`.

## Architecture and files

| Task | Action | Dependency |
| --- | --- | --- |
| `backend` | Writes a greeting to a ConfigMap and captures its value | None |
| `frontend` | Writes the captured greeting to another ConfigMap | `backend` |

`stacktemplate.yaml` is the reusable template. `example/stackinstance.yaml`
applies it to one cluster. `test-manifests.sh` checks the dependency and output
contract. The repository's `examples/starter-stack.yaml` combines both resources;
repository validation checks they remain equivalent.

Both Apps use the `stack-starter` namespace. Install this example only once in a
destination: another instance would target the same ConfigMaps. It installs no
shared operators or external services. The StackInstance owner administers the
Apps, while the StackTemplate is shared across the Platform.

## Parameters and outputs

| Parameter | Type | Required | Default | Purpose |
| --- | --- | --- | --- | --- |
| `greeting` | string | No | `Hello from a Stack` | Text passed between tasks |

The example overrides `greeting`. The published `greeting` output is non-sensitive.
With `kubectl` connected to the **management API**, retrieve it using the
project namespace:

```bash
kubectl get --raw '/apis/management.loft.sh/v1/namespaces/<project-namespace>/stackinstances/starter-stack/outputs'
```

If your kubeconfig server includes a path prefix, such as `/kubernetes/management`,
include that prefix before `/apis/` in the raw request. Output retrieval requires
permission to read StackInstance outputs. Check the returned `greeting` value.

## Update and recover

Connect to the **management API**, change `spec.parameters.greeting` in the
example, and apply it again. Wait for the Stack to become healthy, then repeat
both destination checks with the new text. Changes to this shared StackTemplate
can also affect existing instances that reference it.

If a task stays blocked, inspect its status message. Check that the destination
exists in the same project, the owner has access, and the previous task's output
source matches its App namespace. Fix the input or permissions and observe
reconciliation; do not delete the destination to retry the example.

## Remove

With `kubectl` connected to the **management API**, delete the instance and wait
for its child Apps to be removed before deleting the template:

```bash
kubectl delete stackinstance starter-stack -n <project-namespace> --wait=true
kubectl delete -f stacktemplate.yaml
```

On the **destination**, verify the two ConfigMaps are gone. The namespace may
remain; delete it only if it contains no resources or data you need:

```bash
kubectl get configmaps -n stack-starter
kubectl delete namespace stack-starter
```

The example's `prunePolicy: Prune` applies to tasks removed during template
updates. StackInstance deletion starts child teardown independently of that field.

## Test changes

From this folder:

```bash
bash test-manifests.sh
```

From the repository root:

```bash
python3 hack/validate_stacks.py
```

These static checks do not deploy the example. The live smoke test is the quick
start, the parameter update, and removal above. Record your date, stack commit,
exact Platform/vCluster/Kubernetes versions, node model, results, and untested paths
when contributing a derivative. The new folder has not yet been tested on a live
cluster; do not interpret the minimum version as a live-test result.

## Build your own integration

Copy this folder to `community-stacks/<integration>/`. Rename `starter-stack`,
the `starter-*` ConfigMaps, and the destination namespace consistently, including
output sources, example references, and checks. Replace tasks with your workload,
add functional verification, and adapt the [README outline](../README-template.md)
and [contribution requirements](../../CONTRIBUTING.md).

Report example issues through the repository's GitHub issues. Licensed under
[Apache License 2.0](../../LICENSE).
