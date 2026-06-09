import type { ServerWebSocket } from "bun";
import { db, publicUser, EVERYONE_ID } from "./db";
import { P, can } from "./perms";

export type WSData = { userId: string };
type Sock = ServerWebSocket<WSData>;

const sockets = new Map<string, Set<Sock>>(); // userId -> connections
export type VoiceState = { channel_id: string; mute: boolean; deaf: boolean; streaming: boolean };
export const voiceStates = new Map<string, VoiceState>();

export function onlineUserIds(): string[] {
  return [...sockets.keys()];
}

function send(ws: Sock, t: string, d: unknown) {
  ws.send(JSON.stringify({ t, d }));
}

export function sendToUser(userId: string, t: string, d: unknown) {
  const set = sockets.get(userId);
  if (set) { const msg = JSON.stringify({ t, d }); for (const ws of set) ws.send(msg); }
}

/** Broadcast to everyone online; if channelId given, only to users who can VIEW_CHANNEL it. */
export function broadcast(t: string, d: unknown, channelId?: string) {
  const msg = JSON.stringify({ t, d });
  for (const [userId, set] of sockets) {
    if (channelId && !can(userId, P.VIEW_CHANNEL, channelId)) continue;
    for (const ws of set) ws.send(msg);
  }
}

function fullState(userId: string) {
  const users = (db.query("SELECT * FROM users WHERE banned = 0").all() as any[]).map(publicUser);
  const roles = db.query("SELECT * FROM roles ORDER BY position DESC").all();
  const categories = db.query("SELECT * FROM categories ORDER BY position").all();
  // Channel metadata goes to every member; clients hide non-visible channels using the
  // same permission resolution. Message CONTENT is always filtered server-side.
  const channels = db.query("SELECT * FROM channels ORDER BY position").all();
  const memberRoles = db.query("SELECT * FROM member_roles").all();
  const stickers = db.query("SELECT * FROM stickers ORDER BY name").all();
  const sounds = db.query("SELECT * FROM sounds ORDER BY name").all();
  const overwrites = db.query("SELECT * FROM overwrites").all();
  const commands = db.query("SELECT bot_id, name, description FROM bot_commands ORDER BY name").all();
  return {
    user: publicUser(db.query("SELECT * FROM users WHERE id = ?").get(userId)),
    users, roles, categories, channels, member_roles: memberRoles, overwrites,
    stickers, sounds, commands,
    online: onlineUserIds(),
    voice_states: [...voiceStates.entries()].map(([uid, v]) => ({ user_id: uid, ...v })),
    everyone_role_id: EVERYONE_ID,
  };
}

export function readyPayload(userId: string) { return fullState(userId); }

function leaveVoice(userId: string) {
  const vs = voiceStates.get(userId);
  if (!vs) return;
  voiceStates.delete(userId);
  broadcast("VOICE_STATE", { user_id: userId, channel_id: null });
}

export const websocket = {
  open(ws: Sock) {
    const { userId } = ws.data;
    let set = sockets.get(userId);
    const firstConn = !set;
    if (!set) sockets.set(userId, (set = new Set()));
    set.add(ws);
    send(ws, "READY", fullState(userId));
    if (firstConn) broadcast("PRESENCE_UPDATE", { user_id: userId, online: true });
  },

  message(ws: Sock, raw: string | Buffer) {
    const { userId } = ws.data;
    let msg: { t: string; d?: any };
    try { msg = JSON.parse(String(raw)); } catch { return; }
    const d = msg.d ?? {};
    switch (msg.t) {
      case "PING":
        send(ws, "PONG", null);
        break;
      case "TYPING":
        if (typeof d.channel_id === "string" && can(userId, P.SEND_MESSAGES, d.channel_id))
          broadcast("TYPING", { channel_id: d.channel_id, user_id: userId }, d.channel_id);
        break;
      case "VOICE_JOIN": {
        const ch = db.query("SELECT * FROM channels WHERE id = ? AND type = 'voice'").get(d.channel_id) as any;
        if (!ch || !can(userId, P.CONNECT, ch.id)) return;
        const vs: VoiceState = { channel_id: ch.id, mute: !!d.mute, deaf: !!d.deaf, streaming: false };
        voiceStates.set(userId, vs);
        broadcast("VOICE_STATE", { user_id: userId, ...vs });
        break;
      }
      case "VOICE_STATE": {
        const vs = voiceStates.get(userId);
        if (!vs) return;
        if (typeof d.mute === "boolean") vs.mute = d.mute;
        if (typeof d.deaf === "boolean") vs.deaf = d.deaf;
        if (typeof d.streaming === "boolean") vs.streaming = d.streaming && can(userId, P.STREAM, vs.channel_id);
        broadcast("VOICE_STATE", { user_id: userId, ...vs });
        break;
      }
      case "VOICE_LEAVE":
        leaveVoice(userId);
        break;
    }
  },

  close(ws: Sock) {
    const { userId } = ws.data;
    const set = sockets.get(userId);
    if (!set) return;
    set.delete(ws);
    if (set.size === 0) {
      sockets.delete(userId);
      leaveVoice(userId);
      broadcast("PRESENCE_UPDATE", { user_id: userId, online: false });
    }
  },
};

// ---- bot interactions ----
export type Interaction = {
  id: string; bot_id: string; channel_id: string; user_id: string;
  command: string; args: string; expires: number;
};
export const interactions = new Map<string, Interaction>();

export function dispatchInteraction(i: Interaction): boolean {
  if (!sockets.has(i.bot_id)) return false;
  interactions.set(i.id, i);
  setTimeout(() => interactions.delete(i.id), 30_000);
  sendToUser(i.bot_id, "INTERACTION_CREATE", {
    id: i.id, command: i.command, args: i.args,
    channel_id: i.channel_id, user_id: i.user_id,
  });
  return true;
}
