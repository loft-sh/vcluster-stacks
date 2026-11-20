# Contribute to vCluster Stacks

Contribute a reusable integration or improve an existing one through a pull
request. These requirements cover the repository and installation workflow
available today. They do not require a catalog UI or a catalog metadata format.

## Start a contribution

1. Check existing integrations and issues for related work. Discuss large changes,
   certification requests, and changes to shared infrastructure with maintainers.
2. Fork the repository, create a branch, and put a new integration under
   `community-stacks/<integration>/` using a lowercase, hyphen-separated name.
3. Copy [templates/stack/](templates/stack/) for a small working example. Adapt the
   [README outline](templates/README-template.md); omit inapplicable sections.
4. Add checks, test in a non-production environment, and open a PR using the
   repository's PR template. Say what you have not tested.

New contributions normally start as Community Stacks. Maintainers decide whether
an integration is Certified; a directory, annotation, or passing check does not
grant certification. Community contributions do not carry formal vCluster
Product & Engineering support. Do not promise support coverage that has not been agreed.

## Include a complete integration

Each integration needs:

- A `README.md` covering its outcome, requirements, installation, verification,
  update and removal behavior, limitations, and testing.
- At least one deployable `StackTemplate` and an example `StackInstance` or
  cluster template showing how to use it.
- Referenced Apps and ArgoCDApplicationTemplates, or explicit instructions for
  obtaining dependencies bundled with Platform or installed separately.
- An executable root `test-manifests.sh` or `test-certified-manifests.sh` that
  exits nonzero on failure. Keep integration-specific checks behind this entry
  point, including generated-file checks. Document its prerequisites.

Inline tasks do not need an `apps/` directory. Several related templates or
variants can share an integration folder. Explain their destinations, installation
order, ownership, and removal order. Put generator inputs in `source/`; validation
scans deployable YAML outside `source/`, not generator inputs. Commit generated
output and check it against its source.

The validator discovers integrations automatically under `certified-stacks/` and
`community-stacks/`. Do not add a stack to a hardcoded CI list. Every integration
folder must meet the file and validation-entry-point requirements above.

## Name and configure resources

- Prefix Platform-global App, ArgoCDApplicationTemplate, and StackTemplate names
  with the integration name. Deliberately shared definitions must agree. Renaming
  a task or template can affect existing instances and output references.
- Declare user-facing parameters with useful labels, descriptions, types,
  defaults, and validation. Keep README tables and examples consistent with the
  manifests. Distinguish user inputs from internal values supplied by Platform.
- State minimum requirements separately from tested versions. Include Platform,
  vCluster, Kubernetes, infrastructure, required features, and Argo CD prerequisites
  where relevant. Do not infer universal compatibility from one test.
- Pin chart and image defaults to specific versions or digests. Explain deliberate
  exceptions, such as the Platform-provided image. Add Renovate annotations when
  its existing managers can track the dependency.
- Use the Platform API schema for task/output rules. Keep dependencies acyclic and
  test configuration-dependent references for every supported branch, including
  no-op templates. Document dependencies supplied outside the integration.
- Set timeouts for the workload. Distinguish the task deadline from the child
  App's deployment timeout. Readiness must represent what a dependent task needs,
  such as allocatable GPUs rather than merely an installed operator.

## Describe ownership and operational effects

For components such as GPU Operator, cert-manager, monitoring, or gateways, say
whether the Stack installs them or requires an existing installation. Identify
namespaces, cluster-scoped resources, and supported coexistence with other Stacks.
Unique Platform template names do not prevent two installs from trying to own the
same destination resources.

Document who administers each StackInstance, what access it needs, and whether it
is installed once per Platform, cluster, or instance. Make example owners, project
namespaces, and destinations clearly customizable.

Disclose privileged workloads, RBAC, endpoints, credentials, scheduled hardware
checks, cordoning, and other disruptive actions. Explain defaults and how to
turn off optional behavior. Describe the node model's actual tenant isolation
boundary. Shared nodes are for trusted workloads; they share physical nodes and
the kernel. Use private nodes for untrusted tenants with Kubernetes access or
arbitrary workload execution.

Do not commit credentials, private keys, real rendered Secrets, or kubeconfigs.
Document how users supply sensitive inputs and who can read them. Use `fromSecret`
for Secret outputs, identify sensitive published outputs, and never include their
values in test reports or PR descriptions.

## Document the lifecycle

Give installation commands and a functional check with expected results. A
StackInstance reporting `Healthy` does not alone prove a working model endpoint,
metrics pipeline, scheduler, or application login.

Explain parameter and dependency changes, their effect on existing instances,
and required restarts or migrations. A referenced StackTemplate is resolved during
reconciliation; changing it can affect existing instances. It is not a pinned
Stack revision.

Distinguish these operations:

- **Remove a task from the graph.** `prunePolicy` defaults to `Retain`, preserving
  removed children. `Prune` deletes removed children in dependency order.
- **Delete the StackInstance.** This starts child teardown; `prunePolicy` is not
  the switch for instance deletion. Apps, Helm, Argo CD, hooks, and external
  services determine what resources or data remain.

Document retained namespaces, PVCs/PVs, CRDs, registrations, and data. State what
manual cleanup does and whether it is destructive. For shared foundations, name
the dependents that must be removed first. Include likely failure recovery and
credential/certificate or endpoint changes where applicable.

## Run validation

Use Python 3.10 or later and PyYAML. A virtual environment keeps dependencies local:

```bash
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r hack/requirements.txt
python3 hack/validate_stacks.py
```

The offline validator checks required files, YAML, conflicting global definitions,
local template references, and the starter example. It excludes `source/` inputs
and supporting Kubernetes objects from Platform API validation. It does not
replace Platform admission or resolve arbitrary Go templates. Integration checks
must cover dynamic references, render branches, README defaults, and their own
invariants.

If a static task reference is supplied outside the repository, declare it in
`hack/external-template-references.yaml` as a list entry with `path` (the
repository-relative StackTemplate file), `kind`, `name`, and `instructions`
(a README link and installation/version requirements). The validator checks local
references against the repository and accepts only explicitly declared external
ones. Dynamic references need integration-specific render checks.

Run each integration's test entry point (some fetch upstream charts):

```bash
python3 hack/validate_stacks.py --run-checks
```

Existing checks use Bash 4 or later, Helm, `rg`, and sometimes `jq`; consult the
integration README. Run:ai's entry point runs `render.sh --check` and its manifest
tests. Edit authoritative `source/` files and run `render.sh` for generated changes.

CI starts an ephemeral Platform and validates deployable Platform documents with
strict server-side dry runs. To run that part against your own **test**
installation, confirm your context and connect to its management API:

```bash
vcluster platform connect management
python3 hack/validate_stacks.py --server
```

Server dry runs do not deploy Stacks or prove workloads work. CI executes
contribution scripts without repository secrets on a disposable runner. Do not
add steps that need production access or customer credentials.

## Record test evidence

For each relevant configuration, record the date, stack commit, Platform,
vCluster and Kubernetes versions, infrastructure/node model, commands, result,
and gaps. Put a tested-configuration summary in the README and results for the
change in the PR. Distinguish static checks, Platform admission, and live tests.

Test installation, functional readiness, parameter/dependency updates, failure
recovery, and removal as appropriate. Cover supported destinations and optional
branches; explain omitted hardware-dependent cases. An old test does not prove a
changed configuration works.

Certified integrations need a repeatable smoke-test procedure and success criteria
agreed with maintainers and, when applicable, the partner. Automate it where
practical. A generic CI runner need not provide GPUs or every vendor service;
identify the environment and operator needed for those tests.

## Review and maintenance

Maintainers review the integration and its evidence after automated checks. The
[stack-review skill](.claude/skills/stack-review/SKILL.md) assists with manifests,
documentation, operational behavior, and test evidence. It does not merge, certify,
or deploy contributions.

Automatic review uses the base branch's guide and skill and reads PR files as
text. It runs on PR creation and updates, including fork PRs, after the workflow
is merged and its credential is configured. Missing credentials are reported in
the job summary, not as a successful review. See [review setup](.github/REVIEW.md).

Report bugs through [GitHub issues](https://github.com/loft-sh/vcluster-stacks/issues)
with redacted configuration and reproduction steps, or use an integration's
specific reporting route. Existing-stack documentation can adopt this outline
incrementally; prioritize incorrect defaults, compatibility, verification, and
cleanup instructions when editing a stack.
