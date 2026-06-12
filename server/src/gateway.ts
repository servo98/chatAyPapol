import type { ServerWebSocket } from "bun";
import { db, publicUser, EVERYONE_ID } from "./db";
import { P, can } from "./perms";
import { liveVoiceParticipants } from "./livekit";

export type WSData = { userId: string };
type Sock = ServerWebSocket<WSData>;

const sockets = new Map<string, Set<Sock>>(); // userId -> connections
export type VoiceState = { channel_id: string; mute: boolean; deaf: boolean; streaming: boolean };
export const voiceStates = new Map<string, VoiceState>();

// AMBIENTE de sala: cama de sonido compartida por canal de voz. NO va por WebRTC
// (cada cliente reproduce un clip BUNDLEADO localmente); el server solo coordina
// qué suena y desde cuándo, para que todos arranquen sincronizados (started_at en
// ms del server) y los que entran tarde caigan en el punto correcto.
//   channel_id (voz) -> { ambience_id, started_at(ms server), paused }
//   paused_at: ms del server en que se pausó (para que late joiners caigan en la
//   posición congelada correcta). Ausente mientras suena.
export type AmbienceState = { ambience_id: string; started_at: number; paused: boolean; paused_at?: number };
export const roomAmbience = new Map<string, AmbienceState>();
// Lista blanca de ids válidos. DEBE coincidir con client/assets/ambience_manifest.json.
const AMBIENCE_IDS = new Set(["rain", "ocean", "wind", "fire", "cave", "scifi"]);

/** ¿Queda alguien en el canal de voz? Si no, se apaga su ambiente. */
function cleanupAmbience(channelId: string) {
  if (!roomAmbience.has(channelId)) return;
  for (const v of voiceStates.values()) if (v.channel_id === channelId) return;
  roomAmbience.delete(channelId);
  broadcast("AMBIENCE_STATE", { channel_id: channelId, ambience_id: null }, channelId);
}

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
    ambience_states: [...roomAmbience.entries()].map(([cid, a]) => ({ channel_id: cid, ...a })),
    everyone_role_id: EVERYONE_ID,
  };
}

export function readyPayload(userId: string) { return fullState(userId); }

function leaveVoice(userId: string) {
  const vs = voiceStates.get(userId);
  if (!vs) return;
  voiceStates.delete(userId);
  broadcast("VOICE_STATE", { user_id: userId, channel_id: null });
  cleanupAmbience(vs.channel_id); // si el canal quedó vacío, apaga su ambiente
}

// Sincroniza voiceStates (en memoria) con quién está REALMENTE en el SFU. Cubre el
// caso en que el backend se reinicia y pierde voiceStates pero LiveKit mantiene a la
// gente conectada: sin esto, los oyes pero NO salen en la UI (lo que pasó). También
// sana cualquier deriva (un VOICE_JOIN/LEAVE perdido, un cliente que murió sin
// despedirse). Si el SFU no responde, NO toca nada: jamás borra por un fallo de red.
let reconcileTimer: ReturnType<typeof setInterval> | null = null;
export async function reconcileVoice() {
  let live: Map<string, string>;
  try {
    live = await liveVoiceParticipants();
  } catch {
    return; // SFU inalcanzable → conservamos el estado actual
  }
  // Altas/cambios de canal según el SFU (mute/deaf no los conoce LiveKit: en altas
  // nuevas quedan en false hasta que el cliente reafirme su VOICE_STATE).
  for (const [uid, room] of live) {
    const cur = voiceStates.get(uid);
    if (!cur) {
      const vs: VoiceState = { channel_id: room, mute: false, deaf: false, streaming: false };
      voiceStates.set(uid, vs);
      broadcast("VOICE_STATE", { user_id: uid, ...vs });
    } else if (cur.channel_id !== room) {
      cur.channel_id = room;
      broadcast("VOICE_STATE", { user_id: uid, ...cur });
    }
  }
  // Bajas: en voiceStates pero ya no en el SFU.
  for (const uid of [...voiceStates.keys()]) {
    if (!live.has(uid)) {
      const ch = voiceStates.get(uid)!.channel_id;
      voiceStates.delete(uid);
      broadcast("VOICE_STATE", { user_id: uid, channel_id: null });
      cleanupAmbience(ch);
    }
  }
}

// Arranca la reconciliación: una pasada al inicio (sana el reinicio) y luego
// periódica como red de seguridad. El camino normal sigue siendo instantáneo vía
// los VOICE_JOIN/LEAVE del cliente; esto solo corrige la deriva.
export function startVoiceReconciler() {
  if (reconcileTimer) return;
  setTimeout(reconcileVoice, 3000);
  reconcileTimer = setInterval(reconcileVoice, 20_000);
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
      // ---- ambiente de sala (cama de sonido compartida, sin WebRTC) ----
      // Quien lo controla debe estar EN el canal de voz y tener USE_SOUNDBOARD
      // (misma puerta que el soundboard: el dueño la gobierna por rol/canal).
      case "AMBIENCE_SET": {
        const chId = d.channel_id as string;
        const ambId = d.ambience_id as string;
        if (voiceStates.get(userId)?.channel_id !== chId) return;
        if (!AMBIENCE_IDS.has(ambId) || !can(userId, P.USE_SOUNDBOARD, chId)) return;
        const st: AmbienceState = { ambience_id: ambId, started_at: Date.now(), paused: false };
        roomAmbience.set(chId, st);
        broadcast("AMBIENCE_STATE", { channel_id: chId, ...st, by_user: userId }, chId);
        break;
      }
      case "AMBIENCE_STOP": {
        const chId = d.channel_id as string;
        if (voiceStates.get(userId)?.channel_id !== chId) return;
        if (!can(userId, P.USE_SOUNDBOARD, chId)) return;
        roomAmbience.delete(chId);
        broadcast("AMBIENCE_STATE", { channel_id: chId, ambience_id: null, by_user: userId }, chId);
        break;
      }
      case "AMBIENCE_PAUSE": {
        const chId = d.channel_id as string;
        const st = roomAmbience.get(chId);
        if (!st || voiceStates.get(userId)?.channel_id !== chId) return;
        if (!can(userId, P.USE_SOUNDBOARD, chId)) return;
        const wantPaused = !!d.paused;
        if (wantPaused && !st.paused) {
          st.paused = true;
          st.paused_at = Date.now();
        } else if (!wantPaused && st.paused) {
          // reanuda: corre started_at hacia adelante la duración de la pausa
          // para que la posición continúe donde quedó (no salta).
          st.started_at += Date.now() - (st.paused_at ?? Date.now());
          st.paused = false;
          delete st.paused_at;
        }
        broadcast("AMBIENCE_STATE", { channel_id: chId, ...st, by_user: userId }, chId);
        break;
      }
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
