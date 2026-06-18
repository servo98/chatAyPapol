import { Hono } from "hono";
import { cors } from "hono/cors";
import { join } from "node:path";
import { db, seed, FILES_DIR } from "./db";
import { DEFAULT_EVERYONE } from "./perms";
import { userFromToken } from "./auth";
import { websocket, type WSData, startVoiceReconciler } from "./gateway";
import { authRoutes } from "./routes/auth";
import { chatRoutes } from "./routes/chat";
import { adminRoutes, publicUpdates } from "./routes/admin";
import { createMessage } from "./routes/chat";

seed(DEFAULT_EVERYONE);

const app = new Hono();
app.use("/api/*", cors());

// Public webhook execution (Discord-style: auth is the token in the URL).
app.post("/api/webhooks/:id/:token", async (c) => {
  const wh = db.query("SELECT * FROM webhooks WHERE id = ? AND token = ?")
    .get(c.req.param("id"), c.req.param("token")) as any;
  if (!wh) return c.json({ error: "Webhook inválido" }, 404);
  const b = await c.req.json().catch(() => ({}));
  const content = String(b.content ?? "").slice(0, 4000);
  if (!content) return c.json({ error: "content requerido" }, 400);
  const msg = createMessage({
    channel_id: wh.channel_id, content,
    webhook_name: String(b.username ?? wh.name).slice(0, 50),
    webhook_avatar: typeof b.avatar_url === "string" ? b.avatar_url.slice(0, 500) : wh.avatar,
  });
  return c.json(msg);
});

app.route("/api", publicUpdates);
app.route("/api", authRoutes);
app.route("/api", chatRoutes);
app.route("/api", adminRoutes);

// Static files (uploads, stickers, sounds, avatars, releases) with immutable cache.
app.get("/files/*", async (c) => {
  const rel = c.req.path.slice("/files/".length);
  if (rel.includes("..")) return c.text("nope", 400);
  const f = Bun.file(join(FILES_DIR, rel));
  if (!(await f.exists())) return c.text("not found", 404);
  return new Response(f, { headers: { "cache-control": "public, max-age=31536000, immutable" } });
});

app.get("/", (c) => c.json({ name: "chatpapol", ok: true }));

const port = Number(process.env.PORT ?? 3210);
const server = Bun.serve<WSData, {}>({
  port,
  fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname === "/gateway") {
      const user = userFromToken(url.searchParams.get("token"));
      if (!user) return new Response("unauthorized", { status: 401 });
      if (srv.upgrade(req, { data: { userId: user.id } })) return undefined;
      return new Response("upgrade failed", { status: 400 });
    }
    return app.fetch(req, srv);
  },
  websocket,
});

// Reconcilia la presencia de voz con LiveKit (sana el caso "reinicié el backend y
// los oigo pero no salen en la UI"). No-op si el SFU no es alcanzable.
startVoiceReconciler();

console.log(`⚡ chatpapol server en http://localhost:${server.port} (gateway: /gateway)`);
