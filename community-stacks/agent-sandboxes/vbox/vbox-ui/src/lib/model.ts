// View models: what the pages render, built by joining the raw CRDs and Pods.
// Pure functions and plain JSON-safe data only, so the results can be handed to
// client components unchanged.
import type { V1Container, V1Pod, V1PodSpec } from "@kubernetes/client-node";
import {
  ANNOTATION_POD_NAME,
  ANNOTATION_TEMPLATE_REF,
  LABEL_CLAIM_UID,
  LABEL_CREATED_BY,
  LABEL_LAUNCH_TYPE,
  type Condition,
  type PersistentVolumeClaimTemplate,
  type Sandbox,
  type SandboxClaim,
  type SandboxTemplate,
  type SandboxWarmPool,
} from "./k8s/types";

// available: still owned by its SandboxWarmPool, waiting for a claim.
// claimed:   ownership moved to a SandboxClaim (warm adoption or cold start).
// standalone: a Sandbox created directly, with no pool or claim behind it.
export type SandboxState = "available" | "claimed" | "standalone";

export type Health = "ready" | "pending" | "suspended" | "finished" | "terminating";

export interface ConditionView {
  type: string;
  status: string;
  reason?: string;
  message?: string;
  lastTransitionTime?: string;
}

export interface ContainerView {
  name: string;
  image: string;
  ports: string[];
  requests: Record<string, string>;
  limits: Record<string, string>;
  env: { name: string; value: string }[];
  runAsNonRoot?: boolean;
  runAsUser?: number;
  readOnlyRootFilesystem?: boolean;
  allowPrivilegeEscalation?: boolean;
  privileged?: boolean;
  capabilitiesDrop: string[];
  capabilitiesAdd: string[];
  volumeMounts: { name: string; mountPath: string; readOnly?: boolean }[];
  ready?: boolean;
  restartCount?: number;
  state?: string;
}

export interface VolumeClaimView {
  name: string;
  storage?: string;
  accessModes: string[];
  storageClassName?: string;
}

export interface PodView {
  name: string;
  phase?: string;
  ready: boolean;
  restarts: number;
  hostIP?: string;
  qosClass?: string;
  startTime?: string;
  deleting: boolean;
}

export interface ClaimRef {
  name: string;
  uid: string;
  createdAt: string;
  ready: boolean;
  reason?: string;
  createdBy?: string;
  shutdownTime?: string;
  shutdownPolicy?: string;
}

// Settings that come from a pod spec, shared by sandboxes and templates.
export interface PodSpecView {
  runtimeClassName?: string;
  automountServiceAccountToken?: boolean;
  podSecurity: {
    runAsNonRoot?: boolean;
    runAsUser?: number;
    runAsGroup?: number;
    fsGroup?: number;
    seccompProfile?: string;
  };
  dnsPolicy?: string;
  nameservers: string[];
  restartPolicy?: string;
  containers: ContainerView[];
  volumeClaimTemplates: VolumeClaimView[];
}

export interface SandboxView extends PodSpecView {
  namespace: string;
  name: string;
  uid: string;
  createdAt: string;
  state: SandboxState;
  health: Health;
  healthReason?: string;
  healthMessage?: string;
  template?: string;
  warmPool?: string;
  launchType?: string;
  createdBy?: string;
  claim?: ClaimRef;
  nodeName?: string;
  podIPs: string[];
  serviceFQDN?: string;
  service?: string;
  operatingMode?: string;
  shutdownTime?: string;
  shutdownPolicy?: string;
  pod?: PodView;
  conditions: ConditionView[];
  labels: Record<string, string>;
  annotations: Record<string, string>;
}

export interface ClaimView {
  namespace: string;
  name: string;
  uid: string;
  createdAt: string;
  deleting: boolean;
  warmPool: string;
  sandbox?: string;
  sandboxExists: boolean;
  ready: boolean;
  reason?: string;
  message?: string;
  createdBy?: string;
  shutdownTime?: string;
  shutdownPolicy?: string;
  ttlSecondsAfterFinished?: number;
  launchType?: string;
  podIPs: string[];
  serviceFQDN?: string;
  env: { name: string; value: string; containerName?: string }[];
  podLabels: Record<string, string>;
  podAnnotations: Record<string, string>;
  volumeClaimTemplates: VolumeClaimView[];
  conditions: ConditionView[];
}

export interface WarmPoolView {
  namespace: string;
  name: string;
  createdAt: string;
  template: string;
  desired: number;
  replicas: number;
  ready: number;
  available: number;
  claimed: number;
  updateStrategy: string;
  selector?: string;
  generation?: number;
  observedGeneration?: number;
}

export interface TemplateView extends PodSpecView {
  namespace: string;
  name: string;
  createdAt: string;
  images: string[];
  limits: Record<string, string>;
  networkPolicyManagement: string;
  customNetworkPolicy: boolean;
  envVarsInjectionPolicy: string;
  volumeClaimTemplatesPolicy: string;
  warmPools: string[];
  sandboxes: number;
  service?: boolean;
}

// Pods whose Sandbox is already gone: typically a released claim whose pod is
// still terminating. Not sandboxes any more, but still holding node resources.
export interface OrphanPodView {
  namespace: string;
  name: string;
  sandbox: string;
  phase?: string;
  deleting: boolean;
  createdBy?: string;
  claimUid?: string;
  createdAt?: string;
}

const iso = (d: Date | string | undefined | null): string | undefined =>
  d == null ? undefined : d instanceof Date ? d.toISOString() : d;

const condition = (conds: Condition[] | undefined, type: string) =>
  conds?.find((c) => c.type === type);

const toConditionViews = (conds: Condition[] | undefined): ConditionView[] =>
  (conds ?? []).map(({ type, status, reason, message, lastTransitionTime }) => ({
    type,
    status,
    reason,
    message,
    lastTransitionTime,
  }));

const stringMap = (m: Record<string, unknown> | undefined): Record<string, string> =>
  Object.fromEntries(Object.entries(m ?? {}).map(([k, v]) => [k, String(v)]));

function controllerOf(meta: { ownerReferences?: { kind: string; name: string; uid: string; controller?: boolean }[] }) {
  return meta.ownerReferences?.find((o) => o.controller) ?? meta.ownerReferences?.[0];
}

function sandboxHealth(sb: Sandbox): Pick<SandboxView, "health" | "healthReason" | "healthMessage"> {
  const conds = sb.status?.conditions;
  if (sb.metadata.deletionTimestamp) return { health: "terminating", healthReason: "Deleting" };
  const finished = condition(conds, "Finished");
  if (finished?.status === "True") {
    return { health: "finished", healthReason: finished.reason, healthMessage: finished.message };
  }
  const suspended = condition(conds, "Suspended");
  if (suspended?.status === "True") {
    return { health: "suspended", healthReason: suspended.reason, healthMessage: suspended.message };
  }
  const ready = condition(conds, "Ready");
  if (ready?.status === "True") return { health: "ready", healthReason: ready.reason };
  return {
    health: "pending",
    healthReason: ready?.reason ?? "Pending",
    healthMessage: ready?.message,
  };
}

function containerView(c: V1Container, pod?: V1Pod): ContainerView {
  const status = pod?.status?.containerStatuses?.find((s) => s.name === c.name);
  const sc = c.securityContext;
  const state = status?.state?.running
    ? "Running"
    : status?.state?.waiting
      ? (status.state.waiting.reason ?? "Waiting")
      : status?.state?.terminated
        ? (status.state.terminated.reason ?? "Terminated")
        : undefined;
  return {
    name: c.name,
    image: c.image ?? "",
    ports: (c.ports ?? []).map((p) => `${p.containerPort}/${p.protocol ?? "TCP"}${p.name ? ` (${p.name})` : ""}`),
    requests: stringMap(c.resources?.requests),
    limits: stringMap(c.resources?.limits),
    env: (c.env ?? []).map((e) => ({
      name: e.name,
      value: e.value ?? (e.valueFrom ? "(from reference)" : ""),
    })),
    runAsNonRoot: sc?.runAsNonRoot,
    runAsUser: sc?.runAsUser,
    readOnlyRootFilesystem: sc?.readOnlyRootFilesystem,
    allowPrivilegeEscalation: sc?.allowPrivilegeEscalation,
    privileged: sc?.privileged,
    capabilitiesDrop: sc?.capabilities?.drop ?? [],
    capabilitiesAdd: sc?.capabilities?.add ?? [],
    volumeMounts: (c.volumeMounts ?? []).map((m) => ({
      name: m.name,
      mountPath: m.mountPath,
      readOnly: m.readOnly,
    })),
    ready: status?.ready,
    restartCount: status?.restartCount,
    state,
  };
}

function podSpecView(
  spec: V1PodSpec | undefined,
  vcts: PersistentVolumeClaimTemplate[] | undefined,
  pod?: V1Pod,
): PodSpecView {
  const psc = spec?.securityContext;
  return {
    runtimeClassName: pod?.spec?.runtimeClassName ?? spec?.runtimeClassName,
    automountServiceAccountToken: spec?.automountServiceAccountToken,
    podSecurity: {
      runAsNonRoot: psc?.runAsNonRoot,
      runAsUser: psc?.runAsUser,
      runAsGroup: psc?.runAsGroup,
      fsGroup: psc?.fsGroup,
      seccompProfile: psc?.seccompProfile?.type,
    },
    dnsPolicy: spec?.dnsPolicy,
    nameservers: spec?.dnsConfig?.nameservers ?? [],
    restartPolicy: spec?.restartPolicy,
    // Prefer the live pod's containers: claims can inject env vars and the
    // controller adds its own, neither of which is on the Sandbox spec.
    containers: (pod?.spec?.containers ?? spec?.containers ?? []).map((c) => containerView(c, pod)),
    volumeClaimTemplates: volumeClaimViews(vcts),
  };
}

function volumeClaimViews(vcts: PersistentVolumeClaimTemplate[] | undefined): VolumeClaimView[] {
  return (vcts ?? []).map((v) => ({
    name: v.metadata?.name ?? "",
    storage: v.spec?.resources?.requests?.storage as string | undefined,
    accessModes: v.spec?.accessModes ?? [],
    storageClassName: v.spec?.storageClassName,
  }));
}

function podView(pod: V1Pod): PodView {
  const statuses = pod.status?.containerStatuses ?? [];
  return {
    name: pod.metadata?.name ?? "",
    phase: pod.status?.phase,
    ready: pod.status?.conditions?.some((c) => c.type === "Ready" && c.status === "True") ?? false,
    restarts: statuses.reduce((n, s) => n + (s.restartCount ?? 0), 0),
    hostIP: pod.status?.hostIP,
    qosClass: pod.status?.qosClass,
    startTime: iso(pod.status?.startTime),
    deleting: Boolean(pod.metadata?.deletionTimestamp),
  };
}

const key = (namespace: string, name: string) => `${namespace}/${name}`;

function podsBySandbox(pods: V1Pod[]): Map<string, V1Pod> {
  const map = new Map<string, V1Pod>();
  for (const pod of pods) {
    const owner = pod.metadata?.ownerReferences?.find((o) => o.kind === "Sandbox");
    if (owner && pod.metadata?.namespace) map.set(key(pod.metadata.namespace, owner.name), pod);
  }
  return map;
}

export interface Snapshot {
  sandboxes: SandboxView[];
  claims: ClaimView[];
  warmPools: WarmPoolView[];
  templates: TemplateView[];
  orphanPods: OrphanPodView[];
}

export function buildSnapshot(input: {
  sandboxes: Sandbox[];
  claims: SandboxClaim[];
  warmPools: SandboxWarmPool[];
  templates: SandboxTemplate[];
  pods: V1Pod[];
}): Snapshot {
  const claimsByUid = new Map(input.claims.map((c) => [c.metadata.uid, c]));
  const claimsByName = new Map(input.claims.map((c) => [key(c.metadata.namespace, c.metadata.name), c]));
  const poolsByName = new Map(input.warmPools.map((p) => [key(p.metadata.namespace, p.metadata.name), p]));
  const pods = podsBySandbox(input.pods);

  const sandboxes: SandboxView[] = input.sandboxes.map((sb) => {
    const meta = sb.metadata;
    const labels = meta.labels ?? {};
    const annotations = meta.annotations ?? {};
    const owner = controllerOf(meta);

    let state: SandboxState = "standalone";
    let claim: SandboxClaim | undefined;
    let warmPool: string | undefined;
    if (owner?.kind === "SandboxWarmPool") {
      state = "available";
      warmPool = owner.name;
    } else if (owner?.kind === "SandboxClaim") {
      state = "claimed";
      claim = claimsByUid.get(owner.uid) ?? claimsByName.get(key(meta.namespace, owner.name));
      warmPool = claim?.spec.warmPoolRef?.name;
    }

    const pool = warmPool ? poolsByName.get(key(meta.namespace, warmPool)) : undefined;
    const template = annotations[ANNOTATION_TEMPLATE_REF] ?? pool?.spec.sandboxTemplateRef.name;

    const podName = annotations[ANNOTATION_POD_NAME] ?? meta.name;
    const pod =
      pods.get(key(meta.namespace, meta.name)) ??
      input.pods.find((p) => p.metadata?.namespace === meta.namespace && p.metadata?.name === podName);

    let claimRef: ClaimRef | undefined;
    if (state === "claimed" && owner) {
      const ready = condition(claim?.status?.conditions, "Ready");
      claimRef = {
        name: owner.name,
        uid: owner.uid,
        createdAt: claim?.metadata.creationTimestamp ?? "",
        ready: ready?.status === "True",
        reason: ready?.reason,
        createdBy: claim?.metadata.labels?.[LABEL_CREATED_BY],
        shutdownTime: claim?.spec.lifecycle?.shutdownTime,
        shutdownPolicy: claim?.spec.lifecycle?.shutdownPolicy,
      };
    }

    return {
      namespace: meta.namespace,
      name: meta.name,
      uid: meta.uid,
      createdAt: meta.creationTimestamp,
      state,
      ...sandboxHealth(sb),
      template,
      warmPool,
      launchType: labels[LABEL_LAUNCH_TYPE],
      createdBy: labels[LABEL_CREATED_BY],
      claim: claimRef,
      nodeName: sb.status?.nodeName ?? pod?.spec?.nodeName,
      podIPs: sb.status?.podIPs ?? (pod?.status?.podIPs ?? []).map((p) => p.ip),
      serviceFQDN: sb.status?.serviceFQDN,
      service: sb.status?.service,
      operatingMode: sb.spec.operatingMode,
      shutdownTime: sb.spec.shutdownTime,
      shutdownPolicy: sb.spec.shutdownPolicy,
      ...podSpecView(sb.spec.podTemplate?.spec, sb.spec.volumeClaimTemplates, pod),
      pod: pod ? podView(pod) : undefined,
      conditions: toConditionViews(sb.status?.conditions),
      labels,
      annotations,
    };
  });

  const sandboxNames = new Set(sandboxes.map((s) => key(s.namespace, s.name)));
  const sandboxByName = new Map(sandboxes.map((s) => [key(s.namespace, s.name), s]));

  const claims: ClaimView[] = input.claims.map((c) => {
    const ready = condition(c.status?.conditions, "Ready");
    const sandbox = c.status?.sandbox?.name;
    return {
      namespace: c.metadata.namespace,
      name: c.metadata.name,
      uid: c.metadata.uid,
      createdAt: c.metadata.creationTimestamp,
      deleting: Boolean(c.metadata.deletionTimestamp),
      warmPool: c.spec.warmPoolRef?.name ?? "",
      sandbox,
      sandboxExists: sandbox ? sandboxNames.has(key(c.metadata.namespace, sandbox)) : false,
      ready: ready?.status === "True",
      reason: ready?.reason,
      message: ready?.message,
      createdBy: c.metadata.labels?.[LABEL_CREATED_BY],
      shutdownTime: c.spec.lifecycle?.shutdownTime,
      shutdownPolicy: c.spec.lifecycle?.shutdownPolicy,
      ttlSecondsAfterFinished: c.spec.lifecycle?.ttlSecondsAfterFinished,
      launchType: sandbox ? sandboxByName.get(key(c.metadata.namespace, sandbox))?.launchType : undefined,
      podIPs: c.status?.sandbox?.podIPs ?? [],
      serviceFQDN: c.status?.sandbox?.serviceFQDN,
      env: c.spec.env ?? [],
      podLabels: c.spec.additionalPodMetadata?.labels ?? {},
      podAnnotations: c.spec.additionalPodMetadata?.annotations ?? {},
      volumeClaimTemplates: volumeClaimViews(c.spec.volumeClaimTemplates),
      conditions: toConditionViews(c.status?.conditions),
    };
  });

  const warmPools: WarmPoolView[] = input.warmPools.map((p) => {
    const ns = p.metadata.namespace;
    const inPool = (s: SandboxView) => s.namespace === ns && s.warmPool === p.metadata.name;
    return {
      namespace: ns,
      name: p.metadata.name,
      createdAt: p.metadata.creationTimestamp,
      template: p.spec.sandboxTemplateRef?.name ?? "",
      desired: p.spec.replicas ?? 0,
      replicas: p.status?.replicas ?? 0,
      ready: p.status?.readyReplicas ?? 0,
      available: sandboxes.filter((s) => inPool(s) && s.state === "available").length,
      claimed: sandboxes.filter((s) => inPool(s) && s.state === "claimed").length,
      updateStrategy: p.spec.updateStrategy?.type ?? "Recreate",
      selector: p.status?.selector,
      generation: p.metadata.generation,
      observedGeneration: p.status?.observedGeneration,
    };
  });

  const templates: TemplateView[] = input.templates.map((t) => {
    const ns = t.metadata.namespace;
    const containers = t.spec.podTemplate?.spec?.containers ?? [];
    return {
      ...podSpecView(t.spec.podTemplate?.spec, t.spec.volumeClaimTemplates),
      namespace: ns,
      name: t.metadata.name,
      createdAt: t.metadata.creationTimestamp,
      images: containers.map((c) => c.image ?? ""),
      service: t.spec.service,
      limits: stringMap(containers[0]?.resources?.limits),
      networkPolicyManagement: t.spec.networkPolicyManagement ?? "Managed",
      customNetworkPolicy: Boolean(t.spec.networkPolicy),
      envVarsInjectionPolicy: t.spec.envVarsInjectionPolicy ?? "Disallowed",
      volumeClaimTemplatesPolicy: t.spec.volumeClaimTemplatesPolicy ?? "Disallowed",
      warmPools: input.warmPools
        .filter((p) => p.metadata.namespace === ns && p.spec.sandboxTemplateRef?.name === t.metadata.name)
        .map((p) => p.metadata.name),
      sandboxes: sandboxes.filter((s) => s.namespace === ns && s.template === t.metadata.name).length,
    };
  });

  const orphanPods: OrphanPodView[] = input.pods.flatMap((pod) => {
    const owner = pod.metadata?.ownerReferences?.find((o) => o.kind === "Sandbox");
    const ns = pod.metadata?.namespace ?? "";
    if (!owner || sandboxNames.has(key(ns, owner.name))) return [];
    return [
      {
        namespace: ns,
        name: pod.metadata?.name ?? "",
        sandbox: owner.name,
        phase: pod.status?.phase,
        deleting: Boolean(pod.metadata?.deletionTimestamp),
        createdBy: pod.metadata?.labels?.[LABEL_CREATED_BY],
        claimUid: pod.metadata?.labels?.[LABEL_CLAIM_UID],
        createdAt: iso(pod.metadata?.creationTimestamp),
      },
    ];
  });

  const byName = <T extends { namespace: string; name: string }>(a: T, b: T) =>
    a.namespace.localeCompare(b.namespace) || a.name.localeCompare(b.name);

  return {
    sandboxes: sandboxes.sort(byName),
    claims: claims.sort(byName),
    warmPools: warmPools.sort(byName),
    templates: templates.sort(byName),
    orphanPods: orphanPods.sort(byName),
  };
}
