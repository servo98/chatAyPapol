import 'dart:io' show Platform;

/// URL fija del servidor. Los usuarios no eligen server: esto ES ChatPapol.
/// Para desarrollo se puede sobreescribir sin tocar código:
///   flutter run -d windows --dart-define=CHATPAPOL_SERVER=http://localhost:3210
const serverUrl = String.fromEnvironment(
  'CHATPAPOL_SERVER',
  defaultValue: 'https://chat.aypapol.com',
);

/// Plataforma de escritorio: tiene ventana propia (window_manager), barra de
/// título propia, instalador/updater, drag&drop y captura de pantalla por
/// ventana. Móvil (Android/iOS) no tiene nada de eso. Único punto de verdad
/// para condicionar UI y features según el tipo de dispositivo.
bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Móvil: Android o iOS. Layout táctil, sin ventanas ni instalador.
bool get isMobile => Platform.isAndroid || Platform.isIOS;
