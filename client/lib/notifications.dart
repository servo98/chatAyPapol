import 'dart:io';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';

/// Notificaciones nativas del SO (toast Windows / libnotify Linux vía
/// local_notifier). Singleton; main.dart engancha [onOpenChannel] para que un
/// click traiga la ventana al frente y abra el canal.
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  /// main.dart lo setea: al hacer click en un toast, abre este canal.
  void Function(String channelId)? onOpenChannel;

  bool _ready = false;

  // Canal nativo del runner de Windows (ver flutter_window.cpp).
  static const _windowChannel = MethodChannel('chatpapol/window');

  /// Parpadea el botón de la barra de tareas (Windows) hasta que el usuario
  /// traiga la app al frente. El nativo verifica el foreground y no hace nada si
  /// ya estamos al frente. No-op fuera de Windows.
  Future<void> flashTaskbar() async {
    if (!Platform.isWindows) return;
    try {
      await _windowChannel.invokeMethod('flashTaskbar');
    } catch (_) {}
  }

  Future<void> init() async {
    try {
      await localNotifier.setup(
        appName: 'ChatPapol',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _ready = true;
    } catch (_) {
      // SO sin soporte de toasts (o setup fallido): degradamos en silencio.
      _ready = false;
    }
  }

  Future<void> show({
    required String title,
    required String body,
    String? channelId,
  }) async {
    if (!_ready) return;
    try {
      final notif = LocalNotification(title: title, body: body);
      notif.onClick = () {
        final id = channelId;
        if (id != null) onOpenChannel?.call(id);
      };
      await notif.show();
    } catch (_) {
      // no romper el flujo de mensajes si el SO rechaza el toast
    }
  }
}
