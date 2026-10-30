"use client";

import { useState } from "react";
import {
  ArrowDownWideNarrow,
  ArrowUpNarrowWide,
  CircleDot,
  Download,
  FileDown,
  FileUp,
  FolderSearch,
  Link2,
  Search,
  SquareTerminal,
  Unlink,
} from "lucide-react";
import { durationText, eventTitle } from "@/lib/audit/labels";
import type { AuditEvent } from "@/lib/audit/store";

function iconOf(e: AuditEvent) {
  const p = { size: 16, strokeWidth: 1.9 };
  if (e.kind === "lifecycle") {
    if (e.action === "claim.released" || e.action === "sandbox.gone" || e.action === "claim.releasing")
      return <Unlink {...p} />;
    return <Link2 {...p} />;
  }
  if (e.action === "POST /execute") return <SquareTerminal {...p} />;
  if (e.action === "POST /upload") return <FileUp {...p} />;
  if (e.action.startsWith("GET /download/")) return <FileDown {...p} />;
  if (e.action.startsWith("GET /list/") || e.action.startsWith("GET /exists/")) return <FolderSearch {...p} />;
  return <CircleDot {...p} />;
}

// Timestamps are stored as fixed-width UTC (2026-10-12T13:36:41.916273241Z), so
// slicing gives the same text on the server and in the browser.
const timeOf = (ts: string) => ts.slice(11, 23);
const dateOf = (ts: string) => ts.slice(0, 10);

export function Timeline({ events, exportHref }: { events: AuditEvent[]; exportHref: string }) {
  const [newestFirst, setNewestFirst] = useState(false);
  const [filter, setFilter] = useState("");

  const q = filter.trim().toLowerCase();
  const shown = events.filter((e) => {
    if (!q) return true;
    return [eventTitle(e), e.action, e.message, e.client].filter(Boolean).join(" ").toLowerCase().includes(q);
  });
  const ordered = newestFirst ? [...shown].reverse() : shown;
  const startsDay = ordered.map((e, i) => i === 0 || dateOf(e.ts) !== dateOf(ordered[i - 1].ts));

  const steps = events.filter((e) => e.kind === "request").length;

  return (
    <div className="timeline">
      <div className="timeline-toolbar">
        <label className="input input-sm">
          <Search size={16} strokeWidth={1.75} />
          <input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder="Filter steps and events..." />
        </label>
        <button type="button" className="btn" onClick={() => setNewestFirst((v) => !v)}>
          {newestFirst ? <ArrowDownWideNarrow size={16} /> : <ArrowUpNarrowWide size={16} />}
          {newestFirst ? "Newest first" : "Oldest first"}
        </button>
        <a className="btn timeline-export" href={exportHref} download>
          <Download size={16} />
          Export audit log
        </a>
      </div>
      <p className="muted timeline-summary">
        {events.length} events: {steps} steps, {events.length - steps} lifecycle. Times in UTC.
      </p>

      <ol className="timeline-list">
        {ordered.map((e, i) => (
          <li key={e.id} className={`tl tl-${e.kind}${e.status && e.status >= 400 ? " tl-failed" : ""}`}>
            {startsDay[i] && <div className="tl-date">{dateOf(e.ts)}</div>}
            <div className="tl-row">
              <time className="tl-time" dateTime={e.ts} title={e.ts}>
                {timeOf(e.ts)}
              </time>
              <span className="tl-icon">{iconOf(e)}</span>
              <div className="tl-body">
                <div className="tl-title">
                  <span className="strong">{eventTitle(e)}</span>
                  {e.kind !== "lifecycle" && <code className="tl-action">{e.action}</code>}
                  {e.status !== undefined && (
                    <span className={`chip chip-inline ${e.status < 400 ? "chip-green" : "chip-amber"}`}>{e.status}</span>
                  )}
                  {e.durationMs !== undefined && <span className="muted">{durationText(e.durationMs)}</span>}
                </div>
                {e.kind === "lifecycle" ? (
                  e.message && <div className="muted">{e.message}</div>
                ) : (
                  <div className="muted">
                    {[
                      e.client,
                      e.detail?.clientIp ? `from ${String(e.detail.clientIp)}` : undefined,
                      e.detail?.bytesOut !== undefined ? `${String(e.detail.bytesOut)} bytes returned` : undefined,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </div>
                )}
              </div>
              <span
                className="tl-hash"
                title={`Event #${e.id} (${e.kind})\nsha256 ${e.hash}\nprev ${e.prevHash}\nsource ${e.source}`}
              >
                #{e.id}
              </span>
            </div>
          </li>
        ))}
        {ordered.length === 0 && <li className="muted tl-empty">No events match.</li>}
      </ol>
    </div>
  );
}
