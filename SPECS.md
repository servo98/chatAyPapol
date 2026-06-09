# ChatPapol — Especificaciones del MVP

Chat privado tipo Discord para un **único servidor** (el tuyo y tus amigos). Dos entregables:

| Entregable | Stack | Peso objetivo |
|---|---|---|
| **Server** | Bun + Hono + SQLite (texto/estado) · LiveKit (media, 1 binario Go) | ~50 MB RAM idle |
| **Cliente** | Flutter desktop + `livekit_client` (libwebrtc real, sin Chromium) | ~30 MB instalador |

## Principios
1. **Un solo servidor** (guild). No hay multi-guild: menos UI, menos queries, menos todo.
2. **No reinventar WebRTC**: LiveKit hace voz + screenshare 1080p. Nuestro backend solo firma JWTs.
3. **Ligereza radical**: el backend tiene **cero dependencias** salvo Hono (JWT de LiveKit firmado a mano con WebCrypto, SQLite nativo de Bun, WS nativo de Bun). Stickers/sonidos/uploads = archivos en disco.
4. **Soundboard sin ancho de banda**: el sonido NO viaja por WebRTC. El server emite `SOUND_PLAY` por WS y cada cliente reproduce el archivo localmente (lo tiene cacheado). Latencia ~0, coste ~0.
5. **Auto-update self-hosted**: el cliente consulta `GET /api/updates/:platform` contra tu propio server; si hay versión nueva descarga el instalador/AppImage y lo lanza. Sin stores.

## Features (alcance MVP)

### Texto
- Canales de texto y voz, agrupados en **categorías** (colapsables, reordenables).
- Mensajes con **Markdown estilo Discord**: `**bold**`, `*italic*`, `__underline__`, `~~strike~~`, `` `code` ``, ```bloques```, `||spoiler||`, `> quote`, enlaces, menciones `@usuario`, `@everyone`.
- **Imágenes y GIFs** (upload multipart, render inline), archivos adjuntos genéricos.
- **Enlaces con embed**: el server hace unfurl OpenGraph (título/descr./imagen) en background y emite `MESSAGE_UPDATE`.
- **Stickers**: pack del servidor (PNG/GIF/WebP), picker en el cliente, gestionables por admins.
- Responder (reply), editar, borrar, typing indicator, paginación infinita hacia arriba.
- **Comandos slash**: built-ins (`/me`, `/shrug`, `/tableflip`, `/unflip`, `/spoiler`) + comandos registrados por bots.
- **Filtros de mensajes (AutoMod)**: reglas por palabras bloqueadas, regex y bloqueo de enlaces; acción: bloquear el envío. Los admins están exentos.

### Voz / Media (LiveKit)
- Canales de voz: join/leave, mute/deafen, indicador de quién habla.
- **Screenshare 1080p con audio** (1 publisher por sala simultáneo no limitado, pero UI enfoca uno).
- **Soundboard**: sonidos del servidor (mp3/ogg ≤ 1 MB), botón → todos en el canal lo oyen (vía evento WS, ver Principio 4).
- Estados de voz visibles en el sidebar (quién está en qué canal).

### Permisos (modelo Discord completo, simplificado a 1 guild)
- **Roles** con color, posición (jerarquía) y bitfield de permisos.
- Rol `@everyone` implícito.
- **Overwrites por canal** (allow/deny) por rol y por miembro.
- Resolución exacta estilo Discord: base = OR de roles → si `ADMINISTRATOR` ⇒ todo → aplica overwrite de @everyone → OR de overwrites de roles → overwrite de miembro.
- Bits: `ADMINISTRATOR, MANAGE_CHANNELS, MANAGE_ROLES, MANAGE_MESSAGES, MANAGE_WEBHOOKS, MANAGE_EXPRESSIONS, KICK_MEMBERS, BAN_MEMBERS, CREATE_INVITES, VIEW_CHANNEL, SEND_MESSAGES, EMBED_LINKS, ATTACH_FILES, MENTION_EVERYONE, CONNECT, SPEAK, STREAM, USE_SOUNDBOARD, MUTE_MEMBERS, MOVE_MEMBERS`.

### Integraciones
- **Webhooks**: `POST /api/webhooks/:id/:token` con `{content, username?, avatar_url?, embeds?}` — sin auth de sesión, como Discord. CRUD por canal para admins.
- **Bots**: usuarios con flag `bot` + token. Se conectan al mismo gateway WS y usan la misma REST API. Registran slash-commands; cuando un humano ejecuta `/comando`, el bot recibe `INTERACTION_CREATE` y responde vía `POST /api/interactions/:id/respond`.

### Cuentas
- Registro **solo con invitación** (códigos con usos máximos y expiración). Login usuario+contraseña → token de sesión.
- Avatares subibles. Presencia online/offline en tiempo real.

## Arquitectura

```
┌─────────────┐  WSS gateway (eventos)   ┌──────────────────────┐
│   Cliente    │◄────────────────────────►│  Bun + Hono + SQLite  │
│   Flutter    │  HTTPS REST + uploads    │  (1 proceso, ~30 MB)  │
│ livekit_client│                          └─────────┬────────────┘
│              │   WebRTC (UDP/SRTP)       firma JWT │
│              │◄────────────────────────► ┌─────────▼───────────┐
└─────────────┘                            │  livekit-server (Go) │
                                           │  SFU, solo reenvía   │
                                           └──────────────────────┘
```

- **Gateway WS** (`/gateway?token=`): al conectar el server manda `READY` (estado completo: usuarios, roles, categorías, canales, voice states, stickers, sonidos). Después, eventos incrementales: `MESSAGE_CREATE/UPDATE/DELETE`, `CHANNEL_*`, `CATEGORY_*`, `ROLE_*`, `MEMBER_UPDATE`, `PRESENCE_UPDATE`, `TYPING`, `VOICE_STATE`, `SOUND_PLAY`, `STICKER_*`, `SOUND_*`, `INTERACTION_CREATE` (solo bots). Broadcast filtrado por `VIEW_CHANNEL`.
- **Media**: cliente pide `POST /api/channels/:id/voice-token` → server valida `CONNECT`/`SPEAK`/`STREAM` y firma un JWT HS256 de LiveKit → cliente se conecta directo al SFU. Una sala LiveKit por canal de voz.
- **Datos**: SQLite WAL en `server/data/app.db`; uploads/stickers/sonidos/avatares/releases en `server/data/files/`.

## Auto-update del cliente
1. Al arrancar (y cada 6 h) el cliente hace `GET /api/updates/{windows|linux|macos}` → `{version, url, notes, sha256}`.
2. Si `version > actual`: banner "Actualización disponible" → descarga el artefacto (instalador `.exe` Inno Setup / `.AppImage`), verifica SHA-256 y lo ejecuta (Inno silencioso `/SILENT`; AppImage se reemplaza a sí mismo).
3. Publicar release = subir el artefacto a `server/data/files/releases/` y actualizar `releases.json` (hay endpoint admin y script).

## Decisiones y riesgos
- **Flutter vs Tauri**: Tauri puro no puede hacer screenshare en macOS/Linux (webview sin `getDisplayMedia`); Tauri+Rust SDK es mucho más curro. Flutter bundlea libwebrtc → screenshare funciona en Win/Linux (Wayland vía PipeWire) y macOS (con permiso de grabación). **Spike pendiente** (1 día): validar captura en tu distro/Wayland concreta antes de pulir.
- **Linux empaquetado**: AppImage (1 archivo, auto-reemplazable). Windows: Inno Setup. macOS: fase 2.
- **Escala**: diseñado para ≤ ~100 usuarios concurrentes (broadcast O(n) por evento, permisos calculados al vuelo). Suficiente y simple.

## Estructura del repo
```
chatpapol/
├── SPECS.md
├── server/          # Bun + Hono + SQLite
│   ├── src/         # index, db, auth, perms, gateway, automod, livekit, unfurl, rutas
│   ├── livekit.yaml # config del SFU (dev keys)
│   └── scripts/     # get-livekit.sh, publish-release.ts
└── client/          # Flutter desktop (Win/Linux, macOS fase 2)
    ├── lib/         # api, gateway, store, voice, updater, md, theme, ui/
    └── packaging/   # installer.iss (Inno), AppImage recipe
```
