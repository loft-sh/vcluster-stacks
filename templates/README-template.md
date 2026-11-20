# Stack README outline

Copy this outline into your integration's `README.md` and replace the guidance
with concrete instructions. Keep the information required by
[CONTRIBUTING.md](../CONTRIBUTING.md), but combine or omit sections that do not
apply. See the working [starter README](stack/README.md) for an example.

## Purpose and scope

Start with the integration's name, what it deploys, and when someone would use it.
Link to the other product's documentation instead of repeating its manual.
Identify authorship and the maintenance/reporting route without implying
certification or support guarantees.

## Requirements

State minimum versions, access, Platform features, Argo CD requirements, node
models, hardware, storage, DNS/TLS, network exposure, and vendor accounts where
applicable. Distinguish requirements from tested versions. Put anything that
changes whether a reader should start before the quick start.

## Quick start

Show one path: prepare values, connect to the management API, apply resources in
order, create an instance, and verify a useful result. Identify commands that
use the destination cluster's context instead. Explain placeholders and avoid
real credentials. Link to alternative deployment paths.

## Architecture and files

Explain the task graph and why its gates matter. A table can replace a diagram.
For related templates or variants, list the destination, installation frequency
(once per Platform/cluster/instance), owner, and lifecycle of each. Identify
authoritative source, generated output, and generation commands.

## Dependencies and coexistence

List included, Platform-bundled, and separately installed dependencies. State
which Stack owns operators, namespaces, CRDs, and releases, how existing
installations are handled, and known conflicts. Name required external versions.

## Configure parameters

| Parameter | Type | Required | Default | Purpose and constraints |
| --- | --- | --- | --- | --- |
| `<variable>` | `<type>` | `<yes/no>` | `<default or none>` | `<effect, allowed values, sensitive-value handling>` |

Keep the table aligned with the StackTemplate. Explain inputs forwarded by a
cluster template and values left unset so Stack defaults apply.

## Install

Give detailed instructions for supported models and configuration branches.
Explain privileges and disruptive actions, including how optional hardware tests
or remediation can be disabled. Name resources created outside the destination
namespace or in external systems.

## Verify and use outputs

Show status checks with expected results and a functional check. For every
published output, explain meaning, sensitivity, and retrieval. An installed
operator or `Healthy` phase alone does not demonstrate functional success.

## Upgrade and recover

Explain parameter, App, chart/image, and StackTemplate updates, their effect on
existing instances, migrations, restarts, and recovery. Describe certificate,
credential, and endpoint refresh where relevant.

## Remove

Show removal order, especially for shared foundations. Distinguish instance
deletion from removing tasks with Retain/Prune. List resources and data left
behind, manual cleanup ownership, and destructive purge commands separately.

## Troubleshoot and known limitations

Give symptoms, diagnostic commands, and actions for likely failures. State
unsupported combinations and gaps in advertised behavior explicitly.

## Test changes

Document local commands, dependencies, network requirements, generation checks,
and the live smoke-test procedure and expected results.

## Tested configurations

| Date / stack commit | Platform / vCluster / Kubernetes | Infrastructure and configuration | Checks and result | Untested paths |
| --- | --- | --- | --- | --- |
| `<date / commit>` | `<exact versions>` | `<node model, hardware, options>` | `<static, admission, or live; commands/results>` | `<gaps>` |

## Support and license

Identify the reporting route and link to the repository license. Explain vendor
licensing or account requirements where applicable.
