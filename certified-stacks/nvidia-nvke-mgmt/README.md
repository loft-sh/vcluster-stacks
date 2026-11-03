# NVIDIA NVKE Management Plane Certified Stack

This integration installs the management plane of [NVIDIA NVKE](https://github.com/dsx-ai-factory/nvke) into a tenant cluster from a release that you build with [NVKR](https://github.com/dsx-ai-factory/nvkr), NVIDIA's reproducible release tool. The Stack verifies the release first: cosign signatures and SLSA provenance on the release root and on every output. Nothing installs until that check passes, and every chart version and image digest comes from the verified release, not from a parameter.

The files in this directory are the source manifests for the `nvidia-nvke-mgmt` StackTemplate, its two Apps, and the `nvidia-nvke-mgmt-shared-nodes` and `nvidia-nvke-mgmt-private-nodes` VirtualClusterTemplates.

## Architecture

The `nvidia-nvke-mgmt` StackTemplate has nine tasks. Every task depends on `verify`, so a failed verification leaves the other eight `Waiting` and installs nothing.

| Task | What it installs | Depends on |
| --- | --- | --- |
| `verify` | A Job in the vCluster Platform image (`__image__`) in `nvke-verify`. It downloads a pinned cosign, reads the release root, verifies the root and each of the eight outputs, resolves each chart's version from the registry, and records the result in the `nvke-release-verification` ConfigMap. The Stack captures that ConfigMap as task outputs. | |
| `certmanager` | cert-manager, chart version `certManagerVersion` from `charts.jetstack.io`, with CRDs, in `cert-manager`. | `verify` |
| `baseconfig` | NVKE's base configuration: the namespaces, the shared `nvke-database` Secret in `postgres` and `temporal`, the `nvke-registry` pull Secret in `nke-controller`, the OIDC upstream CA chain cert-manager issues in `spire-server`, and the `nktp-cluster` ConfigMap. | `certmanager` |
| `nktp` | NVKE's telemetry pipeline (OpenTelemetry operator, collectors, monitoring CRDs) in `nktp`. | `verify`, `baseconfig` |
| `postgres` | PostgreSQL in `postgres`, 40Gi persistent volume. | `verify`, `baseconfig` |
| `spirecrds` | The SPIRE CRDs in `spire-server`. | `verify`, `baseconfig` |
| `temporal` | Temporal in `temporal`, using PostgreSQL. | `verify`, `postgres`, `nktp` |
| `spire` | SPIRE server, agents, and on private nodes the SPIFFE CSI driver and the OIDC discovery provider, in `spire-server` and `spire-system`. | `verify`, `spirecrds`, `nktp`, `baseconfig` |
| `controller` | The NVKE controller in `nke-controller`, with its image and the profiles image pinned to the digests the release carries. | `verify`, `temporal`, `spire`, `nktp` |

The install order and the Helm values are NVKE's own (`deploy/nico` at v0.22.0), reduced to what a cluster without NICo, Cluster API, or TPM hardware needs. The chart tasks install `oci://<registryPrefix>/<output>` at the version `verify` resolved, so a newer NVKE release needs no change to the Stack unless NVKE's own values change.

The `verify` task works like this:

1. Waits until the registry answers, then downloads cosign at a pinned version and checks its SHA-256.
2. Reads the release root (an OCI index) down to NVKR's publication-root config and lists the outputs it names. All eight must be present: `controller-chart`, `cwe`, `nktp`, `postgresql`, `profiles`, `spire`, `spire-crds`, `temporal`.
3. With `verifyMode: root`, runs `cosign verify-attestation` for the `https://sigstore.dev/cosign/sign/v1` and `slsaprovenance1` attestation types against the release root and each output, using `signerIdentity` and `oidcIssuer`. With `verifyMode: off`, skips the signatures and only checks that the root, the outputs, and the tags are consistent.
4. For each chart output, reads the registry's tag list and takes the version from the `<version>-<digest>` tag NVKR pushes beside `<version>`, then checks that this tag resolves to the digest the root names.
5. Records the root, the mode, the signer, the time, the chart versions, and the image digests in the ConfigMap.

The Stack publishes `verifiedReleaseRoot`, `verifiedAt`, `verificationMode`, `controllerChartVersion`, and `controllerImageDigest` as outputs, so another Stack or a report can read what was installed.

`sharedNodes` selects between NVKE's two shapes. On private nodes (`"false"`, the default) the Stack installs NVKE's full configuration: the SPIFFE CSI driver, the OIDC discovery provider, and the controller with a SPIFFE identity. On the control plane cluster's shared nodes (`"true"`) vCluster rewrites the hostPath mounts the CSI driver needs, so the Stack leaves out the CSI driver, the SPIRE agent (workloads reach it only through the CSI driver, and its host port would collide with another tenant's agent on the same node) and the OIDC discovery provider, and runs the controller without SPIFFE. nktp's node collector, which reads `/var/log`, `/proc`, and the journal from the node, is kept off shared nodes with a node selector; label a node `nvke.vcluster.com/node-collector=true` to run it there.

The two VirtualClusterTemplates create a tenant cluster and install the Stack through `deploy.stacks`, so one form creates the cluster and the management plane together. The private-node template enables private nodes with VPN and vCluster's local-path provisioner, and optionally creates an auto-node pool from a Platform node provider.

## Requirements

- vCluster Platform 4.12 or later. The tenant cluster templates also need vCluster 0.37 or later for `deploy.stacks`.
- A tenant cluster with `linux/amd64` nodes and a default StorageClass or one named in `storageClass`. The management plane requests about 1 CPU and 2.5 GiB of memory in total, most of it for the nktp collectors; PostgreSQL needs a 40Gi volume and SPIRE a 1Gi volume. On shared nodes, set `sharedNodes` to `"true"`.
- Outbound HTTPS from the tenant cluster to your release registry, to `github.com` for the cosign download, to the public Sigstore services (`rekor.sigstore.dev`, `tuf-repo-cdn.sigstore.dev`) when `verifyMode` is `root`, to `charts.jetstack.io` and `quay.io` for cert-manager, and to the registries the NVKE charts pull their images from (Docker Hub, `ghcr.io`).
- An NVKR release of NVKE, described in the next section.
- Install the Stack at most once per tenant cluster. The SPIRE CRDs, the nktp monitoring CRDs, and the controller's CRDs are cluster-scoped.

### What the Stack expects from your NVKR release

NVKR is a build tool. It takes a Definition (what to build), an Environment (where to publish and how to sign), and produces a release: every output as an OCI artifact, an SBOM and SLSA provenance per output, and one release root that names them all by digest. You run it; NVIDIA does not publish a release for you. The Stack needs:

| What | Where it comes from | Stack parameter |
| --- | --- | --- |
| A Definition with these eight outputs: `controller-chart`, `cwe`, `nktp`, `postgresql`, `profiles`, `spire`, `spire-crds`, `temporal`, built for `linux/amd64`. | [`nvkr/definition.yaml`](nvkr/definition.yaml) is that Definition. It is NVIDIA's `nvke-deploy` example without the CLI outputs, plus `nktp`. Both catalogs it references are pinned to NVKE v0.22.0 in nvkr. | |
| The release root the run published, as `<registry>/<repository>@sha256:<digest>`. | `nvkr run` prints it; the generated GitHub pipeline writes it in the "Publish release" step and in `.nvkr/runs/<attempt>/publications/release.txt`. | `releaseRoot` |
| The publication prefix. Every output is published at `<prefix>/<output>`. | `publication.repositoryPrefix` in your Environment. | `registryPrefix` |
| Keyless cosign signatures and SLSA provenance on the root and every output, with per-output publication (`publication.mode: per-output-v1`). | `signing.mode: cosign` in your Environment, run on a hosted engine with an OIDC identity. [`nvkr/environment-github.example.yaml`](nvkr/environment-github.example.yaml) is an Environment for GitHub Actions and GHCR. A local `nvkr run local` signs in dry-run mode; install such a release with `verifyMode: off`. | `signerIdentity`, `oidcIssuer`, `verifyMode` |
| Read access to the registry. | A token with read access to the packages, or nothing for a public registry. | `registryUsername`, `registryPassword` |

The chart outputs must carry NVKR's `<version>` and `<version>-<digest>` tags, which `nvkr run` pushes for every `helm-oci` output. A release with different output names, or without those tags, fails verification with a message that names the missing output or tag.

## Files

| Path | Purpose |
| --- | --- |
| [`stacktemplate.yaml`](stacktemplate.yaml) | The `nvidia-nvke-mgmt` StackTemplate with the nine tasks. The seven chart tasks are inline, because chart fields use parameters and the outputs of `verify`. |
| [`apps/01-verify.yaml`](apps/01-verify.yaml) | The `nvidia-nvke-mgmt-verify` App: the verification Job, its ConfigMap, and the RBAC limited to that ConfigMap. |
| [`apps/02-base-config.yaml`](apps/02-base-config.yaml) | The `nvidia-nvke-mgmt-base-config` App: NVKE's base configuration manifests. |
| [`virtualclustertemplate-shared-nodes.yaml`](virtualclustertemplate-shared-nodes.yaml) | The `nvidia-nvke-mgmt-shared-nodes` VirtualClusterTemplate. Shared nodes, `sharedNodes: "true"`. |
| [`virtualclustertemplate-private-nodes.yaml`](virtualclustertemplate-private-nodes.yaml) | The `nvidia-nvke-mgmt-private-nodes` VirtualClusterTemplate. Private nodes with VPN, optional auto-node pool, local-path storage, NVKE's full SPIRE configuration. |
| [`example/stackinstance-tenant-cluster.yaml`](example/stackinstance-tenant-cluster.yaml) | A StackInstance for an existing tenant cluster, with placeholders. |
| [`nvkr/definition.yaml`](nvkr/definition.yaml) | The NVKR Definition that produces the eight outputs. |
| [`nvkr/environment-github.example.yaml`](nvkr/environment-github.example.yaml) | An NVKR Environment for a signed release from GitHub Actions to GHCR, with placeholders. |
| [`test-certified-manifests.sh`](test-certified-manifests.sh) | Static checks and chart renders that CI runs on every change in this directory. |

## Configure parameters

| Parameter | Required | Default | Purpose |
| --- | --- | --- | --- |
| `releaseRoot` | yes | | The release root NVKR published, `<registry>/<repository>@sha256:<digest>`. |
| `registryPrefix` | yes | | The publication prefix. Charts install from `oci://<prefix>/<output>`. |
| `signerIdentity` | with `verifyMode: root` | | Regular expression for the certificate identity that signed the release, for example `^https://github\.com/<org>/<repo>/\.github/workflows/nvkr-run\.yml@refs/heads/main$`. |
| `oidcIssuer` | yes | `https://token.actions.githubusercontent.com` | The OIDC issuer of that identity. |
| `verifyMode` | yes | `root` | `root` verifies signatures and provenance. `off` skips them and only checks the release's consistency; use it for dry-run-signed local releases. |
| `registryUsername` | no | | Username for a private registry. Empty means anonymous. |
| `registryPassword` | no | | Token for that username, with read access to the packages. Also used in the `nvke-registry` pull Secret for the controller images. |
| `dbPassword` | yes | | One password shared by PostgreSQL, Temporal, and the controller. |
| `sharedNodes` | yes | `"false"` | `"true"` on the control plane cluster's shared nodes. See Architecture. |
| `storageClass` | no | | StorageClass for PostgreSQL and SPIRE. Empty uses the cluster default. |
| `clusterName` | yes | `nvke` | The `k8s.cluster.name` nktp attaches to telemetry. |
| `certManagerVersion` | yes | `v1.21.3` | cert-manager chart version. |

The VirtualClusterTemplates expose the same parameters without `sharedNodes`, `storageClass`, and `certManagerVersion`, which they set. The private-node template adds `nodeProvider`, `nodeType`, and `nodeCount` for an optional auto-node pool.

## Install

Apply the Apps and the StackTemplate to the Platform, then the VirtualClusterTemplates if you want one-form clusters:

```bash
kubectl apply -f apps/ -f stacktemplate.yaml
kubectl apply -f virtualclustertemplate-shared-nodes.yaml -f virtualclustertemplate-private-nodes.yaml
```

To create a tenant cluster with the management plane, create a cluster from one of the templates in the Platform UI and fill in the release and the credentials. For a private-node cluster without a node provider, join your machines through the cluster's **Nodes** tab after the cluster is created; the Stack waits for a node before anything schedules.

To install into an existing tenant cluster, copy [`example/stackinstance-tenant-cluster.yaml`](example/stackinstance-tenant-cluster.yaml), replace the placeholders, and apply it in the project namespace that owns the cluster:

```bash
kubectl apply -n p-default -f example/stackinstance-tenant-cluster.yaml
```

The Stack takes 15 to 25 minutes on a fresh cluster. `verify` typically finishes within 2 minutes; SPIRE and Temporal take the longest.

## Verify

On the Platform, the StackInstance reports `Healthy` with all nine tasks healthy:

```bash
kubectl get stackinstances -n p-default
kubectl get stackinstance -n p-default <name> -o jsonpath='{range .status.tasks[*]}{.name}{"\t"}{.phase}{"\n"}{end}'
```

The published outputs show which release was installed:

```bash
kubectl get --raw /apis/management.loft.sh/v1/namespaces/p-default/stackinstances/<name>/outputs
```

In the tenant cluster, the controller is ready and the `nvke-release-verification` ConfigMap records the verification:

```bash
kubectl get pods -n nke-controller
kubectl get configmap -n nvke-verify nvke-release-verification -o yaml
```

If `verify` fails, the Job's log names the cause: an unreachable registry, a signature that does not match `signerIdentity`, a missing output, or a chart tag that does not match the digest in the root. The other tasks stay `Waiting` and the StackInstance reports `Degraded`.

## Upgrade

To move to a newer NVKE release, run NVKR again and set `releaseRoot` to the new root on the StackInstance. `verify` runs again, and each chart task upgrades to the version the new root names. A cluster created from one of the VirtualClusterTemplates renders its StackInstance from the parameters given at creation; change the StackInstance the Platform created for it, or recreate the cluster.

cert-manager is the one component the release does not carry; change `certManagerVersion` to upgrade it.

## Remove

Delete the StackInstance. With `prunePolicy: Prune`, the Platform uninstalls the seven Helm releases, the verification Job, and the base configuration, including the NVKE namespaces it created and the PersistentVolumeClaims in them. Deleting a cluster created from one of the VirtualClusterTemplates removes everything with it.

What stays in the tenant cluster after removal:

- The 20 CRDs the charts installed (cert-manager, OpenTelemetry, Prometheus monitoring, SPIRE, and the controller's `internal.nvke.nvidia.com` group), because Helm does not delete CRDs. Remove them by hand if you reinstall with a different release of the CRDs.
- The empty namespaces `cert-manager`, `nvke-base`, and `nvke-verify`, which the Platform creates for the Apps and does not delete.

## Known limitations

- `linux/amd64` only. The Definition builds for that platform, and the verify Job downloads the amd64 cosign.
- On shared nodes, the controller runs without a SPIFFE identity, SPIRE runs without agents and without the OIDC discovery provider, and nktp collects no node-level logs or host metrics. Everything that NVKE issues workload identities for, and node telemetry, needs private nodes.
- Once per tenant cluster. The CRDs are cluster-scoped and the SPIRE trust domain is `example.org`, as in NVKE's own configuration.
- `verifyMode: off` is not a security boundary. It exists for releases that NVKR signed in dry-run mode.
- The Stack does not install NICo, Cluster API, or anything NVKE uses to provision nodes. It installs the management plane; what you connect to it is up to you.
- The NVKE Helm values are the ones NVKE v0.22.0 ships. A newer NVKE release whose charts change their values needs a change here.

## Test changes

Run the static checks and renders. They need `python3` with PyYAML, `helm`, `git`, and network access to the chart repositories and `github.com`:

```bash
./certified-stacks/nvidia-nvke-mgmt/test-certified-manifests.sh
```

The script checks the StackTemplate's parameters, task graph, outputs, and timeouts, renders the two Apps as Helm charts and parses the verify script with `sh -n`, then renders cert-manager, PostgreSQL, SPIRE, Temporal, nktp, and the controller chart with the Stack's values for both `sharedNodes` settings. CI runs it on every change in this directory, followed by a server-side dry run of every manifest against vCluster Platform.

## Tested

Tested on 2026-11-03 against vCluster Platform 5.0.0-alpha.9 on GKE (Kubernetes 1.36) with vCluster 0.37.2, using a keyless-signed NVKR release of NVKE v0.22.0 published to GHCR from GitHub Actions in per-output mode.

| Test | Result |
| --- | --- |
| Shared nodes, from `nvidia-nvke-mgmt-shared-nodes`, `verifyMode: root` | Healthy, nine tasks, 4m46s from cluster creation. Charts installed at the versions the release names (nktp 0.22.0, postgresql 18.5.15, spire-crds 0.6.1, spire 0.30.1, temporal 0.74.0, controller 0.22.0); the controller runs at the signed `cwe` digest; no CSI driver, no OIDC provider; the five published outputs available. |
| Private nodes, from `nvidia-nvke-mgmt-private-nodes`, one joined bare-metal node (28 CPU, H100) | Healthy, nine tasks, 5m35s from cluster creation including the node join. SPIRE server, agent, CSI driver and OIDC discovery provider running; the controller mounts the SPIFFE workload API and holds `spiffe://example.org/nvke-service/nke-controller`; the nktp node collector running. |
| Negative: the example StackInstance on an existing shared-node cluster with one digit of the release digest changed | Degraded. `verify` Failed with `cannot read the release root manifest`; the eight other tasks Waiting; only the `nvke-verify` namespace in the cluster. |
| Update: `releaseRoot` patched to the real root on that StackInstance | `verify` re-ran and went Healthy; the install proceeded to Healthy. |
| Removal: that StackInstance deleted | All nine Helm releases, the NVKE namespaces, and both PersistentVolumeClaims removed within a minute. Left behind: the 20 CRDs and the empty `cert-manager`, `nvke-base`, and `nvke-verify` namespaces. Deleting the shared-node cluster removed everything with it. |
