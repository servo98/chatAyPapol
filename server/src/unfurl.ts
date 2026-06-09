import { db, rowMessage } from "./db";
import { broadcast } from "./gateway";

const URL_RE = /https?:\/\/[^\s<>|]+/;
const MAX_BYTES = 300_000;

function meta(html: string, prop: string): string | null {
  const re = new RegExp(
    `<meta[^>]+(?:property|name)=["']${prop}["'][^>]*content=["']([^"']+)["']|` +
    `<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']${prop}["']`, "i");
  const m = html.match(re);
  return m ? (m[1] ?? m[2]) : null;
}

const decode = (s: string) => s
  .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'");

/** Fire-and-forget OpenGraph unfurl; patches the message and broadcasts MESSAGE_UPDATE. */
export async function unfurl(messageId: string, channelId: string, content: string) {
  const url = content.match(URL_RE)?.[0];
  if (!url) return;
  try {
    const res = await fetch(url, {
      signal: AbortSignal.timeout(5000),
      headers: { "user-agent": "Mozilla/5.0 (compatible; ChatPapol/1.0)", accept: "text/html" },
      redirect: "follow",
    });
    const type = res.headers.get("content-type") ?? "";
    if (type.startsWith("image/")) {
      save(messageId, channelId, [{ url, image: url }]);
      return;
    }
    if (!type.includes("text/html")) return;
    const html = (await res.text()).slice(0, MAX_BYTES);
    const title = meta(html, "og:title") ?? html.match(/<title[^>]*>([^<]+)<\/title>/i)?.[1] ?? null;
    if (!title) return;
    const embed: Record<string, string> = { url, title: decode(title.trim()).slice(0, 200) };
    const desc = meta(html, "og:description") ?? meta(html, "description");
    if (desc) embed.description = decode(desc).slice(0, 350);
    const image = meta(html, "og:image");
    if (image) embed.image = new URL(image, url).href;
    save(messageId, channelId, [embed]);
  } catch { /* unfurl is best-effort */ }
}

function save(messageId: string, channelId: string, embeds: unknown[]) {
  db.run("UPDATE messages SET embeds = ? WHERE id = ?", [JSON.stringify(embeds), messageId]);
  const m = db.query("SELECT * FROM messages WHERE id = ?").get(messageId);
  if (m) broadcast("MESSAGE_UPDATE", rowMessage(m), channelId);
}
