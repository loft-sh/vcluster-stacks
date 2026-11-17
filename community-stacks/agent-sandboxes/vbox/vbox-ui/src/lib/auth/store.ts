// Sign-in state for vBox: the OIDC provider settings, in-flight logins and
// sessions, in SQLite beside the audit trail ($VBOX_DATA_DIR/auth.db).
//
// A separate database from audit.db on purpose: these tables are mutable (sessions
// are created and deleted, settings are overwritten), and the audit database's
// append-only triggers and hash chain are what make it trustworthy.
//
// - settings: one JSON value per key; "oidc" holds the provider configuration.
// - login_requests: the PKCE verifier and nonce of a login that has been sent to
//   the provider, keyed by its state, for the callback to pick up exactly once.
// - sessions: one row per signed-in browser. The cookie holds a random token and
//   only its SHA-256 is stored, so a copy of the database cannot be replayed as a
//   cookie.
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const SCHEMA = `
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS settings (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  updated_by TEXT
);
CREATE TABLE IF NOT EXISTS login_requests (
  state         TEXT PRIMARY KEY,
  code_verifier TEXT NOT NULL,
  nonce         TEXT NOT NULL,
  return_to     TEXT NOT NULL,
  expires_at    INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  id_hash    TEXT PRIMARY KEY,
  provider   TEXT NOT NULL,
  subject    TEXT NOT NULL,
  username   TEXT NOT NULL,
  name       TEXT,
  email      TEXT,
  groups     TEXT,
  id_token   TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
`;

export const LOGIN_REQUEST_TTL_MS = 10 * 60 * 1000;
export const SESSION_TTL_MS = 8 * 60 * 60 * 1000;

type Row = Record<string, string | number | null>;

const str = (v: unknown) => (v === null || v === undefined ? undefined : String(v));
const hashToken = (token: string) => createHash("sha256").update(token).digest("hex");

export interface LoginRequest {
  state: string;
  codeVerifier: string;
  nonce: string;
  returnTo: string;
}

export interface SessionUser {
  // Which provider configuration signed the user in (issuer and client ID). A
  // session from another configuration is not accepted, so changing the provider
  // signs everyone out.
  provider: string;
  subject: string;
  username: string;
  name?: string;
  email?: string;
  groups: string[];
  idToken?: string;
  expiresAt: number;
}

export interface StoredSetting<T> {
  value: T;
  updatedAt: string;
  updatedBy?: string;
}

export class AuthStore {
  readonly file: string;
  private db: DatabaseSync;

  constructor(dir: string) {
    mkdirSync(dir, { recursive: true });
    this.file = path.join(dir, "auth.db");
    this.db = new DatabaseSync(this.file);
    this.db.exec(SCHEMA);
  }

  getSetting<T>(key: string): StoredSetting<T> | undefined {
    const r = this.db.prepare("SELECT value, updated_at, updated_by FROM settings WHERE key = ?").get(key) as
      | Row
      | undefined;
    if (!r) return undefined;
    return { value: JSON.parse(String(r.value)) as T, updatedAt: String(r.updated_at), updatedBy: str(r.updated_by) };
  }

  setSetting(key: string, value: unknown, updatedBy?: string): void {
    this.db
      .prepare(
        `INSERT INTO settings (key, value, updated_at, updated_by) VALUES (?, ?, ?, ?)
         ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at,
           updated_by = excluded.updated_by`,
      )
      .run(key, JSON.stringify(value), new Date().toISOString(), updatedBy ?? null);
  }

  saveLoginRequest(r: LoginRequest): void {
    const now = Date.now();
    this.db.prepare("DELETE FROM login_requests WHERE expires_at < ?").run(now);
    this.db
      .prepare("INSERT INTO login_requests (state, code_verifier, nonce, return_to, expires_at) VALUES (?, ?, ?, ?, ?)")
      .run(r.state, r.codeVerifier, r.nonce, r.returnTo, now + LOGIN_REQUEST_TTL_MS);
  }

  // Returns the login request and deletes it, so a callback URL works once.
  takeLoginRequest(state: string): LoginRequest | undefined {
    const r = this.db.prepare("SELECT * FROM login_requests WHERE state = ?").get(state) as Row | undefined;
    if (!r) return undefined;
    this.db.prepare("DELETE FROM login_requests WHERE state = ?").run(state);
    if (Number(r.expires_at) < Date.now()) return undefined;
    return {
      state: String(r.state),
      codeVerifier: String(r.code_verifier),
      nonce: String(r.nonce),
      returnTo: String(r.return_to),
    };
  }

  // Creates a session and returns the token for the cookie.
  createSession(u: Omit<SessionUser, "expiresAt">): { token: string; expiresAt: number } {
    const now = Date.now();
    const token = randomBytes(32).toString("base64url");
    const expiresAt = now + SESSION_TTL_MS;
    this.db.prepare("DELETE FROM sessions WHERE expires_at < ?").run(now);
    this.db
      .prepare(
        `INSERT INTO sessions (id_hash, provider, subject, username, name, email, groups, id_token, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        hashToken(token),
        u.provider,
        u.subject,
        u.username,
        u.name ?? null,
        u.email ?? null,
        JSON.stringify(u.groups),
        u.idToken ?? null,
        now,
        expiresAt,
      );
    return { token, expiresAt };
  }

  getSession(token: string): SessionUser | undefined {
    const r = this.db.prepare("SELECT * FROM sessions WHERE id_hash = ?").get(hashToken(token)) as Row | undefined;
    if (!r || Number(r.expires_at) < Date.now()) return undefined;
    return {
      provider: String(r.provider),
      subject: String(r.subject),
      username: String(r.username),
      name: str(r.name),
      email: str(r.email),
      groups: r.groups ? (JSON.parse(String(r.groups)) as string[]) : [],
      idToken: str(r.id_token),
      expiresAt: Number(r.expires_at),
    };
  }

  deleteSession(token: string): void {
    this.db.prepare("DELETE FROM sessions WHERE id_hash = ?").run(hashToken(token));
  }
}

const globalForAuth = globalThis as unknown as { __vboxAuth?: AuthStore };

export function getAuthStore(): AuthStore {
  if (!globalForAuth.__vboxAuth) {
    const dir = process.env.VBOX_DATA_DIR ?? path.join(process.cwd(), "data");
    globalForAuth.__vboxAuth = new AuthStore(dir);
  }
  return globalForAuth.__vboxAuth;
}
