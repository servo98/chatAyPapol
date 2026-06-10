// TOTP (RFC 6238, SHA-1, 6 dígitos, paso de 30s) sin dependencias: el 2FA de
// las cuentas. Compatible con Google Authenticator / Authy / 1Password / etc.
import { createHmac, randomBytes } from "node:crypto";

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function newTotpSecret(): string {
  const bytes = randomBytes(20);
  let bits = 0, value = 0, out = "";
  for (const b of bytes) {
    value = (value << 8) | b; bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

function b32decode(s: string): Buffer {
  let bits = 0, value = 0;
  const out: number[] = [];
  for (const ch of s.toUpperCase().replace(/=+$/, "")) {
    const idx = B32.indexOf(ch);
    if (idx < 0) continue;
    value = (value << 5) | idx; bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
  }
  return Buffer.from(out);
}

function hotp(secret: string, counter: number): string {
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(counter));
  const h = createHmac("sha1", b32decode(secret)).update(buf).digest();
  const off = h[h.length - 1] & 0xf;
  const code = ((h[off] & 0x7f) << 24) | (h[off + 1] << 16) | (h[off + 2] << 8) | h[off + 3];
  return String(code % 1_000_000).padStart(6, "0");
}

/** Acepta el código del paso actual ±1 (tolerancia a desfase de reloj). */
export function verifyTotp(secret: string, code: string): boolean {
  if (!/^\d{6}$/.test(code ?? "")) return false;
  const step = Math.floor(Date.now() / 30_000);
  return [step - 1, step, step + 1].some((s) => hotp(secret, s) === code);
}

export function totpUri(username: string, secret: string): string {
  return `otpauth://totp/ChatPapol:${encodeURIComponent(username)}` +
    `?secret=${secret}&issuer=ChatPapol&algorithm=SHA1&digits=6&period=30`;
}
