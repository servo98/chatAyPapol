import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'sfx.dart';

/// Conexión WS al gateway con reconexión automática y heartbeat.
class Gateway {
  WebSocketChannel? _ch;
  Timer? _heartbeat;
  Timer? _reconnect;
  bool _closed = false;
  String _url = '';
  // Estado de conexión SOLO para disparar SFX en transiciones reales (onStatus
  // se llama en cada mensaje, así que no sirve para detectar el flanco).
  bool _sfxConnected = false;

  void Function(String t, dynamic d)? onEvent;
  void Function(bool connected)? onStatus;

  void connect(String base, String token) {
    _closed = false;
    _url = '${base.replaceFirst('http', 'ws')}/gateway?token=$token';
    _open();
  }

  void _open() {
    if (_closed) return;
    _ch?.sink.close();
    final ch = WebSocketChannel.connect(Uri.parse(_url));
    _ch = ch;
    ch.stream.listen((raw) {
      onStatus?.call(true);
      // SFX solo en el flanco: primer mensaje tras (re)conectar.
      if (!_sfxConnected) {
        _sfxConnected = true;
        SfxService.instance.play(UiSound.connected);
      }
      final msg = jsonDecode(raw as String);
      if (msg['t'] != 'PONG') onEvent?.call(msg['t'], msg['d']);
    }, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) => send('PING', null));
  }

  void _scheduleReconnect() {
    onStatus?.call(false);
    // SFX solo si veníamos conectados: evita ruido en reintentos en bucle
    // (el flag no se rearma hasta que llega de nuevo el primer mensaje).
    if (_sfxConnected) {
      _sfxConnected = false;
      SfxService.instance.play(UiSound.disconnected);
    }
    if (_closed) return;
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 3), _open);
  }

  void send(String t, dynamic d) {
    try {
      _ch?.sink.add(jsonEncode({'t': t, 'd': d}));
    } catch (_) {/* sin conexión: el reconnect se encarga */}
  }

  void dispose() {
    _closed = true;
    _sfxConnected = false; // logout intencional: no suena 'desconectado'
    _heartbeat?.cancel();
    _reconnect?.cancel();
    _ch?.sink.close();
    _ch = null;
  }
}
