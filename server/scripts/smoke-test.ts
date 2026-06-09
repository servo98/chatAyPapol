// E2E smoke test: corre contra un server LIMPIO (borra data/app.db antes).
// Uso: bun scripts/smoke-test.ts
const BASE = process.env.BASE ?? "http://localhost:3210";
let failures = 0;

function check(name: string, cond: boolean, extra?: unknown) {
  if (cond) console.log(`  ✓ ${name}`);
  else { failures++; console.error(`  ✗ ${name}`, extra ?? ""); }
}

async function api(method: string, path: string, token?: string, body?: unknown) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      ...(body ? { "content-type": "application/json" } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: await res.json().catch(() => null) as any };
}

console.log("— auth —");
const admin = await api("POST", "/api/auth/register", undefined, { username: "papol", password: "supersecreta" });
check("primer usuario se registra sin invite", admin.status === 200 && admin.body.token, admin.body);
const at = admin.body.token;

const noInv = await api("POST", "/api/auth/register", undefined, { username: "intruso", password: "12345678x" });
check("segundo usuario SIN invite es rechazado", noInv.status === 403, noInv);

const inv = await api("POST", "/api/invites", at, { max_uses: 5 });
check("admin crea invite", inv.status === 200 && inv.body.code, inv.body);

const friend = await api("POST", "/api/auth/register", undefined, { username: "amigo", password: "12345678x", invite: inv.body.code });
check("amigo se registra con invite", friend.status === 200, friend.body);
const ft = friend.body.token;

const login = await api("POST", "/api/auth/login", undefined, { username: "papol", password: "supersecreta" });
check("login funciona", login.status === 200 && login.body.token);

console.log("— estado y canales —");
const state = await api("GET", "/api/state", at);
check("state trae canales seed", state.body.channels?.length >= 2, state.body.channels);
const textCh = state.body.channels.find((c: any) => c.type === "text");
const voiceCh = state.body.channels.find((c: any) => c.type === "voice");

const cat = await api("POST", "/api/categories", at, { name: "Gaming" });
check("crear categoría", cat.status === 200);
const newCh = await api("POST", "/api/channels", at, { name: "Sala Secreta", type: "text", category_id: cat.body.id });
check("crear canal (nombre kebab)", newCh.status === 200 && newCh.body.name === "sala-secreta", newCh.body);

const chDenied = await api("POST", "/api/channels", ft, { name: "hack", type: "text" });
check("amigo NO puede crear canales", chDenied.status === 403);

console.log("— permisos / overwrites —");
const VIEW = 1 << 9;
const ow = await api("PUT", `/api/channels/${newCh.body.id}/overwrites`, at,
  { target_id: "everyone", target_type: "role", allow: 0, deny: VIEW });
check("overwrite deny VIEW a @everyone", ow.status === 200);
const denied = await api("GET", `/api/channels/${newCh.body.id}/messages`, ft);
check("amigo NO ve canal restringido", denied.status === 403, denied);
const adminSees = await api("GET", `/api/channels/${newCh.body.id}/messages`, at);
check("admin SÍ ve canal restringido", adminSees.status === 200);

console.log("— mensajes —");
const msg = await api("POST", `/api/channels/${textCh.id}/messages`, ft, { content: "Hola **mundo** :)" });
check("amigo envía mensaje", msg.status === 200 && msg.body.content === "Hola **mundo** :)", msg.body);
const edit = await api("PATCH", `/api/channels/${textCh.id}/messages/${msg.body.id}`, ft, { content: "editado" });
check("autor edita su mensaje", edit.status === 200 && edit.body.edited_at);
const editOther = await api("PATCH", `/api/channels/${textCh.id}/messages/${msg.body.id}`, at, { content: "x" });
check("otro no puede editar", editOther.status === 403);
const delByAdmin = await api("DELETE", `/api/channels/${textCh.id}/messages/${msg.body.id}`, at);
check("admin borra con MANAGE_MESSAGES", delByAdmin.status === 200);

const shrug = await api("POST", `/api/channels/${textCh.id}/messages`, ft, { content: "/shrug que va" });
check("builtin /shrug", shrug.body?.content?.includes("¯\\_(ツ)_/¯"), shrug.body);

const reply = await api("POST", `/api/channels/${textCh.id}/messages`, at, { content: "respuesta", reply_to: shrug.body.id });
check("reply guarda reply_to", reply.body?.reply_to === shrug.body.id);

const everyone = await api("POST", `/api/channels/${textCh.id}/messages`, ft, { content: "hola @everyone" });
check("mención @everyone neutralizada sin permiso", !everyone.body.content.match(/@everyone/), everyone.body.content);

console.log("— automod —");
const rule = await api("POST", "/api/automod", at, { name: "groserías", type: "words", pattern: "tonto, feo" });
check("admin crea regla automod", rule.status === 200);
const blocked = await api("POST", `/api/channels/${textCh.id}/messages`, ft, { content: "eres muy TONTO jaja" });
check("automod bloquea palabra (case-insensitive)", blocked.status === 422, blocked);
const adminBypass = await api("POST", `/api/channels/${textCh.id}/messages`, at, { content: "tonto el que lo lea" });
check("admin exento de automod", adminBypass.status === 200);

console.log("— roles —");
const role = await api("POST", "/api/roles", at, { name: "Mod", color: "#57f287", permissions: (1 << 3) | (1 << 9) });
check("crear rol", role.status === 200);
const assign = await api("PUT", `/api/members/${friend.body.user.id}/roles`, at, { role_ids: [role.body.id] });
check("asignar rol", assign.status === 200);
const delOther = await api("DELETE", `/api/channels/${textCh.id}/messages/${reply.body.id}`, ft);
check("amigo ahora borra mensajes ajenos (MANAGE_MESSAGES)", delOther.status === 200, delOther);

console.log("— webhooks —");
const wh = await api("POST", `/api/channels/${textCh.id}/webhooks`, at, { name: "GitHub" });
check("crear webhook", wh.status === 200 && wh.body.token);
const whExec = await api("POST", `/api/webhooks/${wh.body.id}/${wh.body.token}`, undefined, { content: "deploy ok ✅", username: "CI Bot" });
check("ejecutar webhook sin auth", whExec.status === 200 && whExec.body.webhook_name === "CI Bot", whExec.body);
const whBad = await api("POST", `/api/webhooks/${wh.body.id}/tokenfalso`, undefined, { content: "x" });
check("webhook con token malo → 404", whBad.status === 404);

console.log("— bots + slash commands —");
const bot = await api("POST", "/api/bots", at, { username: "dado.bot" });
check("crear bot", bot.status === 200 && bot.body.token);
const cmds = await api("PUT", "/api/bot/commands", bot.body.token, [{ name: "roll", description: "Tira un dado" }]);
check("bot registra comandos", cmds.status === 200 && cmds.body.length === 1, cmds.body);

// bot conectado al gateway responde la interacción
const botWs = new WebSocket(`${BASE.replace("http", "ws")}/gateway?token=${bot.body.token}`);
const interactionDone = new Promise<boolean>((resolve) => {
  botWs.onmessage = async (ev) => {
    const { t, d } = JSON.parse(String(ev.data));
    if (t === "INTERACTION_CREATE") {
      const r = await api("POST", `/api/interactions/${d.id}/respond`, bot.body.token, { content: `🎲 ${d.user_id} sacó un 6 (args: ${d.args})` });
      resolve(r.status === 200);
    }
  };
  setTimeout(() => resolve(false), 5000);
});
await new Promise(r => { botWs.onopen = r; setTimeout(r, 3000); });

// el gateway del amigo debe recibir MESSAGE_CREATE del bot
const ws = new WebSocket(`${BASE.replace("http", "ws")}/gateway?token=${ft}`);
const events: string[] = [];
let gotReady = false, botReply = false;
ws.onmessage = (ev) => {
  const { t, d } = JSON.parse(String(ev.data));
  events.push(t);
  if (t === "READY") gotReady = !!d.users && !!d.roles && !!d.channels;
  if (t === "MESSAGE_CREATE" && d.content?.startsWith("🎲")) botReply = true;
};
await new Promise(r => { ws.onopen = r; setTimeout(r, 3000); });
await new Promise(r => setTimeout(r, 300));
check("gateway manda READY completo", gotReady);

const slashMsg = await api("POST", `/api/channels/${textCh.id}/messages`, ft, { content: "/roll 1d20" });
check("comando de bot despachado", slashMsg.body?.interaction?.ok === true, slashMsg.body);
check("bot respondió la interacción", await interactionDone);
await new Promise(r => setTimeout(r, 500));
check("amigo recibió la respuesta del bot por WS", botReply, events);

console.log("— voz / soundboard —");
ws.send(JSON.stringify({ t: "VOICE_JOIN", d: { channel_id: voiceCh.id } }));
await new Promise(r => setTimeout(r, 300));
check("VOICE_STATE broadcast tras join", events.includes("VOICE_STATE"));

const vt = await api("POST", `/api/channels/${voiceCh.id}/voice-token`, ft);
check("voice token JWT firmado", vt.status === 200 && vt.body.token?.split(".").length === 3, vt.body);
const jwtPayload = JSON.parse(Buffer.from(vt.body.token.split(".")[1], "base64url").toString());
check("JWT con grants de sala correcta", jwtPayload.video?.room === voiceCh.id && jwtPayload.video?.roomJoin === true, jwtPayload);

const sndFail = await api("POST", `/api/channels/${voiceCh.id}/sounds/123/play`, at);
check("soundboard requiere estar en el canal", sndFail.status === 400);

console.log("— updates —");
const upd = await api("GET", "/api/updates/windows", ft);
check("updates sin release → 404 limpio", upd.status === 404);

ws.close(); botWs.close();
console.log(failures === 0 ? "\n✅ TODO OK" : `\n❌ ${failures} fallos`);
process.exit(failures === 0 ? 0 : 1);
