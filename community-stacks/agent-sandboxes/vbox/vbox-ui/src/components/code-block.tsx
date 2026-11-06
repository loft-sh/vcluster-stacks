import { highlightYaml } from "@/lib/yaml-highlight";
import { CopyButton } from "./copy-button";

// A read-only YAML viewer: highlighted on the server, line numbers that are not
// part of the copied text, and a copy button for the whole document.
export function CodeBlock({ code, label = "YAML" }: { code: string; label?: string }) {
  const lines = highlightYaml(code);
  return (
    <div className="code-block">
      <div className="code-head">
        <span className="code-lang">{label}</span>
        <span className="code-meta">
          {lines.length} line{lines.length === 1 ? "" : "s"}
        </span>
        <CopyButton text={code} label={`Copy ${label}`} />
      </div>
      <pre className="code">
        <code>
          {lines.map((tokens, i) => (
            <span key={i} className="code-line">
              {tokens.map((t, j) =>
                t.kind === "text" ? t.text : <span key={j} className={`tok-${t.kind}`}>{t.text}</span>,
              )}
              {"\n"}
            </span>
          ))}
        </code>
      </pre>
    </div>
  );
}
