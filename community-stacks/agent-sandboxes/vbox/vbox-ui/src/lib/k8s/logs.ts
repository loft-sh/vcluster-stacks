// Container log streaming from the API server's pods/log subresource, used by the
// audit collector to follow the Sandbox Router and claimed sandbox pods.
//
// Not client-node's Log class: it replaces the API server's error message with a
// generic one for anything but a 500 (so "previous terminated container not found"
// is lost) and does not propagate stream errors. This makes the same request with
// the same credentials and TLS dispatcher, which is why fetch comes from undici:
// the dispatcher is an undici object and must match the fetch that uses it.
import { fetch } from "undici";
import { getClients, k8s } from "./client";

export interface LogOptions {
  tailLines?: number;
  timestamps?: boolean;
  previous?: boolean;
  follow?: boolean;
  // RFC 3339; resume point after a reconnect.
  sinceTime?: string;
}

export class LogStreamError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export async function openLogStream(
  namespace: string,
  pod: string,
  container: string,
  opts: LogOptions,
  signal: AbortSignal,
): Promise<ReadableStream<Uint8Array>> {
  const { kc } = getClients();
  const cluster = kc.getCurrentCluster();
  if (!cluster) throw new LogStreamError(500, "No current cluster in the kubeconfig");

  const url = new URL(
    `${cluster.server}/api/v1/namespaces/${encodeURIComponent(namespace)}/pods/${encodeURIComponent(pod)}/log`,
  );
  url.searchParams.set("container", container);
  url.searchParams.set("follow", String(opts.follow ?? true));
  if (opts.tailLines !== undefined) url.searchParams.set("tailLines", String(opts.tailLines));
  if (opts.timestamps) url.searchParams.set("timestamps", "true");
  if (opts.previous) url.searchParams.set("previous", "true");
  if (opts.sinceTime) url.searchParams.set("sinceTime", opts.sinceTime);

  const ctx = new k8s.RequestContext(url.toString(), k8s.HttpMethod.GET);
  await kc.applySecurityAuthentication(ctx);

  const res = await fetch(url, {
    headers: ctx.getHeaders(),
    dispatcher: ctx.getDispatcher(),
    signal,
  });
  if (!res.ok || !res.body) {
    let message = `${res.status} ${res.statusText}`;
    try {
      // The API server answers errors with a metav1.Status object.
      message = ((await res.json()) as { message?: string }).message ?? message;
    } catch {
      // not a Status object
    }
    throw new LogStreamError(res.status, message);
  }
  return res.body as ReadableStream<Uint8Array>;
}
