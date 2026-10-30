// Human wording for audit events. Pure, so both server and client components use it.

// The python runtime's API (examples/python-runtime-sandbox/main.py upstream).
export function stepLabel(action: string): string {
  const [method, ...rest] = action.split(" ");
  const path = rest.join(" ");
  if (method === "POST" && path === "/execute") return "Executed a command";
  if (method === "POST" && path === "/upload") return "Uploaded a file";
  const m = path.match(/^\/(download|list|exists)\/(.*)$/);
  if (method === "GET" && m) {
    const target = decodeURIComponent(m[2]) || ".";
    if (m[1] === "download") return `Downloaded ${target}`;
    if (m[1] === "list") return `Listed ${target}`;
    return `Checked whether ${target} exists`;
  }
  if (method === "GET" && path === "/") return "Health check";
  return action;
}

export const LIFECYCLE: Record<string, string> = {
  "claim.created": "Claimed a sandbox",
  "claim.assigned": "Sandbox assigned",
  "claim.ready": "Sandbox ready",
  "claim.releasing": "Release requested",
  "claim.released": "Sandbox released",
  "sandbox.gone": "Sandbox no longer exists",
};

export function eventTitle(e: { kind: string; action: string }): string {
  if (e.kind === "request") return stepLabel(e.action);
  return LIFECYCLE[e.action] ?? e.action;
}

export function durationText(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)} ms`;
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

// Who the session belongs to: the claim's agents.x-k8s.io/created-by label when
// the claim was observed, otherwise the HTTP user agent the router recorded.
export const clientOf = (s: { client?: string; userAgent?: string }) => s.client ?? s.userAgent ?? "unknown";
