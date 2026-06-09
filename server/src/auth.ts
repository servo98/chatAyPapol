import type { Context, Next } from "hono";
import { db } from "./db";

export type AuthedUser = {
  id: string; username: string; avatar: string | null;
  is_bot: number; banned: number;
};

const qSession = db.query(
  `SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token = ?`);
const qBot = db.query(`SELECT * FROM users WHERE bot_token = ? AND is_bot = 1`);

export function userFromToken(token: string | null | undefined): AuthedUser | null {
  if (!token) return null;
  const t = token.replace(/^(Bearer|Bot)\s+/i, "");
  const u = (qSession.get(t) ?? qBot.get(t)) as any;
  return u && !u.banned ? u : null;
}

declare module "hono" {
  interface ContextVariableMap { user: AuthedUser }
}

export async function requireAuth(c: Context, next: Next) {
  const u = userFromToken(c.req.header("authorization"));
  if (!u) return c.json({ error: "No autorizado" }, 401);
  c.set("user", u);
  await next();
}
