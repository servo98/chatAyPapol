# ChatPapol 💬

Chat privado tipo Discord para ti y tus amigos. Un solo servidor, ultraligero.
Specs completas en [SPECS.md](SPECS.md).

## Arranque rápido (server)

```bash
cd server
bun install
bun run dev                # backend en :3210

# en otra terminal — el SFU de voz/screenshare (1 binario Go):
bun run livekit            # descarga el binario y lo arranca en :7880
```

El **primer usuario** que se registre es el dueño (rol Admin). Los demás
necesitan una invitación (créala desde la app o `POST /api/invites`).

Prueba E2E del backend: `bun scripts/smoke-test.ts` (con `data/` limpio).

## Cliente (Flutter, Windows/Linux)

```bash
cd client
flutter pub get
flutter run -d windows     # o -d linux
```

Empaquetado e instaladores con auto-update: ver `client/packaging/README.md`.

## Bots y webhooks

- Webhook: crea uno en un canal y haz
  `curl -X POST $URL -d '{"content":"hola desde CI","username":"CI"}'`.
- Bot de ejemplo: `BOT_TOKEN=xxx bun examples/dice-bot.ts` → `/roll 2d20` en el chat.

## Producción (resumen)

1. VPS pequeño. `livekit-server` necesita UDP 50000-50100 y 7880 abiertos.
2. Genera keys reales (`livekit-server generate-keys`) → ponlas en `livekit.yaml`
   y en variables `LIVEKIT_KEY/LIVEKIT_SECRET` del backend.
3. Pon un reverse proxy con TLS (Caddy: 2 líneas) delante del backend (:3210)
   y de LiveKit (:7880, websocket).
4. Publica releases del cliente: `POST /api/updates/:platform` (multipart
   `file` + `version`) — los clientes se auto-actualizan solos.
