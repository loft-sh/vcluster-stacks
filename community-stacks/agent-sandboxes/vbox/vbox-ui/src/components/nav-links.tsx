"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Box, FileCode2, Flame, Link2, Settings, ShieldCheck } from "lucide-react";

const LINKS = [
  { href: "/sandboxes", label: "Sandboxes", icon: Box },
  { href: "/audit", label: "Audit", icon: ShieldCheck },
  { href: "/claims", label: "Claims", icon: Link2 },
  { href: "/warm-pools", label: "Warm Pools", icon: Flame },
  { href: "/templates", label: "Templates", icon: FileCode2 },
];

const FOOTER_LINKS = [{ href: "/settings", label: "Settings", icon: Settings }];

function NavList({ links }: { links: typeof LINKS }) {
  const pathname = usePathname();
  return (
    <nav className="nav">
      {links.map(({ href, label, icon: Icon }) => {
        const active = pathname === href || pathname.startsWith(`${href}/`);
        return (
          <Link key={href} href={href} className={`nav-link${active ? " active" : ""}`}>
            <Icon size={20} strokeWidth={1.75} />
            {label}
          </Link>
        );
      })}
    </nav>
  );
}

export function NavLinks() {
  return <NavList links={LINKS} />;
}

// Below the resource views, apart from them.
export function SettingsLink() {
  return <NavList links={FOOTER_LINKS} />;
}
