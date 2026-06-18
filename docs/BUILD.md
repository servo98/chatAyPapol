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
`flutter_webrtc` + `livekit_client` obligan a **`compileSdk 36`**, y por eso
`android/settings.gradle.kts` fija **AGP 8.13.2** (con AGP ≥ 9 `file_picker` 11 no
compila — ver [ANDROID.md](ANDROID.md)). Para compilar en local hace falta:
- **JDK 17** (Gradle 9.x lo exige; un JRE 8 NO sirve).
- **Android SDK Platform 36** + build-tools (≥ 34) + **`cmdline-tools`**. Un SDK de
  Android Studio viejo (plataformas ≤ 30, sin `cmdline-tools`) **no basta**; instala
  lo que falte con `sdkmanager`.
- **CMake 3.22.1 + NDK** para el build nativo de `jni` (dep transitiva de livekit);
  `flutter build` los instala solo si el SDK tiene `cmdline-tools` y licencias aceptadas.
- **Modo Desarrollador** de Windows (symlinks de plugins): `start ms-settings:developers`.

> Verificado: APK debug construido e **instalado y lanzado en un Pixel 5 (Android 14)**.
> La CI (`release.yml`, job `android`) compila con un toolchain fresco (instala
> SDK 36 + cmake y acepta licencias), así que no depende de tu setup local.

### Lanzar en un dispositivo
```bash
cd client
flutter devices                       # confirma que ves el teléfono
flutter run -d <id-del-dispositivo>   # build + install + launch + logs en vivo
# o, con el APK ya construido:
adb -s <id> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <id> shell am start -n dev.papol.chatpapol/.MainActivity
```

### Notas WSL / Windows
- Flutter está solo en **Windows** (`C:\src\flutter`); el de WSL falla (sus scripts
  `.sh` tienen CRLF). Invócalo vía `cmd.exe`:
  ```bash
  cmd.exe /c "cd /d C:\ruta\al\client && C:\src\flutter\bin\flutter.bat <args>"
  ```

## Releases (CI)
Empujar un tag `vX.Y.Z` (o cambiar `client/**` en `main`, que dispara
`auto-release.yml`) compila Linux (AppImage) + Android (APK) y publica la
GitHub Release. Windows se sube aparte desde local. Ver
`.github/workflows/release.yml`.
