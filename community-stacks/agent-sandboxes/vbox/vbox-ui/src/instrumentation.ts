// Runs once when the Next.js server starts (never during `next build`). Starts the
// audit collector in the Node.js runtime; VBOX_COLLECTOR=off disables it.
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const { startCollector } = await import("./lib/audit/collector");
    startCollector();
  }
}
