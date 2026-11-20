# Contribute a Community Stack

Share a stack that someone else can install, use, and remove with clear
expectations. This guide covers Community Stack contributions using today's
repository workflow. It does not define certification requirements.

## What a contribution needs

- A `StackTemplate` and an example `StackInstance` or cluster template.
- The referenced Apps and ArgoCDApplicationTemplates, or instructions for obtaining
  dependencies supplied by Platform or installed separately.
- A short README explaining the purpose, prerequisites, inputs, installation,
  a functional check, removal, and known limitations.
- An honest account of what works in the configuration you tested and what
  remains unverified.
- No real credentials, conflicting resource definitions, or undisclosed privileged
  or destructive behavior.

A simple stack can meet these requirements with a few manifests and a short
README. You do not need a custom test script, a compatibility matrix, a diagram,
or a particular number of README sections.

## Get started

1. Check existing integrations and issues for related work. Discuss changes to
   shared infrastructure with maintainers before doing substantial work.
2. Fork the repository and create a branch. Put a new stack under
   `community-stacks/<integration>/` with a lowercase, hyphen-separated name.
3. Copy the working [starter](templates/stack/) or use an existing integration
   with a similar shape. Adapt the [README outline](templates/README-template.md)
   to your stack; combine or omit sections that do not apply.
4. Run shared validation and any relevant checks, then open a PR. A draft is
   welcome when you need help with testing or a dependency.

Community contributions do not carry formal vCluster Product & Engineering
support. Use the repository's [GitHub issues](https://github.com/loft-sh/vcluster-stacks/issues)
for problems, or identify an integration-specific reporting route. Do not promise
support coverage that has not been agreed.

## Make the stack usable

Show one installation path with the values a reader must replace, the API or
cluster context each command uses, and the expected result. An App being installed
or a Stack reporting `Healthy` may not prove the application works: include a
useful check, such as querying an endpoint or confirming metrics reach storage.

Name the versions and environment you used. List known requirements such as GPUs,
Argo CD, storage, Platform features, or vendor credentials. Keep parameters,
defaults, and examples consistent with the manifests. You do not need to establish
an exhaustive minimum-version or platform-support matrix; distinguish the tested
configuration from alternatives that are unverified.

Give resources collision-resistant names, normally prefixed with the integration
name. This applies to Apps, ArgoCDApplicationTemplates, StackTemplates, and
VirtualClusterTemplates. If the stack installs shared components such as GPU
Operator, cert-manager, or monitoring, explain what it owns and how it handles an
existing installation. Disclose known conflicts with other stacks.

Pin chart and image defaults to specific versions or digests, or explain why a
value follows the installed Platform. Renovate annotations are helpful when an
existing manager supports the dependency; maintainers can help add them.

Provide removal commands and identify resources or data that remain, including
manual or destructive cleanup. If you have not verified removal, say so. When a
change affects existing installations, explain the update path and known restart,
migration, or recovery requirements. A first contribution does not need a full
upgrade and failure-recovery test suite.

## Disclose operational effects

Do not commit credentials, private keys, real rendered Secrets, or kubeconfigs.
Explain how users supply sensitive inputs and who can read them. Use `fromSecret`
for Secret outputs and identify sensitive published outputs without revealing
values in the README or PR.

Explain privileged workloads, broad RBAC, exposed endpoints, hardware tests,
cordoning, or other disruptive actions when present. State their defaults and how
to turn off optional behavior. Shared nodes share the kernel and physical nodes;
use private nodes for untrusted tenants with Kubernetes access or arbitrary
workload execution. Describe the actual tenant isolation boundary you rely on.

For stacks with several templates or deployment variants, explain which resources
are installed once per Platform, cluster, or instance, who administers them, and
the installation/removal order. Inline tasks do not require an `apps/` directory.

## Validate and tell us what you tested

Run the shared offline checks from the repository root with Python 3.10 or later:

```bash
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r hack/requirements.txt
python3 hack/validate_stacks.py
```

These checks cover required files, YAML, conflicting global definitions, local
references, and literal README defaults. CI discovers new integration folders
and performs strict Platform admission dry runs. It runs on a fresh GitHub-hosted
VM without repository secrets; it does not deploy your application.

Use `p-default` for project-scoped examples so admission checks can use the test
Platform's default project. Tell readers to customize the namespace, owner, and
destination. If validation flags a dependency supplied outside this repository,
document how to obtain it in your README and ask a maintainer to help register
that external reference for CI.

Run an existing integration's check script when changing behavior it covers. For
a new stack, add focused checks when they protect behavior the shared validator
cannot check, such as generated files or conditional template references.
Maintainers can help wire them into CI. Do not add a script that merely repeats
shared validation to satisfy a folder convention.

If you provide `test-manifests.sh` or `test-certified-manifests.sh` at the integration
root, make it executable, document prerequisites, and exit nonzero on failure.
CI discovers and runs these scripts when present. Keep generator inputs in
`source/`, commit deployable output, and provide generation and consistency-check
commands. Existing generated integrations retain their checks.

For a new stack, one successful installation and functional check should be
verified before merge. You or a reviewer can provide that evidence. In the PR,
state the Platform/vCluster/Kubernetes versions, relevant infrastructure and
options, commands or steps tried, results, and gaps. Try basic cleanup where
practical. Other configurations can remain explicitly unverified; do not claim
support beyond the evidence.

In the README, keep a brief tested-environment statement so users know what to
expect. Put change-specific test details in the PR rather than maintaining the
same report twice. Distinguish static checks and admission dry runs from live
results. You do not need GPUs or vendor accounts for every possible configuration;
explain what access is missing so a reviewer can help.

## Review

Maintainers review usability, correctness, operational effects, and the evidence
for the documented path. The [review skill](.claude/skills/stack-review/SKILL.md)
assists them; it does not approve or merge contributions. Missing optional sections,
custom automation, or a broad test matrix alone are not reasons to reject a simple
Community Stack.

Paid AI review is a maintainer tool, not a contributor prerequisite. Fork PRs need
a maintainer's one-shot `stack-review-approved` label for the current head. Authors
do not need an API key or to arrange AI review. See [review setup](.github/REVIEW.md)
for maintainer configuration and request limits.
