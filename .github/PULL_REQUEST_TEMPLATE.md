## What changed

<!-- Explain the integration or change and why it is needed. Link an issue if applicable. -->

## Compatibility and dependencies

<!-- Required Platform/vCluster/Kubernetes versions, node models/destinations, hardware,
     features, Argo CD, and external/bundled dependencies. State shared ownership or conflicts. -->

## Validation and live-test evidence

<!-- List exact commands and results. Distinguish static checks, admission dry runs, and live tests.
     For live tests include date, commit, exact versions, infrastructure, and configuration.
     Say what was NOT tested, including hardware-dependent branches. -->

| Check / configuration | Environment and versions | Result or untested reason |
| --- | --- | --- |
| | | |

## Lifecycle and operational effects

<!-- Parameter/dependency updates, recovery, disruptive actions, removal order, retained data,
     and manual cleanup. State “No change” when applicable. Never include secret values. -->

## Contributor checklist

- [ ] Read CONTRIBUTING.md; README and examples describe the changed behavior.
- [ ] Ran repository validation and the affected integration's test entry point.
- [ ] Checked generated output when applicable.
- [ ] Reported live-test evidence and gaps accurately.
- [ ] Documented compatibility, dependencies, shared ownership, and lifecycle effects.
- [ ] Included no real credentials, kubeconfigs, or sensitive test output.
