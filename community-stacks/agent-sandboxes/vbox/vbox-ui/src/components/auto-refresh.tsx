"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { RefreshCw } from "lucide-react";

const INTERVAL_MS = 5000;

// Re-renders the current page on the server every few seconds (router.refresh()
// keeps client state such as filters), plus a manual refresh button.
export function AutoRefresh({ fetchedAt }: { fetchedAt: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [auto, setAuto] = useState(true);

  useEffect(() => {
    if (!auto) return;
    const id = setInterval(() => {
      if (document.visibilityState === "visible") startTransition(() => router.refresh());
    }, INTERVAL_MS);
    return () => clearInterval(id);
  }, [auto, router]);

  return (
    <div className="refresh">
      <span className="refresh-time" suppressHydrationWarning>
        Updated {new Date(fetchedAt).toLocaleTimeString()}
      </span>
      <label className="toggle">
        <input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} />
        Auto-refresh
      </label>
      <button
        type="button"
        className="icon-button"
        aria-label="Refresh"
        title="Refresh"
        onClick={() => startTransition(() => router.refresh())}
      >
        <RefreshCw size={20} strokeWidth={1.75} className={pending ? "spin" : undefined} />
      </button>
    </div>
  );
}
