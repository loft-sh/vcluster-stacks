import type { Metadata } from "next";
import Link from "next/link";
import { AutoRefresh } from "@/components/auto-refresh";
import { FilterTable, type FilterRow } from "@/components/filter-table";
import { Errors, Muted, Page } from "@/components/page";
import { loadSnapshot } from "@/lib/data";
import { resources, timeAgo } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";
import { RuntimeClass } from "@/components/runtime-class";

export const metadata: Metadata = { title: "Templates" };

export default async function TemplatesPage() {
  const data = await loadSnapshot();

  const rows: FilterRow[] = data.templates.map((t) => ({
    key: `${t.namespace}/${t.name}`,
    namespace: t.namespace,
    search: [t.name, t.namespace, ...t.images].join(" ").toLowerCase(),
    cells: [
      <div key="n" className="stack">
        <Link className="row-link" href={hrefs.template(t.namespace, t.name)}>
          {t.name}
        </Link>
        <Muted>{t.namespace}</Muted>
      </div>,
      <div key="i" className="stack wrap">
        {t.images.map((img) => (
          <span key={img} className="mono small">
            {img}
          </span>
        ))}
      </div>,
      <div key="r" className="stack">
        <RuntimeClass name={t.runtimeClassName} fallback="default runtime" />
        <Muted>{resources(t.limits, ["cpu", "memory"])}</Muted>
      </div>,
      <div key="np" className="stack">
        <span>{t.networkPolicyManagement}</span>
        <Muted>{t.networkPolicyManagement === "Managed" ? (t.customNetworkPolicy ? "Custom rules" : "Default rules") : ""}</Muted>
      </div>,
      <div key="p" className="stack">
        <span>Env: {t.envVarsInjectionPolicy}</span>
        <Muted>Volumes: {t.volumeClaimTemplatesPolicy}</Muted>
      </div>,
      <div key="u" className="stack">
        <span>
          {t.warmPools.length
            ? t.warmPools.map((p, i) => (
                <span key={p}>
                  {i > 0 && ", "}
                  <Link className="link" href={hrefs.warmPool(t.namespace, p)}>
                    {p}
                  </Link>
                </span>
              ))
            : "-"}
        </span>
        <Muted>
          {t.sandboxes} sandbox{t.sandboxes === 1 ? "" : "es"}
        </Muted>
      </div>,
      <span key="a">{timeAgo(t.createdAt)}</span>,
    ],
  }));

  return (
    <Page crumbs={[{ label: "Agent Sandbox" }, { label: "Templates" }]} title="Sandbox Templates">
      <Errors errors={data.errors} />
      <FilterTable
        placeholder="Filter by template or image..."
        toolbar={<AutoRefresh fetchedAt={data.fetchedAt} />}
        columns={[
          { label: "Name", width: "18%" },
          { label: "Image" },
          { label: "Runtime" },
          { label: "Network Policy" },
          { label: "Claim Overrides" },
          { label: "Warm Pools" },
          { label: "Age" },
        ]}
        rows={rows}
        empty="No sandbox templates."
      />
    </Page>
  );
}
