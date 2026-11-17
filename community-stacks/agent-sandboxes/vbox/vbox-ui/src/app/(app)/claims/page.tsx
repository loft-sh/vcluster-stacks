import type { Metadata } from "next";
import Link from "next/link";
import { AutoRefresh } from "@/components/auto-refresh";
import { FilterTable, type FilterRow } from "@/components/filter-table";
import { Errors, Muted, Page } from "@/components/page";
import { ReadyChip } from "@/components/status";
import { loadSnapshot } from "@/lib/data";
import { hrefs } from "@/lib/hrefs";
import { timeAgo, timeUntil } from "@/lib/format";

export const metadata: Metadata = { title: "Claims" };

export default async function ClaimsPage() {
  const data = await loadSnapshot();

  const rows: FilterRow[] = data.claims.map((c) => ({
    key: c.uid,
    namespace: c.namespace,
    state: c.deleting ? "deleting" : c.ready ? "ready" : "pending",
    search: [c.name, c.namespace, c.sandbox, c.warmPool, c.createdBy].filter(Boolean).join(" ").toLowerCase(),
    cells: [
      <div key="n" className="stack">
        <Link className="row-link" href={hrefs.claim(c.namespace, c.name)}>
          {c.name}
        </Link>
        <Muted>{c.namespace}</Muted>
      </div>,
      c.deleting ? (
        <span key="r" className="chip chip-gray">Deleting</span>
      ) : (
        <ReadyChip key="r" ready={c.ready} reason={c.reason} />
      ),
      c.sandbox && c.sandboxExists ? (
        <div key="s" className="stack">
          <Link className="link" href={hrefs.sandbox(c.namespace, c.sandbox)}>
            {c.sandbox}
          </Link>
          <Muted>{c.launchType === "warm" ? "Warm start" : c.launchType === "cold" ? "Cold start" : ""}</Muted>
        </div>
      ) : (
        <Muted key="s">{c.sandbox ?? "Not assigned yet"}</Muted>
      ),
      c.warmPool ? (
        <Link key="p" className="link" href={hrefs.warmPool(c.namespace, c.warmPool)}>
          {c.warmPool}
        </Link>
      ) : (
        <Muted key="p">-</Muted>
      ),
      <span key="b">{c.createdBy ?? "-"}</span>,
      <div key="l" className="stack">
        <span>{c.shutdownTime ? timeUntil(c.shutdownTime) : "No shutdown time"}</span>
        <Muted>{c.shutdownPolicy ?? "Delete"}</Muted>
      </div>,
      <span key="a">{timeAgo(c.createdAt)}</span>,
    ],
  }));

  return (
    <Page crumbs={[{ label: "Agent Sandbox" }, { label: "Claims" }]} title="Sandbox Claims">
      <Errors errors={data.errors} />
      <FilterTable
        placeholder="Filter by claim, sandbox or creator..."
        stateOptions={[
          { value: "ready", label: "Ready" },
          { value: "pending", label: "Pending" },
          { value: "deleting", label: "Deleting" },
        ]}
        stateLabel="Any status"
        toolbar={<AutoRefresh fetchedAt={data.fetchedAt} />}
        columns={[
          { label: "Name", width: "22%" },
          { label: "Status" },
          { label: "Sandbox" },
          { label: "Warm Pool" },
          { label: "Created By" },
          { label: "Shutdown" },
          { label: "Age" },
        ]}
        rows={rows}
        empty="No sandbox claims. Agents create one per session, through the SDK or kubectl."
      />
    </Page>
  );
}
