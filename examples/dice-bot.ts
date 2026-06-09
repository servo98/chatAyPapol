// Bot de ejemplo para ChatPapol: /roll [NdM]
// 1) Crea el bot desde la app (Ajustes → Bots) o:
//    curl -X POST $BASE/api/bots -H "Authorization: Bearer <token-admin>" -d '{"username":"dado.bot"}'
// 2) BASE=http://localhost:3210 BOT_TOKEN=xxx bun examples/dice-bot.ts
const BASE = process.env.BASE ?? "http://localhost:3210";
const TOKEN = process.env.BOT_TOKEN ?? "";
if (!TOKEN) { console.error("Falta BOT_TOKEN"); process.exit(1); }

const api = (method: string, path: string, body?: unknown) =>
  fetch(BASE + path, {
    method,
    headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  }).then(r => r.json());

// registra los slash commands del bot
await api("PUT", "/api/bot/commands", [
  { name: "roll", description: "Tira dados, ej: /roll 2d20" },
  { name: "coin", description: "Cara o cruz" },
]);
console.log("Comandos registrados. Conectando al gateway...");

function connect() {
  const ws = new WebSocket(`${BASE.replace("http", "ws")}/gateway?token=${TOKEN}`);
  ws.onopen = () => console.log("✓ conectado");
  ws.onclose = () => setTimeout(connect, 3000);
  ws.onmessage = async (ev) => {
    const { t, d } = JSON.parse(String(ev.data));
    if (t !== "INTERACTION_CREATE") return;
    let content = "";
    if (d.command === "coin") content = Math.random() < 0.5 ? "🪙 Cara" : "🪙 Cruz";
    if (d.command === "roll") {
      const [, n = "1", m = "6"] = d.args.match(/(\d*)d(\d+)/) ?? [];
      const rolls = Array.from({ length: Math.min(+n || 1, 20) },
        () => 1 + Math.floor(Math.random() * (+m || 6)));
      content = `🎲 ${rolls.join(" + ")}${rolls.length > 1 ? ` = **${rolls.reduce((a, b) => a + b)}**` : ""}`;
    }
    if (content) await api("POST", `/api/interactions/${d.id}/respond`, { content });
  };
}
connect();
