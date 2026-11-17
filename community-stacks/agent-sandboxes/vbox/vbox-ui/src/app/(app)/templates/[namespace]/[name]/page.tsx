import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Clock, Cpu, FileCode2, Flame, Layers } from "lucide-react";
import {
  ContainersCard,
  NetworkCard,
  PodSettingsCard,
  SandboxesCard,
  SecurityCard,
  StorageCard,
} from "@/components/cards";
import { DetailFrame, MetaItem, viewOf } from "@/components/detail";
import { Card, Errors, KeyValues, Page } from "@/components/page";
import { loadDetailExtras, loadSnapshot } from "@/lib/data";
import { dateTime, timeAgo } from "@/lib/format";
import { hrefs } from "@/lib/hrefs";
import type { TemplateView } from "@/lib/model";
import { isVNode, RuntimeClass, VNodeMark } from "@/components/runtime-class";

type Params = { namespace: string; name: string };

export async function generateMetadata({ params }: { params: Promise<Params> }): Promise<Metadata> {
  const { name } = await params;
  return { title: name };
}

const POLICY: Record<string, string> = {
  Disallowed: "Disallowed (claims cannot change it)",
  Allowed: "Allowed (claims may add, not replace)",
  Overrides: "Overrides (claims may add and replace)",
};

function TemplateCard({ t }: { t: TemplateView }) {
  return (
    <Card icon={<FileCode2 size={22} strokeWidth={1.75} />} title="Sandbox Template">
      <h3>Basics</h3>
      <KeyValues
        rows={[
          ["Namespace", t.namespace],
          ["Image", t.images.map((i) => <div key={i} className="mono">{i}</div>)],
          ["Runtime Class", <RuntimeClass key="rc" name={t.runtimeClassName} fallback="Cluster default" icon={false} />],
          ["Created", `${dateTime(t.createdAt)} (${timeAgo(t.createdAt)})`],
        ]}
      />
      <h3>What Claims May Override</h3>
      <KeyValues
        rows={[
          ["Environment Variables", POLICY[t.envVarsInjectionPolicy] ?? t.envVarsInjectionPolicy],
          ["Volume Claim Templates", POLICY[t.volumeClaimTemplatesPolicy] ?? t.volumeClaimTemplatesPolicy],
        ]}
      />
    </Card>
  );
}

function UsageCard({ t }: { t: TemplateView }) {
  return (
    <Card icon={<Flame size={22} strokeWidth={1.75} />} title={`Warm Pools (${t.warmPools.length})`}>
      {t.warmPools.length === 0 ? (
        <p className="muted">No warm pool uses this template, so every claim on it cold-starts.</p>
      ) : (
        <KeyValues
          rows={t.warmPools.map((p) => [
            p,
            <Link key={p} className="link" href={hrefs.warmPool(t.namespace, p)}>
              View pool
            </Link>,
          ])}
        />
      )}
    </Card>
  );
}

export default async function TemplatePage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<{ view?: string }>;
}) {
  const { namespace, name } = await params;
  const { view } = await searchParams;
  const data = await loadSnapshot();
  const crumbs = [{ label: "Templates", href: "/templates" }, { label: name }];
  const t = data.templates.find((x) => x.namespace === namespace && x.name === name);
  if (!t) {
    if (data.errors.length) {
      return (
        <Page crumbs={crumbs} title={name}>
          <Errors errors={data.errors} />
        </Page>
      );
    }
    notFound();
  }

  const sandboxes = data.sandboxes.filter((s) => s.namespace === namespace && s.template === name);
  const extras = await loadDetailExtras(namespace, {
    objects: [{ title: "Sandbox Template", kind: "sandboxtemplates", name }],
    networkPolicyFor: name,
  });
  if (extras.networkPolicy) {
    extras.yamls.push({ title: `Network Policy ${extras.networkPolicy.name} (managed)`, yaml: extras.networkPolicy.yaml });
  }

  return (
    <DetailFrame
      crumbs={crumbs}
      title={name}
      base={hrefs.template(namespace, name)}
      view={viewOf(view)}
      fetchedAt={data.fetchedAt}
      errors={[...data.errors, ...extras.errors]}
      detailsTitle="Template Details"
      yamls={extras.yamls}
      meta={
        <>
          <MetaItem icon={<Layers size={18} strokeWidth={1.75} />}>{t.namespace}</MetaItem>
          <MetaItem icon={<Clock size={18} strokeWidth={1.75} />}>{timeAgo(t.createdAt)}</MetaItem>
          <MetaItem icon={isVNode(t.runtimeClassName) ? <VNodeMark size={18} /> : <Cpu size={18} strokeWidth={1.75} />}>
            {isVNode(t.runtimeClassName) ? "vNode" : (t.runtimeClassName ?? "default runtime")}
          </MetaItem>
          <MetaItem icon={<Flame size={18} strokeWidth={1.75} />}>
            {t.warmPools.length} warm pool{t.warmPools.length === 1 ? "" : "s"}
          </MetaItem>
        </>
      }
    >
      <TemplateCard t={t} />
      <UsageCard t={t} />
      <PodSettingsCard spec={t} service={t.service} />
      <ContainersCard containers={t.containers} />
      <SecurityCard spec={t} />
      <StorageCard templates={t.volumeClaimTemplates} />
      <NetworkCard template={t} policy={extras.networkPolicy} />
      <SandboxesCard sandboxes={sandboxes} empty="No sandboxes use this template right now." />
    </DetailFrame>
  );
}
