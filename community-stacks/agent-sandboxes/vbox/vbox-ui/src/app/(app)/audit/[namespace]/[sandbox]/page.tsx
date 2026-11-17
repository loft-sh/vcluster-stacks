import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { connection } from "next/server";
import { Clock, History, ShieldCheck, User } from "lucide-react";
import { AutoRefresh } from "@/components/auto-refresh";
import { MetaItem } from "@/components/detail";
import { Card, KeyValues, Muted, Page } from "@/components/page";
import { Timeline } from "@/components/timeline";
import { clientOf, durationText } from "@/lib/audit/labels";
import { getAuditStore } from "@/lib/audit/store";
import { loadSnapshot } from "@/lib/data";
import { dateTime, timeAgo } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";

type Params = { namespace: string; sandbox: string };

export async function generateMetadata({ params }: { params: Promise<Params> }): Promise<Metadata> {
  const { sandbox } = await params;
  return { title: `Audit · ${sandbox}` };
}

const ms = (iso?: string) => (iso ? new Date(iso).getTime() : 0);

async function readSession(namespace: string, sandbox: string) {
  await connection();
  const fetchedAt = new Date().toISOString();
  const store = getAuditStore();
  const session = store.getSession(namespace, sandbox);
  if (!session) return undefined;
  return {
    fetchedAt,
    session,
    events: store.sessionEvents(namespace, sandbox, session.claimUid),
    chain: store.verifyChain(),
    snapshot: await loadSnapshot(),
  };
}

export default async function AuditSessionPage({ params }: { params: Promise<Params> }) {
  const { namespace, sandbox } = await params;
  const data = await readSession(namespace, sandbox);
  if (!data) notFound();
  const { fetchedAt, session: s, events, chain, snapshot } = data;
  const live = snapshot.sandboxes.find((x) => x.namespace === namespace && x.name === sandbox);
  const liveClaim = s.claim ? snapshot.claims.find((c) => c.namespace === namespace && c.name === s.claim) : undefined;
  const client = clientOf(s);
  const end = s.endedAt ?? fetchedAt;
  const exportHref = `/api/audit/${encodeURIComponent(namespace)}/${encodeURIComponent(sandbox)}/export`;

  return (
    <Page
      crumbs={[{ label: "Audit", href: "/audit" }, { label: sandbox }]}
      title={sandbox}
      actions={<AutoRefresh fetchedAt={fetchedAt} />}
    >
      <div className="meta-row">
        {s.endedAt ? <span className="badge badge-gray">Ended</span> : <span className="badge badge-orange">Active</span>}
        <MetaItem icon={<User size={18} strokeWidth={1.75} />}>{client}</MetaItem>
        <MetaItem icon={<Clock size={18} strokeWidth={1.75} />}>Started {timeAgo(s.startedAt)}</MetaItem>
        <MetaItem icon={<History size={18} strokeWidth={1.75} />}>
          {durationText(ms(end) - ms(s.startedAt))}
          {s.endedAt ? "" : " so far"}
        </MetaItem>
      </div>

      <div className="page-stack">
        <Card icon={<User size={22} strokeWidth={1.75} />} title="Session">
          <KeyValues
            rows={[
              ["Client", <span key="c" className="strong">{client}</span>],
              ["User Agent", s.userAgent],
              ["Client IP", s.clientIp && <span key="ip" className="mono">{s.clientIp}</span>],
              [
                "Sandbox",
                live ? (
                  <Link key="s" className="link" href={hrefs.sandbox(namespace, sandbox)}>
                    {sandbox}
                  </Link>
                ) : (
                  `${sandbox} (deleted)`
                ),
              ],
              [
                "Claim",
                s.claim ? (
                  liveClaim ? (
                    <Link key="cl" className="link" href={hrefs.claim(namespace, s.claim)}>
                      {s.claim}
                    </Link>
                  ) : (
                    `${s.claim} (released)`
                  )
                ) : (
                  <Muted key="cl">Not observed: the claim was gone before vBox recorded it</Muted>
                ),
              ],
              ["Warm Pool", s.warmPool],
              ["Start", s.launchType === "warm" ? "Warm (adopted from the pool)" : s.launchType === "cold" ? "Cold" : undefined],
              ["Started", `${dateTime(s.startedAt)} (${timeAgo(s.startedAt)})`],
              ["Ended", s.endedAt ? `${dateTime(s.endedAt)} (${timeAgo(s.endedAt)})` : "Still active"],
              [
                "Steps",
                `${s.steps} (${s.commands} commands, ${s.uploads} uploads, ${s.downloads} downloads${s.errors ? `, ${s.errors} failed` : ""})`,
              ],
            ]}
          />
        </Card>

        <Card
          icon={<History size={22} strokeWidth={1.75} />}
          title="Audit Trail"
          aside={
            <span className={`chip ${chain.ok ? "chip-green" : "chip-amber"}`}>
              <ShieldCheck size={14} />
              {chain.ok ? "Hash chain verified" : `Chain broken at event ${chain.brokenAt}`}
            </span>
          }
        >
          <Timeline events={events} exportHref={exportHref} />
        </Card>
      </div>
    </Page>
  );
}
