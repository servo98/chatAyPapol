import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

export const DATA_DIR = join(import.meta.dir, "..", "data");
export const FILES_DIR = join(DATA_DIR, "files");
for (const d of ["uploads", "stickers", "sounds", "avatars", "releases"])
  mkdirSync(join(FILES_DIR, d), { recursive: true });

export const db = new Database(join(DATA_DIR, "app.db"), { create: true });
db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  username TEXT UNIQUE NOT NULL COLLATE NOCASE,
  password_hash TEXT,
  avatar TEXT,
  is_bot INTEGER NOT NULL DEFAULT 0,
  bot_token TEXT,
  banned INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS invites (
  code TEXT PRIMARY KEY,
  created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
  uses INTEGER NOT NULL DEFAULT 0,
  max_uses INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER
);
CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS channels (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('text','voice')),
  category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
  topic TEXT,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  author_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  content TEXT NOT NULL DEFAULT '',
  attachments TEXT NOT NULL DEFAULT '[]',
  embeds TEXT NOT NULL DEFAULT '[]',
  sticker_id TEXT,
  reply_to TEXT,
  webhook_name TEXT,
  webhook_avatar TEXT,
  created_at INTEGER NOT NULL,
  edited_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel_id, id);
CREATE TABLE IF NOT EXISTS roles (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  color TEXT,
  permissions INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL DEFAULT 0,
  is_everyone INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS member_roles (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);
CREATE TABLE IF NOT EXISTS overwrites (
  channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  target_id TEXT NOT NULL,
  target_type TEXT NOT NULL CHECK (target_type IN ('role','member')),
  allow INTEGER NOT NULL DEFAULT 0,
  deny INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (channel_id, target_id)
);
CREATE TABLE IF NOT EXISTS webhooks (
  id TEXT PRIMARY KEY,
  token TEXT NOT NULL,
  channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  avatar TEXT,
  created_by TEXT
);
CREATE TABLE IF NOT EXISTS stickers (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  url TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sounds (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  emoji TEXT,
  url TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS automod_rules (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('words','regex','links')),
  pattern TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS bot_commands (
  bot_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (bot_id, name)
);
`);

// Monotonic, sortable ids (time-ordered like snowflakes).
let lastId = 0;
export function newId(): string {
  let id = Date.now() * 4096;
  if (id <= lastId) id = lastId + 1;
  lastId = id;
  return id.toString();
}

export function token(bytes = 24): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(bytes))).toString("hex");
}

export type User = {
  id: string; username: string; avatar: string | null;
  is_bot: number; banned: number; created_at: number;
};

export function publicUser(u: any): User {
  return { id: u.id, username: u.username, avatar: u.avatar, is_bot: u.is_bot, banned: u.banned, created_at: u.created_at };
}

export function rowMessage(m: any) {
  return { ...m, attachments: JSON.parse(m.attachments), embeds: JSON.parse(m.embeds) };
}

// ---- seed ----
export const EVERYONE_ID = "everyone";
export function seed(defaultEveryonePerms: number) {
  if (!db.query("SELECT id FROM roles WHERE is_everyone = 1").get()) {
    db.run("INSERT INTO roles (id, name, permissions, position, is_everyone) VALUES (?,?,?,?,1)",
      [EVERYONE_ID, "@everyone", defaultEveryonePerms, 0]);
    const cat = newId();
    db.run("INSERT INTO categories (id, name, position) VALUES (?,?,0)", [cat, "General"]);
    db.run("INSERT INTO channels (id, name, type, category_id, topic, position) VALUES (?,?,?,?,?,0)",
      [newId(), "general", "text", cat, "Bienvenido a ChatPapol 🎉"]);
    db.run("INSERT INTO channels (id, name, type, category_id, position) VALUES (?,?,?,?,1)",
      [newId(), "Voz General", "voice", cat]);
  }
}
