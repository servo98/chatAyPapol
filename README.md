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

## CI/CD (gratis)

**Soltar una versión nueva del cliente = un comando:**

```bash
# (commitea tus cambios primero)
./release.sh        # push → CI compila Linux → compila+firma Windows local → sube todo
```

Detalle de qué hace cada parte:
- **Linux**: lo compila GitHub Actions. Push a `main` que toque `client/**` →
  `auto-release.yml` calcula la siguiente versión y publica el Release con el AppImage.
  (Saltar: `[skip release]` en el commit. Minor/major: tag manual `vX.Y.0`.)
- **Windows**: NO lo hace el CI (lento). Se compila **en local** con
  `client/scripts/publish-windows.sh`, que además **firma** el `Setup.exe`
  (evita que Defender lo borre) y lo sube al Release. `release.sh` orquesta los dos.
- La **llave de firma** (`.pfx`) vive solo en la máquina de build (no en el repo).
- **Server**: push que toque `server/**` → imagen Docker en
  `ghcr.io/servo98/chatpapol-server:latest`.

Los clientes instalados se **auto-actualizan** (descargan el `.zip` del Release y
muestran la pantalla de carga propia). La primera instalación es el `Setup.exe`
firmado (un solo doble clic; SmartScreen pide "Ejecutar de todas formas" una vez).

## Producción (resumen)

1. VPS pequeño con Docker: copia `docker-compose.yml` + `server/livekit.yaml`
   y `docker compose up -d` (backend + LiveKit). Actualizar:
   `docker compose pull && docker compose up -d`.
2. `livekit-server` necesita UDP 50000-50100 y 7880 abiertos.
3. Genera keys reales (`livekit-server generate-keys`) → `livekit.yaml` y
   variables `LIVEKIT_KEY/LIVEKIT_SECRET/LIVEKIT_URL` del backend.
4. Pon un reverse proxy con TLS (Caddy: 2 líneas) delante del backend (:3210)
   y de LiveKit (:7880, websocket).
