// Server-side data loading. Every page render reads the cluster afresh; nothing is
// cached between requests, so a refresh always shows the API server's state.
import { connection } from "next/server";
import { stringify } from "yaml";
import { getClients, getClusterInfo, type ClusterInfo } from "./k8s/client";
import {
  AGENTS_GROUP,
  API_VERSION,
  EXTENSIONS_GROUP,
  LABEL_SANDBOX_NAME_HASH,
  type List,
  type ObjectMeta,
  type Sandbox,
  type SandboxClaim,
  type SandboxTemplate,
  type SandboxWarmPool,
} from "./k8s/types";
import { buildSnapshot, type Snapshot } from "./model";

export interface LoadError {
  resource: string;
  status?: number;
  message: string;
}

export interface LoadResult extends Snapshot {
  cluster?: ClusterInfo;
  errors: LoadError[];
  fetchedAt: string;
}

function describeError(resource: string, err: unknown): LoadError {
  const e = err as { code?: number; body?: unknown; message?: string };
  let message = e.message ?? String(err);
  if (typeof e.body === "string") {
    try {
      message = (JSON.parse(e.body) as { message?: string }).message ?? message;
    } catch {
      // not JSON, keep the exception message
    }
  }
  if (e.code === 404) {
    message = `The ${resource} API is not served by this cluster. Is the Agent Sandbox controller installed${
      resource.includes("extensions") ? " with controller.extensions enabled" : ""
    }?`;
  }
  return { resource, status: e.code, message };
}

async function listCustom<T>(group: string, plural: string): Promise<T[]> {
  const { custom } = getClients();
  const res = (await custom.listClusterCustomObject({ group, version: API_VERSION, plural })) as List<T>;
  return res.items ?? [];
}

export async function loadSnapshot(): Promise<LoadResult> {
  // Opt out of prerendering: this must run per request, never at build time.
  await connection();
  const fetchedAt = new Date().toISOString();

  let cluster: ClusterInfo;
  try {
    cluster = getClusterInfo();
  } catch (err) {
    return {
      ...buildSnapshot({ sandboxes: [], claims: [], warmPools: [], templates: [], pods: [] }),
      errors: [{ resource: "kubeconfig", message: (err as Error).message }],
      fetchedAt,
    };
  }

  const { core } = getClients();
  const requests = {
    [`sandboxes.${AGENTS_GROUP}`]: listCustom<Sandbox>(AGENTS_GROUP, "sandboxes"),
    [`sandboxclaims.${EXTENSIONS_GROUP}`]: listCustom<SandboxClaim>(EXTENSIONS_GROUP, "sandboxclaims"),
    [`sandboxwarmpools.${EXTENSIONS_GROUP}`]: listCustom<SandboxWarmPool>(EXTENSIONS_GROUP, "sandboxwarmpools"),
    [`sandboxtemplates.${EXTENSIONS_GROUP}`]: listCustom<SandboxTemplate>(EXTENSIONS_GROUP, "sandboxtemplates"),
    // Every sandbox pod carries this label, warm or claimed; it also finds the
    // pods of sandboxes that are already gone.
    pods: core.listPodForAllNamespaces({ labelSelector: LABEL_SANDBOX_NAME_HASH }).then((r) => r.items),
  };
  const names = Object.keys(requests);
  const settled = await Promise.allSettled(Object.values(requests));

  const errors: LoadError[] = [];
  const value = <T,>(i: number): T[] => {
    const r = settled[i];
    if (r.status === "fulfilled") return r.value as T[];
    errors.push(describeError(names[i], r.reason));
    return [];
  };

  const snapshot = buildSnapshot({
    sandboxes: value(0),
    claims: value(1),
    warmPools: value(2),
    templates: value(3),
    pods: value(4),
  });

  return { ...snapshot, cluster, errors, fetchedAt };
}

interface NetworkPolicy {
  metadata: ObjectMeta;
  spec?: { podSelector?: unknown; policyTypes?: string[]; ingress?: unknown[]; egress?: unknown[] };
}

export interface PvcView {
  name: string;
  phase?: string;
  capacity?: string;
  storageClassName?: string;
  volumeName?: string;
  deleting: boolean;
}

export interface NetworkPolicyView {
  name: string;
  yaml: string;
}

export interface YamlView {
  title: string;
  yaml: string;
}

// One Agent Sandbox object to show under a detail page's Config view.
export interface ObjectRef {
  title: string;
  kind: "sandboxes" | "sandboxclaims" | "sandboxwarmpools" | "sandboxtemplates";
  name: string;
}

export interface DetailExtras {
  yamls: YamlView[];
  pvcs: PvcView[];
  networkPolicy?: NetworkPolicyView;
  errors: LoadError[];
}

const GROUP_OF: Record<ObjectRef["kind"], string> = {
  sandboxes: AGENTS_GROUP,
  sandboxclaims: EXTENSIONS_GROUP,
  sandboxwarmpools: EXTENSIONS_GROUP,
  sandboxtemplates: EXTENSIONS_GROUP,
};

// Server-written bookkeeping that only adds noise to a YAML view.
function clean<T extends { metadata?: ObjectMeta | Record<string, unknown> }>(obj: T): T {
  const copy = structuredClone(obj);
  const meta = copy.metadata as Record<string, unknown> | undefined;
  if (meta) delete meta.managedFields;
  return copy;
}

const toYaml = (obj: unknown) => stringify(obj, { lineWidth: 0 });

// Detail page extras, all in one namespace: the raw objects as YAML (each fetched
// individually so the Config view shows exactly what the API server holds), the
// workspace PVCs of a sandbox, and the NetworkPolicy the controller manages for a
// template.
export async function loadDetailExtras(
  namespace: string,
  opts: {
    objects: ObjectRef[];
    // Workspace PVCs are named <volumeClaimTemplate>-<sandbox>.
    pvcs?: { sandbox: string; templates: string[] };
    networkPolicyFor?: string;
  },
): Promise<DetailExtras> {
  const { custom, core } = getClients();
  const errors: LoadError[] = [];
  const out: DetailExtras = { yamls: [], pvcs: [], errors };

  const [objects, pvcs, policies] = await Promise.all([
    Promise.allSettled(
      opts.objects.map((o) =>
        custom.getNamespacedCustomObject({
          group: GROUP_OF[o.kind],
          version: API_VERSION,
          namespace,
          plural: o.kind,
          name: o.name,
        }),
      ),
    ),
    opts.pvcs
      ? core.listNamespacedPersistentVolumeClaim({ namespace }).then(
          (r) => ({ ok: true as const, items: r.items }),
          (err: unknown) => ({ ok: false as const, err }),
        )
      : undefined,
    opts.networkPolicyFor
      ? // Through the custom objects path on purpose: it returns wire JSON, whereas the
        // typed NetworkingV1Api renames fields (from -> _from) and would corrupt the YAML.
        custom
          .listNamespacedCustomObject({ group: "networking.k8s.io", version: "v1", namespace, plural: "networkpolicies" })
          .then(
            (r) => ({ ok: true as const, items: (r as List<NetworkPolicy>).items }),
            (err: unknown) => ({ ok: false as const, err }),
          )
      : undefined,
  ]);

  objects.forEach((r, i) => {
    const ref = opts.objects[i];
    if (r.status === "fulfilled") out.yamls.push({ title: ref.title, yaml: toYaml(clean(r.value as Sandbox)) });
    else errors.push(describeError(`${ref.kind}/${ref.name}`, r.reason));
  });

  if (pvcs?.ok && opts.pvcs) {
    const wanted = new Set(opts.pvcs.templates.map((v) => `${v}-${opts.pvcs!.sandbox}`));
    out.pvcs = pvcs.items
      .filter((p) => wanted.has(p.metadata?.name ?? ""))
      .map((p) => ({
        name: p.metadata?.name ?? "",
        phase: p.status?.phase,
        capacity: p.status?.capacity?.storage,
        storageClassName: p.spec?.storageClassName,
        volumeName: p.spec?.volumeName,
        deleting: Boolean(p.metadata?.deletionTimestamp),
      }));
  } else if (pvcs && !pvcs.ok) errors.push(describeError("persistentvolumeclaims", pvcs.err));

  if (policies?.ok) {
    const np = policies.items.find((p) =>
      p.metadata?.ownerReferences?.some((o) => o.kind === "SandboxTemplate" && o.name === opts.networkPolicyFor),
    );
    if (np) {
      const { metadata, spec } = np;
      out.networkPolicy = {
        name: metadata.name,
        yaml: toYaml({ podSelector: spec?.podSelector, policyTypes: spec?.policyTypes, ingress: spec?.ingress, egress: spec?.egress }),
      };
    }
  } else if (policies && !policies.ok) errors.push(describeError("networkpolicies", policies.err));

  return out;
}
