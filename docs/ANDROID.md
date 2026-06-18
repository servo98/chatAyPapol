# ChatPapol en Android

El cliente Flutter corre en Android reutilizando **la misma base de código** que
escritorio. Esta nota explica cómo está montado, qué cambia en móvil y qué queda
pendiente. Para compilar ver [BUILD.md](BUILD.md).

## El proyecto Android (`client/android/`)
- Generado con `flutter create --platforms=android --org dev.papol .`
  → `applicationId`/namespace **`dev.papol.chatpapol`** (igual que el bundle id de
  escritorio).
- **`compileSdk 36`** (lo exigen `flutter_webrtc` fork + `livekit_client`).
- Icono de launcher generado desde `assets/icon.png` con `flutter_launcher_icons`
  (adaptativo, fondo `#17131f`). Regenerar: `dart run flutter_launcher_icons`.
- Permisos (`AndroidManifest.xml`): `INTERNET`/red, `RECORD_AUDIO` +
  `MODIFY_AUDIO_SETTINGS` + Bluetooth (rutado de audio), `WAKE_LOCK`,
  `FOREGROUND_SERVICE(_MICROPHONE)`, `POST_NOTIFICATIONS`. **Sin `CAMERA`**: la app
  solo publica voz.

## Patrón de adaptación: `isDesktop` / `isMobile`
Las features de solo escritorio **compilan** en Android (son Dart + MethodChannel)
y solo fallarían en runtime, así que **no** usamos imports condicionales: las
condicionamos con los getters de `lib/config.dart`:

```dart
bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
bool get isMobile  => Platform.isAndroid || Platform.isIOS;
```

### Qué se desactiva en móvil y por qué
| Feature | En móvil | Dónde |
|---|---|---|
| Barra de título / gestión de ventana (`window_manager`) | No se monta (`TitleBar` solo en escritorio) | `main.dart`, `titlebar.dart` |
| Drag & drop de archivos (`desktop_drop`) | Se omite; adjuntar va por el botón + (`file_picker`) | `ui/chat.dart` |
| Botón de **compartir pantalla** (`desktopCapturer`) | Oculto (ver/recibir un share **sí** funciona) | `ui/voice_panel.dart` |
| Pantalla completa del share | `SystemChrome` inmersivo en vez de `windowManager.setFullScreen` | `ui/screenshare_fullscreen.dart` |
| Auto-updater/instalador | Desactivado (la actualización va por la tienda) | `updater.dart`, `ui/shell.dart`, `ui/settings.dart` |
| Efectos de voz (FFI `voicefx`) | Degradan a no-op (no hay `.so` en el APK) | `audio/voicefx_bindings.dart` |

Lo demás (chat, adjuntos, voz: unirse/mutear/ensordecer/soundboard, 2FA con QR,
ambiente de sala) es multiplataforma y funciona igual.

## UI responsive
`lib/ui/shell.dart` cambia de layout según el ancho:
- **≥ 600 px (escritorio)**: 3 columnas (Sidebar · Chat/Voz · Miembros).
- **< 600 px (móvil)**: `Scaffold` con `AppBar` (canal actual), **Drawer** =
  canales, **endDrawer** = miembros, `body` = chat/voz, y una **barra de voz
  compacta** (mutear/ensordecer/colgar) cuando sigues en llamada viendo texto. El
  Drawer se cierra solo al elegir canal.

Otros ajustes móviles: `Sidebar`/`MemberList` aceptan `width` (llenan el Drawer);
**Ajustes** se abre a pantalla completa con rail de pestañas solo-iconos; el
login recorta el ancho de la tarjeta; las barras de sistema se tematizan con
`SystemChrome`.

> La estructura responsive está verificada por compilación (`flutter analyze`),
> pero el **pulido visual fino** (burbujas de chat, grid de voz, tamaños táctiles)
> conviene iterarlo probando en un dispositivo real.

## Pendiente (siguientes iteraciones)
1. **Voz en segundo plano**: servicio en primer plano de micrófono (p. ej.
   `flutter_foreground_task`) alrededor de `VoiceManager.join()/leave()` para que la
   llamada sobreviva al backgrounding en Android 12+. Hoy la voz asume foreground.
2. **Compartir pantalla en Android** (MediaProjection): requiere
   `FOREGROUND_SERVICE_MEDIA_PROJECTION` + su servicio y una rama Android en
   `_pickShareSource` (sin selector de ventana; consentimiento del SO).
3. **Firma de release / Play Store**: hoy el APK va firmado con la debug key
   (sirve para sideload). Para publicar: keystore propio vía `android/key.properties`
   y `versionCode` incremental.
4. **Pulido táctil** por pantalla a partir de pruebas en dispositivo.
