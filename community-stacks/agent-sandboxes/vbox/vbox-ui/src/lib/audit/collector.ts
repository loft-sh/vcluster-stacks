// Background collector that records client interactions with sandboxes into the
// audit trail. Started once per server process from src/instrumentation.ts.
//
// Two sources, each mapped to events on one session (= one claimed sandbox):
//
// 1. Claim lifecycle, by polling SandboxClaims: created (with the client from the
//    agents.x-k8s.io/created-by label), sandbox assigned (warm or cold), ready,
//    released. Polling and diffing rather than a watch, because every transition is
//    recorded under a dedup key, so a missed poll or a restart cannot lose or
//    double-record one.
// 2. Steps, from the Sandbox Router's access log: one structured JSON line per
//    client request (method, path, status, duration, client IP, user agent,
//    sandbox_id). The router outlives the sandboxes, so this also covers sessions
//    whose sandbox is already gone when the collector catches up.
import { getClients } from "../k8s/client";
import { openLogStream } from "../k8s/logs";
import {
  EXTENSIONS_GROUP,
  API_VERSION,
  LABEL_CREATED_BY,
  LABEL_LAUNCH_TYPE,
  type List,
  type SandboxClaim,
} from "../k8s/types";
import { getAuditStore, normalizeTs, type AuditStore } from "./store";

const CLAIM_POLL_MS = 3000;
const ROUTER_POLL_MS = 30000;
const RETRY_MS = 5000;

const ROUTER_NAMESPACE = process.env.VBOX_ROUTER_NAMESPACE ?? "agent-sandbox-system";
const ROUTER_SELECTOR = process.env.VBOX_ROUTER_SELECTOR ?? "app.kubernetes.io/name=sandbox-router";

const log = (...args: unknown[]) => console.log("[vbox audit]", ...args);

interface ClaimInfo {
  namespace: string;
  name: string;
  uid: string;
  client?: string;
}

class Collector {
  private store: AuditStore;
  private stopped = false;
  private followers = new Map<string, AbortController>();
  // Sandbox -> claim, from the latest claim poll; used to attribute router events
  // to a claim and client.
  private claimBySandbox = new Map<string, ClaimInfo>();

  constructor() {
    this.store = getAuditStore();
  }

  start() {
    log(`recording to ${this.store.file}`);
    this.loop("claims", CLAIM_POLL_MS, () => this.pollClaims());
    this.loop("router pods", ROUTER_POLL_MS, () => this.pollRouterPods());
  }

  private loop(name: string, interval: number, fn: () => Promise<void>) {
    let failing = false;
    const tick = async () => {
      if (this.stopped) return;
      try {
        await fn();
        if (failing) log(`${name}: recovered`);
        failing = false;
      } catch (err) {
        if (!failing) log(`${name}: ${(err as Error).message}`);
        failing = true;
      }
      setTimeout(tick, interval);
    };
    void tick();
  }

  // ---------- 1. claim lifecycle ----------

  private async pollClaims() {
    const { custom } = getClients();
    const res = (await custom.listClusterCustomObject({
      group: EXTENSIONS_GROUP,
      version: API_VERSION,
      plural: "sandboxclaims",
    })) as List<SandboxClaim>;

    const live = new Set<string>();
    const bySandbox = new Map<string, ClaimInfo>();

    for (const c of res.items) {
      const { namespace, name, uid, creationTimestamp } = c.metadata;
      const client = c.metadata.labels?.[LABEL_CREATED_BY];
      const base = { namespace, claim: name, claimUid: uid, client, source: "k8s/sandboxclaims" };
      live.add(uid);

      this.store.append({
        ...base,
        ts: creationTimestamp,
        kind: "lifecycle",
        action: "claim.created",
        message: `${client ?? "A client"} claimed a sandbox from pool ${c.spec.warmPoolRef?.name}`,
        detail: { warmPool: c.spec.warmPoolRef?.name, lifecycle: c.spec.lifecycle },
        dedup: `claim.created/${uid}`,
      });

      // Conditions can carry an earlier time than the claim itself (a warm sandbox
      // was ready long before it was claimed), so nothing is dated before the claim.
      const ready = c.status?.conditions?.find((x) => x.type === "Ready");
      const notBeforeClaim = (ts?: string) =>
        ts && Date.parse(ts) > Date.parse(creationTimestamp) ? ts : creationTimestamp;
      const readyTs = ready?.status === "True" ? notBeforeClaim(ready.lastTransitionTime) : undefined;

      const sandbox = c.status?.sandbox?.name;
      if (sandbox) {
        bySandbox.set(`${namespace}/${sandbox}`, { namespace, name, uid, client });
        if (!this.store.hasEvent(`claim.assigned/${uid}`)) {
          // Looked up once, when the assignment is first seen.
          const launchType = await this.launchTypeOf(namespace, sandbox);
          this.store.upsertSession({
            namespace,
            sandbox,
            claim: name,
            claimUid: uid,
            client,
            warmPool: c.spec.warmPoolRef?.name,
            launchType,
            startedAt: creationTimestamp,
          });
          this.store.append({
            ...base,
            sandbox,
            // The claim records no assignment time; becoming ready is the closest
            // it has. Otherwise, when vBox first saw it.
            ts: readyTs ?? new Date().toISOString(),
            kind: "lifecycle",
            action: "claim.assigned",
            message:
              launchType === "warm"
                ? `Sandbox ${sandbox} adopted from the warm pool`
                : launchType === "cold"
                  ? `Sandbox ${sandbox} cold-started for the claim`
                  : `Sandbox ${sandbox} assigned`,
            detail: { launchType, podIPs: c.status?.sandbox?.podIPs, serviceFQDN: c.status?.sandbox?.serviceFQDN },
            dedup: `claim.assigned/${uid}`,
          });
        }
      }

      if (readyTs) {
        this.store.append({
          ...base,
          sandbox,
          ts: readyTs,
          kind: "lifecycle",
          action: "claim.ready",
          message: "Sandbox ready for the client",
          dedup: `claim.ready/${uid}`,
        });
      }
      if (c.metadata.deletionTimestamp) {
        this.store.append({
          ...base,
          sandbox,
          ts: c.metadata.deletionTimestamp,
          kind: "lifecycle",
          action: "claim.releasing",
          message: "Claim deletion requested",
          dedup: `claim.releasing/${uid}`,
        });
      }
    }

    this.claimBySandbox = bySandbox;

    const open = this.store.openSessions();
    const unclaimed = open.filter((s) => !s.claimUid);
    if (unclaimed.length) await this.closeVanishedSandboxes(unclaimed);

    // Sessions whose claim is gone: the client released the sandbox (or it expired).
    for (const s of open) {
      if (!s.claimUid || live.has(s.claimUid)) continue;
      const ts = new Date().toISOString();
      this.store.append({
        ts,
        namespace: s.namespace,
        sandbox: s.sandbox,
        claim: s.claim,
        claimUid: s.claimUid,
        kind: "lifecycle",
        action: "claim.released",
        message: "Claim deleted; the sandbox is released",
        source: "k8s/sandboxclaims",
        dedup: `claim.released/${s.claimUid}`,
      });
      this.store.endSession(s.namespace, s.sandbox, ts);
    }
  }

  // Sessions known only from the router log (their claim was gone before vBox saw
  // it, or there never was one) end when their sandbox no longer exists. The end
  // is set to the last recorded activity: the real release time is unknown.
  private async closeVanishedSandboxes(sessions: { namespace: string; sandbox: string }[]) {
    const { custom } = getClients();
    const res = (await custom.listClusterCustomObject({
      group: "agents.x-k8s.io",
      version: API_VERSION,
      plural: "sandboxes",
    })) as List<{ metadata: { namespace: string; name: string } }>;
    const existing = new Set(res.items.map((i) => `${i.metadata.namespace}/${i.metadata.name}`));
    for (const s of sessions) {
      if (existing.has(`${s.namespace}/${s.sandbox}`)) continue;
      const lastActivity = this.store.getSession(s.namespace, s.sandbox)?.lastActivity ?? new Date().toISOString();
      this.store.append({
        ts: new Date().toISOString(),
        namespace: s.namespace,
        sandbox: s.sandbox,
        kind: "lifecycle",
        action: "sandbox.gone",
        message: "The sandbox no longer exists; vBox did not observe its release, so the session ends at its last activity",
        detail: { lastActivity },
        source: "k8s/sandboxes",
        dedup: `sandbox.gone/${s.namespace}/${s.sandbox}`,
      });
      this.store.endSession(s.namespace, s.sandbox, lastActivity);
    }
  }

  private async launchTypeOf(namespace: string, sandbox: string): Promise<string | undefined> {
    try {
      const { custom } = getClients();
      const sb = (await custom.getNamespacedCustomObject({
        group: "agents.x-k8s.io",
        version: API_VERSION,
        namespace,
        plural: "sandboxes",
        name: sandbox,
      })) as { metadata: { labels?: Record<string, string> } };
      return sb.metadata.labels?.[LABEL_LAUNCH_TYPE];
    } catch {
      return undefined;
    }
  }

  // ---------- 2. router access log ----------

  private async pollRouterPods() {
    const { core } = getClients();
    const pods = await core.listNamespacedPod({ namespace: ROUTER_NAMESPACE, labelSelector: ROUTER_SELECTOR });
    for (const pod of pods.items) {
      const name = pod.metadata?.name;
      const container = pod.spec?.containers[0]?.name;
      if (!name || !container || pod.status?.phase !== "Running") continue;
      const source = `router/${name}`;
      this.follow(source, ROUTER_NAMESPACE, name, container, (line) => this.onRouterLine(source, line));
    }
  }

  private onRouterLine(source: string, line: string) {
    // With timestamps=true the kubelet prefixes each line with its own timestamp.
    const sp = line.indexOf(" ");
    const kubeletTs = line.slice(0, sp);
    const json = line.slice(sp + 1);
    if (!json.startsWith("{")) return;
    let r: Record<string, unknown>;
    try {
      r = JSON.parse(json);
    } catch {
      return;
    }
    if (r.msg !== "request" || typeof r.sandbox_id !== "string" || typeof r.sandbox_namespace !== "string") return;

    const namespace = r.sandbox_namespace;
    const sandbox = r.sandbox_id;
    const claim = this.claimBySandbox.get(`${namespace}/${sandbox}`);
    const ts = kubeletTs || String(r.ts);
    const userAgent = typeof r.user_agent === "string" ? r.user_agent : undefined;
    const clientIp = typeof r.client_ip === "string" ? r.client_ip : undefined;

    this.store.upsertSession({
      namespace,
      sandbox,
      claim: claim?.name,
      claimUid: claim?.uid,
      client: claim?.client,
      userAgent,
      clientIp,
      startedAt: ts,
    });
    this.store.append({
      ts,
      namespace,
      sandbox,
      claim: claim?.name,
      claimUid: claim?.uid,
      client: claim?.client ?? userAgent,
      kind: "request",
      action: `${r.method} ${r.path}`,
      status: typeof r.status === "number" ? r.status : undefined,
      durationMs: typeof r.duration_ms === "number" ? r.duration_ms : undefined,
      detail: { clientIp, userAgent, bytesOut: r.bytes_out },
      source,
      // The kubelet timestamp has nanoseconds, so two requests in one second differ.
      dedup: `${source}/${ts}/${json.length}`,
    });
    this.store.setCursor(source, ts);
  }

  // ---------- log following ----------

  private follow(
    source: string,
    namespace: string,
    pod: string,
    container: string,
    onLine: (line: string) => void,
  ) {
    if (this.followers.has(source)) return;
    const ctrl = new AbortController();
    this.followers.set(source, ctrl);

    const run = async () => {
      while (!ctrl.signal.aborted && !this.stopped) {
        try {
          const since = this.store.getCursor(source);
          const body = await openLogStream(
            namespace,
            pod,
            container,
            // Resume a little before the cursor: the dedup key absorbs the overlap.
            { timestamps: true, follow: true, sinceTime: since ? sinceRfc3339(since) : undefined },
            ctrl.signal,
          );
          const reader = body.getReader();
          const decoder = new TextDecoder();
          let partial = "";
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            const parts = (partial + decoder.decode(value, { stream: true })).split("\n");
            partial = parts.pop() ?? "";
            for (const p of parts) if (p) onLine(p);
          }
          if (partial) onLine(partial);
        } catch (err) {
          if (ctrl.signal.aborted) break;
          const status = (err as { status?: number }).status;
          // The pod is gone: stop following it; the next poll restarts it if it returns.
          if (status === 404 || status === 400) break;
          log(`${source}: ${(err as Error).message}`);
        }
        await new Promise((r) => setTimeout(r, RETRY_MS));
      }
      this.followers.delete(source);
    };
    void run();
  }
}

// sinceTime takes RFC 3339 with at most second precision on some API servers;
// rounding down re-reads at most one second, which dedup absorbs.
function sinceRfc3339(ts: string): string {
  return normalizeTs(ts).replace(/\.\d+Z$/, "Z");
}

const globalForCollector = globalThis as unknown as { __vboxCollector?: Collector };

export function startCollector() {
  if (process.env.VBOX_COLLECTOR === "off" || globalForCollector.__vboxCollector) return;
  globalForCollector.__vboxCollector = new Collector();
  globalForCollector.__vboxCollector.start();
}
