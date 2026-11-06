import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Clock, FileCode2, Flame, Layers } from "lucide-react";
import { SandboxesCard } from "@/components/cards";
import { DetailFrame, MetaItem, viewOf } from "@/components/detail";
import { Card, Errors, KeyValues, Page } from "@/components/page";
import { ReadyChip } from "@/components/status";
import { loadDetailExtras, loadSnapshot } from "@/lib/data";
import { dateTime, timeAgo } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";
import type { WarmPoolView } from "@/lib/model";

type Params = { namespace: string; name: string };

export async function generateMetadata({ params }: { params: Promise<Params> }): Promise<Metadata> {
  const { name } = await params;
  return { title: name };
}

const UPDATE: Record<string, string> = {
  Recreate: "Recreate (unclaimed sandboxes are replaced when the template changes)",
  OnReplenish: "OnReplenish (only new sandboxes use the changed template)",
};

function PoolStatus({ p }: { p: WarmPoolView }) {
  const full = p.ready >= p.desired;
  return <ReadyChip ready={full} label={`${p.ready} / ${p.desired} ready`} reason={`${p.ready} / ${p.desired} ready`} />;
}

function PoolCard({ p }: { p: WarmPoolView }) {
  const pct = p.desired > 0 ? Math.min(100, Math.round((p.ready / p.desired) * 100)) : 100;
  return (
    <Card icon={<Flame size={22} strokeWidth={1.75} />} title="Warm Pool">
      <div className="chips">
        <PoolStatus p={p} />
        <span className={`chip ${p.observedGeneration === p.generation ? "chip-green" : "chip-amber"}`}>
          Observed generation: {p.observedGeneration ?? "-"} / {p.generation ?? "-"}
        </span>
      </div>
      <h3>Capacity</h3>
      <KeyValues
        rows={[
          ["Desired", p.desired],
          ["Current", p.replicas],
          [
            "Ready",
            <span key="r" className="with-gap">
              {p.ready}
              <span className="meter" aria-hidden>
                <span style={{ width: `${pct}%` }} />
              </span>
            </span>,
          ],
          ["Available Now", p.available],
          ["Claimed From Pool", p.claimed],
        ]}
      />
      <h3>Basics</h3>
      <KeyValues
        rows={[
          ["Namespace", p.namespace],
          [
            "Template",
            <Link key="t" className="link" href={hrefs.template(p.namespace, p.template)}>
              {p.template}
            </Link>,
          ],
          ["Update Strategy", UPDATE[p.updateStrategy] ?? p.updateStrategy],
          ["Selector", p.selector && <span key="s" className="mono">{p.selector}</span>],
          ["Created", `${dateTime(p.createdAt)} (${timeAgo(p.createdAt)})`],
        ]}
      />
    </Card>
  );
}

export default async function WarmPoolPage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<{ view?: string }>;
}) {
  const { namespace, name } = await params;
  const { view } = await searchParams;
  const data = await loadSnapshot();
  const crumbs = [{ label: "Warm Pools", href: "/warm-pools" }, { label: name }];
  const p = data.warmPools.find((x) => x.namespace === namespace && x.name === name);
  if (!p) {
    if (data.errors.length) {
      return (
        <Page crumbs={crumbs} title={name}>
          <Errors errors={data.errors} />
        </Page>
      );
    }
    notFound();
  }

  const sandboxes = data.sandboxes.filter((s) => s.namespace === namespace && s.warmPool === name);
  const extras = await loadDetailExtras(namespace, {
    objects: [
      { title: "Sandbox Warm Pool", kind: "sandboxwarmpools", name },
      { title: "Sandbox Template", kind: "sandboxtemplates", name: p.template },
    ],
  });

  return (
    <DetailFrame
      crumbs={crumbs}
      title={name}
      base={hrefs.warmPool(namespace, name)}
      view={viewOf(view)}
      fetchedAt={data.fetchedAt}
      errors={[...data.errors, ...extras.errors]}
      detailsTitle="Warm Pool Details"
      yamls={extras.yamls}
      meta={
        <>
          <PoolStatus p={p} />
          <MetaItem icon={<Layers size={18} strokeWidth={1.75} />}>{p.namespace}</MetaItem>
          <MetaItem icon={<Clock size={18} strokeWidth={1.75} />}>{timeAgo(p.createdAt)}</MetaItem>
          <MetaItem icon={<FileCode2 size={18} strokeWidth={1.75} />}>{p.template}</MetaItem>
        </>
      }
    >
      <PoolCard p={p} />
      <SandboxesCard sandboxes={sandboxes} empty="No sandboxes in this pool right now." />
    </DetailFrame>
  );
}
