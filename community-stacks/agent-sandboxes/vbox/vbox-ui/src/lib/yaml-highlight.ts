// Line-based YAML tokenizer for the code viewer. Covers what the yaml package
// emits for Kubernetes objects: mappings, sequences, scalars, comments, flow
// collections and block scalars (| and >), whose lines are kept as plain text so
// an embedded shell script is not mistaken for YAML. Pure, so it runs on the
// server and nothing is shipped to the browser for it.

export type TokenKind = "key" | "string" | "quoted" | "number" | "bool" | "null" | "comment" | "punct" | "block" | "text";

export interface Token {
  kind: TokenKind;
  text: string;
}

const KEY_RE = /^((?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#'"{}[\],&*!|>%@`][^:#]*?|[^\s#][^:#]*?))(:)(?=\s|$)/;

function scalar(text: string): TokenKind {
  const t = text.trim();
  if (/^(true|false|yes|no|on|off)$/i.test(t)) return "bool";
  if (/^(null|~)$/i.test(t)) return "null";
  if (/^[-+]?(\d[\d_]*(\.\d*)?([eE][-+]?\d+)?|\.\d+|0x[\da-fA-F]+|0o[0-7]+|\.inf|\.nan)$/.test(t)) return "number";
  return "string";
}

// A value after "key:" or "- ": scalar, quoted string, flow collection, block
// indicator, anchor/alias/tag, then an optional trailing comment.
function value(rest: string, out: Token[]): void {
  if (!rest) return;
  const lead = rest.match(/^\s*/)![0];
  if (lead) out.push({ kind: "text", text: lead });
  let s = rest.slice(lead.length);

  if (s.startsWith("#")) {
    out.push({ kind: "comment", text: s });
    return;
  }
  // Anchors, aliases and tags.
  const meta = s.match(/^([&*!][^\s]*)(\s*)/);
  if (meta) {
    out.push({ kind: "punct", text: meta[1] });
    if (meta[2]) out.push({ kind: "text", text: meta[2] });
    s = s.slice(meta[0].length);
    if (!s) return;
  }
  if (/^[|>][-+]?\d*\s*(#.*)?$/.test(s)) {
    const [, ind, comment] = s.match(/^([|>][-+]?\d*)(\s*#.*)?/)!;
    out.push({ kind: "punct", text: ind });
    if (comment) out.push({ kind: "comment", text: comment });
    return;
  }
  // Quoted string, then whatever follows (usually a comment).
  const quoted = s.match(/^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*')(.*)$/);
  if (quoted) {
    out.push({ kind: "quoted", text: quoted[1] });
    if (quoted[2]) value(quoted[2], out);
    return;
  }
  if (s.startsWith("{") || s.startsWith("[")) {
    // Flow collection: punctuation apart, the items as scalars.
    for (const part of s.split(/([{}[\],:]\s*)/).filter(Boolean)) {
      out.push(/^[{}[\],:]/.test(part) ? { kind: "punct", text: part } : { kind: scalar(part), text: part });
    }
    return;
  }
  // Plain scalar; " #" starts a comment.
  const hash = s.search(/\s#/);
  const body = hash >= 0 ? s.slice(0, hash) : s;
  out.push({ kind: scalar(body), text: body });
  if (hash >= 0) out.push({ kind: "comment", text: s.slice(hash) });
}

export function highlightYaml(source: string): Token[][] {
  const lines = source.replace(/\n$/, "").split("\n");
  const result: Token[][] = [];
  // Indentation of the line that opened a block scalar; deeper lines are its text.
  let blockIndent = -1;

  for (const line of lines) {
    const indent = line.match(/^ */)![0].length;
    if (blockIndent >= 0) {
      if (line.trim() === "" || indent > blockIndent) {
        result.push([{ kind: "block", text: line }]);
        continue;
      }
      blockIndent = -1;
    }

    const out: Token[] = [];
    let s = line;
    if (indent) out.push({ kind: "text", text: s.slice(0, indent) });
    s = s.slice(indent);

    if (s === "---" || s === "...") {
      out.push({ kind: "punct", text: s });
      result.push(out);
      continue;
    }
    // Sequence dashes, possibly several ("- - a").
    let dashCol = indent;
    while (/^-(\s|$)/.test(s)) {
      const m = s.match(/^-\s*/)![0];
      out.push({ kind: "punct", text: "-" });
      if (m.length > 1) out.push({ kind: "text", text: m.slice(1) });
      dashCol += m.length;
      s = s.slice(m.length);
    }
    if (s.startsWith("#")) {
      out.push({ kind: "comment", text: s });
      result.push(out);
      continue;
    }
    const key = s.match(KEY_RE);
    if (key) {
      out.push({ kind: "key", text: key[1] });
      out.push({ kind: "punct", text: ":" });
      const rest = s.slice(key[0].length);
      value(rest, out);
      if (/^\s*[|>][-+]?\d*\s*(#.*)?$/.test(rest)) blockIndent = dashCol;
    } else {
      value(s, out);
      if (/^[|>][-+]?\d*\s*(#.*)?$/.test(s)) blockIndent = Math.max(dashCol - 2, 0);
    }
    result.push(out);
  }
  return result;
}
