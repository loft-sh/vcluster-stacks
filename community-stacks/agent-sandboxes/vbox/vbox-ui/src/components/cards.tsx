// Cards shared between detail pages. Sandboxes and templates both carry a pod
// spec, so the container, security, storage and pod-settings cards take a
// PodSpecView and work for either.
import Link from "next/link";
import { Boxes, Container, HardDrive, ListChecks, Network, ShieldCheck, SlidersHorizontal } from "lucide-react";
import type { NetworkPolicyView, PvcView } from "@/lib/data";
import { resources, timeAgo, yesNo } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";
import type { ConditionView, ContainerView, PodSpecView, SandboxView, TemplateView, VolumeClaimView } from "@/lib/model";
import { Card, KeyValues, Muted } from "./page";
import { HealthChip, StateBadge } from "./status";
import { RuntimeClass } from "./runtime-class";
import { CodeBlock } from "./code-block";

const ICON = { size: 22, strokeWidth: 1.75 };

export function PodSettingsCard({ spec, service }: { spec: PodSpecView; service?: boolean }) {
  return (
    <Card icon={<SlidersHorizontal {...ICON} />} title="Pod Settings">
      <KeyValues
        rows={[
          ["Runtime Class", <RuntimeClass key="rc" name={spec.runtimeClassName} fallback="Cluster default" icon={false} />],
          ["Restart Policy", spec.restartPolicy],
          [
            "DNS",
            spec.dnsPolicy === "None" && spec.nameservers.length
              ? `Custom: ${spec.nameservers.join(", ")}`
              : (spec.dnsPolicy ?? "ClusterFirst"),
          ],
          ["Service Account Token", spec.automountServiceAccountToken === false ? "Not mounted" : "Mounted"],
          ["Headless Service", service === undefined ? "Default" : yesNo(service)],
        ]}
      />
    </Card>
  );
}

export function ContainersCard({ containers }: { containers: ContainerView[] }) {
  return (
    <Card icon={<Container {...ICON} />} title="Containers">
      {containers.map((c) => (
        <div key={c.name}>
          <h3>{c.name}</h3>
          <KeyValues
            rows={[
              ["Image", <span key="i" className="mono">{c.image}</span>],
              ...(c.state !== undefined
                ? [["State", `${c.state}${c.ready === false ? ", not ready" : ""}`] as [string, string]]
                : []),
              ["Ports", c.ports.join(", ")],
              ["Requests", resources(c.requests)],
              ["Limits", resources(c.limits)],
              [
                "Mounts",
                c.volumeMounts.length
                  ? c.volumeMounts.map((m) => `${m.mountPath} (${m.name}${m.readOnly ? ", ro" : ""})`).join(", ")
                  : undefined,
              ],
            ]}
          />
          {c.env.length > 0 && <EnvTable env={c.env} />}
        </div>
      ))}
    </Card>
  );
}

export function EnvTable({ env, title = "Environment" }: { env: { name: string; value: string; containerName?: string }[]; title?: string }) {
  return (
    <>
      <h4>{title}</h4>
      <table className="kv kv-compact">
        <tbody>
          {env.map((e) => (
            <tr key={`${e.containerName ?? ""}/${e.name}`}>
              <th className="mono">
                {e.name}
                {e.containerName && <Muted> ({e.containerName})</Muted>}
              </th>
              <td className="mono">{e.value || "-"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  );
}

export function SecurityCard({ spec }: { spec: PodSpecView }) {
  const p = spec.podSecurity;
  return (
    <Card icon={<ShieldCheck {...ICON} />} title="Security">
      <h3>Pod</h3>
      <KeyValues
        rows={[
          ["Run As Non-Root", yesNo(p.runAsNonRoot)],
          ["User / Group", p.runAsUser !== undefined ? `${p.runAsUser} / ${p.runAsGroup ?? "-"}` : undefined],
          ["FS Group", p.fsGroup],
          ["Seccomp Profile", p.seccompProfile],
          ["Service Account Token", spec.automountServiceAccountToken === false ? "Not mounted" : "Mounted"],
        ]}
      />
      {spec.containers.map((c) => (
        <div key={c.name}>
          <h3>Container {c.name}</h3>
          <KeyValues
            rows={[
              ["Read-Only Root Filesystem", yesNo(c.readOnlyRootFilesystem)],
              ["Privilege Escalation", c.allowPrivilegeEscalation === false ? "Disallowed" : "Allowed"],
              ["Privileged", yesNo(c.privileged ?? false)],
              ["Capabilities Dropped", c.capabilitiesDrop.join(", ") || "None"],
              ["Capabilities Added", c.capabilitiesAdd.join(", ") || "None"],
            ]}
          />
        </div>
      ))}
    </Card>
  );
}

// Volume claim templates, plus the live PVCs when shown for a sandbox.
export function StorageCard({
  templates,
  sandbox,
  pvcs,
}: {
  templates: VolumeClaimView[];
  sandbox?: string;
  pvcs?: PvcView[];
}) {
  if (templates.length === 0) return null;
  return (
    <Card icon={<HardDrive {...ICON} />} title="Storage">
      {templates.map((v) => {
        const pvc = pvcs?.find((p) => p.name === `${v.name}-${sandbox}`);
        const live: [string, React.ReactNode][] = pvcs
          ? [
              ["PVC", pvc ? <span key="p" className="mono">{pvc.name}</span> : "Not created"],
              ["PVC Status", pvc ? `${pvc.phase ?? "-"}${pvc.deleting ? " (terminating)" : ""}` : undefined],
              ["Capacity", pvc?.capacity],
            ]
          : [];
        return (
          <div key={v.name}>
            <h3>{v.name}</h3>
            <KeyValues
              rows={[
                ["Requested", v.storage],
                ["Access Modes", v.accessModes.join(", ")],
                ...live,
                ["Storage Class", pvc?.storageClassName ?? v.storageClassName ?? "Cluster default"],
              ]}
            />
          </div>
        );
      })}
    </Card>
  );
}

export function NetworkCard({ template, policy }: { template?: TemplateView; policy?: NetworkPolicyView }) {
  return (
    <Card icon={<Network {...ICON} />} title="Network Policy">
      <KeyValues
        rows={[
          ["Management", template?.networkPolicyManagement ?? "Unknown (template not found)"],
          [
            "Rules",
            template
              ? template.customNetworkPolicy
                ? "Custom rules from the template"
                : "Controller default: ingress from the Sandbox Router only, egress to public IPs only"
              : undefined,
          ],
          ["Policy", policy ? <span key="p" className="mono">{policy.name}</span> : "None found"],
        ]}
      />
      {policy && (
        <details className="code-details">
          <summary>Show rules</summary>
          <CodeBlock code={policy.yaml} />
        </details>
      )}
    </Card>
  );
}

export function ConditionsCard({ conditions }: { conditions: ConditionView[] }) {
  if (conditions.length === 0) return null;
  return (
    <Card icon={<ListChecks {...ICON} />} title="Conditions">
      <table className="table table-inner">
        <thead>
          <tr>
            <th>Type</th>
            <th>Status</th>
            <th>Reason</th>
            <th>Message</th>
            <th>Last Transition</th>
          </tr>
        </thead>
        <tbody>
          {conditions.map((c) => (
            <tr key={c.type}>
              <td>{c.type}</td>
              <td>{c.status}</td>
              <td>{c.reason ?? "-"}</td>
              <td className="wrap-cell">{c.message || "-"}</td>
              <td>{timeAgo(c.lastTransitionTime)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Card>
  );
}

export function SandboxesCard({ sandboxes, empty }: { sandboxes: SandboxView[]; empty: string }) {
  return (
    <Card icon={<Boxes {...ICON} />} title={`Sandboxes (${sandboxes.length})`}>
      {sandboxes.length === 0 ? (
        <p className="muted">{empty}</p>
      ) : (
        <table className="table table-inner">
          <thead>
            <tr>
              <th>Name</th>
              <th>Status</th>
              <th>Health</th>
              <th>Claim</th>
              <th>Age</th>
            </tr>
          </thead>
          <tbody>
            {sandboxes.map((s) => (
              <tr key={s.uid}>
                <td>
                  <Link className="row-link" href={hrefs.sandbox(s.namespace, s.name)}>
                    {s.name}
                  </Link>
                </td>
                <td>
                  <StateBadge state={s.state} />
                </td>
                <td>
                  <HealthChip health={s.health} reason={s.healthReason} />
                </td>
                <td>
                  {s.claim ? (
                    <Link className="link" href={hrefs.claim(s.namespace, s.claim.name)}>
                      {s.claim.name}
                    </Link>
                  ) : (
                    "-"
                  )}
                </td>
                <td>{timeAgo(s.createdAt)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Card>
  );
}
