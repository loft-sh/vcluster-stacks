import type { Metadata } from "next";
import Link from "next/link";
import { AutoRefresh } from "@/components/auto-refresh";
import { FilterTable, type FilterRow } from "@/components/filter-table";
import { Errors, Muted, Page } from "@/components/page";
import { loadSnapshot } from "@/lib/data";
import { hrefs } from "@/lib/hrefs";
import { timeAgo } from "@/lib/format";

export const metadata: Metadata = { title: "Warm Pools" };

export default async function WarmPoolsPage() {
  const data = await loadSnapshot();

  const rows: FilterRow[] = data.warmPools.map((p) => {
    const pct = p.desired > 0 ? Math.min(100, Math.round((p.ready / p.desired) * 100)) : 100;
    return {
      key: `${p.namespace}/${p.name}`,
      namespace: p.namespace,
      search: [p.name, p.namespace, p.template].join(" ").toLowerCase(),
      cells: [
        <div key="n" className="stack">
          <Link className="row-link" href={hrefs.warmPool(p.namespace, p.name)}>
          {p.name}
        </Link>
          <Muted>{p.namespace}</Muted>
        </div>,
        <div key="r" className="stack">
          <span>
            {p.ready} / {p.desired} ready
          </span>
          <span className="meter" aria-hidden>
            <span style={{ width: `${pct}%` }} />
          </span>
        </div>,
        <span key="a" className="strong">{p.available} available</span>,
        <span key="c">{p.claimed} claimed</span>,
        <Link key="t" className="link" href={hrefs.template(p.namespace, p.template)}>
          {p.template}
        </Link>,
        <span key="u">{p.updateStrategy}</span>,
        <span key="g">{timeAgo(p.createdAt)}</span>,
      ],
    };
  });

  return (
    <Page crumbs={[{ label: "Agent Sandbox" }, { label: "Warm Pools" }]} title="Warm Pools">
      <Errors errors={data.errors} />
      <FilterTable
        placeholder="Filter by pool or template..."
        toolbar={<AutoRefresh fetchedAt={data.fetchedAt} />}
        columns={[
          { label: "Name", width: "22%" },
          { label: "Warm Sandboxes", width: "18%" },
          { label: "Available" },
          { label: "Claimed From Pool" },
          { label: "Template" },
          { label: "Update Strategy" },
          { label: "Age" },
        ]}
        rows={rows}
        empty="No warm pools. Without one, every claim cold-starts a sandbox."
      />
    </Page>
  );
}
