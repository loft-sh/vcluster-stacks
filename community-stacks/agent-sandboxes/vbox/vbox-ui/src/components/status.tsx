import { Ban, Check, CircleDashed, CirclePause, Flag, Link2, LoaderCircle, Trash2, X } from "lucide-react";
import type { ConditionView, Health, SandboxState } from "@/lib/model";

const STATE: Record<SandboxState, { label: string; tone: string; icon: React.ReactNode }> = {
  available: { label: "Available", tone: "blue", icon: <Check size={16} strokeWidth={2} /> },
  claimed: { label: "Claimed", tone: "orange", icon: <Link2 size={16} strokeWidth={2} /> },
  standalone: { label: "Standalone", tone: "gray", icon: <CircleDashed size={16} strokeWidth={2} /> },
};

export function StateBadge({ state }: { state: SandboxState }) {
  const s = STATE[state];
  return (
    <span className={`badge badge-${s.tone}`}>
      {s.icon}
      {s.label}
    </span>
  );
}

const HEALTH: Record<Health, { label: string; tone: string; icon: React.ReactNode }> = {
  ready: { label: "Ready", tone: "green", icon: <Check size={14} strokeWidth={2.25} /> },
  pending: { label: "Pending", tone: "amber", icon: <LoaderCircle size={14} strokeWidth={2.25} /> },
  suspended: { label: "Suspended", tone: "gray", icon: <CirclePause size={14} strokeWidth={2.25} /> },
  finished: { label: "Finished", tone: "gray", icon: <Flag size={14} strokeWidth={2.25} /> },
  terminating: { label: "Terminating", tone: "gray", icon: <Trash2 size={14} strokeWidth={2.25} /> },
};

export function HealthChip({ health, reason }: { health: Health; reason?: string }) {
  const h = HEALTH[health];
  return (
    <span className={`chip chip-${h.tone}`} title={reason}>
      {h.icon}
      {h.label}
    </span>
  );
}

export function ReadyChip({ ready, label = "Ready", reason }: { ready: boolean; label?: string; reason?: string }) {
  return (
    <span className={`chip ${ready ? "chip-green" : "chip-amber"}`} title={reason}>
      {ready ? <Check size={14} strokeWidth={2.25} /> : <LoaderCircle size={14} strokeWidth={2.25} />}
      {ready ? label : (reason ?? `Not ${label.toLowerCase()}`)}
    </span>
  );
}

// Conditions whose healthy value is False rather than True.
const NEGATIVE = new Set(["Suspended", "Finished"]);

export function ConditionChip({ c }: { c: ConditionView }) {
  const healthy = NEGATIVE.has(c.type) ? c.status === "False" : c.status === "True";
  const unknown = c.status === "Unknown";
  const tone = unknown ? "gray" : healthy ? "green" : "amber";
  return (
    <span className={`chip chip-${tone}`} title={[c.reason, c.message].filter(Boolean).join(": ")}>
      {unknown ? <Ban size={14} /> : healthy ? <Check size={14} strokeWidth={2.25} /> : <X size={14} strokeWidth={2.25} />}
      {c.type}: {c.status.toLowerCase()}
    </span>
  );
}
