import { db } from "./db";

const URL_RE = /https?:\/\/\S+/i;

/** Returns a block reason, or null if the message passes all enabled rules. */
export function checkAutomod(content: string): string | null {
  const rules = db.query("SELECT * FROM automod_rules WHERE enabled = 1").all() as any[];
  const lower = content.toLowerCase();
  for (const rule of rules) {
    switch (rule.type) {
      case "words": {
        const words = rule.pattern.split(",").map((w: string) => w.trim().toLowerCase()).filter(Boolean);
        if (words.some((w: string) => lower.includes(w))) return rule.name;
        break;
      }
      case "regex":
        try { if (new RegExp(rule.pattern, "i").test(content)) return rule.name; } catch { /* bad regex: skip */ }
        break;
      case "links":
        if (URL_RE.test(content)) return rule.name;
        break;
    }
  }
  return null;
}
