// Liveness and readiness probe target. Kept free of any Kubernetes API call so a
// slow or unreachable API server never restarts the pod.
export const dynamic = "force-dynamic";

export function GET() {
  return Response.json({ status: "ok" });
}
