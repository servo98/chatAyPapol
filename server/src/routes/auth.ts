import { Hono } from "hono";
import { db, newId, token, publicUser } from "../db";
import { requireAuth } from "../auth";
import { P, ALL_PERMS } from "../perms";
import { broadcast } from "../gateway";

export const authRoutes = new Hono();

const USERNAME_RE = /^[a-zA-Z0-9_.]{2,32}$/;

authRoutes.post("/auth/register", async (c) => {
  const { invite, username, password } = await c.req.json().catch(() => ({}));
  if (!USERNAME_RE.test(username ?? ""))
    return c.json({ error: "Usuario inválido (2-32 chars: letras, números, _ .)" }, 400);
  if (typeof password !== "string" || password.length < 8)
    return c.json({ error: "Contraseña mínima de 8 caracteres" }, 400);

  const isFirst = !(db.query("SELECT id FROM users WHERE is_bot = 0 LIMIT 1").get());
  if (!isFirst) {
    const inv = db.query("SELECT * FROM invites WHERE code = ?").get(invite ?? "") as any;
    if (!inv || (inv.expires_at && inv.expires_at < Date.now()) ||
        (inv.max_uses > 0 && inv.uses >= inv.max_uses))
      return c.json({ error: "Invitación inválida o expirada" }, 403);
    db.run("UPDATE invites SET uses = uses + 1 WHERE code = ?", [inv.code]);
  }
  if (db.query("SELECT id FROM users WHERE username = ?").get(username))
    return c.json({ error: "Ese usuario ya existe" }, 409);

  const id = newId();
  const hash = await Bun.password.hash(password);
  db.run("INSERT INTO users (id, username, password_hash, created_at) VALUES (?,?,?,?)",
    [id, username, hash, Date.now()]);

  if (isFirst) { // founder gets an Administrator role
    const roleId = newId();
    db.run("INSERT INTO roles (id, name, color, permissions, position) VALUES (?,?,?,?,?)",
      [roleId, "Admin", "#f23f43", P.ADMINISTRATOR | ALL_PERMS, 100]);
    db.run("INSERT INTO member_roles (user_id, role_id) VALUES (?,?)", [id, roleId]);
  }

  const sess = token();
  db.run("INSERT INTO sessions (token, user_id, created_at) VALUES (?,?,?)", [sess, id, Date.now()]);
  const u = db.query("SELECT * FROM users WHERE id = ?").get(id) as any;
  broadcast("MEMBER_JOIN", publicUser(u));
  return c.json({ token: sess, user: publicUser(u) });
});

authRoutes.post("/auth/login", async (c) => {
  const { username, password } = await c.req.json().catch(() => ({}));
  const u = db.query("SELECT * FROM users WHERE username = ? AND is_bot = 0").get(username ?? "") as any;
  if (!u || u.banned || !(await Bun.password.verify(password ?? "", u.password_hash)))
    return c.json({ error: "Usuario o contraseña incorrectos" }, 401);
  const sess = token();
  db.run("INSERT INTO sessions (token, user_id, created_at) VALUES (?,?,?)", [sess, u.id, Date.now()]);
  return c.json({ token: sess, user: publicUser(u) });
});

authRoutes.post("/auth/logout", requireAuth, (c) => {
  const t = c.req.header("authorization")!.replace(/^Bearer\s+/i, "");
  db.run("DELETE FROM sessions WHERE token = ?", [t]);
  return c.json({ ok: true });
});

authRoutes.get("/me", requireAuth, (c) => c.json(publicUser(c.get("user"))));

authRoutes.patch("/me", requireAuth, async (c) => {
  const me = c.get("user");
  const { username, avatar } = await c.req.json().catch(() => ({}));
  if (username !== undefined) {
    if (!USERNAME_RE.test(username)) return c.json({ error: "Usuario inválido" }, 400);
    const taken = db.query("SELECT id FROM users WHERE username = ? AND id != ?").get(username, me.id);
    if (taken) return c.json({ error: "Ese usuario ya existe" }, 409);
    db.run("UPDATE users SET username = ? WHERE id = ?", [username, me.id]);
  }
  if (avatar !== undefined) db.run("UPDATE users SET avatar = ? WHERE id = ?", [avatar, me.id]);
  const u = db.query("SELECT * FROM users WHERE id = ?").get(me.id) as any;
  broadcast("MEMBER_UPDATE", publicUser(u));
  return c.json(publicUser(u));
});
