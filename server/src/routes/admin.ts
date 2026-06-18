import { Hono } from "hono";
import { join } from "node:path";
import { db, newId, token, publicUser, FILES_DIR, EVERYONE_ID } from "../db";
import { requireAuth } from "../auth";
import { P, can, topPosition } from "../perms";
import { broadcast, interactions, readyPayload } from "../gateway";
import { createMessage } from "./chat";

export const adminRoutes = new Hono();
adminRoutes.use("*", requireAuth);

// full state for REST-only consumers (bots)
adminRoutes.get("/state", (c) => c.json(readyPayload(c.get("user").id)));

// ---------- invites ----------
adminRoutes.post("/invites", async (c) => {
  const me = c.get("user");
  if (!can(me.id, P.CREATE_INVITES)) return c.json({ error: "Sin permiso" }, 403);
  const b = await c.req.json().catch(() => ({}));
  const code = token(4); // 8 hex chars
  const expiresAt = b.expires_in_hours ? Date.now() + b.expires_in_hours * 3600_000 : null;
  db.run("INSERT INTO invites (code, created_by, max_uses, expires_at) VALUES (?,?,?,?)",
    [code, me.id, b.max_uses | 0, expiresAt]);
  return c.json({ code, max_uses: b.max_uses | 0, expires_at: expiresAt });
});

adminRoutes.get("/invites", (c) => {
  if (!can(c.get("user").id, P.CREATE_INVITES)) return c.json({ error: "Sin permiso" }, 403);
  return c.json(db.query("SELECT * FROM invites").all());
});

adminRoutes.delete("/invites/:code", (c) => {
  const me = c.get("user");
  const inv = db.query("SELECT * FROM invites WHERE code = ?").get(c.req.param("code")) as any;
  if (!inv) return c.json({ error: "No existe" }, 404);
  if (inv.created_by !== me.id && !can(me.id, P.ADMINISTRATOR)) return c.json({ error: "Sin permiso" }, 403);
  db.run("DELETE FROM invites WHERE code = ?", [inv.code]);
  return c.json({ ok: true });
});

// ---------- roles ----------
adminRoutes.post("/roles", async (c) => {
  const me = c.get("user");
  if (!can(me.id, P.MANAGE_ROLES)) return c.json({ error: "Sin permiso" }, 403);
  const { name, color, permissions } = await c.req.json();
  const id = newId();
  const pos = (db.query("SELECT COALESCE(MAX(position)+1,1) p FROM roles WHERE is_everyone = 0").get() as any).p;
  db.run("INSERT INTO roles (id, name, color, permissions, position) VALUES (?,?,?,?,?)",
    [id, String(name ?? "nuevo rol").slice(0, 50), color ?? null, permissions | 0, pos]);
  const role = db.query("SELECT * FROM roles WHERE id = ?").get(id);
  broadcast("ROLE_CREATE", role);
  return c.json(role);
});

adminRoutes.patch("/roles/:id", async (c) => {
  const me = c.get("user");
  if (!can(me.id, P.MANAGE_ROLES)) return c.json({ error: "Sin permiso" }, 403);
  const role = db.query("SELECT * FROM roles WHERE id = ?").get(c.req.param("id")) as any;
  if (!role) return c.json({ error: "No existe" }, 404);
  if (!can(me.id, P.ADMINISTRATOR) && !role.is_everyone && role.position >= topPosition(me.id))
    return c.json({ error: "No puedes editar un rol igual o superior al tuyo" }, 403);
  const b = await c.req.json();
  if (b.name !== undefined && !role.is_everyone)
    db.run("UPDATE roles SET name = ? WHERE id = ?", [String(b.name).slice(0, 50), role.id]);
  if (b.color !== undefined) db.run("UPDATE roles SET color = ? WHERE id = ?", [b.color, role.id]);
  if (b.permissions !== undefined) db.run("UPDATE roles SET permissions = ? WHERE id = ?", [b.permissions | 0, role.id]);
  if (b.position !== undefined && !role.is_everyone)
    db.run("UPDATE roles SET position = ? WHERE id = ?", [b.position | 0, role.id]);
  const updated = db.query("SELECT * FROM roles WHERE id = ?").get(role.id);
  broadcast("ROLE_UPDATE", updated);
  return c.json(updated);
});

adminRoutes.delete("/roles/:id", (c) => {
  const me = c.get("user");
  if (!can(me.id, P.MANAGE_ROLES)) return c.json({ error: "Sin permiso" }, 403);
  const role = db.query("SELECT * FROM roles WHERE id = ?").get(c.req.param("id")) as any;
  if (!role) return c.json({ error: "No existe" }, 404);
  if (role.is_everyone) return c.json({ error: "@everyone no se puede borrar" }, 400);
  if (!can(me.id, P.ADMINISTRATOR) && role.position >= topPosition(me.id))
    return c.json({ error: "No puedes borrar un rol igual o superior al tuyo" }, 403);
  db.run("DELETE FROM roles WHERE id = ?", [role.id]);
  broadcast("ROLE_DELETE", { id: role.id });
  return c.json({ ok: true });
});

adminRoutes.put("/members/:id/roles", async (c) => {
  const me = c.get("user");
  if (!can(me.id, P.MANAGE_ROLES)) return c.json({ error: "Sin permiso" }, 403);
  const { role_ids } = await c.req.json();
  if (!Array.isArray(role_ids)) return c.json({ error: "role_ids debe ser un array" }, 400);
  const target = c.req.param("id");
  if (!db.query("SELECT id FROM users WHERE id = ?").get(target)) return c.json({ error: "No existe" }, 404);
  db.run("DELETE FROM member_roles WHERE user_id = ?", [target]);
  for (const rid of role_ids) {
    if (rid === EVERYONE_ID) continue;
    if (db.query("SELECT id FROM roles WHERE id = ?").get(rid))
      db.run("INSERT OR IGNORE INTO member_roles (user_id, role_id) VALUES (?,?)", [target, rid]);
  }
  broadcast("MEMBER_ROLES_UPDATE", { user_id: target, role_ids });
  return c.json({ ok: true });
});

// ---------- kick / ban ----------
adminRoutes.delete("/members/:id", (c) => {
  const me = c.get("user");
  if (!can(me.id, P.KICK_MEMBERS)) return c.json({ error: "Sin permiso" }, 403);
  const target = c.req.param("id");
  if (target === me.id) return c.json({ error: "No puedes expulsarte a ti mismo" }, 400);
  db.run("DELETE FROM sessions WHERE user_id = ?", [target]);
  db.run("DELETE FROM member_roles WHERE user_id = ?", [target]);
  db.run("DELETE FROM users WHERE id = ? AND is_bot = 0", [target]);
  broadcast("MEMBER_REMOVE", { user_id: target });
  return c.json({ ok: true });
});

adminRoutes.post("/bans/:id", (c) => {
  const me = c.get("user");
  if (!can(me.id, P.BAN_MEMBERS)) return c.json({ error: "Sin permiso" }, 403);
  const target = c.req.param("id");
  if (target === me.id) return c.json({ error: "No puedes banearte a ti mismo" }, 400);
  db.run("UPDATE users SET banned = 1 WHERE id = ?", [target]);
  db.run("DELETE FROM sessions WHERE user_id = ?", [target]);
  broadcast("MEMBER_REMOVE", { user_id: target, banned: true });
  return c.json({ ok: true });
});

// ---------- automod ----------
adminRoutes.get("/automod", (c) => {
  if (!can(c.get("user").id, P.MANAGE_MESSAGES)) return c.json({ error: "Sin permiso" }, 403);
  return c.json(db.query("SELECT * FROM automod_rules").all());
});

adminRoutes.post("/automod", async (c) => {
  if (!can(c.get("user").id, P.ADMINISTRATOR)) return c.json({ error: "Sin permiso" }, 403);
  const { name, type, pattern } = await c.req.json();
  if (!["words", "regex", "links"].includes(type)) return c.json({ error: "Tipo inválido" }, 400);
  const id = newId();
  db.run("INSERT INTO automod_rules (id, name, type, pattern) VALUES (?,?,?,?)",
    [id, String(name ?? "regla").slice(0, 50), type, String(pattern ?? "")]);
  return c.json(db.query("SELECT * FROM automod_rules WHERE id = ?").get(id));
});

adminRoutes.patch("/automod/:id", async (c) => {
  if (!can(c.get("user").id, P.ADMINISTRATOR)) return c.json({ error: "Sin permiso" }, 403);
  const b = await c.req.json();
  const id = c.req.param("id");
  if (b.name !== undefined) db.run("UPDATE automod_rules SET name = ? WHERE id = ?", [b.name, id]);
  if (b.pattern !== undefined) db.run("UPDATE automod_rules SET pattern = ? WHERE id = ?", [b.pattern, id]);
  if (b.enabled !== undefined) db.run("UPDATE automod_rules SET enabled = ? WHERE id = ?", [b.enabled ? 1 : 0, id]);
  return c.json(db.query("SELECT * FROM automod_rules WHERE id = ?").get(id) ?? { error: "No existe" });
});

adminRoutes.delete("/automod/:id", (c) => {
  if (!can(c.get("user").id, P.ADMINISTRATOR)) return c.json({ error: "Sin permiso" }, 403);
  db.run("DELETE FROM automod_rules WHERE id = ?", [c.req.param("id")]);
  return c.json({ ok: true });
});

// ---------- bots ----------
adminRoutes.post("/bots", async (c) => {
  if (!can(c.get("user").id, P.ADMINISTRATOR)) return c.json({ error: "Sin permiso" }, 403);
  const { username } = await c.req.json();
  if (!/^[a-zA-Z0-9_.-]{2,32}$/.test(username ?? "")) return c.json({ error: "Nombre inválido" }, 400);
  if (db.query("SELECT id FROM users WHERE username = ?").get(username)) return c.json({ error: "Ya existe" }, 409);
  const id = newId(), tok = token(32);
  db.run("INSERT INTO users (id, username, is_bot, bot_token, created_at) VALUES (?,?,1,?,?)",
    [id, username, tok, Date.now()]);
  const u = db.query("SELECT * FROM users WHERE id = ?").get(id) as any;
  broadcast("MEMBER_JOIN", publicUser(u));
  return c.json({ user: publicUser(u), token: tok });
});

adminRoutes.get("/bots", (c) => {
  if (!can(c.get("user").id, P.ADMINISTRATOR)) return c.json({ error: "Sin permiso" }, 403);
  return c.json((db.query("SELECT * FROM users WHERE is_bot = 1").all() as any[])
    .map(u => ({ ...publicUser(u), token: u.bot_token })));
});

adminRoutes.delete("/bots/:id", (c) => {
  if (!can(c.get("user").id, P.ADMINISTRATOR)) return c.json({ error: "Sin permiso" }, 403);
  db.run("DELETE FROM users WHERE id = ? AND is_bot = 1", [c.req.param("id")]);
  broadcast("MEMBER_REMOVE", { user_id: c.req.param("id") });
  return c.json({ ok: true });
});

// bot registers its slash commands with its own token
adminRoutes.put("/bot/commands", async (c) => {
  const me = c.get("user");
  if (!me.is_bot) return c.json({ error: "Solo bots" }, 403);
  const cmds = await c.req.json();
  if (!Array.isArray(cmds)) return c.json({ error: "Se espera un array" }, 400);
  db.run("DELETE FROM bot_commands WHERE bot_id = ?", [me.id]);
  for (const cmd of cmds.slice(0, 50)) {
    const name = String(cmd.name ?? "").toLowerCase().replace(/[^a-z0-9_-]/g, "").slice(0, 32);
    if (name) db.run("INSERT OR REPLACE INTO bot_commands (bot_id, name, description) VALUES (?,?,?)",
      [me.id, name, String(cmd.description ?? "").slice(0, 100)]);
  }
  const all = db.query("SELECT bot_id, name, description FROM bot_commands ORDER BY name").all();
  broadcast("COMMANDS_UPDATE", all);
  return c.json(all);
});

adminRoutes.post("/interactions/:id/respond", async (c) => {
  const me = c.get("user");
  const i = interactions.get(c.req.param("id"));
  if (!i || i.bot_id !== me.id || i.expires < Date.now())
    return c.json({ error: "Interacción inválida o expirada" }, 404);
  interactions.delete(i.id);
  const { content } = await c.req.json();
  const msg = createMessage({
    channel_id: i.channel_id, author_id: me.id,
    content: String(content ?? "").slice(0, 4000),
  });
  return c.json(msg);
});

// ---------- client auto-updates ----------
// Dos fuentes (el cliente no distingue cuál usas):
//   1. Manifiesto local (subes el instalador con POST /api/updates/:platform).
//   2. GitHub Releases: define GITHUB_REPO=usuario/repo y el server hace de
//      espejo de releases/latest — no alojas nada, GitHub pone el CDN.
const releasesPath = join(FILES_DIR, "releases", "releases.json");
const GITHUB_REPO = process.env.GITHUB_REPO ?? "";
// El updater in-app de Windows descarga el .zip de la versión (instalador/swap
// propio, sin Inno). El Setup.exe (primera instalación) NO se sirve por aquí.
const ASSET_EXT: Record<string, RegExp> = {
  windows: /windows.*\.zip$/i, linux: /\.AppImage$/i, macos: /\.(dmg|pkg)$/i,
};
// Instaladores de PRIMERA instalación (para la landing / descarga directa).
// Distinto de ASSET_EXT, que apunta al .zip del auto-update in-app: aquí
// queremos el Setup.exe / AppImage / dmg que descarga un usuario nuevo.
const INSTALLER_EXT: Record<string, RegExp> = {
  windows: /Setup.*\.exe$/i, linux: /\.AppImage$/i, macos: /\.(dmg|pkg)$/i,
};
let ghCache: { at: number; data: any } | null = null;
let ghListCache: { at: number; data: any[] } | null = null;

// Último release crudo de GitHub, cacheado 5 min (compartido por /updates,
// /download y /releases para no multiplicar llamadas a la API de GitHub).
async function rawLatestRelease(): Promise<any | null> {
  if (!GITHUB_REPO) return null;
  try {
    if (!ghCache || Date.now() - ghCache.at > 5 * 60_000) {
      const res = await fetch(`https://api.github.com/repos/${GITHUB_REPO}/releases/latest`, {
        headers: { "user-agent": "chatpapol", accept: "application/vnd.github+json" },
        signal: AbortSignal.timeout(8000),
      });
      if (!res.ok) return null;
      ghCache = { at: Date.now(), data: await res.json() };
    }
    return ghCache.data;
  } catch {
    return null;
  }
}

// Lista de los últimos releases (para enlistar versiones en la landing).
async function rawReleaseList(): Promise<any[]> {
  if (!GITHUB_REPO) return [];
  try {
    if (!ghListCache || Date.now() - ghListCache.at > 5 * 60_000) {
      const res = await fetch(`https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=10`, {
        headers: { "user-agent": "chatpapol", accept: "application/vnd.github+json" },
        signal: AbortSignal.timeout(8000),
      });
      if (!res.ok) return [];
      const data = await res.json();
      ghListCache = { at: Date.now(), data: Array.isArray(data) ? data : [] };
    }
    return ghListCache.data;
  } catch {
    return [];
  }
}

function installerUrl(rel: any, re: RegExp): string | null {
  return (rel?.assets ?? []).find((a: any) => re.test(a.name))?.browser_download_url ?? null;
}

async function githubRelease(platform: string) {
  if (!ASSET_EXT[platform]) return null;
  const rel = await rawLatestRelease();
  if (!rel) return null;
  const asset = (rel.assets ?? []).find((a: any) => ASSET_EXT[platform].test(a.name));
  if (!asset) return null;
  return {
    version: String(rel.tag_name ?? "").replace(/^v/, ""),
    url: asset.browser_download_url, // checksum no disponible vía API: el cliente lo omite
    sha256: "",
    notes: String(rel.name ?? rel.body ?? "").slice(0, 500),
    source: "github",
  };
}

// Consultar la última versión es público (no hace falta sesión para actualizarse).
export const publicUpdates = new Hono();
publicUpdates.get("/updates/:platform", async (c) => {
  const manifest = await Bun.file(releasesPath).json().catch(() => ({}));
  const rel = manifest[c.req.param("platform")] ?? await githubRelease(c.req.param("platform"));
  return rel ? c.json(rel) : c.json({ error: "Sin releases para esa plataforma" }, 404);
});

// Descarga directa del INSTALADOR (primera instalación) para la landing.
// 302 → asset del último release; funciona con el nombre versionado actual
// (no espera a un asset de nombre fijo). Uso en la landing:
//   <a href="https://chat.aypapol.com/api/download/windows">Descargar</a>
publicUpdates.get("/download/:platform", async (c) => {
  const re = INSTALLER_EXT[c.req.param("platform")];
  if (!re) return c.json({ error: "Plataforma inválida" }, 400);
  const url = installerUrl(await rawLatestRelease(), re);
  if (!url) return c.json({ error: "Sin instalador para esa plataforma" }, 404);
  return c.redirect(url, 302);
});

// Lista de versiones (último ↓ a más viejas) con notas y enlaces de descarga
// por plataforma — para mostrar versiones/changelog en la landing.
publicUpdates.get("/releases", async (c) => {
  const list = (await rawReleaseList()).filter((r) => !r.draft);
  return c.json(list.map((rel) => ({
    version: String(rel.tag_name ?? "").replace(/^v/, ""),
    name: rel.name ?? rel.tag_name ?? "",
    notes: String(rel.body ?? "").slice(0, 4000),
    published_at: rel.published_at ?? null,
    prerelease: !!rel.prerelease,
    downloads: {
      windows: installerUrl(rel, INSTALLER_EXT.windows),
      linux: installerUrl(rel, INSTALLER_EXT.linux),
      macos: installerUrl(rel, INSTALLER_EXT.macos),
    },
  })));
});

adminRoutes.post("/updates/:platform", async (c) => {
  if (!can(c.get("user").id, P.ADMINISTRATOR)) return c.json({ error: "Sin permiso" }, 403);
  const platform = c.req.param("platform");
  const form = await c.req.formData();
  const file = form.get("file");
  const version = String(form.get("version") ?? "");
  if (!(file instanceof File) || !/^\d+\.\d+\.\d+$/.test(version))
    return c.json({ error: "Faltan archivo o versión (x.y.z)" }, 400);
  const fname = `chatpapol-${platform}-${version}${file.name.match(/\.[a-zA-Z0-9.]+$/)?.[0] ?? ""}`;
  const bytes = await file.arrayBuffer();
  await Bun.write(join(FILES_DIR, "releases", fname), bytes);
  const sha = new Bun.CryptoHasher("sha256").update(new Uint8Array(bytes)).digest("hex");
  const manifest = await Bun.file(releasesPath).json().catch(() => ({}));
  manifest[platform] = {
    version, url: `/files/releases/${fname}`, sha256: sha,
    notes: String(form.get("notes") ?? ""), published_at: Date.now(),
  };
  await Bun.write(releasesPath, JSON.stringify(manifest, null, 2));
  return c.json(manifest[platform]);
});
