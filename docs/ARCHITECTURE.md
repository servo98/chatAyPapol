# Arquitectura de ChatPapol

Visión general de las piezas del proyecto y cómo encajan. Para el alcance
funcional ver [SPECS.md](../SPECS.md); para compilar/ejecutar ver
[BUILD.md](BUILD.md); para el target Android ver [ANDROID.md](ANDROID.md).

```
┌─────────────────────────────────────────────────────────────┐
│  Cliente Flutter  (client/)                                  │
│  Windows · Linux · macOS · Android                           │
│   REST  ───────────────► server (Bun/Hono)  :3210            │
│   WS gateway ──────────► server (eventos en tiempo real)     │
│   WebRTC (voz/share) ──► LiveKit SFU (Go)    :7880           │
└─────────────────────────────────────────────────────────────┘
```

## Servidor (`server/`)

- **Runtime**: [Bun](https://bun.sh). Filosofía de **cero dependencias** externas
  cuando se puede; SQLite va por `bun:sqlite` con sentencias preparadas.
- **HTTP**: [Hono](https://hono.dev). Rutas REST bajo `server/src/routes/`
  (`auth.ts`, `chat.ts`, `admin.ts`, …) montadas en `server/src/index.ts`.
- **Gateway WS** (`server/src/gateway.ts`): eventos en tiempo real (mensajes,
  presencia, estados de voz, typing, ambiente de sala).
- **Permisos** (`server/src/perms.ts`): modelo estilo Discord (bitmask) sobre un
  único guild. El cliente lo refleja en `client/lib/perms.dart`.
- **Voz**: el servidor **no** transporta audio; firma JWT de LiveKit
  (`server/src/livekit.ts`) y el cliente habla con el **SFU LiveKit** (binario Go,
  `bun run livekit`). Soporta voz + screenshare (incl. audio del sistema).
- **Otros**: 2FA TOTP (`totp.ts`), automod (`automod.ts`), unfurl de enlaces
  (`unfurl.ts`), auth + invitaciones (`auth.ts`).
- **Persistencia**: SQLite (`server/src/db.ts`, datos en `server/data/`).

## Cliente (`client/`)

Una sola base de código Dart/Flutter para **escritorio y móvil**.

### Capas
- **Datos/red**: `lib/api.dart` (REST + multipart), `lib/gateway.dart` (WS con
  reconexión + heartbeat), `lib/store.dart` (`AppStore extends ChangeNotifier`,
  estado global: usuarios, roles, canales, mensajes, voz, typing, permisos).
- **Voz/media**: `lib/voice.dart` (`VoiceManager`: micro, screenshare, soundboard
  sobre `livekit_client`), `lib/audio/` (efectos de voz por **FFI nativa**
  `voicefx`, ecualizador de usuario), `lib/ambience.dart`, `lib/sfx.dart`.
- **Config/plataforma**: `lib/config.dart` (URL del server + **`isDesktop`/
  `isMobile`**, el único punto de verdad para condicionar features),
  `lib/perms.dart`, `lib/theme.dart` (paleta violeta oscura), `lib/md.dart`
  (markdown), `lib/version.dart`.
- **Solo escritorio**: `lib/installer.dart` + `lib/updater.dart` (auto-instalación
  y auto-update tipo Discord), `lib/notifications.dart` (toasts de Windows).
- **UI** (`lib/ui/`): `shell.dart` (**shell responsive**: 3 columnas en escritorio,
  navegación por Drawer en móvil), `sidebar.dart`, `chat.dart`, `members.dart`,
  `voice_panel.dart`, `settings.dart`, `login.dart`, `totp.dart`,
  `titlebar.dart` (barra de título propia, escritorio), `screenshare_fullscreen.dart`,
  `widgets.dart`.

### Shells nativos
- `client/windows/`, `client/linux/`, `client/macos/`: runners nativos
  (C++/CMake, GTK, Cocoa) con barra de título oculta y ventana sin marco.
- `client/android/`: proyecto Gradle (Kotlin DSL), `MainActivity` por defecto.
- `client/native/voicefx/`: librería C++ de efectos de voz (`voicefx.dll` /
  `libvoicefx.so`) cargada por FFI; en plataformas sin binario degrada a no-op.

### Estrategia multiplataforma
Las features de **solo escritorio** (gestión de ventana, drag&drop, selector de
pantalla para screenshare, instalador/updater, FFI de voicefx) **compilan** en
todas las plataformas y solo fallarían en runtime; se condicionan con **guards
`isDesktop`/`isMobile`** en vez de stubs por import. Detalle en
[ANDROID.md](ANDROID.md).

## CI/CD (`.github/workflows/`)
- **`release.yml`**: compila el **AppImage de Linux** y el **APK de Android** y
  publica la GitHub Release. Windows se compila en local
  (`client/scripts/publish-windows.sh`) y se sube al mismo release.
- **`auto-release.yml`**: al cambiar `client/**` en `main`, calcula la siguiente
  versión (bump de patch) y dispara `release.yml`.
- **`docker.yml`**: imagen del servidor a GHCR al cambiar `server/**`.

## Convenciones del repo
- **Fin de línea**: `.gitattributes` fuerza **LF** en el repo (los `.bat`/`.ps1`
  y el SFX config del instalador mantienen CRLF al hacer checkout). Esto evita el
  ruido CRLF↔LF al editar en Windows.
- **Versión**: `client/lib/version.dart` + `version` de `pubspec.yaml`; la CI la
  sella en cada release.
