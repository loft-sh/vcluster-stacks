// The interaction audit trail: an append-only, hash-chained event log in SQLite.
//
// - events is the audit trail. Triggers reject UPDATE and DELETE, so rows can only
//   be added, and every row carries the SHA-256 of its predecessor, so an edit made
//   behind the database's back (or a deleted row) breaks the chain and shows up in
//   verifyChain().
// - sessions is an index over the trail, one row per claimed sandbox, holding who
//   the client was and when the session started and ended. It is mutable on purpose
//   and holds nothing the events do not also record.
// - cursors remembers how far each log source has been read, so a restarted
//   collector resumes instead of re-reading from the beginning. Events also carry a
//   unique dedup key, so an overlapping re-read inserts nothing twice.
//
// node:sqlite (built into Node 22.5+) rather than a native module, so the
// container image needs no compiler. Access is synchronous and single-process.
import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

// lifecycle: a claim transition (created, assigned, ready, released)
// request:   a client call as the Sandbox Router saw it (method, path, status, timing)
// exchange and log (payloads from the former in-pod audit proxy, raw sandbox log
// lines) are no longer recorded. Rows from earlier versions stay in the chain, so
// they are still hashed and verified, but are not shown.
export type EventKind = "lifecycle" | "request" | "exchange" | "log";

// The kinds the audit view reads.
const SHOWN_KINDS = "('lifecycle', 'request')";

export interface NewEvent {
  ts: string;
  namespace: string;
  sandbox?: string;
  claim?: string;
  claimUid?: string;
  client?: string;
  kind: EventKind;
  action: string;
  status?: number;
  durationMs?: number;
  message?: string;
  detail?: Record<string, unknown>;
  source: string;
  dedup: string;
}

export interface AuditEvent extends Omit<NewEvent, "detail"> {
  id: number;
  recordedAt: string;
  detail?: Record<string, unknown>;
  prevHash: string;
  hash: string;
}

export interface SessionMeta {
  namespace: string;
  sandbox: string;
  claim?: string;
  claimUid?: string;
  client?: string;
  userAgent?: string;
  clientIp?: string;
  warmPool?: string;
  launchType?: string;
  startedAt: string;
}

export interface SessionSummary extends SessionMeta {
  endedAt?: string;
  lastActivity?: string;
  steps: number;
  commands: number;
  uploads: number;
  downloads: number;
  errors: number;
}

const GENESIS = "0".repeat(64);

const SCHEMA = `
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts          TEXT NOT NULL,
  recorded_at TEXT NOT NULL,
  namespace   TEXT NOT NULL,
  sandbox     TEXT,
  claim       TEXT,
  claim_uid   TEXT,
  client      TEXT,
  kind        TEXT NOT NULL,
  action      TEXT NOT NULL,
  status      INTEGER,
  duration_ms INTEGER,
  message     TEXT,
  detail      TEXT,
  source      TEXT NOT NULL,
  dedup       TEXT NOT NULL UNIQUE,
  prev_hash   TEXT NOT NULL,
  hash        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_sandbox ON events (namespace, sandbox, ts);
CREATE INDEX IF NOT EXISTS events_claim ON events (claim_uid);
CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
  BEGIN SELECT RAISE(ABORT, 'the audit trail is append-only'); END;
CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
  BEGIN SELECT RAISE(ABORT, 'the audit trail is append-only'); END;

CREATE TABLE IF NOT EXISTS sessions (
  namespace   TEXT NOT NULL,
  sandbox     TEXT NOT NULL,
  claim       TEXT,
  claim_uid   TEXT,
  client      TEXT,
  user_agent  TEXT,
  client_ip   TEXT,
  warm_pool   TEXT,
  launch_type TEXT,
  started_at  TEXT NOT NULL,
  ended_at    TEXT,
  PRIMARY KEY (namespace, sandbox)
);

CREATE TABLE IF NOT EXISTS cursors (
  source TEXT PRIMARY KEY,
  ts     TEXT NOT NULL
);
`;

// Fixed-width UTC with nanoseconds, so timestamps from the router (seconds), the
// API server (seconds) and kubelet log prefixes (nanoseconds) sort as strings.
export function normalizeTs(input: string | Date): string {
  if (input instanceof Date) return input.toISOString().replace(/\.(\d{3})Z$/, ".$1000000Z");
  const m = input.match(/^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z$/);
  if (m) return `${m[1]}.${(m[2] ?? "").padEnd(9, "0").slice(0, 9)}Z`;
  const d = new Date(input);
  if (Number.isNaN(d.getTime())) throw new Error(`invalid timestamp: ${input}`);
  return normalizeTs(d);
}

const nowTs = () => normalizeTs(new Date());

type Row = Record<string, string | number | null>;

const str = (v: unknown) => (v === null || v === undefined ? undefined : String(v));
const num = (v: unknown) => (v === null || v === undefined ? undefined : Number(v));

function hashOf(prevHash: string, e: NewEvent, recordedAt: string): string {
  const body = JSON.stringify([
    e.ts,
    recordedAt,
    e.namespace,
    e.sandbox ?? null,
    e.claim ?? null,
    e.claimUid ?? null,
    e.client ?? null,
    e.kind,
    e.action,
    e.status ?? null,
    e.durationMs ?? null,
    e.message ?? null,
    e.detail ? JSON.stringify(e.detail) : null,
    e.source,
    e.dedup,
  ]);
  return createHash("sha256").update(prevHash).update("\n").update(body).digest("hex");
}

function toEvent(r: Row): AuditEvent {
  return {
    id: Number(r.id),
    ts: String(r.ts),
    recordedAt: String(r.recorded_at),
    namespace: String(r.namespace),
    sandbox: str(r.sandbox),
    claim: str(r.claim),
    claimUid: str(r.claim_uid),
    client: str(r.client),
    kind: String(r.kind) as EventKind,
    action: String(r.action),
    status: num(r.status),
    durationMs: num(r.duration_ms),
    message: str(r.message),
    detail: r.detail ? (JSON.parse(String(r.detail)) as Record<string, unknown>) : undefined,
    source: String(r.source),
    dedup: String(r.dedup),
    prevHash: String(r.prev_hash),
    hash: String(r.hash),
  };
}

function toSession(r: Row): SessionSummary {
  return {
    namespace: String(r.namespace),
    sandbox: String(r.sandbox),
    claim: str(r.claim),
    claimUid: str(r.claim_uid),
    client: str(r.client),
    userAgent: str(r.user_agent),
    clientIp: str(r.client_ip),
    warmPool: str(r.warm_pool),
    launchType: str(r.launch_type),
    startedAt: String(r.started_at),
    endedAt: str(r.ended_at),
    lastActivity: str(r.last_activity),
    steps: Number(r.steps ?? 0),
    commands: Number(r.commands ?? 0),
    uploads: Number(r.uploads ?? 0),
    downloads: Number(r.downloads ?? 0),
    errors: Number(r.errors ?? 0),
  };
}

export class AuditStore {
  readonly file: string;
  private db: DatabaseSync;

  constructor(dir: string) {
    mkdirSync(dir, { recursive: true });
    this.file = path.join(dir, "audit.db");
    this.db = new DatabaseSync(this.file);
    this.db.exec(SCHEMA);
  }

  // Appends one event to the chain. Returns false when an event with the same
  // dedup key is already recorded, which is how re-reads after a restart are
  // absorbed.
  append(e: NewEvent): boolean {
    const event = { ...e, ts: normalizeTs(e.ts) };
    this.db.exec("BEGIN IMMEDIATE");
    try {
      if (this.db.prepare("SELECT 1 FROM events WHERE dedup = ?").get(event.dedup)) {
        this.db.exec("ROLLBACK");
        return false;
      }
      const last = this.db.prepare("SELECT hash FROM events ORDER BY id DESC LIMIT 1").get() as Row | undefined;
      const prevHash = last ? String(last.hash) : GENESIS;
      const recordedAt = nowTs();
      this.db
        .prepare(
          `INSERT INTO events (ts, recorded_at, namespace, sandbox, claim, claim_uid, client, kind, action, status,
             duration_ms, message, detail, source, dedup, prev_hash, hash)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          event.ts,
          recordedAt,
          event.namespace,
          event.sandbox ?? null,
          event.claim ?? null,
          event.claimUid ?? null,
          event.client ?? null,
          event.kind,
          event.action,
          event.status ?? null,
          event.durationMs ?? null,
          event.message ?? null,
          event.detail ? JSON.stringify(event.detail) : null,
          event.source,
          event.dedup,
          prevHash,
          hashOf(prevHash, event, recordedAt),
        );
      this.db.exec("COMMIT");
      return true;
    } catch (err) {
      this.db.exec("ROLLBACK");
      throw err;
    }
  }

  hasEvent(dedup: string): boolean {
    return Boolean(this.db.prepare("SELECT 1 FROM events WHERE dedup = ?").get(dedup));
  }

  // Creates the session or fills in what it was missing. The earliest start wins,
  // and known values are never overwritten with empty ones.
  upsertSession(s: SessionMeta): void {
    this.db
      .prepare(
        `INSERT INTO sessions (namespace, sandbox, claim, claim_uid, client, user_agent, client_ip, warm_pool,
           launch_type, started_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (namespace, sandbox) DO UPDATE SET
           claim       = COALESCE(excluded.claim, claim),
           claim_uid   = COALESCE(excluded.claim_uid, claim_uid),
           client      = COALESCE(excluded.client, client),
           user_agent  = COALESCE(user_agent, excluded.user_agent),
           client_ip   = COALESCE(client_ip, excluded.client_ip),
           warm_pool   = COALESCE(excluded.warm_pool, warm_pool),
           launch_type = COALESCE(excluded.launch_type, launch_type),
           started_at  = MIN(started_at, excluded.started_at)`,
      )
      .run(
        s.namespace,
        s.sandbox,
        s.claim ?? null,
        s.claimUid ?? null,
        s.client ?? null,
        s.userAgent ?? null,
        s.clientIp ?? null,
        s.warmPool ?? null,
        s.launchType ?? null,
        normalizeTs(s.startedAt),
      );
  }

  endSession(namespace: string, sandbox: string, ts: string): void {
    this.db
      .prepare("UPDATE sessions SET ended_at = ? WHERE namespace = ? AND sandbox = ? AND ended_at IS NULL")
      .run(normalizeTs(ts), namespace, sandbox);
  }

  openSessions(): { namespace: string; sandbox: string; claim?: string; claimUid?: string }[] {
    return (
      this.db.prepare("SELECT namespace, sandbox, claim, claim_uid FROM sessions WHERE ended_at IS NULL").all() as Row[]
    ).map((r) => ({
      namespace: String(r.namespace),
      sandbox: String(r.sandbox),
      claim: str(r.claim),
      claimUid: str(r.claim_uid),
    }));
  }

  getCursor(source: string): string | undefined {
    const r = this.db.prepare("SELECT ts FROM cursors WHERE source = ?").get(source) as Row | undefined;
    return r ? String(r.ts) : undefined;
  }

  setCursor(source: string, ts: string): void {
    this.db
      .prepare("INSERT INTO cursors (source, ts) VALUES (?, ?) ON CONFLICT (source) DO UPDATE SET ts = MAX(ts, excluded.ts)")
      .run(source, normalizeTs(ts));
  }

  private static readonly SESSION_COLUMNS = `
    s.*,
    -- sandbox.gone is vBox noticing, not the client doing anything.
    (SELECT MAX(ts) FROM events e WHERE e.namespace = s.namespace AND e.action != 'sandbox.gone' AND e.kind IN ${SHOWN_KINDS}
       AND (e.sandbox = s.sandbox OR (s.claim_uid IS NOT NULL AND e.claim_uid = s.claim_uid))) AS last_activity,
    (SELECT COUNT(*) FROM events e WHERE e.namespace = s.namespace AND e.sandbox = s.sandbox AND e.kind = 'request') AS steps,
    (SELECT COUNT(*) FROM events e WHERE e.namespace = s.namespace AND e.sandbox = s.sandbox AND e.kind = 'request'
       AND e.action = 'POST /execute') AS commands,
    (SELECT COUNT(*) FROM events e WHERE e.namespace = s.namespace AND e.sandbox = s.sandbox AND e.kind = 'request'
       AND e.action = 'POST /upload') AS uploads,
    (SELECT COUNT(*) FROM events e WHERE e.namespace = s.namespace AND e.sandbox = s.sandbox AND e.kind = 'request'
       AND e.action LIKE 'GET /download/%') AS downloads,
    (SELECT COUNT(*) FROM events e WHERE e.namespace = s.namespace AND e.sandbox = s.sandbox AND e.kind = 'request'
       AND e.status >= 400) AS errors`;

  listSessions(limit = 500): SessionSummary[] {
    return (
      this.db
        .prepare(`SELECT ${AuditStore.SESSION_COLUMNS} FROM sessions s ORDER BY s.started_at DESC LIMIT ?`)
        .all(limit) as Row[]
    ).map(toSession);
  }

  getSession(namespace: string, sandbox: string): SessionSummary | undefined {
    const r = this.db
      .prepare(`SELECT ${AuditStore.SESSION_COLUMNS} FROM sessions s WHERE s.namespace = ? AND s.sandbox = ?`)
      .get(namespace, sandbox) as Row | undefined;
    return r ? toSession(r) : undefined;
  }

  // Everything recorded for one session: events of the sandbox itself plus the
  // claim's lifecycle events, which are recorded before a sandbox is assigned.
  sessionEvents(namespace: string, sandbox: string, claimUid?: string): AuditEvent[] {
    return (
      this.db
        .prepare(
          `SELECT * FROM events WHERE namespace = ? AND (sandbox = ? OR (? IS NOT NULL AND claim_uid = ?))
             AND kind IN ${SHOWN_KINDS}
           ORDER BY ts, id`,
        )
        .all(namespace, sandbox, claimUid ?? null, claimUid ?? null) as Row[]
    ).map(toEvent);
  }

  stats(): { events: number; sessions: number; firstTs?: string; lastTs?: string } {
    const e = this.db.prepare("SELECT COUNT(*) AS n, MIN(ts) AS first, MAX(ts) AS last FROM events").get() as Row;
    const s = this.db.prepare("SELECT COUNT(*) AS n FROM sessions").get() as Row;
    return { events: Number(e.n), sessions: Number(s.n), firstTs: str(e.first), lastTs: str(e.last) };
  }

  // Recomputes every hash in insertion order. Any edited or removed row makes a
  // later prev_hash or hash disagree, and the first such row is reported.
  verifyChain(): { ok: boolean; checked: number; brokenAt?: number } {
    let prev = GENESIS;
    let checked = 0;
    for (const r of this.db.prepare("SELECT * FROM events ORDER BY id").iterate() as Iterable<Row>) {
      const e = toEvent(r);
      const expected = hashOf(prev, e, e.recordedAt);
      if (e.prevHash !== prev || e.hash !== expected) return { ok: false, checked, brokenAt: e.id };
      prev = e.hash;
      checked++;
    }
    return { ok: true, checked };
  }
}

const globalForAudit = globalThis as unknown as { __vboxAudit?: AuditStore };

export function getAuditStore(): AuditStore {
  if (!globalForAudit.__vboxAudit) {
    const dir = process.env.VBOX_DATA_DIR ?? path.join(process.cwd(), "data");
    globalForAudit.__vboxAudit = new AuditStore(dir);
  }
  return globalForAudit.__vboxAudit;
}
