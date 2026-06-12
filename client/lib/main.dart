import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:window_manager/window_manager.dart';
import 'api.dart';
import 'config.dart';
import 'crash_log.dart';
import 'installer.dart';
import 'notifications.dart';
import 'sfx.dart';
import 'ambience.dart';
import 'audio/voice_fx.dart';
import 'updater.dart';
import 'version.dart';
import 'webrtc_apm.dart';
import 'store.dart';
import 'theme.dart';
import 'ui/bootstrap_runner.dart';
import 'ui/bootstrap_screen.dart';
import 'ui/crash_overlay.dart';
import 'ui/login.dart';
import 'ui/shell.dart';
import 'ui/titlebar.dart';
import 'voice.dart';

bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

// Diagnóstico aislado de screenshare + dispositivos. Escribe paso a paso a un
// archivo (si la app CRASHEA en un paso nativo, falta esa línea → ahí murió).
Future<void> _diag() async {
  final f = File(r'C:\Users\ferna\Downloads\chatpapol-toolchain\diag.txt');
  Future<void> log(String s) async => f.writeAsStringSync('$s\n', mode: FileMode.append);
  f.writeAsStringSync('=== diag inicio ===\n');
  try {
    await log('paso 1: getSources(Screen) ...');
    final scr = await rtc.desktopCapturer.getSources(types: [rtc.SourceType.Screen]);
    await log('  OK pantallas=${scr.length}');

    await log('paso 2: getSources(Window) ...');
    final win = await rtc.desktopCapturer.getSources(types: [rtc.SourceType.Window]);
    await log('  OK ventanas=${win.length}');

    await log('paso 3: getSources(Screen+Window) ...');
    final both = await rtc.desktopCapturer
        .getSources(types: [rtc.SourceType.Screen, rtc.SourceType.Window]);
    await log('  OK total=${both.length}');

    await log('paso 4: audioInputs/outputs (sin init) ...');
    var ins = await lk.Hardware.instance.audioInputs();
    var outs = await lk.Hardware.instance.audioOutputs();
    await log('  in=${ins.length} out=${outs.length}');
    for (final d in ins) {
      await log('   IN  ${d.deviceId} | ${d.label}');
    }
    for (final d in outs) {
      await log('   OUT ${d.deviceId} | ${d.label}');
    }

    await log('paso 5: init audio (crear+parar track) y re-enumerar ...');
    final t = await lk.LocalAudioTrack.create();
    await t.stop();
    await t.dispose();
    ins = await lk.Hardware.instance.audioInputs();
    outs = await lk.Hardware.instance.audioOutputs();
    await log('  TRAS INIT: in=${ins.length} out=${outs.length}');
    for (final d in ins) {
      await log('   IN  ${d.deviceId} | ${d.label}');
    }
    for (final d in outs) {
      await log('   OUT ${d.deviceId} | ${d.label}');
    }

    await log('=== diag FIN ok ===');
  } catch (e, st) {
    await log('EXCEPCIÓN: $e\n$st');
  }
  exit(0);
}

// Reproduce el screenshare REAL: conecta a una sala LiveKit y prueba la captura
// con distintos presets, registrando cada paso (si crashea, falta la línea).
Future<void> _diagShare() async {
  final out = File(r'C:\Users\ferna\Downloads\chatpapol-toolchain\diag-share.txt');
  final cfg = File(r'C:\Users\ferna\Downloads\chatpapol-toolchain\share-test.txt')
      .readAsLinesSync();
  final url = cfg[0], token = cfg[1];
  final variant = cfg.length > 2 ? cfg[2].trim() : '1080';
  Future<void> log(String s) async => out.writeAsStringSync('$s\n', mode: FileMode.append);
  out.writeAsStringSync('=== diag-share variant=$variant ===\n');
  lk.Room? room;
  try {
    await log('1: conectando ...');
    // mismas opciones de publish que la app (una capa, sin simulcast)
    room = lk.Room(
        roomOptions: const lk.RoomOptions(
            defaultVideoPublishOptions:
                lk.VideoPublishOptions(simulcast: false)));
    await room.connect(url, token);
    await log('  conectado ✓');

    // variant: "screen:N" / "window:N" / 1080 / 720 / default / captureonly / fps
    // "fps" es la prueba discriminante del fix: idéntico a 1080 pero con
    // maxFrameRate explícito (sin él, livekit manda mandatory:{frameRate:null}
    // y el plugin C++ hace fastfail). Predicción: 1080/default crashean, fps NO.
    final isWin = variant.startsWith('window');
    final idx = variant.contains(':') ? int.tryParse(variant.split(':')[1]) ?? 0 : 0;
    List<rtc.DesktopCapturerSource> srcs;
    if (variant == 'app') {
      // flujo REAL del picker: pantallas y luego ventanas (la lista nativa
      // queda en "ventanas"); sin la re-enumeración de startShare esto daba
      // "source not found" al compartir una pantalla
      srcs = await rtc.desktopCapturer.getSources(types: [rtc.SourceType.Screen]);
      await rtc.desktopCapturer.getSources(types: [rtc.SourceType.Window]);
    } else {
      srcs = await rtc.desktopCapturer.getSources(
          types: [isWin ? rtc.SourceType.Window : rtc.SourceType.Screen]);
    }
    await log('2: ${srcs.length} fuentes (${isWin ? "ventanas" : "pantallas"}):');
    for (var i = 0; i < srcs.length; i++) {
      await log('     [$i] ${srcs[i].name}');
    }
    final src = srcs[idx.clamp(0, srcs.length - 1)];
    await log('   usando [$idx] "${src.name}"');

    lk.ScreenShareCaptureOptions opts;
    switch (variant) {
      case '720':
        opts = lk.ScreenShareCaptureOptions(
            sourceId: src.id, params: lk.VideoParametersPresets.screenShareH720FPS5);
        break;
      case 'default': // sin params: deja que webrtc negocie
        opts = lk.ScreenShareCaptureOptions(sourceId: src.id);
        break;
      case 'fps': // el FIX: maxFrameRate explícito evita frameRate:null
        opts = lk.ScreenShareCaptureOptions(
            sourceId: src.id,
            maxFrameRate: 30.0,
            params: lk.VideoParametersPresets.screenShareH1080FPS30);
        break;
      case 'app': // igual que startShare: re-enumera el tipo elegido y 60fps
        await rtc.desktopCapturer.getSources(types: [src.type]);
        opts = lk.ScreenShareCaptureOptions(
            sourceId: src.id,
            maxFrameRate: 60.0,
            params: const lk.VideoParameters(
                dimensions: lk.VideoDimensionsPresets.h1080_169,
                encoding:
                    lk.VideoEncoding(maxBitrate: 8000 * 1000, maxFramerate: 60)));
        break;
      case 'audio': // screenshare CON audio del sistema (loopback) x3 ciclos
        opts = lk.ScreenShareCaptureOptions(
            sourceId: src.id,
            captureScreenAudio: true,
            maxFrameRate: 30.0,
            params: lk.VideoParametersPresets.screenShareH1080FPS30);
        break;
      case '60': // 1080p60 (lo que usa la app): mide fps reales del sender
        opts = lk.ScreenShareCaptureOptions(
            sourceId: src.id,
            maxFrameRate: 60.0,
            params: const lk.VideoParameters(
                dimensions: lk.VideoDimensionsPresets.h1080_169,
                encoding:
                    lk.VideoEncoding(maxBitrate: 8000 * 1000, maxFramerate: 60)));
        break;
      case 'window':
        opts = lk.ScreenShareCaptureOptions(
            sourceId: src.id, params: lk.VideoParametersPresets.screenShareH720FPS5);
        break;
      default: // 1080
        opts = lk.ScreenShareCaptureOptions(
            sourceId: src.id, params: lk.VideoParametersPresets.screenShareH1080FPS30);
    }

    if (variant == 'captureonly') {
      await log('3: createScreenShareTrack SIN publicar (aísla la captura) ...');
      final t = await lk.LocalVideoTrack.createScreenShareTrack(opts);
      await log('  CAPTURA SOLA OK ✓ (el crash NO es la captura → es el encoder/publish)');
      await Future.delayed(const Duration(seconds: 1));
      await t.stop();
      await t.dispose();
      await log('  stop OK');
    } else {
      // 'audio' hace 3 ciclos start/stop para cazar leaks del loopback
      final cycles = variant == 'audio' ? 3 : 1;
      for (var c = 1; c <= cycles; c++) {
        await log('3: setScreenShareEnabled ($variant) ciclo $c/$cycles ...');
        // captureScreenAudio debe ir como PARÁMETRO (livekit revisa ese, no
        // el de las opciones) para que cree y publique el track de audio
        await room.localParticipant?.setScreenShareEnabled(true,
            captureScreenAudio: variant == 'audio',
            screenShareCaptureOptions: opts);
        final pubsOn = room.localParticipant?.audioTrackPublications.length;
        await log('  CAPTURA+PUBLISH OK ✓ (audio pubs=$pubsOn)');
        // deja correr el encoder y mide los fps/bitrate reales del sender
        await Future.delayed(Duration(seconds: variant == 'audio' ? 3 : 6));
        for (final pub in room.localParticipant?.videoTrackPublications ?? []) {
          final track = pub.track;
          if (track is lk.LocalVideoTrack) {
            for (final st in await track.getSenderStats()) {
              await log('  stats rid=${st.rid} fps=${st.framesPerSecond} '
                  '${st.frameWidth}x${st.frameHeight} limit=${st.qualityLimitationReason}');
            }
          }
        }
        await room.localParticipant?.setScreenShareEnabled(false);
        final pubsOff = room.localParticipant?.audioTrackPublications.length;
        await log('  stop OK (audio pubs=$pubsOff)');
      }
    }

    await log('=== diag-share FIN ok (variant=$variant NO crasheó) ===');
  } catch (e, st) {
    await log('EXCEPCIÓN: $e\n$st');
  } finally {
    await room?.disconnect();
    await room?.dispose();
  }
  exit(0);
}

// Ejercita el flujo de auto-update completo SIN UI: check contra el server,
// descarga, extracción y swap (bat + relanzamiento). Para probar el updater
// en un sandbox: compilar con appVersion baja y LOCALAPPDATA redirigido.
Future<void> _diagUpdate() async {
  final out = File(r'C:\Users\ferna\Downloads\chatpapol-toolchain\diag-update.txt');
  Future<void> log(String s) async => out.writeAsStringSync('$s\n', mode: FileMode.append);
  out.writeAsStringSync('=== diag-update v$appVersion desde ${Platform.resolvedExecutable} ===\n');
  try {
    final api = Api()..base = serverUrl;
    await log('1: Updater.check ($serverUrl) ...');
    final u = await Updater.check(api);
    if (u == null) {
      await log('  sin update (ya estamos al día) — FIN');
      exit(0);
    }
    await log('  update ${u.version} → ${u.url}');
    await log('2: downloadAndExtract ...');
    final dir = await Bootstrap.downloadAndExtract(
        api.fileUrl(u.url), u.sha256,
        onProgress: (s, p) {});
    await log('  extraído en ${dir.path}');
    await log('3: applyAndRestart (bat + swap + relaunch) ...');
    await Bootstrap.applyAndRestart(dir); // hace exit(0)
  } catch (e, st) {
    await log('EXCEPCIÓN: $e\n$st');
    exit(1);
  }
}

// [chatpapol diag] Ejercita la ruta nativa de RNNoise + voicefx SIN UI: crea un
// track de audio (inicializa el factory → APM), activa RNNoise y luego los
// efectos, registrando cada paso. Si crashea, la última línea de diag-voicefx.txt
// (Dart) + native.log (C++) dicen dónde. Headless: se puede correr sin GUI.
Future<void> _diagVoiceFx() async {
  final out =
      File(r'C:\Users\ferna\Downloads\chatpapol-toolchain\diag-voicefx.txt');
  Future<void> log(String s) async =>
      out.writeAsStringSync('$s\n', mode: FileMode.append);
  out.writeAsStringSync('=== diag-voicefx v$appVersion ===\n');
  try {
    await log('1: crear LocalAudioTrack (init factory + APM) ...');
    final t = await lk.LocalAudioTrack.create();
    await log('  track OK');

    await log('2: WebrtcApm.setRnnoise(true) ...');
    await WebrtcApm.setRnnoise(true);
    await log('  setRnnoise volvió (NO crasheó)');

    await log('3: WebrtcApm.setVoiceFx(true, spec) ...');
    await WebrtcApm.setVoiceFx(true, '1.0;1.0;0,0,');
    await log('  setVoiceFx volvió (NO crasheó)');

    await log('4: dejar correr 2s (procesado en hilo de audio) ...');
    await Future.delayed(const Duration(seconds: 2));
    await log('  sobrevivió al procesado');

    await log('4b: monitor ON/OFF (escucharme) ...');
    await WebrtcApm.setVoiceMonitor(true);
    await Future.delayed(const Duration(seconds: 1));
    await WebrtcApm.setVoiceMonitor(false);
    await log('  monitor on/off OK (no crasheó)');

    await log('5: apagar (setRnnoise/setVoiceFx false) ...');
    await WebrtcApm.setVoiceFx(false, '');
    await WebrtcApm.setRnnoise(false);
    await log('  apagado OK');

    await t.stop();
    await t.dispose();
    await log('=== diag-voicefx FIN ok (NO crasheó) ===');
  } catch (e, st) {
    await log('EXCEPCIÓN: $e\n$st');
  }
  exit(0);
}

/// Punto de entrada: TODO corre dentro de un runZonedGuarded para que ningún
/// error asíncrono se pierda — el CrashLog lo captura, lo persiste a disco y
/// levanta el banner copiable. La inicialización del binding va DENTRO de la
/// misma zona que runApp (Flutter avisa si no coinciden).
Future<void> main(List<String> args) async {
  runZonedGuarded(() => _main(args), (error, stack) {
    CrashLog.instance.reportError(error, stack, fatal: true);
  });
}

Future<void> _main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lo más temprano posible: engancha debugPrint + errores globales y abre el
  // archivo de log (rota la sesión anterior y detecta si crasheó).
  await CrashLog.instance.init();
  CrashLog.instance.install();
  if (args.contains('--diag')) {
    await _diag();
    return;
  }
  if (args.contains('--diag-share')) {
    await _diagShare();
    return;
  }
  if (args.contains('--diag-update')) {
    await _diagUpdate();
    return;
  }
  if (args.contains('--diag-voicefx')) {
    await _diagVoiceFx();
    return;
  }
  // Desinstalación (la invoca Windows con la UninstallString del registro):
  // limpia registro + accesos directos y borra la carpeta. Headless, sin UI.
  if (args.contains('--uninstall')) {
    await Bootstrap.uninstall();
    return;
  }
  if (_desktop) {
    // tras una actualización quedan los binarios viejos como *.old (el swap
    // in-process los aparta porque estaban en uso): bórralos sin bloquear
    unawaited(Bootstrap.cleanupOldFiles());
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

  // Previews estáticos (verificación visual) — antes de cualquier lógica real.
  if (args.contains('--preview-install')) {
    runApp(const _BootstrapApp(
        child: BootstrapScreen(
            title: 'instalando ChatPapol',
            status: 'instalando…',
            progress: 0.62)));
    return;
  }
  if (args.contains('--preview-update')) {
    runApp(const _BootstrapApp(
        child: BootstrapScreen(
            title: 'actualizando ChatPapol',
            status: 'descargando actualización…',
            progress: 0.41)));
    return;
  }

  // Modo instalación: lanzado con --setup, o corriendo fuera de la carpeta de
  // instalación (zip recién extraído). Muestra la pantalla de instalación.
  if (Bootstrap.isSetupArg(args) ||
      (!args.contains('--no-install') && Bootstrap.needsInstall())) {
    runApp(const _BootstrapApp(child: BootstrapRunner(install: true)));
    return;
  }

  // App instalada corriendo desde su carpeta: asegura la entrada de
  // "Desinstalar" (idempotente; auto-repara instalaciones viejas sin la clave).
  if (Platform.isWindows && !Bootstrap.needsInstall()) {
    unawaited(Bootstrap.ensureUninstallEntry());
  }

  await SfxService.instance.init();
  await AmbienceService.instance.init();
  await VoiceFxEngine.instance.init();
  await NotificationService.instance.init();
  final store = AppStore();
  final voice = VoiceManager(store);
  // Click en un toast del SO: traer la ventana al frente y abrir el canal.
  NotificationService.instance.onOpenChannel = (chId) async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
    store.selectChannel(chId);
  };
  // Foco de ventana: solo notificamos por toast cuando la app NO está enfocada.
  if (_desktop) {
    try {
      store.setWindowFocused(await windowManager.isFocused());
    } catch (_) {}
    // Interceptamos el cierre para desconectar la sala de voz ANTES de morir:
    // si no, WebRTC nunca libera el dispositivo de salida y la sesión queda
    // colgada en el Mezclador de volumen de Windows.
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {}
    windowManager.addListener(_FocusListener(store, voice));
  }
  store.tryRestore();
  runApp(ChatPapolApp(store: store, voice: voice));
}

/// Mantiene `store.windowFocused` al día y, al cerrar la ventana, desconecta la
/// voz antes de destruirla (libera el dispositivo de audio → la sesión
/// desaparece del Mezclador de volumen).
class _FocusListener extends WindowListener {
  final AppStore store;
  final VoiceManager voice;
  _FocusListener(this.store, this.voice);
  @override
  void onWindowClose() async {
    // Desconectar la sala libera el dispositivo de audio. Con timeout: si la
    // desconexión de WebRTC se cuelga, NO bloqueamos el cierre — destruimos la
    // ventana igual y el runner nativo fuerza la salida del proceso.
    try {
      await voice.leave().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // Marca el cierre como limpio: si la próxima sesión no ve este marcador,
    // sabrá que la app murió de golpe (crash) y ofrecerá copiar esos logs.
    CrashLog.instance.markCleanShutdown();
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
  }

  @override
  void onWindowFocus() => store.setWindowFocused(true);
  @override
  void onWindowBlur() => store.setWindowFocused(false);
}

/// Compone la barra de título propia encima del contenido de la app.
/// El TitleBar va dentro de su PROPIO Overlay para que sus Tooltip encuentren
/// un Overlay ancestro (se monta por encima del Navigator de la MaterialApp).
/// El [child] (el Navigator) queda FUERA del Overlay para que se reconstruya
/// con normalidad en cada rebuild.
Widget _withTitleBar(Widget? child) {
  final content = child ?? const SizedBox.shrink();
  if (!_desktop) return CrashOverlay(child: content);
  return CrashOverlay(
    child: Column(children: [
      SizedBox(
        height: 36,
        child: Overlay(initialEntries: [
          OverlayEntry(builder: (_) => const TitleBar()),
        ]),
      ),
      Expanded(child: content),
    ]),
  );
}

class _BootstrapApp extends StatelessWidget {
  final Widget child;
  const _BootstrapApp({required this.child});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChatPapol',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      builder: (ctx, c) => _withTitleBar(c),
      home: child,
    );
  }
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
      builder: (ctx, child) => _withTitleBar(child),
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
