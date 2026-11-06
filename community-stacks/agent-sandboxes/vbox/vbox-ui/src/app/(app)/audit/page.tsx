import type { Metadata } from "next";
import Link from "next/link";
import { connection } from "next/server";
import { AutoRefresh } from "@/components/auto-refresh";
import { FilterTable, type FilterRow } from "@/components/filter-table";
import { Errors, Muted, Page } from "@/components/page";
import { clientOf, durationText } from "@/lib/audit/labels";
import { getAuditStore, type SessionSummary } from "@/lib/audit/store";
import { dateTime, timeAgo } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";

export const metadata: Metadata = { title: "Audit" };

const ms = (iso?: string) => (iso ? new Date(iso).getTime() : 0);

async function readAudit() {
  await connection();
  const fetchedAt = new Date().toISOString();
  try {
    const store = getAuditStore();
    return {
      fetchedAt,
      sessions: store.listSessions(),
      error: undefined,
    };
  } catch (err) {
    return {
      fetchedAt,
      sessions: [] as SessionSummary[],
      error: (err as Error).message,
    };
  }
}

export default async function AuditPage() {
  const { fetchedAt, sessions, error } = await readAudit();
  const now = ms(fetchedAt);

  const clients = [...new Set(sessions.map(clientOf))].sort();

  const rows: FilterRow[] = sessions.map((s) => {
    const client = clientOf(s);
    // An ended session runs to its end; an active one up to now.
    const duration = (s.endedAt ? ms(s.endedAt) : now) - ms(s.startedAt);
    return {
      key: `${s.namespace}/${s.sandbox}`,
      namespace: s.namespace,
      state: client,
      search: [client, s.userAgent, s.clientIp, s.sandbox, s.claim, s.namespace].filter(Boolean).join(" ").toLowerCase(),
      sort: {
        client: client.toLowerCase(),
        created: ms(s.startedAt),
        duration,
        steps: s.steps,
      },
      cells: [
        <div key="c" className="stack">
          <span className="strong">{client}</span>
          <Muted>{[s.client && s.userAgent, s.clientIp].filter(Boolean).join(" · ") || "-"}</Muted>
        </div>,
        <div key="s" className="stack">
          <Link className="row-link" href={hrefs.audit(s.namespace, s.sandbox)}>
            {s.sandbox}
          </Link>
          <Muted>{s.namespace}</Muted>
        </div>,
        <div key="cl" className="stack">
          <span>{s.claim ?? "-"}</span>
          <Muted>
            {s.claim ? [s.warmPool, s.launchType && `${s.launchType} start`].filter(Boolean).join(" · ") : "Claim not observed"}
          </Muted>
        </div>,
        <div key="cr" className="stack">
          <span>{timeAgo(s.startedAt)}</span>
          <Muted>{dateTime(s.startedAt)}</Muted>
        </div>,
        <div key="d" className="stack">
          <span>{durationText(duration)}</span>
          {s.endedAt ? <Muted>Ended</Muted> : <span className="badge badge-orange">Active</span>}
        </div>,
        <span key="n">
          {s.steps}
          {s.errors > 0 && <span className="chip chip-amber chip-inline">{s.errors} failed</span>}
        </span>,
      ],
    };
  });

  return (
    <Page crumbs={[{ label: "Agent Sandbox" }, { label: "Audit" }]} title="Audit">
      {error && <Errors errors={[{ resource: "audit store", message: error }]} />}
      <FilterTable
        placeholder="Filter by client, sandbox, claim or IP..."
        stateOptions={clients.map((c) => ({ value: c, label: c }))}
        stateLabel="Any client"
        defaultSort={{ key: "created", dir: "desc" }}
        sortOptions={[
          { key: "created", dir: "desc", label: "Newest first" },
          { key: "created", dir: "asc", label: "Oldest first" },
          { key: "client", dir: "asc", label: "Client A-Z" },
          { key: "client", dir: "desc", label: "Client Z-A" },
          { key: "duration", dir: "desc", label: "Longest session" },
          { key: "steps", dir: "desc", label: "Most steps" },
        ]}
        toolbar={<AutoRefresh fetchedAt={fetchedAt} />}
        columns={[
          { label: "Client", sortKey: "client", width: "20%" },
          { label: "Sandbox", width: "20%" },
          { label: "Claim" },
          { label: "Created", sortKey: "created" },
          { label: "Session Duration", sortKey: "duration" },
          { label: "Steps", sortKey: "steps" },
        ]}
        rows={rows}
        empty="No sessions recorded yet. A session appears here as soon as a client claims a sandbox or calls it through the Sandbox Router."
      />
    </Page>
  );
}
