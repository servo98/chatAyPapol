import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'store.dart';
import 'theme.dart';
import 'ui/login.dart';
import 'ui/shell.dart';
import 'ui/titlebar.dart';
import 'voice.dart';

bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_desktop) {
    // El runner nativo ya muestra la ventana en el primer frame (visible
    // garantizado). Aquí solo ajustamos tamaño/centrado y QUITAMOS la barra
    // del SO; si esto último fallara, peor caso = ventana normal usable.
    try {
      await windowManager.ensureInitialized();
      const opts = WindowOptions(
        size: Size(1280, 800),
        minimumSize: Size(960, 600),
        center: true,
        title: 'ChatPapol',
      );
      await windowManager.waitUntilReadyToShow(opts);
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {/* la ventana ya está visible por el runner nativo */}
  }
  final store = AppStore();
  final voice = VoiceManager(store);
  store.tryRestore();
  runApp(ChatPapolApp(store: store, voice: voice));
}

class ChatPapolApp extends StatelessWidget {
  final AppStore store;
  final VoiceManager voice;
  const ChatPapolApp({super.key, required this.store, required this.voice});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChatPapol',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      builder: (ctx, child) => Column(children: [
        if (_desktop) const TitleBar(),
        Expanded(child: child ?? const SizedBox.shrink()),
      ]),
      home: ListenableBuilder(
        listenable: store,
        builder: (ctx, _) {
          if (store.restoring) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator(strokeWidth: 2)));
          }
          return store.loggedIn
              ? Shell(store: store, voice: voice)
              : LoginScreen(store: store);
        },
      ),
    );
  }
}
