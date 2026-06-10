import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart' as m;
import 'store.dart';

/// livekit no trae preset de screenshare a 60fps; 1080p60 fluido necesita
/// más bitrate que el preset de 30fps (4Mbps) para no verse borroso.
const _share1080FPS60 = VideoParameters(
  dimensions: VideoDimensionsPresets.h1080_169,
  encoding: VideoEncoding(maxBitrate: 8000 * 1000, maxFramerate: 60),
);

VideoParameters _shareParamsFor(int fps) => switch (fps) {
      15 => VideoParametersPresets.screenShareH1080FPS15,
      60 => _share1080FPS60,
      _ => VideoParametersPresets.screenShareH1080FPS30,
    };

/// Voz, screenshare y soundboard. LiveKit hace el trabajo duro (SFU);
/// el soundboard NO usa WebRTC: cada cliente reproduce el archivo localmente.
class VoiceManager extends ChangeNotifier {
  final AppStore store;
  VoiceManager(this.store) {
    store.onSoundPlay = _playSound;
    _loadPrefs();
  }

  Room? room;
  EventsListener<RoomEvent>? _listener;
  String? channelId;
  bool muted = false;
  bool deafened = false;
  bool _mutedByDeafen = false; // el micro lo cerró el propio ensordecer
  bool sharing = false;
  bool connecting = false;
  final speaking = <String>{};
  // Aro propio: detección LOCAL del nivel del micro que se ESTÁ ENVIANDO —
  // aro encendido = tus amigos te están oyendo. Umbral bajo a propósito
  // (sensible); el server solo gobierna los aros de los demás.
  static const _selfSpeakLevel = 0.01;
  Timer? _selfSpeakTimer;
  DateTime _selfLastLoud = DateTime.fromMillisecondsSinceEpoch(0);
  final _player = AudioPlayer();

  // Opciones de micrófono persistidas (ajustes de "Voz y micrófono").
  String? micDeviceId;
  bool noiseSuppression = true;
  bool echoCancellation = true;
  bool autoGainControl = true;
  // Volumen de SALIDA (playout de tracks remotos). NO hay ganancia de captura:
  // ver setOutputVolume.
  double outputVolume = 1.0;
  // Volumen POR USUARIO (identity → 0.0..2.0; 1.0 = normal). Persistido en
  // local: si te encuentras a la misma persona en otro canal, se respeta.
  final userVolumes = <String, double>{};

  bool get connected => room != null && channelId != null;

  /// Opciones con las que se publica el micro SIEMPRE (join y re-publicaciones).
  AudioCaptureOptions get micOptions => AudioCaptureOptions(
        deviceId: micDeviceId,
        noiseSuppression: noiseSuppression,
        echoCancellation: echoCancellation,
        autoGainControl: autoGainControl,
      );

  /// Track de micro publicado en la sala actual (o null si no hay).
  LocalAudioTrack? get micTrack {
    final pub = room?.localParticipant
        ?.getTrackPublicationBySource(TrackSource.microphone);
    final t = pub?.track;
    return t is LocalAudioTrack ? t : null;
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    micDeviceId = prefs.getString('mic_device_id');
    noiseSuppression = prefs.getBool('mic_noise_suppression') ?? true;
    echoCancellation = prefs.getBool('mic_echo_cancellation') ?? true;
    autoGainControl = prefs.getBool('mic_auto_gain') ?? true;
    outputVolume = prefs.getDouble('voice_output_volume') ?? 1.0;
    try {
      final raw = prefs.getString('voice_user_volumes');
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach(
            (k, v) => userVolumes[k] = (v as num).toDouble().clamp(0.0, 2.0));
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Volumen individual de [identity] (0.0..2.0). Se guarda en local y se
  /// aplica de inmediato si está en la llamada.
  Future<void> setUserVolume(String identity, double v) async {
    v = v.clamp(0.0, 2.0);
    // 1.0 = normal: no ensuciar el mapa con valores default
    (v - 1.0).abs() < 0.01 ? userVolumes.remove(identity) : userVolumes[identity] = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('voice_user_volumes', jsonEncode(userVolumes));
    _applyOutputVolumeAll();
    notifyListeners();
  }

  double userVolume(String identity) => userVolumes[identity] ?? 1.0;

  Future<void> _saveMicPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    micDeviceId == null
        ? await prefs.remove('mic_device_id')
        : await prefs.setString('mic_device_id', micDeviceId!);
    await prefs.setBool('mic_noise_suppression', noiseSuppression);
    await prefs.setBool('mic_echo_cancellation', echoCancellation);
    await prefs.setBool('mic_auto_gain', autoGainControl);
  }

  /// Cambia el dispositivo de entrada (null = predeterminado del sistema).
  Future<void> setMicDevice(MediaDevice? device) async {
    micDeviceId = device?.deviceId;
    if (device != null) {
      try {
        await Hardware.instance.selectAudioInput(device); // solo desktop
      } catch (_) {}
    }
    await _saveMicPrefs();
    await applyMicOptions();
    notifyListeners();
  }

  Future<void> setNoiseSuppression(bool v) =>
      _setFlag(() => noiseSuppression = v);
  Future<void> setEchoCancellation(bool v) =>
      _setFlag(() => echoCancellation = v);
  Future<void> setAutoGainControl(bool v) =>
      _setFlag(() => autoGainControl = v);

  Future<void> _setFlag(void Function() apply) async {
    apply();
    await _saveMicPrefs();
    await applyMicOptions();
    notifyListeners();
  }

  // Opciones cambiadas estando muteado: se aplican al des-mutear.
  bool _micOptionsPending = false;

  /// Re-aplica las opciones al track de micro publicado: restartTrack
  /// reemplaza el stream de captura (replaceTrack) sin re-negociar.
  ///
  /// NUNCA con el track muteado: restartTrack reabre la captura
  /// (getUserMedia) y hace replaceTrack en el sender sin re-aplicar el mute,
  /// así que el micro volvería a enviar audio real mientras la UI dice
  /// "muteado" (livekit hace este mismo guard en LocalAudioTrack.setDeviceId).
  /// En ese caso se difiere hasta el siguiente des-mute.
  Future<void> applyMicOptions() async {
    final t = micTrack;
    if (t == null) return;
    if (t.muted) {
      _micOptionsPending = true;
      return;
    }
    try {
      await t.restartTrack(micOptions);
    } catch (_) {}
  }

  /// Volumen de SALIDA: atenúa el playout de los tracks remotos.
  /// HONESTO: en desktop NO existe API real de ganancia de CAPTURA del micro
  /// (Helper.setVolume sobre un track local es un no-op en el pipeline de
  /// envío de webrtc; solo afecta a fuentes remotas). Por eso el slider de
  /// ajustes controla la salida; la ganancia de entrada se regula con el AGC
  /// (autoGainControl) o con el volumen de micrófono del sistema operativo.
  Future<void> setOutputVolume(double v) async {
    outputVolume = v.clamp(0.0, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('voice_output_volume', outputVolume);
    _applyOutputVolumeAll();
    notifyListeners();
  }

  void _applyOutputVolume(Track t, String identity) {
    if (t is! RemoteAudioTrack) return;
    try {
      rtc.Helper.setVolume(
          (outputVolume * userVolume(identity)).clamp(0.0, 2.0),
          t.mediaStreamTrack);
    } catch (_) {}
  }

  void _applyOutputVolumeAll() {
    final r = room;
    if (r == null) return;
    for (final p in r.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t != null) _applyOutputVolume(t, p.identity);
      }
    }
  }

  Future<void> join(String chId) async {
    if (channelId == chId) return;
    await leave();
    connecting = true;
    notifyListeners();
    try {
      final t = await store.api.post('/api/channels/$chId/voice-token');
      final r = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioCaptureOptions: micOptions,
          // captureScreenAudio va por llamada en startShare (opt-in): el
          // loopback de audio en Windows puede crashear el capturador nativo
          // maxFrameRate explícito SIEMPRE: si queda null, livekit manda
          // mandatory:{frameRate:null} y el plugin nativo de Windows hace
          // std::get<int> sobre null → __fastfail 0xC0000409 (app muerta).
          defaultScreenShareCaptureOptions: const ScreenShareCaptureOptions(
            maxFrameRate: 30.0,
            params: VideoParametersPresets.screenShareH1080FPS30,
          ),
          // una sola capa a máxima calidad: con simulcast el screenshare
          // reparte el bitrate entre capas y la nítida tarda/no llega
          defaultVideoPublishOptions:
              const VideoPublishOptions(simulcast: false),
        ),
      );
      await r.connect(t['url'], t['token']);
      room = r;
      channelId = chId;
      _listener = r.createListener()
        ..on<ActiveSpeakersChangedEvent>((e) {
          final selfId = store.me?.id;
          final selfOn = selfId != null && speaking.contains(selfId);
          speaking
            ..clear()
            ..addAll(e.speakers.map((p) => p.identity));
          // el aro propio lo gobierna la detección local, no el server
          if (selfId != null) {
            selfOn ? speaking.add(selfId) : speaking.remove(selfId);
          }
          notifyListeners();
        })
        // transiciones por participante: prende/apaga el aro sin esperar al
        // siguiente snapshot completo de active speakers
        ..on<SpeakingChangedEvent>((e) {
          if (e.participant.identity == store.me?.id) return; // self = local
          e.speaking
              ? speaking.add(e.participant.identity)
              : speaking.remove(e.participant.identity);
          notifyListeners();
        })
        ..on<RoomDisconnectedEvent>((_) => _cleanup())
        ..on<TrackSubscribedEvent>((e) {
          _applyOutputVolume(e.track, e.participant.identity);
          notifyListeners();
        })
        ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
        ..on<ParticipantConnectedEvent>((_) => notifyListeners())
        ..on<ParticipantDisconnectedEvent>((_) => notifyListeners());
      try {
        await r.localParticipant
            ?.setMicrophoneEnabled(!muted, audioCaptureOptions: micOptions);
      } catch (_) {/* sin permiso SPEAK: solo escucha */}
      _startSelfSpeaking();
      store.gateway.send('VOICE_JOIN', {'channel_id': chId, 'mute': muted, 'deaf': deafened});
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> leave() async {
    if (room == null) return;
    store.gateway.send('VOICE_LEAVE', null);
    final r = room;
    _cleanup();
    await r?.disconnect();
    await r?.dispose();
  }

  /// Aro propio por nivel LOCAL del micro: sondea audioLevel (stats
  /// media-source del sender) cada ~180ms con hangover de 350ms.
  void _startSelfSpeaking() {
    _selfSpeakTimer?.cancel();
    _selfSpeakTimer =
        Timer.periodic(const Duration(milliseconds: 180), (_) async {
      final selfId = store.me?.id;
      if (selfId == null || room == null) return;
      var level = 0.0;
      if (!muted) {
        try {
          final sender = micTrack?.sender;
          if (sender != null) {
            for (final rep in await sender.getStats()) {
              if (rep.type == 'media-source') {
                final v = rep.values['audioLevel'];
                if (v is num) level = v.toDouble();
              }
            }
          }
        } catch (_) {}
      }
      final now = DateTime.now();
      if (level > _selfSpeakLevel) _selfLastLoud = now;
      final on = now.difference(_selfLastLoud).inMilliseconds < 350;
      final changed = on ? speaking.add(selfId) : speaking.remove(selfId);
      if (changed) notifyListeners();
    });
  }

  void _cleanup() {
    _selfSpeakTimer?.cancel();
    _selfSpeakTimer = null;
    _listener?.dispose();
    _listener = null;
    room = null;
    channelId = null;
    sharing = false;
    _micOptionsPending = false;
    speaking.clear();
    notifyListeners();
  }

  Future<void> toggleMute() async {
    muted = !muted;
    try {
      // las opciones solo aplican si es la primera publicación del micro
      await room?.localParticipant
          ?.setMicrophoneEnabled(!muted, audioCaptureOptions: micOptions);
      if (!muted && _micOptionsPending) {
        // hubo cambios de opciones mientras estaba muteado: aplícalos ahora
        _micOptionsPending = false;
        await applyMicOptions();
      }
    } catch (_) {}
    store.gateway.send('VOICE_STATE', {'mute': muted});
    notifyListeners();
  }

  Future<void> toggleDeafen() async {
    deafened = !deafened;
    if (deafened) {
      // al ensordecer, cierra el micro si estaba abierto y recuerda que fuimos
      // nosotros, para poder restaurarlo al desensordecer.
      if (!muted) { _mutedByDeafen = true; await toggleMute(); }
    } else if (_mutedByDeafen) {
      // al desensordecer, reabre el micro solo si lo cerró el ensordecer
      // (si el usuario lo había silenciado a mano, lo dejamos como estaba).
      _mutedByDeafen = false;
      await toggleMute();
    }
    // silencia/reactiva todos los streams de audio remotos
    final r = room;
    if (r != null) {
      for (final p in r.remoteParticipants.values) {
        for (final pub in p.trackPublications.values) {
          if (pub.kind == TrackType.AUDIO) {
            try {
              deafened ? await pub.disable() : await pub.enable();
            } catch (_) {}
          }
        }
      }
    }
    store.gateway.send('VOICE_STATE', {'deaf': deafened});
    notifyListeners();
  }

  /// Enumera pantallas/ventanas con miniatura para el selector.
  /// Dos llamadas separadas: pedir Screen+Window en una sola getSources
  /// devuelve solo las ventanas (las pantallas se pierden en el plugin).
  Future<List<rtc.DesktopCapturerSource>> shareSources() async {
    final thumb = rtc.ThumbnailSize(320, 180);
    final screens = await rtc.desktopCapturer
        .getSources(types: [rtc.SourceType.Screen], thumbnailSize: thumb);
    final windows = await rtc.desktopCapturer
        .getSources(types: [rtc.SourceType.Window], thumbnailSize: thumb);
    // dedupe por id: eventos tardíos del plugin pueden re-inyectar fuentes de
    // la primera enumeración en el resultado de la segunda (lista duplicada)
    final byId = <String, rtc.DesktopCapturerSource>{};
    for (final s in [...screens, ...windows]) {
      byId[s.id] = s;
    }
    return byId.values.toList();
  }

  /// [withAudio] comparte el audio del sistema vía loopback WASAPI (plugin
  /// flutter-webrtc pineado a main; verificado con --diag-share). [fps] =
  /// 15, 30 o 60 (1080p en todos).
  Future<void> startShare(rtc.DesktopCapturerSource source,
      {bool withAudio = false, int fps = 60}) async {
    // el plugin solo captura fuentes de la ÚLTIMA enumeración (getSources
    // limpia la lista nativa) y el selector enumera ventanas al final: hay que
    // re-enumerar el tipo elegido aquí o getDisplayMedia da "source not found"
    await rtc.desktopCapturer.getSources(types: [source.type]);
    await room?.localParticipant?.setScreenShareEnabled(
      true,
      // OJO: livekit revisa este PARÁMETRO (no el campo de las opciones)
      // para crear y publicar el track de audio del sistema (loopback)
      captureScreenAudio: withAudio,
      screenShareCaptureOptions: ScreenShareCaptureOptions(
        sourceId: source.id,
        captureScreenAudio: withAudio,
        // null aquí mata el proceso en Windows (mandatory frameRate:null →
        // fastfail en ParseConstraints del plugin C++); ver RoomOptions.
        maxFrameRate: fps.toDouble(),
        params: _shareParamsFor(fps),
      ),
    );
    sharing = true;
    store.gateway.send('VOICE_STATE', {'streaming': true});
    notifyListeners();
  }

  Future<void> stopShare() async {
    await room?.localParticipant?.setScreenShareEnabled(false);
    sharing = false;
    store.gateway.send('VOICE_STATE', {'streaming': false});
    notifyListeners();
  }

  /// Pide al server que emita SOUND_PLAY a todos los del canal.
  Future<void> triggerSound(m.Sound sound) async {
    if (channelId == null) return;
    await store.api.post('/api/channels/$channelId/sounds/${sound.id}/play');
  }

  void _playSound(m.Sound sound, String chId) {
    if (deafened || channelId != chId) return;
    _player.play(UrlSource(store.api.fileUrl(sound.url)));
  }

  /// Tracks de video (screenshare) visibles en la sala.
  List<VideoTrack> get videoTracks {
    final r = room;
    if (r == null) return [];
    final tracks = <VideoTrack>[];
    for (final p in r.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        final t = pub.track;
        if (t != null && pub.subscribed) tracks.add(t);
      }
    }
    for (final pub in r.localParticipant?.videoTrackPublications ?? const []) {
      final t = pub.track;
      if (t != null) tracks.add(t as VideoTrack);
    }
    return tracks;
  }

  @override
  void dispose() {
    leave();
    _player.dispose();
    super.dispose();
  }
}
