# Compilar y ejecutar ChatPapol

Resumen por plataforma. Arquitectura general en [ARCHITECTURE.md](ARCHITECTURE.md).

## Servidor

```bash
cd server
bun install
bun run dev          # backend en :3210
bun run livekit      # SFU de voz/screenshare en :7880 (descarga el binario Go)
```
El primer usuario registrado es el dueño (Admin); el resto necesita invitación.
Imagen Docker: la publica `.github/workflows/docker.yml` en GHCR.

## Cliente — requisitos comunes

- **Flutter** stable (probado con 3.44.x, Dart 3.9). `flutter pub get` en `client/`.
- `flutter_webrtc` está fijado al **fork de servo98** (RNNoise + efectos de voz +
  loopback WASAPI de Windows). Se resuelve solo con `flutter pub get`.
- Override del server en desarrollo:
  `--dart-define=CHATPAPOL_SERVER=http://localhost:3210`.

## Escritorio

```bash
cd client
flutter run -d windows      # o -d linux / -d macos
```
- **Windows**: build + instalador firmado con `client/scripts/publish-windows.sh`
  (requiere Flutter Windows, signtool, certificado PFX). Empaquetado:
  `client/packaging/README.md`.
- **Linux**: `flutter build linux --release` → AppImage con
  `client/packaging/make-appimage.sh` (lo hace también la CI).
- **Efectos de voz**: necesitan el binario nativo `voicefx` (`client/native/voicefx/`);
  sin él, los FX quedan deshabilitados (no es un fallo).

## Android

```bash
cd client
flutter build apk --debug        # o --release
flutter install                  # a un dispositivo/emulador conectado
```
APK resultante: `client/build/app/outputs/flutter-apk/`. Detalle del target en
[ANDROID.md](ANDROID.md).

### Requisitos del toolchain Android (¡importante!)
`flutter_webrtc` + `livekit_client` obligan a **`compileSdk 36`**. Para compilar
en local hace falta tener instalado:
- **Android SDK Platform 36** (`platforms;android-36`) y build-tools recientes
  (≥ 34). El SDK que trae un Android Studio viejo (plataformas ≤ 30) **no basta**:
  instala lo que falte con el SDK Manager de Android Studio o con `sdkmanager`.
- **JDK 17**.
- No hace falta NDK (los plugins traen sus `.so` precompilados).

> La CI (`release.yml`, job `android`) ya construye el APK con un toolchain
> fresco; si compilar en local te bloquea por el SDK, usa la release de CI.

### Notas WSL / Windows
- Si editas en **WSL** pero tienes Flutter solo en **Windows**, invoca el Flutter
  de Windows vía `cmd.exe` (los scripts `.sh` del SDK de Windows tienen CRLF y
  fallan bajo bash):
  ```bash
  cmd.exe /c "cd /d C:\ruta\al\client && C:\src\flutter\bin\flutter.bat <args>"
  ```
- En Windows, compilar con plugins requiere **Modo Desarrollador** activado
  (symlinks): `start ms-settings:developers`.

## Releases (CI)
Empujar un tag `vX.Y.Z` (o cambiar `client/**` en `main`, que dispara
`auto-release.yml`) compila Linux (AppImage) + Android (APK) y publica la
GitHub Release. Windows se sube aparte desde local. Ver
`.github/workflows/release.yml`.
