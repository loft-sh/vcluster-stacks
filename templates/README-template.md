# Community Stack README outline

Use this as a starting point, not a form to complete. A short README is enough
when it gives someone a path that works and discloses the limitations. Combine
sections, omit inapplicable ones, and remove these instructions when copying.
See the [starter](stack/README.md) and [contribution guide](../CONTRIBUTING.md).

## Purpose

Name the integration and explain what it deploys and when someone would use it.
Link to the other product's documentation rather than repeating its manual.

## Before you begin

List the dependencies, access, tools, hardware, credentials, and other known
requirements for the path below. Explain whether you supply each dependency,
reuse one bundled with Platform, or expect the reader to install it separately.
If the stack installs a shared operator or service, describe existing-installation
handling and known conflicts. State privileged or disruptive behavior before the
reader runs commands.

## Install and configure

Show one installation path in order. Explain example values, parameters and
defaults, resource ownership, and which commands use the Platform management API
versus the destination cluster. Include alternate paths only when useful.

A parameter table is optional for small stacks; when used, keep it aligned with
the manifests:

| Parameter | Default | Purpose / allowed values |
| --- | --- | --- |
| `<variable>` | `<default or none>` | `<effect and constraints>` |

Explain how users supply credentials without committing or publishing them.

## Verify

Give a command or action that demonstrates the application works and its expected
result. `Healthy` alone may not demonstrate this. Document published outputs and
how to use them if applicable, including whether they are sensitive.

## Remove

Show removal commands and ordering. Identify retained data and resources, manual
cleanup, and destructive steps. Say if removal has not been verified. Deleting the
StackInstance starts teardown; `prunePolicy` applies only to tasks removed from
the graph during an update.

## Tested environment and limitations

Briefly name the versions, infrastructure, and configuration you tested. Identify
unverified paths and known limitations. A paragraph is sufficient; a version
matrix and a duplicate copy of PR test results are not required.

## Add detail when the stack needs it

- **Architecture and files:** explain related templates, task gates, deployment
  variants, shared resources, and generated source/output when these affect use.
- **Update and recover:** include known upgrade, restart, migration, or recovery
  steps when relevant, especially for a change affecting existing users.
- **Troubleshoot:** describe likely symptoms, a diagnostic check, and an action.
- **Test changes:** document custom test or generation commands when provided.
- **Reporting and licensing:** name a specific reporting route or vendor license
  requirement if needed; otherwise link to repository issues and license.

These details can be paragraphs beside the steps that need them. A simple stack
needs neither a custom test script nor all these headings.
