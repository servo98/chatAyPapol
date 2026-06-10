import { Hono } from "hono";
import { db, newId, token, publicUser } from "../db";
import { requireAuth } from "../auth";
import { P, ALL_PERMS } from "../perms";
import { broadcast } from "../gateway";
import { newTotpSecret, verifyTotp, totpUri } from "../totp";

export const authRoutes = new Hono();

/** 2FA activo y código inválido → mensaje de error; null = OK. El 2FA solo
 * protege acciones sensibles (credenciales y recuperación), no el login. */
function totpGate(u: any, code: unknown): string | null {
  if (!u.totp_ok || !u.totp_secret) return null; // cuentas pre-2FA: sin candado
  return verifyTotp(u.totp_secret, String(code ?? "")) ? null : "Código 2FA inválido";
}

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
  const totpSecret = newTotpSecret(); // 2FA de fábrica: se confirma con el QR
  db.run("INSERT INTO users (id, username, password_hash, created_at, totp_secret) VALUES (?,?,?,?,?)",
    [id, username, hash, Date.now(), totpSecret]);

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
  return c.json({
    token: sess, user: publicUser(u),
    totp: { secret: totpSecret, uri: totpUri(username, totpSecret) },
  });
});

// Confirma el enrolamiento 2FA: el usuario escaneó el QR y manda su primer
// código válido. Hasta entonces el candado no aplica (totp_ok = 0).
authRoutes.post("/auth/totp/confirm", requireAuth, async (c) => {
  const me = c.get("user");
  const { code } = await c.req.json().catch(() => ({}));
  if (!me.totp_secret) return c.json({ error: "Sin 2FA pendiente" }, 400);
  if (!verifyTotp(me.totp_secret, String(code ?? "")))
    return c.json({ error: "Código inválido, revisa tu app de autenticación" }, 400);
  db.run("UPDATE users SET totp_ok = 1 WHERE id = ?", [me.id]);
  return c.json({ ok: true });
});

// Enrola 2FA en una cuenta existente (pre-2FA): genera secreto nuevo.
authRoutes.post("/auth/totp/enroll", requireAuth, async (c) => {
  const me = c.get("user");
  if (me.totp_ok) return c.json({ error: "Ya tienes 2FA activo" }, 400);
  const secret = newTotpSecret();
  db.run("UPDATE users SET totp_secret = ?, totp_ok = 0 WHERE id = ?", [secret, me.id]);
  return c.json({ secret, uri: totpUri(me.username, secret) });
});

// Cambio de contraseña: contraseña actual + código 2FA (si está activo).
authRoutes.post("/auth/password", requireAuth, async (c) => {
  const me = c.get("user");
  const { current, password, code } = await c.req.json().catch(() => ({}));
  if (typeof password !== "string" || password.length < 8)
    return c.json({ error: "Contraseña mínima de 8 caracteres" }, 400);
  if (!(await Bun.password.verify(current ?? "", me.password_hash)))
    return c.json({ error: "Contraseña actual incorrecta" }, 401);
  const gate = totpGate(me, code);
  if (gate) return c.json({ error: gate }, 401);
  db.run("UPDATE users SET password_hash = ? WHERE id = ?",
    [await Bun.password.hash(password), me.id]);
  // cierra las demás sesiones por seguridad (conserva la actual)
  const t = c.req.header("authorization")!.replace(/^Bearer\s+/i, "");
  db.run("DELETE FROM sessions WHERE user_id = ? AND token != ?", [me.id, t]);
  return c.json({ ok: true });
});

// Recuperación SIN email: username + código 2FA → contraseña nueva.
authRoutes.post("/auth/recover", async (c) => {
  const { username, code, password } = await c.req.json().catch(() => ({}));
  if (typeof password !== "string" || password.length < 8)
    return c.json({ error: "Contraseña mínima de 8 caracteres" }, 400);
  const u = db.query("SELECT * FROM users WHERE username = ? AND is_bot = 0").get(username ?? "") as any;
  // respuesta uniforme: no revelar si el usuario existe o si tiene 2FA
  if (!u || u.banned || !u.totp_ok || !u.totp_secret ||
      !verifyTotp(u.totp_secret, String(code ?? "")))
    return c.json({ error: "Usuario o código 2FA incorrectos" }, 401);
  db.run("UPDATE users SET password_hash = ? WHERE id = ?",
    [await Bun.password.hash(password), u.id]);
  db.run("DELETE FROM sessions WHERE user_id = ?", [u.id]);
  const sess = token();
  db.run("INSERT INTO sessions (token, user_id, created_at) VALUES (?,?,?)", [sess, u.id, Date.now()]);
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
  const { username, avatar, code } = await c.req.json().catch(() => ({}));
  if (username !== undefined) {
    if (!USERNAME_RE.test(username)) return c.json({ error: "Usuario inválido" }, 400);
    const gate = totpGate(me, code); // cambiar username es acción sensible
    if (gate) return c.json({ error: gate }, 401);
    const taken = db.query("SELECT id FROM users WHERE username = ? AND id != ?").get(username, me.id);
    if (taken) return c.json({ error: "Ese usuario ya existe" }, 409);
    db.run("UPDATE users SET username = ? WHERE id = ?", [username, me.id]);
  }
  if (avatar !== undefined) db.run("UPDATE users SET avatar = ? WHERE id = ?", [avatar, me.id]);
  const u = db.query("SELECT * FROM users WHERE id = ?").get(me.id) as any;
  broadcast("MEMBER_UPDATE", publicUser(u));
  return c.json(publicUser(u));
});
