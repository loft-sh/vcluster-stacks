import Link from "next/link";
import { List, Settings } from "lucide-react";
import type { LoadError, YamlView } from "@/lib/data";
import { AutoRefresh } from "./auto-refresh";
import { Errors, Page } from "./page";
import type { Crumb } from "./shell";
import { CodeBlock } from "./code-block";

export type DetailView = "details" | "config";

export const viewOf = (v: string | undefined): DetailView => (v === "config" ? "config" : "details");

// Layout shared by every detail page: title, a row of key facts, then a sub-nav
// switching between the cards (Details) and the raw objects as YAML (Config).
export function DetailFrame({
  crumbs,
  title,
  base,
  view,
  fetchedAt,
  meta,
  errors,
  detailsTitle,
  yamls,
  children,
}: {
  crumbs: Crumb[];
  title: string;
  base: string;
  view: DetailView;
  fetchedAt: string;
  meta: React.ReactNode;
  errors: LoadError[];
  detailsTitle: string;
  yamls: YamlView[];
  children: React.ReactNode;
}) {
  const current = view;
  const item = (v: DetailView, label: string, icon: React.ReactNode) => (
    <Link
      href={v === "details" ? base : `${base}?view=${v}`}
      className={`subnav-link${current === v ? " active" : ""}`}
      aria-current={current === v ? "page" : undefined}
    >
      {icon}
      {label}
    </Link>
  );
  return (
    <Page crumbs={crumbs} title={title} actions={<AutoRefresh fetchedAt={fetchedAt} />}>
      <div className="meta-row">{meta}</div>
      <Errors errors={errors} />

      <div className="detail">
        <nav className="subnav">
          {item("details", "Details", <List size={20} strokeWidth={1.75} />)}
          {item("config", "Config", <Settings size={20} strokeWidth={1.75} />)}
        </nav>

        <div className="detail-main">
          {current === "config" ? (
            yamls.length ? (
              yamls.map((y) => (
                <section key={y.title}>
                  <h2>{y.title}</h2>
                  <CodeBlock code={y.yaml} />
                </section>
              ))
            ) : (
              <p className="muted">The object could not be read.</p>
            )
          ) : (
            <>
              <h2>{detailsTitle}</h2>
              {children}
            </>
          )}
        </div>
      </div>
    </Page>
  );
}

export function MetaItem({ icon, children }: { icon: React.ReactNode; children: React.ReactNode }) {
  return (
    <span className="with-icon">
      {icon}
      {children}
    </span>
  );
}
