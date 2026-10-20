import Link from "next/link";
import { connection } from "next/server";
import { ChevronRight } from "lucide-react";
import { currentUser } from "@/lib/auth/session";
import { authMode } from "@/lib/auth/settings";
import { timeUntil } from "@/lib/format";
import { getClusterInfo, type ClusterInfo } from "@/lib/k8s/client";
import { AccountMenu } from "./account-menu";
import { NavLinks, SettingsLink } from "./nav-links";
import { VBoxLogo } from "./vbox-logo";

// "Alice Admin" -> "AA", "alice@example.com" -> "AL".
function initialsOf(text: string): string {
  const words = text.split(/[\s@._-]+/).filter(Boolean);
  const pick = words.length >= 2 && !text.includes("@") ? words[0][0] + words[1][0] : text.replace(/[^a-z0-9]/gi, "").slice(0, 2);
  return pick.toUpperCase() || "?";
}

function clusterInfo(): ClusterInfo | undefined {
  try {
    return getClusterInfo();
  } catch {
    return undefined;
  }
}

export async function Sidebar() {
  // Reads the kubeconfig: never at build time, or the build machine's cluster
  // would be baked into prerendered pages.
  await connection();
  const cluster = clusterInfo();
  const user = await currentUser();
  const name = user ? (user.name ?? user.username) : undefined;
  return (
    <aside className="sidebar">
      <Link href="/sandboxes" className="logo" aria-label="vBox home">
        <VBoxLogo />
      </Link>

      <div className="scope">
        <NavLinks />
      </div>
      <div className="scope scope-secondary">
        <SettingsLink />
      </div>

      <AccountMenu
        user={
          user && name
            ? {
                name,
                detail: user.email ?? user.username,
                username: user.username,
                groups: user.groups.length,
                expires: timeUntil(new Date(user.expiresAt).toISOString()),
              }
            : undefined
        }
        initials={name ? initialsOf(name) : "?"}
        cluster={cluster?.context ?? "in-cluster"}
        signInMode={await authMode()}
      />
    </aside>
  );
}

export interface Crumb {
  label: string;
  href?: string;
}

export function TopBar({ crumbs }: { crumbs: Crumb[] }) {
  return (
    <header className="topbar">
      <ol className="crumbs">
        {crumbs.map((c, i) => (
          <li key={i} className={i === crumbs.length - 1 ? "current" : undefined}>
            {i > 0 && <ChevronRight size={14} className="crumb-sep" />}
            {c.href ? <Link href={c.href}>{c.label}</Link> : c.label}
          </li>
        ))}
      </ol>
    </header>
  );
}

export function Footer() {
  return (
    <footer className="footer">
      <span>vBox 0.1.0</span>
      <span className="footer-sep" />
      <a href="https://github.com/kubernetes-sigs/agent-sandbox" target="_blank" rel="noreferrer">
        Agent Sandbox API v1beta1
      </a>
    </footer>
  );
}
