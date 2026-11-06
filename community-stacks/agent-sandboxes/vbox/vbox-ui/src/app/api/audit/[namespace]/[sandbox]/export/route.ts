// One session's audit trail as JSON Lines: every event with its hash and the hash
// of its predecessor, so the export can be checked against the chain later.
import { getAuditStore } from "@/lib/audit/store";
import { unauthorized } from "@/lib/auth/session";

export const dynamic = "force-dynamic";

export async function GET(_req: Request, { params }: { params: Promise<{ namespace: string; sandbox: string }> }) {
  const denied = await unauthorized();
  if (denied) return denied;
  const { namespace, sandbox } = await params;
  const store = getAuditStore();
  const session = store.getSession(namespace, sandbox);
  if (!session) return Response.json({ error: `No audit trail recorded for ${namespace}/${sandbox}` }, { status: 404 });

  const lines = [
    JSON.stringify({ type: "session", ...session }),
    ...store.sessionEvents(namespace, sandbox, session.claimUid).map((e) => JSON.stringify({ type: "event", ...e })),
  ];
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  return new Response(lines.join("\n") + "\n", {
    headers: {
      "Content-Type": "application/x-ndjson; charset=utf-8",
      "Content-Disposition": `attachment; filename="audit-${namespace}-${sandbox}-${stamp}.jsonl"`,
      "Cache-Control": "no-store",
    },
  });
}
