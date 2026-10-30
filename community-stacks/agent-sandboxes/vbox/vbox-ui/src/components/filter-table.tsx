"use client";

import { useMemo, useState } from "react";
import { ArrowDown, ArrowUp, ChevronDown, Search } from "lucide-react";

export interface FilterRow {
  key: string;
  namespace: string;
  // Lower-cased text the search box matches against.
  search: string;
  // Value the optional "state" dropdown filters on.
  state?: string;
  // Values the sortable columns sort by, keyed by Column.sortKey.
  sort?: Record<string, string | number>;
  // Cells are rendered on the server and passed through as-is.
  cells: React.ReactNode[];
}

export interface Column {
  label: string;
  width?: string;
  // Makes the header clickable; rows must provide sort[sortKey].
  sortKey?: string;
}

export interface SortState {
  key: string;
  dir: "asc" | "desc";
}

export function FilterTable({
  columns,
  rows,
  placeholder = "Filter by name...",
  stateOptions,
  stateLabel = "Any state",
  sortOptions,
  defaultSort,
  empty,
  toolbar,
}: {
  columns: Column[];
  rows: FilterRow[];
  placeholder?: string;
  stateOptions?: { value: string; label: string }[];
  stateLabel?: string;
  // Presets for the sort dropdown; header clicks cover the rest.
  sortOptions?: (SortState & { label: string })[];
  defaultSort?: SortState;
  empty: React.ReactNode;
  toolbar?: React.ReactNode;
}) {
  const [query, setQuery] = useState("");
  const [namespace, setNamespace] = useState("");
  const [state, setState] = useState("");
  const [sort, setSort] = useState<SortState | undefined>(defaultSort);

  const namespaces = useMemo(() => [...new Set(rows.map((r) => r.namespace))].sort(), [rows]);
  const q = query.trim().toLowerCase();
  const filtered = rows.filter(
    (r) => (!q || r.search.includes(q)) && (!namespace || r.namespace === namespace) && (!state || r.state === state),
  );
  const visible = sort
    ? [...filtered].sort((a, b) => {
        const x = a.sort?.[sort.key] ?? "";
        const y = b.sort?.[sort.key] ?? "";
        const c = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y));
        return sort.dir === "asc" ? c : -c;
      })
    : filtered;

  const toggle = (key: string) =>
    setSort((s) => (s?.key === key ? { key, dir: s.dir === "asc" ? "desc" : "asc" } : { key, dir: "asc" }));
  const presetValue = sortOptions?.findIndex((o) => o.key === sort?.key && o.dir === sort?.dir) ?? -1;

  return (
    <>
      <div className="filters">
        <label className="input">
          <Search size={18} strokeWidth={1.75} />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder={placeholder} />
        </label>
        <label className="select">
          <select value={namespace} onChange={(e) => setNamespace(e.target.value)}>
            <option value="">Any namespace</option>
            {namespaces.map((ns) => (
              <option key={ns} value={ns}>
                {ns}
              </option>
            ))}
          </select>
          <ChevronDown size={18} strokeWidth={1.75} />
        </label>
        {stateOptions && (
          <label className="select">
            <select value={state} onChange={(e) => setState(e.target.value)}>
              <option value="">{stateLabel}</option>
              {stateOptions.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
            <ChevronDown size={18} strokeWidth={1.75} />
          </label>
        )}
        {sortOptions && (
          <label className="select">
            <select
              value={presetValue}
              onChange={(e) => {
                const o = sortOptions[Number(e.target.value)];
                if (o) setSort({ key: o.key, dir: o.dir });
              }}
              aria-label="Sort"
            >
              {presetValue < 0 && <option value={-1}>Custom sort</option>}
              {sortOptions.map((o, i) => (
                <option key={o.label} value={i}>
                  Sort: {o.label}
                </option>
              ))}
            </select>
            <ChevronDown size={18} strokeWidth={1.75} />
          </label>
        )}
        <div className="filters-end">{toolbar}</div>
      </div>

      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr>
              {columns.map((c) => (
                <th
                  key={c.label}
                  style={c.width ? { width: c.width } : undefined}
                  aria-sort={sort && c.sortKey === sort.key ? (sort.dir === "asc" ? "ascending" : "descending") : undefined}
                >
                  {c.sortKey ? (
                    <button type="button" className="th-sort" onClick={() => toggle(c.sortKey!)}>
                      {c.label}
                      {sort?.key === c.sortKey &&
                        (sort.dir === "asc" ? <ArrowUp size={14} strokeWidth={2} /> : <ArrowDown size={14} strokeWidth={2} />)}
                    </button>
                  ) : (
                    c.label
                  )}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {visible.map((r) => (
              <tr key={r.key}>
                {r.cells.map((cell, i) => (
                  <td key={i}>{cell}</td>
                ))}
              </tr>
            ))}
            {visible.length === 0 && (
              <tr>
                <td colSpan={columns.length} className="table-empty">
                  {rows.length === 0 ? empty : "No rows match the current filters."}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
