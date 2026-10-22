# NICo machine validation and the recorder

NICo already validates every host it manages, so on NICo the gpu-burn-in Stack adds to a check
that exists rather than filling a gap. NICo's machine validation runs before a host is offered and
after every release. The Stack runs later, on the production OS, with load and NCCL that NICo's
validation does not have. The recorder records Stack runs on NICo machines today. It does not yet
read NICo's own validation results; this document describes how it could.

Sources: NICo (`infra-controller`) at `d35a3c644`, 2026-10-21, and vCluster Platform at
v5.0.0-alpha.5. Nothing here has been run against a NICo site.

## Contents

- [What NICo machine validation does](#what-nico-machine-validation-does)
- [NICo validation and the Stack side by side](#nico-validation-and-the-stack-side-by-side)
- [Run the Stack on NICo machines](#run-the-stack-on-nico-machines)
- [Proposed: a NICo source for QualificationReports](#proposed-a-nico-source-for-qualificationreports)
- [NICo's External Validation Allocation Hold design](#nicos-external-validation-allocation-hold-design)
- [Rack scale: NICo's Rack Validation Service](#rack-scale-nicos-rack-validation-service)
- [Open questions](#open-questions)

## What NICo machine validation does

NICo boots the host into its Scout discovery OS and runs the tests there, before the host is
`Ready`. Docs: `docs/provisioning/machine-validation.md`. Code: `crates/machine-validation/` and
`crates/scout/src/machine_validation.rs`.

**When it runs.** A test declares the contexts it runs in:

| Context | When |
| --- | --- |
| `Discovery` | When a host is first brought in, after SKU validation |
| `Cleanup` | After every instance release, before the host is `Ready` again |
| `OnDemand` | When an operator asks, through the API or `nico-admin-cli machine-validation on-demand start`. Only from `Ready` or `Failed` |

It does not run on a schedule.

**What it runs.** The seeded catalog is host-level and short:

| Test | Command | Contexts |
| --- | --- | --- |
| `DcgmFullShort` | `dcgmi diag -r 2` | Cleanup |
| `DcgmFullLong` | `dcgmi diag -r 3` | Discovery, OnDemand |
| `CPUTest*`, `MemoryTest*`, `MqStresser*` | stress-ng, 30 to 120 seconds | Short in Cleanup, long in Discovery and OnDemand |
| `NvmeCheck` | Checks that every NVMe drive is writable | All |

- **Only `NvmeCheck` is enabled by default.** A site turns the others on in
  `[machine_validation_config]`, and each test lists the SKUs it supports.
- **There is no NCCL test and no soak.** A test's length is its own arguments plus a 2-hour
  timeout. The `nvbandwidth` and CUDA sample tests were removed in August 2026. The provisioning
  doc still lists them, so it is out of date there.
- **Sites can add tests as container plugins.** NICo's own default plugin runs only DCGM
  diagnostics.

**What a failure does.** NICo enforces the result itself:

- The host moves to `Failed` with cause `MachineValidation`.
- A `PreventAllocations` health alert is raised.
- Nothing retries on its own. An on-demand run clears the alert, and a pass returns the host to
  `Ready`.

Separately, NICo's NVLink partition monitor raises a `PreventAllocations` alert (`NvlinkUnhealthy`)
for each GPU that NMX reports as degraded or without NVLink.

## NICo validation and the Stack side by side

| | NICo machine validation | gpu-burn-in Stack |
| --- | --- | --- |
| Runs on | Scout, NICo's discovery OS | The production OS image, with the GPU Operator's driver |
| When | Discovery, after every release, on demand | When a qualification tenant cluster is created |
| GPU tests | DCGM level 2 or 3, if the site enables them | DCGM levels 1 to 4, NCCL, a DCGM soak of up to 24 hours with temperature and XID checks |
| Blocks allocation | Yes: `Failed` plus a `PreventAllocations` alert | Only through a NodeType selector on the result label |
| Results | NICo's database, gRPC, REST and `nico-admin-cli` | ConfigMap, Stack outputs, a QualificationReport, the dashboards |

The two complement each other. NICo catches a host that is broken before anyone can claim it. The
Stack shows that the image tenants actually run holds up under sustained load.

## Run the Stack on NICo machines

The recorder doesn't need NICo-specific code for Stack runs, because it works from vCluster
Platform objects, which are the same for every provider:

- **Finding the server works the same way.** The Platform's NICo provider mirrors each NICo
  machine as a Machine named `<provider>.<NICo machine id>`. When a tenant cluster claims one, the
  Platform puts `machines.vcluster.com/node-claim` on it, which is what the recorder follows.
- **Use `target: machine`.** A NICo machine has no BareMetalHost. The Platform accepts labels and
  annotations on Machines, except its own keys and labels mirrored from NICo. A recorder label
  written to a Machine on 4.13.0-alpha.19 was accepted.
- **The label can gate NICo NodeTypes from v5.0.0-alpha.5.** Before that release a NICo NodeType
  picks machines by instance type, so no label can gate it. From v5.0.0-alpha.5 it selects
  Machines with a label selector, so a production NodeType can require
  `<labelDomain>/result=passed`. Two cases get past it: a claim pinned to a machine with
  `spec.machineRef` skips the selector, and a label key that NICo also reports is overwritten by
  NICo's value.
- **NetBox doesn't apply.** NICo has no NetBox import, so `netboxUpdate` is skipped.
- **Release starts NICo's cleanup.** `releaseServer` deletes the tenant cluster. The Platform
  deletes the NICo instance, and NICo runs its `Cleanup` validation before the host is `Ready`
  again. A Stack failure doesn't stop that: NICo returns the host to `Ready` if its own tests pass.
  Only the recorder's label keeps the host out of production NodeTypes.

Not run yet: the Stack on a NICo machine, and the `machine` target with a real write.

## Proposed: a NICo source for QualificationReports

QualificationReport already has `source.kind: NICoValidation` for this. A NICo source in the
recorder would turn each finished NICo validation run into a report. Then NICo's checks and Stack
runs appear in the same history, on the same dashboards and behind the same label. None of this is
built.

**Knowing a run finished:**

- **Push:** NICo publishes every host state change over MQTT, on
  `NICO/v1/machine/<machine id>/state` by default. A change out of `validation` into `ready` or
  `failed` marks a finished run, but the message carries no test results.
- **Poll:** the gRPC `GetMachineValidationRuns` with no machine id returns every run on the site.
  The REST API lists runs one machine at a time:
  `GET /v2/org/{org}/nico/machine/{machineId}/validation/run`.

**Reading the results:** gRPC `GetMachineValidationResults`, or REST
`GET /v2/org/{org}/nico/machine/{machineId}/validation/result`. Both return one entry per test,
with the command, exit code, stdout, stderr and times.

**Mapping to the report:**

| QualificationReport | From NICo |
| --- | --- |
| `machineRef`, `providerRef` | `<provider>.<machine id>`, the NICo provider |
| `source` | `kind: NICoValidation`, `name`: the validation id |
| `profile` | The run's context (`Discovery`, `Cleanup`, `OnDemand`) and name |
| `result` | Run state `Success` is `passed` and `Failed` is `failed`. `Skipped`, or a run that went stale, is `error` |
| `failedTests`, `summary` | Tests with a non-zero exit code, with their stderr |
| `startedAt`, `finishedAt` | The run's start and end times |
| `tests[]` | One per result: name, status from the exit code, times. No `metrics`, because NICo stores DCGM's text output, not its numbers |
| `hardware` | NICo's discovery data: each GPU's name, serial and driver, and the DMI serials and product |
| `topology` | The Machine's labels as today, or NICo's `rack_id` and slot |

The recorder would record each validation id once, as it does with Stack runs, and could also write
the result label on the Machine. That gives one NodeType gate for both sources, even though NICo
already blocks a failed host by itself.

**Access:**

- **REST:** a JWT with the `PROVIDER_ADMIN` role. That's the role vCluster Platform's NICo provider
  already uses, with tokens it signs itself. REST has no site-wide run list, so it needs one call
  per machine.
- **gRPC:** an mTLS client certificate that NICo maps to an admin-CLI user, or a NICo change that
  adds a principal for this reader. Only the admin CLI and the site agent may read validation
  results today.

## NICo's External Validation Allocation Hold design

`designs/machine-validation/external-validation-allocation-hold.md` in the NICo repository (draft
0.6, 2026-10-07) describes a direct way for an outside validator such as this Stack to gate a host.
NICo has no code for it yet.

1. After its own validation passes, NICo keeps the host `Ready` but holds it with a
   `PreventAllocations` alert.
2. The validator calls `StartExternalValidation`, then creates an instance on the held host with
   the request id.
3. When the validator's tests finish, it calls `CompleteExternalValidation` with `Passed` or
   `Failed`.
4. A pass releases the hold.

With that, the recorder could report the Stack's verdict to NICo, and NICo would enforce it. A
NodeType label would no longer be needed. The Platform would also have to pass the request id when
it creates the instance.

## Rack scale: NICo's Rack Validation Service

NICo's Rack Validation Service (`crates/rvs`) is the closest NICo has to this Stack at rack scale.
It allocates instances across a rack with a scenario OS, runs scenario scripts such as NCCL or MPI,
and writes each node's result as NICo machine labels:

- `rv.run-id` and `rv.part-id`
- `rv.st`: `idle`, `inp`, `pass` or `fail`
- `rv.fail-desc`

NICo's rack controller combines those labels into the rack's `Validating` state. The Platform
copies NICo machine labels onto Machines from v5.0.0-alpha.5, so those labels should show up there.
If they do, the recorder could build reports from them without access to the NICo API. That is
inferred from the code and not observed. For what this Stack leaves out at rack scale, see
[Rack-scale and multi-rack fabric](../README.md#rack-scale-and-multi-rack-fabric).

## Open questions

- Which DCGM tests a typical NICo site turns on, and in which contexts.
- How a `Failed` NICo host appears on the Platform Machine. It is not `Available`, but the phase it
  maps to was not traced.
- Whether REST validation runs include history.
- Whether the `rv.*` labels appear on Platform Machines in practice.
- Whether NICo plans to build the External Validation Allocation Hold, and on what timeline.
