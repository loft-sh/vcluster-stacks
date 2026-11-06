import { CircleAlert } from "lucide-react";
import type { LoadError } from "@/lib/data";
import { TopBar, type Crumb } from "./shell";

export function Page({
  crumbs,
  title,
  actions,
  children,
}: {
  crumbs: Crumb[];
  title: React.ReactNode;
  actions?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <>
      <TopBar crumbs={crumbs} />
      <div className="page-head">
        <h1>{title}</h1>
        {actions && <div className="page-actions">{actions}</div>}
      </div>
      <div className="page-body">{children}</div>
    </>
  );
}

export function Errors({ errors }: { errors: LoadError[] }) {
  if (errors.length === 0) return null;
  return (
    <div className="alert" role="alert">
      <CircleAlert size={20} strokeWidth={1.75} />
      <div>
        <strong>Some data could not be loaded from the Kubernetes API.</strong>
        <ul>
          {errors.map((e) => (
            <li key={e.resource}>
              <code>{e.resource}</code>
              {e.status ? ` (HTTP ${e.status})` : ""}: {e.message}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

export function Card({
  icon,
  title,
  aside,
  children,
}: {
  icon: React.ReactNode;
  title: string;
  aside?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <details className="card" open>
      <summary className="card-head">
        <span className="card-title">
          {icon}
          {title}
        </span>
        {aside}
        <span className="card-toggle" />
      </summary>
      <div className="card-body">{children}</div>
    </details>
  );
}

export function KeyValues({ rows }: { rows: [string, React.ReactNode][] }) {
  return (
    <table className="kv">
      <tbody>
        {rows.map(([k, v]) => (
          <tr key={k}>
            <th>{k}</th>
            <td>{v === undefined || v === null || v === "" ? "-" : v}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export function Muted({ children }: { children: React.ReactNode }) {
  return <span className="muted">{children}</span>;
}
