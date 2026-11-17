import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Box, Clock, Code, Flame, Link2, Tags } from "lucide-react";
import { ConditionsCard, EnvTable, StorageCard } from "@/components/cards";
import { DetailFrame, MetaItem, viewOf } from "@/components/detail";
import { Card, Errors, KeyValues, Muted, Page } from "@/components/page";
import { ConditionChip, HealthChip, ReadyChip, StateBadge } from "@/components/status";
import { loadDetailExtras, loadSnapshot, type ObjectRef } from "@/lib/data";
import { dateTime, timeAgo, timeUntil } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";
import type { ClaimView, SandboxView } from "@/lib/model";
import { RuntimeClass } from "@/components/runtime-class";

type Params = { namespace: string; name: string };

const ICON = { size: 22, strokeWidth: 1.75 };

export async function generateMetadata({ params }: { params: Promise<Params> }): Promise<Metadata> {
  const { name } = await params;
  return { title: name };
}

function ClaimStatus({ c }: { c: ClaimView }) {
  return c.deleting ? <span className="chip chip-gray">Deleting</span> : <ReadyChip ready={c.ready} reason={c.reason} />;
}

function ClaimCard({ c }: { c: ClaimView }) {
  return (
    <Card icon={<Link2 {...ICON} />} title="Sandbox Claim">
      <div className="chips">
        {c.conditions.map((x) => (
          <ConditionChip key={x.type} c={x} />
        ))}
      </div>
      <h3>Basics</h3>
      <KeyValues
        rows={[
          ["Status", <span key="s" className="with-gap"><ClaimStatus c={c} />{c.message && <Muted>{c.message}</Muted>}</span>],
          ["Namespace", c.namespace],
          [
            "Warm Pool",
            c.warmPool && (
              <Link key="p" className="link" href={hrefs.warmPool(c.namespace, c.warmPool)}>
                {c.warmPool}
              </Link>
            ),
          ],
          ["Start", c.launchType === "warm" ? "Warm (adopted from the pool)" : c.launchType === "cold" ? "Cold (created for the claim)" : undefined],
          ["Created By", c.createdBy],
          ["Created", `${dateTime(c.createdAt)} (${timeAgo(c.createdAt)})`],
        ]}
      />
      <h3>Lifecycle</h3>
      <KeyValues
        rows={[
          ["Shutdown Time", c.shutdownTime ? `${dateTime(c.shutdownTime)} (${timeUntil(c.shutdownTime)})` : "Never"],
          ["Shutdown Policy", c.shutdownPolicy ?? "Delete"],
          ["TTL After Finished", c.ttlSecondsAfterFinished !== undefined ? `${c.ttlSecondsAfterFinished}s` : "None"],
        ]}
      />
    </Card>
  );
}

function AssignedSandboxCard({ c, s }: { c: ClaimView; s?: SandboxView }) {
  return (
    <Card icon={<Box {...ICON} />} title="Assigned Sandbox">
      {!c.sandbox ? (
        <p className="muted">No sandbox assigned yet. The controller adopts one from the pool or cold-starts one.</p>
      ) : (
        <KeyValues
          rows={[
            [
              "Sandbox",
              s ? (
                <Link key="s" className="link" href={hrefs.sandbox(c.namespace, c.sandbox)}>
                  {c.sandbox}
                </Link>
              ) : (
                `${c.sandbox} (no longer exists)`
              ),
            ],
            ["Status", s && <StateBadge key="st" state={s.state} />],
            ["Health", s && <HealthChip key="h" health={s.health} reason={s.healthReason} />],
            ["Template", s?.template && (
              <Link key="t" className="link" href={hrefs.template(c.namespace, s.template)}>
                {s.template}
              </Link>
            )],
            ["Node", s?.nodeName],
            ["Pod IPs", c.podIPs.length ? <span key="ip" className="mono">{c.podIPs.join(", ")}</span> : undefined],
            ["Service", c.serviceFQDN ? <span key="svc" className="mono">{c.serviceFQDN}</span> : "None"],
            ["Runtime Class", s?.runtimeClassName && <RuntimeClass key="rc" name={s.runtimeClassName} fallback="" icon={false} />],
          ]}
        />
      )}
    </Card>
  );
}

function OverridesCard({ c }: { c: ClaimView }) {
  const labels = Object.entries(c.podLabels);
  const annotations = Object.entries(c.podAnnotations);
  if (!c.env.length && !labels.length && !annotations.length) {
    return (
      <Card icon={<Tags {...ICON} />} title="Claim Overrides">
        <p className="muted">None. The sandbox runs exactly as its template defines it.</p>
      </Card>
    );
  }
  return (
    <Card icon={<Tags {...ICON} />} title="Claim Overrides">
      {c.env.length > 0 && <EnvTable env={c.env} title="Injected Environment" />}
      {labels.length > 0 && <EnvTable env={labels.map(([name, value]) => ({ name, value }))} title="Pod Labels" />}
      {annotations.length > 0 && (
        <EnvTable env={annotations.map(([name, value]) => ({ name, value }))} title="Pod Annotations" />
      )}
    </Card>
  );
}

export default async function ClaimPage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<{ view?: string }>;
}) {
  const { namespace, name } = await params;
  const { view } = await searchParams;
  const data = await loadSnapshot();
  const crumbs = [{ label: "Claims", href: "/claims" }, { label: name }];
  const c = data.claims.find((x) => x.namespace === namespace && x.name === name);
  if (!c) {
    if (data.errors.length) {
      return (
        <Page crumbs={crumbs} title={name}>
          <Errors errors={data.errors} />
        </Page>
      );
    }
    notFound();
  }

  const sandbox = c.sandbox ? data.sandboxes.find((s) => s.namespace === namespace && s.name === c.sandbox) : undefined;
  const objects: ObjectRef[] = [{ title: "Sandbox Claim", kind: "sandboxclaims", name }];
  if (sandbox) objects.push({ title: "Sandbox", kind: "sandboxes", name: sandbox.name });
  const extras = await loadDetailExtras(namespace, { objects });

  return (
    <DetailFrame
      crumbs={crumbs}
      title={name}
      base={hrefs.claim(namespace, name)}
      view={viewOf(view)}
      fetchedAt={data.fetchedAt}
      errors={[...data.errors, ...extras.errors]}
      detailsTitle="Claim Details"
      yamls={extras.yamls}
      meta={
        <>
          <ClaimStatus c={c} />
          <MetaItem icon={<Code size={18} strokeWidth={1.75} />}>ID: {c.uid}</MetaItem>
          <MetaItem icon={<Clock size={18} strokeWidth={1.75} />}>{timeAgo(c.createdAt)}</MetaItem>
          <MetaItem icon={<Flame size={18} strokeWidth={1.75} />}>{c.warmPool || "No warm pool"}</MetaItem>
        </>
      }
    >
      <ClaimCard c={c} />
      <AssignedSandboxCard c={c} s={sandbox} />
      <OverridesCard c={c} />
      <StorageCard templates={c.volumeClaimTemplates} />
      <ConditionsCard conditions={c.conditions} />
    </DetailFrame>
  );
}
