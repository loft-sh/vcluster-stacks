import type { Metadata } from "next";
import Link from "next/link";
import { CircleAlert } from "lucide-react";
import { AutoRefresh } from "@/components/auto-refresh";
import { FilterTable, type FilterRow } from "@/components/filter-table";
import { Errors, Muted, Page } from "@/components/page";
import { HealthChip, StateBadge } from "@/components/status";
import { loadSnapshot } from "@/lib/data";
import { resources, timeAgo } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";
import type { SandboxView } from "@/lib/model";
import { RuntimeClass } from "@/components/runtime-class";

export const metadata: Metadata = { title: "Sandboxes" };

function runtimeOf(s: SandboxView) {
  const c = s.containers[0];
  return (
    <div className="stack">
      <RuntimeClass name={s.runtimeClassName} fallback="default runtime" />
      {c && <Muted>{resources(c.limits, ["cpu", "memory"])}</Muted>}
    </div>
  );
}

export default async function SandboxesPage() {
  const data = await loadSnapshot();
  const { sandboxes } = data;
  const count = (state: string) => sandboxes.filter((s) => s.state === state).length;

  const rows: FilterRow[] = sandboxes.map((s) => ({
    key: s.uid,
    namespace: s.namespace,
    state: s.state,
    search: [s.name, s.namespace, s.template, s.warmPool, s.claim?.name, s.nodeName, ...s.podIPs]
      .filter(Boolean)
      .join(" ")
      .toLowerCase(),
    cells: [
      <div key="name" className="stack">
        <Link className="row-link" href={hrefs.sandbox(s.namespace, s.name)}>
          {s.name}
        </Link>
        <Muted>{s.namespace}</Muted>
      </div>,
      <StateBadge key="state" state={s.state} />,
      <HealthChip key="health" health={s.health} reason={s.healthReason} />,
      s.claim ? (
        <div key="claim" className="stack">
          <Link className="link" href={hrefs.claim(s.namespace, s.claim.name)}>
            {s.claim.name}
          </Link>
          <Muted>
            {s.claim.createdBy ? `by ${s.claim.createdBy}, ` : ""}
            {timeAgo(s.claim.createdAt)}
          </Muted>
        </div>
      ) : (
        <Muted key="claim">-</Muted>
      ),
      <div key="tpl" className="stack">
        {s.template ? (
          <Link className="link" href={hrefs.template(s.namespace, s.template)}>
            {s.template}
          </Link>
        ) : (
          <span>-</span>
        )}
        <Muted>{s.warmPool ? `Pool: ${s.warmPool}` : "No warm pool"}</Muted>
      </div>,
      runtimeOf(s),
      <div key="node" className="stack">
        <span className="mono">{s.podIPs[0] ?? "-"}</span>
        <Muted>{s.nodeName ?? "Not scheduled"}</Muted>
      </div>,
      <span key="age">{timeAgo(s.createdAt)}</span>,
    ],
  }));

  return (
    <Page
      crumbs={[{ label: "Agent Sandbox" }, { label: "Sandboxes" }]}
      title="Sandboxes"
      actions={
        <div className="summary">
          <span>
            <strong>{count("available")}</strong> available
          </span>
          <span>
            <strong>{count("claimed")}</strong> claimed
          </span>
          {count("standalone") > 0 && (
            <span>
              <strong>{count("standalone")}</strong> standalone
            </span>
          )}
        </div>
      }
    >
      <Errors errors={data.errors} />
      <FilterTable
        placeholder="Filter by name, claim, pool or IP..."
        stateOptions={[
          { value: "available", label: "Available (warm)" },
          { value: "claimed", label: "Claimed" },
          { value: "standalone", label: "Standalone" },
        ]}
        stateLabel="Available or claimed"
        toolbar={<AutoRefresh fetchedAt={data.fetchedAt} />}
        columns={[
          { label: "Name", width: "22%" },
          { label: "Status" },
          { label: "Health" },
          { label: "Claim" },
          { label: "Template" },
          { label: "Runtime" },
          { label: "IP Address" },
          { label: "Age" },
        ]}
        rows={rows}
        empty="No sandboxes found. Warm pools and claims create them."
      />

      {data.orphanPods.length > 0 && (
        <div className="notice">
          <CircleAlert size={18} strokeWidth={1.75} />
          <div>
            <strong>
              {data.orphanPods.length} pod{data.orphanPods.length === 1 ? "" : "s"} of deleted sandboxes still on the
              cluster
            </strong>
            <ul>
              {data.orphanPods.map((p) => (
                <li key={`${p.namespace}/${p.name}`}>
                  <span className="mono">
                    {p.namespace}/{p.name}
                  </span>{" "}
                  <Muted>
                    {p.deleting ? "terminating" : (p.phase ?? "unknown")}
                    {p.createdBy ? `, claimed by ${p.createdBy}` : ""}
                    {p.createdAt ? `, created ${timeAgo(p.createdAt)}` : ""}
                  </Muted>
                </li>
              ))}
            </ul>
          </div>
        </div>
      )}
    </Page>
  );
}
