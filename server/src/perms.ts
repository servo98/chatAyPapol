import { db, EVERYONE_ID } from "./db";

export const P = {
  ADMINISTRATOR:     1 << 0,
  MANAGE_CHANNELS:   1 << 1,
  MANAGE_ROLES:      1 << 2,
  MANAGE_MESSAGES:   1 << 3,
  MANAGE_WEBHOOKS:   1 << 4,
  MANAGE_EXPRESSIONS: 1 << 5, // stickers + sounds
  KICK_MEMBERS:      1 << 6,
  BAN_MEMBERS:       1 << 7,
  CREATE_INVITES:    1 << 8,
  VIEW_CHANNEL:      1 << 9,
  SEND_MESSAGES:     1 << 10,
  EMBED_LINKS:       1 << 11,
  ATTACH_FILES:      1 << 12,
  MENTION_EVERYONE:  1 << 13,
  CONNECT:           1 << 14,
  SPEAK:             1 << 15,
  STREAM:            1 << 16,
  USE_SOUNDBOARD:    1 << 17,
  MUTE_MEMBERS:      1 << 18,
  MOVE_MEMBERS:      1 << 19,
  CONTROL_AMBIENCE:  1 << 20, // activar/cambiar la cama de ambiente de la sala
} as const;

export const ALL_PERMS = Object.values(P).reduce((a, b) => a | b, 0);
export const DEFAULT_EVERYONE =
  P.VIEW_CHANNEL | P.SEND_MESSAGES | P.EMBED_LINKS | P.ATTACH_FILES |
  P.CONNECT | P.SPEAK | P.STREAM | P.USE_SOUNDBOARD | P.CREATE_INVITES;

const qMemberRoles = db.query(
  `SELECT r.* FROM roles r JOIN member_roles mr ON mr.role_id = r.id WHERE mr.user_id = ?`);
const qEveryone = db.query(`SELECT * FROM roles WHERE is_everyone = 1`);
const qOverwrites = db.query(`SELECT * FROM overwrites WHERE channel_id = ?`);

export function memberRoleIds(userId: string): string[] {
  return (qMemberRoles.all(userId) as any[]).map(r => r.id);
}

export function basePerms(userId: string): number {
  let perms = (qEveryone.get() as any)?.permissions ?? 0;
  for (const r of qMemberRoles.all(userId) as any[]) perms |= r.permissions;
  return perms;
}

/** Discord-style resolution: base → @everyone overwrite → role overwrites → member overwrite. */
export function channelPerms(userId: string, channelId: string): number {
  let perms = basePerms(userId);
  if (perms & P.ADMINISTRATOR) return ALL_PERMS;
  const ows = qOverwrites.all(channelId) as any[];
  const roleIds = new Set(memberRoleIds(userId));

  const ev = ows.find(o => o.target_type === "role" && o.target_id === EVERYONE_ID);
  if (ev) perms = (perms & ~ev.deny) | ev.allow;

  let allow = 0, deny = 0;
  for (const o of ows) if (o.target_type === "role" && roleIds.has(o.target_id)) { allow |= o.allow; deny |= o.deny; }
  perms = (perms & ~deny) | allow;

  const me = ows.find(o => o.target_type === "member" && o.target_id === userId);
  if (me) perms = (perms & ~me.deny) | me.allow;
  return perms;
}

export function can(userId: string, perm: number, channelId?: string): boolean {
  const perms = channelId ? channelPerms(userId, channelId) : basePerms(userId);
  return (perms & P.ADMINISTRATOR) !== 0 || (perms & perm) === perm;
}

/** Highest role position; used for role hierarchy checks. */
export function topPosition(userId: string): number {
  if (basePerms(userId) & P.ADMINISTRATOR) {
    // admins still ordered by role position; fall through
  }
  const roles = qMemberRoles.all(userId) as any[];
  return roles.reduce((m, r) => Math.max(m, r.position), 0);
}
