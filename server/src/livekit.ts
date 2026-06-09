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
