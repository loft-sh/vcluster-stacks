// Formatting shared by server and client components.

export function timeAgo(isoTime: string | undefined, now: number = Date.now()): string {
  if (!isoTime) return "-";
  const seconds = Math.max(0, Math.round((now - new Date(isoTime).getTime()) / 1000));
  if (seconds < 60) return "just now";
  const units: [number, string][] = [
    [60, "minute"],
    [3600, "hour"],
    [86400, "day"],
    [2592000, "month"],
    [31536000, "year"],
  ];
  let value = 0;
  let unit = "minute";
  for (const [size, name] of units) {
    if (seconds >= size) {
      value = Math.floor(seconds / size);
      unit = name;
    }
  }
  return `${value} ${unit}${value === 1 ? "" : "s"} ago`;
}

export function timeUntil(isoTime: string | undefined, now: number = Date.now()): string {
  if (!isoTime) return "-";
  const ms = new Date(isoTime).getTime() - now;
  if (ms <= 0) return `expired ${timeAgo(isoTime, now)}`;
  const minutes = Math.round(ms / 60000);
  if (minutes < 60) return `in ${minutes} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `in ${hours} h`;
  return `in ${Math.round(hours / 24)} days`;
}

export function dateTime(isoTime: string | undefined): string {
  if (!isoTime) return "-";
  return new Date(isoTime).toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
}

export function resources(map: Record<string, string>, order = ["cpu", "memory", "ephemeral-storage"]): string {
  const parts = order.filter((k) => map[k]).map((k) => `${map[k]} ${k === "cpu" ? "CPU" : k === "memory" ? "Memory" : "Disk"}`);
  return parts.length ? parts.join(", ") : "-";
}

export const yesNo = (v: boolean | undefined): string => (v === undefined ? "-" : v ? "Yes" : "No");
