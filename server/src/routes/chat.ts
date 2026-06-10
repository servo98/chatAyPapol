import { Hono } from "hono";
import { join, extname } from "node:path";
import { unlinkSync } from "node:fs";
import { db, newId, token, FILES_DIR, rowMessage, publicUser } from "../db";
import { requireAuth } from "../auth";
import { P, can, channelPerms } from "../perms";
import { broadcast, voiceStates, dispatchInteraction } from "../gateway";
import { checkAutomod } from "../automod";
import { unfurl } from "../unfurl";
import { mintVoiceToken, LIVEKIT_URL } from "../livekit";

export const chatRoutes = new Hono();
chatRoutes.use("*", requireAuth);

const MAX_UPLOAD = 25 * 1024 * 1024;
const SAFE_EXT = /^\.[a-z0-9]{1,8}$/i;

// MIME por extensión cuando el cliente sube octet-stream: sin tipo real el
// chat no sabe que el adjunto es imagen y no muestra la preview inline.
const MIME_BY_EXT: Record<string, string> = {
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp",
  ".mp4": "video/mp4", ".webm": "video/webm", ".mp3": "audio/mpeg",
  ".ogg": "audio/ogg", ".wav": "audio/wav", ".pdf": "application/pdf",
};

async function saveFile(file: File, dir: string, maxBytes: number) {
  if (file.size === 0 || file.size > maxBytes) throw new Error(`Archivo vacío o > ${Math.round(maxBytes / 1e6)} MB`);
  let ext = extname(file.name).toLowerCase();
  if (!SAFE_EXT.test(ext)) ext = "";
  const name = `${newId()}${ext}`;
  await Bun.write(join(FILES_DIR, dir, name), file);
  const type = (!file.type || file.type === "application/octet-stream")
    ? (MIME_BY_EXT[ext] ?? file.type) : file.type;
  return { name: file.name, url: `/files/${dir}/${name}`, size: file.size, type };
}

// ---------- uploads ----------
chatRoutes.post("/uploads", async (c) => {
  if (!can(c.get("user").id, P.ATTACH_FILES)) return c.json({ error: "Sin permiso para adjuntar" }, 403);
  const form = await c.req.formData();
  const file = form.get("file");
  if (!(file instanceof File)) return c.json({ error: "Falta el archivo" }, 400);
  try { return c.json(await saveFile(file, "uploads", MAX_UPLOAD)); }
  catch (e: any) { return c.json({ error: e.message }, 400); }
});

chatRoutes.post("/avatar", async (c) => {
  const form = await c.req.formData();
  const file = form.get("file");
  if (!(file instanceof File)) return c.json({ error: "Falta el archivo" }, 400);
  try {
    const f = await saveFile(file, "avatars", 2 * 1024 * 1024);
    db.run("UPDATE users SET avatar = ? WHERE id = ?", [f.url, c.get("user").id]);
    const u = db.query("SELECT * FROM users WHERE id = ?").get(c.get("user").id);
    broadcast("MEMBER_UPDATE", publicUser(u));
    return c.json(f);
  } catch (e: any) { return c.json({ error: e.message }, 400); }
});

// ---------- categories ----------
chatRoutes.post("/categories", async (c) => {
  if (!can(c.get("user").id, P.MANAGE_CHANNELS)) return c.json({ error: "Sin permiso" }, 403);
  const { name } = await c.req.json();
  const id = newId();
  const pos = (db.query("SELECT COALESCE(MAX(position)+1,0) p FROM categories").get() as any).p;
  db.run("INSERT INTO categories (id, name, position) VALUES (?,?,?)", [id, String(name).slice(0, 100), pos]);
  const cat = db.query("SELECT * FROM categories WHERE id = ?").get(id);
  broadcast("CATEGORY_CREATE", cat);
  return c.json(cat);
});

chatRoutes.patch("/categories/:id", async (c) => {
  if (!can(c.get("user").id, P.MANAGE_CHANNELS)) return c.json({ error: "Sin permiso" }, 403);
  const { name, position } = await c.req.json();
  if (name !== undefined) db.run("UPDATE categories SET name = ? WHERE id = ?", [String(name).slice(0, 100), c.req.param("id")]);
  if (position !== undefined) db.run("UPDATE categories SET position = ? WHERE id = ?", [position | 0, c.req.param("id")]);
  const cat = db.query("SELECT * FROM categories WHERE id = ?").get(c.req.param("id"));
  if (!cat) return c.json({ error: "No existe" }, 404);
  broadcast("CATEGORY_UPDATE", cat);
  return c.json(cat);
});

chatRoutes.delete("/categories/:id", (c) => {
  if (!can(c.get("user").id, P.MANAGE_CHANNELS)) return c.json({ error: "Sin permiso" }, 403);
  db.run("DELETE FROM categories WHERE id = ?", [c.req.param("id")]);
  broadcast("CATEGORY_DELETE", { id: c.req.param("id") });
  return c.json({ ok: true });
});

// ---------- channels ----------
chatRoutes.post("/channels", async (c) => {
  if (!can(c.get("user").id, P.MANAGE_CHANNELS)) return c.json({ error: "Sin permiso" }, 403);
  const { name, type, category_id, topic } = await c.req.json();
  if (!["text", "voice"].includes(type)) return c.json({ error: "Tipo inválido" }, 400);
  const id = newId();
  const pos = (db.query("SELECT COALESCE(MAX(position)+1,0) p FROM channels").get() as any).p;
  const cname = String(name).slice(0, 100).trim();
  db.run("INSERT INTO channels (id, name, type, category_id, topic, position) VALUES (?,?,?,?,?,?)",
    [id, type === "text" ? cname.toLowerCase().replace(/\s+/g, "-") : cname, type, category_id ?? null, topic ?? null, pos]);
  const ch = db.query("SELECT * FROM channels WHERE id = ?").get(id);
  broadcast("CHANNEL_CREATE", ch);
  return c.json(ch);
});

chatRoutes.patch("/channels/:id", async (c) => {
  if (!can(c.get("user").id, P.MANAGE_CHANNELS)) return c.json({ error: "Sin permiso" }, 403);
  const b = await c.req.json();
  const id = c.req.param("id");
  if (b.name !== undefined) db.run("UPDATE channels SET name = ? WHERE id = ?", [String(b.name).slice(0, 100), id]);
  if (b.topic !== undefined) db.run("UPDATE channels SET topic = ? WHERE id = ?", [b.topic, id]);
  if (b.category_id !== undefined) db.run("UPDATE channels SET category_id = ? WHERE id = ?", [b.category_id, id]);
  if (b.position !== undefined) db.run("UPDATE channels SET position = ? WHERE id = ?", [b.position | 0, id]);
  const ch = db.query("SELECT * FROM channels WHERE id = ?").get(id);
  if (!ch) return c.json({ error: "No existe" }, 404);
  broadcast("CHANNEL_UPDATE", ch);
  return c.json(ch);
});

chatRoutes.delete("/channels/:id", (c) => {
  if (!can(c.get("user").id, P.MANAGE_CHANNELS)) return c.json({ error: "Sin permiso" }, 403);
  db.run("DELETE FROM channels WHERE id = ?", [c.req.param("id")]);
  broadcast("CHANNEL_DELETE", { id: c.req.param("id") });
  return c.json({ ok: true });
});

// ---------- channel permission overwrites ----------
chatRoutes.put("/channels/:id/overwrites", async (c) => {
  if (!can(c.get("user").id, P.MANAGE_ROLES)) return c.json({ error: "Sin permiso" }, 403);
  const { target_id, target_type, allow, deny } = await c.req.json();
  if (!["role", "member"].includes(target_type)) return c.json({ error: "target_type inválido" }, 400);
  db.run(`INSERT INTO overwrites (channel_id, target_id, target_type, allow, deny) VALUES (?,?,?,?,?)
          ON CONFLICT(channel_id, target_id) DO UPDATE SET allow = excluded.allow, deny = excluded.deny`,
    [c.req.param("id"), target_id, target_type, allow | 0, deny | 0]);
  const ow = { channel_id: c.req.param("id"), target_id, target_type, allow: allow | 0, deny: deny | 0 };
  broadcast("OVERWRITE_SET", ow);
  return c.json(ow);
});

chatRoutes.delete("/channels/:id/overwrites/:targetId", (c) => {
  if (!can(c.get("user").id, P.MANAGE_ROLES)) return c.json({ error: "Sin permiso" }, 403);
  db.run("DELETE FROM overwrites WHERE channel_id = ? AND target_id = ?",
    [c.req.param("id"), c.req.param("targetId")]);
  broadcast("OVERWRITE_DELETE", { channel_id: c.req.param("id"), target_id: c.req.param("targetId") });
  return c.json({ ok: true });
});

// ---------- messages ----------
const BUILTINS: Record<string, (args: string) => string> = {
  me: (a) => `*${a}*`,
  shrug: (a) => `${a} ¯\\_(ツ)_/¯`.trim(),
  tableflip: (a) => `${a} (╯°□°）╯︵ ┻━┻`.trim(),
  unflip: (a) => `${a} ┬─┬ ノ( ゜-゜ノ)`.trim(),
  spoiler: (a) => `||${a}||`,
};

export function createMessage(row: {
  channel_id: string; author_id?: string | null; content?: string;
  attachments?: unknown[]; sticker_id?: string | null; reply_to?: string | null;
  webhook_name?: string | null; webhook_avatar?: string | null;
}) {
  const id = newId();
  db.run(
    `INSERT INTO messages (id, channel_id, author_id, content, attachments, sticker_id, reply_to, webhook_name, webhook_avatar, created_at)
     VALUES (?,?,?,?,?,?,?,?,?,?)`,
    [id, row.channel_id, row.author_id ?? null, row.content ?? "", JSON.stringify(row.attachments ?? []),
     row.sticker_id ?? null, row.reply_to ?? null, row.webhook_name ?? null, row.webhook_avatar ?? null, Date.now()]);
  const m = rowMessage(db.query("SELECT * FROM messages WHERE id = ?").get(id));
  broadcast("MESSAGE_CREATE", m, row.channel_id);
  return m;
}

chatRoutes.get("/channels/:id/messages", (c) => {
  const me = c.get("user");
  const chId = c.req.param("id");
  if (!can(me.id, P.VIEW_CHANNEL, chId)) return c.json({ error: "Sin permiso" }, 403);
  const before = c.req.query("before");
  const limit = Math.min(parseInt(c.req.query("limit") ?? "50") || 50, 100);
  const rows = before
    ? db.query("SELECT * FROM messages WHERE channel_id = ? AND id < ? ORDER BY id DESC LIMIT ?").all(chId, before, limit)
    : db.query("SELECT * FROM messages WHERE channel_id = ? ORDER BY id DESC LIMIT ?").all(chId, limit);
  return c.json((rows as any[]).map(rowMessage).reverse());
});

chatRoutes.post("/channels/:id/messages", async (c) => {
  const me = c.get("user");
  const chId = c.req.param("id");
  const ch = db.query("SELECT * FROM channels WHERE id = ? AND type = 'text'").get(chId) as any;
  if (!ch) return c.json({ error: "Canal no existe" }, 404);
  const perms = channelPerms(me.id, chId);
  if (!(perms & P.VIEW_CHANNEL) || !(perms & P.SEND_MESSAGES)) return c.json({ error: "Sin permiso" }, 403);

  const b = await c.req.json().catch(() => ({}));
  let content = String(b.content ?? "").slice(0, 4000).trim();
  const attachments = Array.isArray(b.attachments) ? b.attachments.slice(0, 10) : [];
  if (attachments.length && !(perms & P.ATTACH_FILES)) return c.json({ error: "Sin permiso para adjuntar" }, 403);
  if (!content && attachments.length === 0 && !b.sticker_id) return c.json({ error: "Mensaje vacío" }, 400);

  if (!(perms & P.MENTION_EVERYONE) && !(perms & P.ADMINISTRATOR))
    content = content.replace(/@everyone/g, "@​everyone");

  if (!(perms & P.ADMINISTRATOR)) {
    const blocked = checkAutomod(content);
    if (blocked) return c.json({ error: `Mensaje bloqueado por AutoMod: ${blocked}` }, 422);
  }

  // slash commands
  let interaction: { ok: boolean; command: string } | undefined;
  const slash = content.match(/^\/([a-z0-9_-]+)\s*([\s\S]*)$/i);
  if (slash) {
    const [, name, args] = slash;
    const builtin = BUILTINS[name.toLowerCase()];
    if (builtin) content = builtin(args).slice(0, 4000);
    else {
      const cmd = db.query("SELECT * FROM bot_commands WHERE name = ?").get(name.toLowerCase()) as any;
      if (cmd) {
        const msg = createMessage({ channel_id: chId, author_id: me.id, content });
        const ok = dispatchInteraction({
          id: newId(), bot_id: cmd.bot_id, channel_id: chId, user_id: me.id,
          command: cmd.name, args, expires: Date.now() + 30_000,
        });
        return c.json({ ...msg, interaction: { ok, command: cmd.name } });
      }
    }
  }

  const msg = createMessage({
    channel_id: chId, author_id: me.id, content,
    attachments, sticker_id: b.sticker_id ?? null, reply_to: b.reply_to ?? null,
  });
  if ((perms & P.EMBED_LINKS) && content.includes("http")) unfurl(msg.id, chId, content);
  return c.json(interaction ? { ...msg, interaction } : msg);
});

chatRoutes.patch("/channels/:chId/messages/:id", async (c) => {
  const me = c.get("user");
  const m = db.query("SELECT * FROM messages WHERE id = ? AND channel_id = ?")
    .get(c.req.param("id"), c.req.param("chId")) as any;
  if (!m) return c.json({ error: "No existe" }, 404);
  if (m.author_id !== me.id) return c.json({ error: "Solo el autor puede editar" }, 403);
  const { content } = await c.req.json();
  db.run("UPDATE messages SET content = ?, edited_at = ? WHERE id = ?",
    [String(content ?? "").slice(0, 4000), Date.now(), m.id]);
  const updated = rowMessage(db.query("SELECT * FROM messages WHERE id = ?").get(m.id));
  broadcast("MESSAGE_UPDATE", updated, m.channel_id);
  return c.json(updated);
});

chatRoutes.delete("/channels/:chId/messages/:id", (c) => {
  const me = c.get("user");
  const m = db.query("SELECT * FROM messages WHERE id = ? AND channel_id = ?")
    .get(c.req.param("id"), c.req.param("chId")) as any;
  if (!m) return c.json({ error: "No existe" }, 404);
  if (m.author_id !== me.id && !can(me.id, P.MANAGE_MESSAGES, m.channel_id))
    return c.json({ error: "Sin permiso" }, 403);
  db.run("DELETE FROM messages WHERE id = ?", [m.id]);
  broadcast("MESSAGE_DELETE", { id: m.id, channel_id: m.channel_id }, m.channel_id);
  return c.json({ ok: true });
});

// ---------- stickers ----------
chatRoutes.post("/stickers", async (c) => {
  if (!can(c.get("user").id, P.MANAGE_EXPRESSIONS)) return c.json({ error: "Sin permiso" }, 403);
  const form = await c.req.formData();
  const file = form.get("file");
  const name = String(form.get("name") ?? "").slice(0, 50);
  if (!(file instanceof File) || !name) return c.json({ error: "Faltan archivo o nombre" }, 400);
  try {
    const f = await saveFile(file, "stickers", 2 * 1024 * 1024);
    const id = newId();
    db.run("INSERT INTO stickers (id, name, url) VALUES (?,?,?)", [id, name, f.url]);
    const st = db.query("SELECT * FROM stickers WHERE id = ?").get(id);
    broadcast("STICKER_CREATE", st);
    return c.json(st);
  } catch (e: any) { return c.json({ error: e.message }, 400); }
});

chatRoutes.delete("/stickers/:id", (c) => {
  if (!can(c.get("user").id, P.MANAGE_EXPRESSIONS)) return c.json({ error: "Sin permiso" }, 403);
  const st = db.query("SELECT * FROM stickers WHERE id = ?").get(c.req.param("id")) as any;
  if (st) { try { unlinkSync(join(FILES_DIR, "..", st.url.slice(1))); } catch {} }
  db.run("DELETE FROM stickers WHERE id = ?", [c.req.param("id")]);
  broadcast("STICKER_DELETE", { id: c.req.param("id") });
  return c.json({ ok: true });
});

// ---------- soundboard ----------
chatRoutes.post("/sounds", async (c) => {
  if (!can(c.get("user").id, P.MANAGE_EXPRESSIONS)) return c.json({ error: "Sin permiso" }, 403);
  const form = await c.req.formData();
  const file = form.get("file");
  const name = String(form.get("name") ?? "").slice(0, 50);
  if (!(file instanceof File) || !name) return c.json({ error: "Faltan archivo o nombre" }, 400);
  try {
    const f = await saveFile(file, "sounds", 1024 * 1024);
    const id = newId();
    db.run("INSERT INTO sounds (id, name, emoji, url) VALUES (?,?,?,?)",
      [id, name, String(form.get("emoji") ?? "") || null, f.url]);
    const snd = db.query("SELECT * FROM sounds WHERE id = ?").get(id);
    broadcast("SOUND_CREATE", snd);
    return c.json(snd);
  } catch (e: any) { return c.json({ error: e.message }, 400); }
});

chatRoutes.delete("/sounds/:id", (c) => {
  if (!can(c.get("user").id, P.MANAGE_EXPRESSIONS)) return c.json({ error: "Sin permiso" }, 403);
  const snd = db.query("SELECT * FROM sounds WHERE id = ?").get(c.req.param("id")) as any;
  if (snd) { try { unlinkSync(join(FILES_DIR, "..", snd.url.slice(1))); } catch {} }
  db.run("DELETE FROM sounds WHERE id = ?", [c.req.param("id")]);
  broadcast("SOUND_DELETE", { id: c.req.param("id") });
  return c.json({ ok: true });
});

chatRoutes.post("/channels/:id/sounds/:soundId/play", (c) => {
  const me = c.get("user");
  const chId = c.req.param("id");
  const vs = voiceStates.get(me.id);
  if (!vs || vs.channel_id !== chId) return c.json({ error: "No estás en ese canal de voz" }, 400);
  if (!can(me.id, P.USE_SOUNDBOARD, chId)) return c.json({ error: "Sin permiso" }, 403);
  const snd = db.query("SELECT * FROM sounds WHERE id = ?").get(c.req.param("soundId")) as any;
  if (!snd) return c.json({ error: "Sonido no existe" }, 404);
  broadcast("SOUND_PLAY", { channel_id: chId, sound: snd, user_id: me.id }, chId);
  return c.json({ ok: true });
});

// ---------- voice token (LiveKit) ----------
chatRoutes.post("/channels/:id/voice-token", async (c) => {
  const me = c.get("user");
  const ch = db.query("SELECT * FROM channels WHERE id = ? AND type = 'voice'").get(c.req.param("id")) as any;
  if (!ch) return c.json({ error: "Canal no existe" }, 404);
  const perms = channelPerms(me.id, ch.id);
  if (!(perms & P.CONNECT)) return c.json({ error: "Sin permiso para conectar" }, 403);
  const jwt = await mintVoiceToken({
    identity: me.id, name: me.username, room: ch.id,
    canPublish: (perms & P.SPEAK) !== 0,
    canScreenshare: (perms & P.STREAM) !== 0,
  });
  return c.json({ url: LIVEKIT_URL, token: jwt, room: ch.id });
});

// ---------- webhooks (management; public exec lives in index.ts) ----------
chatRoutes.post("/channels/:id/webhooks", async (c) => {
  if (!can(c.get("user").id, P.MANAGE_WEBHOOKS)) return c.json({ error: "Sin permiso" }, 403);
  const { name } = await c.req.json();
  const id = newId(), tok = token();
  db.run("INSERT INTO webhooks (id, token, channel_id, name, created_by) VALUES (?,?,?,?,?)",
    [id, tok, c.req.param("id"), String(name ?? "Webhook").slice(0, 50), c.get("user").id]);
  return c.json({ id, token: tok, channel_id: c.req.param("id"), name, url: `/api/webhooks/${id}/${tok}` });
});

chatRoutes.get("/webhooks", (c) => {
  if (!can(c.get("user").id, P.MANAGE_WEBHOOKS)) return c.json({ error: "Sin permiso" }, 403);
  return c.json(db.query("SELECT id, token, channel_id, name FROM webhooks").all());
});

chatRoutes.delete("/webhooks/:id", (c) => {
  if (!can(c.get("user").id, P.MANAGE_WEBHOOKS)) return c.json({ error: "Sin permiso" }, 403);
  db.run("DELETE FROM webhooks WHERE id = ?", [c.req.param("id")]);
  return c.json({ ok: true });
});
