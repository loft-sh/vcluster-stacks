import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Box, Clock, Code, FileCode2, Link2, Server } from "lucide-react";
import {
  ConditionsCard,
  ContainersCard,
  NetworkCard,
  PodSettingsCard,
  SecurityCard,
  StorageCard,
} from "@/components/cards";
import { DetailFrame, MetaItem, viewOf } from "@/components/detail";
import { Card, Errors, KeyValues, Muted, Page } from "@/components/page";
import { ConditionChip, HealthChip, ReadyChip, StateBadge } from "@/components/status";
import { loadDetailExtras, loadSnapshot, type ObjectRef } from "@/lib/data";
import { dateTime, timeAgo, timeUntil, yesNo } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";
import type { SandboxView } from "@/lib/model";

type Params = { namespace: string; name: string };

const ICON = { size: 22, strokeWidth: 1.75 };

export async function generateMetadata({ params }: { params: Promise<Params> }): Promise<Metadata> {
  const { name } = await params;
  return { title: name };
}

// The controller sets launch-type=warm when the pool creates the sandbox, not when
// a claim adopts it, so the wording depends on whether it has been claimed yet.
function launchType(s: SandboxView): string | undefined {
  if (s.launchType === "cold") return "Cold (created for the claim)";
  if (s.launchType === "warm") return s.state === "claimed" ? "Warm (adopted from the pool)" : "Warm (waiting in the pool)";
  return s.launchType;
}

function SandboxCard({ s }: { s: SandboxView }) {
  return (
    <Card icon={<Box {...ICON} />} title="Sandbox">
      <div className="chips">
        {s.conditions.map((c) => (
          <ConditionChip key={c.type} c={c} />
        ))}
      </div>
      <h3>Basics</h3>
      <KeyValues
        rows={[
          ["Status", <StateBadge key="s" state={s.state} />],
          [
            "Health",
            <span key="h" className="with-gap">
              <HealthChip health={s.health} reason={s.healthReason} />
              {s.healthMessage && <Muted>{s.healthMessage}</Muted>}
            </span>,
          ],
          ["Namespace", s.namespace],
          [
            "Template",
            s.template && (
              <Link key="t" className="link" href={hrefs.template(s.namespace, s.template)}>
                {s.template}
              </Link>
            ),
          ],
          [
            "Warm Pool",
            s.warmPool && (
              <Link key="p" className="link" href={hrefs.warmPool(s.namespace, s.warmPool)}>
                {s.warmPool}
              </Link>
            ),
          ],
          ["Launch Type", launchType(s)],
          ["Created By", s.createdBy],
          ["Operating Mode", s.operatingMode ?? "Running"],
          ["Shutdown Time", s.shutdownTime ? `${dateTime(s.shutdownTime)} (${timeUntil(s.shutdownTime)})` : "Never"],
          ["Shutdown Policy", s.shutdownPolicy],
          ["Created", `${dateTime(s.createdAt)} (${timeAgo(s.createdAt)})`],
        ]}
      />
    </Card>
  );
}

function ClaimCard({ s }: { s: SandboxView }) {
  const c = s.claim;
  if (!c) {
    return (
      <Card icon={<Link2 {...ICON} />} title="Sandbox Claim">
        <p className="muted">
          {s.state === "available"
            ? `Not claimed. The sandbox is warm in pool ${s.warmPool} and is handed to the next SandboxClaim for that pool.`
            : "Not claimed. This sandbox was created directly, not through a claim."}
        </p>
      </Card>
    );
  }
  return (
    <Card icon={<Link2 {...ICON} />} title="Sandbox Claim">
      <div className="chips">
        <ReadyChip ready={c.ready} reason={c.reason} />
      </div>
      <h3>Basics</h3>
      <KeyValues
        rows={[
          [
            "Claim",
            <Link key="c" className="link" href={hrefs.claim(s.namespace, c.name)}>
              {c.name}
            </Link>,
          ],
          ["Claimed By", c.createdBy],
          ["Claimed", c.createdAt ? `${dateTime(c.createdAt)} (${timeAgo(c.createdAt)})` : undefined],
          ["Shutdown Time", c.shutdownTime ? `${dateTime(c.shutdownTime)} (${timeUntil(c.shutdownTime)})` : "Never"],
          ["Shutdown Policy", c.shutdownPolicy ?? "Delete"],
          ["Claim UID", <span key="u" className="mono">{c.uid}</span>],
          [
            "Audit",
            <Link key="i" className="link" href={hrefs.audit(s.namespace, s.name)}>
              View audit trail
            </Link>,
          ],
        ]}
      />
    </Card>
  );
}

function RuntimeCard({ s }: { s: SandboxView }) {
  return (
    <Card icon={<Server {...ICON} />} title="Runtime">
      <KeyValues
        rows={[
          ["Pod", s.pod ? <span key="p" className="mono">{s.pod.name}</span> : "No pod"],
          ["Pod Phase", s.pod ? `${s.pod.phase ?? "-"}${s.pod.deleting ? " (terminating)" : ""}` : undefined],
          ["Pod Ready", s.pod ? yesNo(s.pod.ready) : undefined],
          ["Restarts", s.pod?.restarts],
          ["Node", s.nodeName],
          ["Pod IPs", s.podIPs.length ? <span key="ip" className="mono">{s.podIPs.join(", ")}</span> : undefined],
          ["Service", s.serviceFQDN ? <span key="svc" className="mono">{s.serviceFQDN}</span> : "None"],
          ["QoS Class", s.pod?.qosClass],
        ]}
      />
    </Card>
  );
}

export default async function SandboxPage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<{ view?: string }>;
}) {
  const { namespace, name } = await params;
  const { view } = await searchParams;
  const data = await loadSnapshot();
  const crumbs = [{ label: "Sandboxes", href: "/sandboxes" }, { label: name }];
  const s = data.sandboxes.find((x) => x.namespace === namespace && x.name === name);
  if (!s) {
    if (data.errors.length) {
      return (
        <Page crumbs={crumbs} title={name}>
          <Errors errors={data.errors} />
        </Page>
      );
    }
    notFound();
  }

  const objects: ObjectRef[] = [{ title: "Sandbox", kind: "sandboxes", name }];
  if (s.claim) objects.push({ title: "Sandbox Claim", kind: "sandboxclaims", name: s.claim.name });
  const extras = await loadDetailExtras(namespace, {
    objects,
    pvcs: { sandbox: name, templates: s.volumeClaimTemplates.map((v) => v.name) },
    networkPolicyFor: s.template,
  });
  const template = data.templates.find((t) => t.namespace === namespace && t.name === s.template);

  return (
    <DetailFrame
      crumbs={crumbs}
      title={name}
      base={hrefs.sandbox(namespace, name)}
      view={viewOf(view)}
      fetchedAt={data.fetchedAt}
      errors={[...data.errors, ...extras.errors]}
      detailsTitle="Sandbox Details"
      yamls={extras.yamls}
      meta={
        <>
          <StateBadge state={s.state} />
          <MetaItem icon={<Code size={18} strokeWidth={1.75} />}>ID: {s.uid}</MetaItem>
          <MetaItem icon={<Clock size={18} strokeWidth={1.75} />}>{timeAgo(s.createdAt)}</MetaItem>
          <MetaItem icon={<FileCode2 size={18} strokeWidth={1.75} />}>{s.template ?? "No template"}</MetaItem>
        </>
      }
    >
      <SandboxCard s={s} />
      <ClaimCard s={s} />
      <RuntimeCard s={s} />
      <PodSettingsCard spec={s} />
      <ContainersCard containers={s.containers} />
      <SecurityCard spec={s} />
      <StorageCard templates={s.volumeClaimTemplates} sandbox={name} pvcs={extras.pvcs} />
      <NetworkCard template={template} policy={extras.networkPolicy} />
      <ConditionsCard conditions={s.conditions} />
    </DetailFrame>
  );
}
