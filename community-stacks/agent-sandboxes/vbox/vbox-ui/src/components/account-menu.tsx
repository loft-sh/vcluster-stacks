"use client";

import { useEffect, useRef } from "react";
import Link from "next/link";
import { ChevronsUpDown, LogOut, Settings } from "lucide-react";
import type { AuthMode } from "@/lib/auth/settings";

export interface AccountIdentity {
  name: string;
  // Second line: the email, or the username when there is no email.
  detail: string;
  username: string;
  groups: number;
  expires: string;
}

// The account block at the bottom of the sidebar: who is signed in, and a menu
// (opening upwards) with the identity, the cluster and Sign out. A <details>, so it
// opens without JavaScript too; the effect only adds closing on an outside click,
// Escape and navigation.
export function AccountMenu({
  user,
  initials,
  cluster,
  signInMode,
}: {
  user?: AccountIdentity;
  initials: string;
  cluster: string;
  signInMode: AuthMode;
}) {
  const ref = useRef<HTMLDetailsElement>(null);

  useEffect(() => {
    const close = () => ref.current?.removeAttribute("open");
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    document.addEventListener("click", onClick);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("click", onClick);
      document.removeEventListener("keydown", onKey);
    };
  }, []);

  const close = () => ref.current?.removeAttribute("open");

  return (
    <details ref={ref} className="account">
      <summary className="sidebar-user account-trigger" aria-label="Account">
        <span className={`avatar${user ? " avatar-user" : ""}`}>{initials}</span>
        <span className="sidebar-user-text">
          <span className="sidebar-user-name">{user ? user.name : "Not signed in"}</span>
          <span className="sidebar-user-sub">
            {user ? user.detail : signInMode === "disabled-by-env" ? "Sign-in off (VBOX_AUTH=off)" : "Sign-in off"}
          </span>
        </span>
        <ChevronsUpDown size={16} strokeWidth={1.75} className="account-chevron" />
      </summary>

      <div className="account-menu" role="menu">
        {user ? (
          <div className="account-identity">
            <span className="account-label">Signed in as</span>
            <span className="strong">{user.name}</span>
            {user.detail !== user.name && <span className="muted">{user.detail}</span>}
            {user.username !== user.detail && user.username !== user.name && (
              <span className="muted mono small">{user.username}</span>
            )}
          </div>
        ) : (
          <div className="account-identity">
            <span className="account-label">Not signed in</span>
            <span className="muted">
              {signInMode === "disabled-by-env"
                ? "Sign-in is switched off by VBOX_AUTH=off."
                : "Sign-in is not configured, so vBox is open to anyone who can reach it."}
            </span>
          </div>
        )}

        <dl className="account-facts">
          <dt>Cluster</dt>
          <dd title={cluster}>{cluster}</dd>
          {user && (
            <>
              <dt>Groups</dt>
              <dd>{user.groups}</dd>
              <dt>Session</dt>
              <dd>Expires {user.expires}</dd>
            </>
          )}
        </dl>

        <div className="account-actions">
          {user ? (
            <form action="/api/auth/logout" method="post">
              <button type="submit" className="account-item" role="menuitem">
                <LogOut size={16} strokeWidth={1.75} />
                Sign out
              </button>
            </form>
          ) : (
            <Link href="/settings" className="account-item" role="menuitem" onClick={close}>
              <Settings size={16} strokeWidth={1.75} />
              Configure sign-in
            </Link>
          )}
        </div>
      </div>
    </details>
  );
}
