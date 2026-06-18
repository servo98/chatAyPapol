// Minimal LiveKit access-token minting (HS256 JWT, WebCrypto). No SDK needed.
const KEY = process.env.LIVEKIT_KEY ?? "devkey";
const SECRET = process.env.LIVEKIT_SECRET ?? "devsecret-devsecret-devsecret-32";
export const LIVEKIT_URL = process.env.LIVEKIT_URL ?? "ws://localhost:7880";

const enc = new TextEncoder();
let hmacKey: CryptoKey | null = null;

function b64url(data: Uint8Array | string): string {
  const buf = typeof data === "string" ? enc.encode(data) : data;
  return Buffer.from(buf).toString("base64url");
}

export async function mintVoiceToken(opts: {
  identity: string; name: string; room: string;
  canPublish: boolean; canScreenshare: boolean;
}): Promise<string> {
  hmacKey ??= await crypto.subtle.importKey(
    "raw", enc.encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);

  const now = Math.floor(Date.now() / 1000);
  const sources = opts.canPublish ? ["microphone"] : [];
  if (opts.canScreenshare) sources.push("screen_share", "screen_share_audio");
  const payload = {
    iss: KEY, sub: opts.identity, name: opts.name,
    nbf: now - 10, exp: now + 6 * 3600,
    video: {
      room: opts.room, roomJoin: true,
      canPublish: sources.length > 0, canSubscribe: true,
      canPublishSources: sources,
    },
  };
  const head = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64url(JSON.stringify(payload));
  const sig = await crypto.subtle.sign("HMAC", hmacKey, enc.encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(new Uint8Array(sig))}`;
}

// ---- RoomService (Twirp) para reconciliar presencia con la realidad del SFU ----
// LIVEKIT_URL es la URL que usan LOS CLIENTES (puede ser wss pública). Para que el
// BACKEND hable con el SFU se usa LIVEKIT_API_URL: en docker-compose el SFU corre en
// host networking, así que el contenedor del backend lo alcanza vía
// http://host.docker.internal:7880 (ver docker-compose.yml). Si no se puede alcanzar,
// la reconciliación es no-op y NUNCA borra estado (ver gateway.reconcileVoice).
const API_URL = (process.env.LIVEKIT_API_URL ?? LIVEKIT_URL)
  .replace(/^ws/, "http").replace(/\/+$/, "");

async function mintAdminToken(video: Record<string, unknown>): Promise<string> {
  hmacKey ??= await crypto.subtle.importKey(
    "raw", enc.encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: KEY, sub: "chatpapol-server", nbf: now - 10, exp: now + 600, video };
  const head = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64url(JSON.stringify(payload));
  const sig = await crypto.subtle.sign("HMAC", hmacKey, enc.encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(new Uint8Array(sig))}`;
}

async function twirp(method: string, body: object, video: Record<string, unknown>): Promise<any> {
  const token = await mintAdminToken(video);
  const res = await fetch(`${API_URL}/twirp/livekit.RoomService/${method}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${method} → HTTP ${res.status}`);
  return res.json();
}

// Quién está REALMENTE conectado al SFU: Map identity(userId) → room(channelId).
// (identity y room los fijamos al acuñar el token: identity=user.id, room=channel.id)
export async function liveVoiceParticipants(): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const { rooms = [] } = await twirp("ListRooms", {}, { roomList: true });
  for (const r of rooms as Array<{ name: string }>) {
    const { participants = [] } = await twirp(
      "ListParticipants", { room: r.name }, { roomAdmin: true, room: r.name });
    for (const p of participants as Array<{ identity: string }>) {
      if (p.identity) out.set(p.identity, r.name);
    }
  }
  return out;
}
