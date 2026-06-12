import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart' as m;
import 'store.dart';
import 'sfx.dart';
import 'ambience.dart';
import 'audio/voice_fx.dart';
import 'webrtc_apm.dart';

/// Un screenshare remoto visible: track de video + quién lo comparte.
/// Se usa para el grid y para el modo pantalla completa.
class ScreenShare {
  final VideoTrack track;
  final String identity;
  final String? name;
  const ScreenShare(
      {required this.track, required this.identity, this.name});
}

/// livekit no trae preset de screenshare a 60fps; 1080p60 fluido necesita
/// más bitrate que el preset de 30fps (4Mbps) para no verse borroso.
const _share1080FPS60 = VideoParameters(
  dimensions: VideoDimensionsPresets.h1080_169,
  encoding: VideoEncoding(maxBitrate: 8000 * 1000, maxFramerate: 60),
);

/// Publicación del MICRO: voz clara pero económica. dtx/red ON (ahorra ancho
/// de banda en silencios y resiste pérdida de paquetes), 96kbps. Va por
/// RoomOptions.defaultAudioPublishOptions porque setMicrophoneEnabled en
/// livekit 2.8.0 NO acepta audioPublishOptions (solo audioCaptureOptions).
const _micPublishOptions = AudioPublishOptions(
  dtx: true,
  red: true,
  encoding: AudioEncoding.presetMusicHighQuality, // 96kbps
);

/// Publicación del AUDIO DEL SISTEMA (screenshare): ALTA FIDELIDAD ESTÉREO
/// FIJA. dtx:false y red:false (no recortar en "silencios" musicales ni meter
/// redundancia que enturbie), 128kbps estéreo. NO se puede setear por
/// RoomOptions (eso también afectaría al micro): se publica el track a mano
/// con estas opciones en startShare. Esto arregla el "se oye lejano".
const _sharePublishOptions = AudioPublishOptions(
  dtx: false,
  red: false,
  encoding: AudioEncoding.presetMusicHighQualityStereo, // 128kbps estéreo
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
    store.onAmbienceChange = _onAmbienceChange;
    // Empuja la cadena de efectos al procesador nativo cada vez que cambia.
    VoiceFxEngine.instance.addListener(_onVoiceFxChanged);
    _loadPrefs();
  }

  // Debounce del push de la cadena de efectos al nativo (coalesce drags).
  Timer? _fxPushTimer;
  void _onVoiceFxChanged() {
    _fxPushTimer?.cancel();
    _fxPushTimer = Timer(const Duration(milliseconds: 150), _pushVoiceFx);
  }

  /// Envía el estado actual de los efectos (enabled + cadena) al post-procesador
  /// nativo del fork flutter_webrtc. No-op si el build no lo soporta.
  Future<void> _pushVoiceFx() async {
    final e = VoiceFxEngine.instance;
    await WebrtcApm.setVoiceFx(e.enabled, e.nativeChainSpec());
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
  // RNNoise (IA, CPU): supresor de ruido extra del micro, encima del NS clásico.
  // El APM es global del factory → se aplica una vez (no por track).
  bool rnnoise = false;
  // Volumen de SALIDA (playout de tracks remotos). NO hay ganancia de captura:
  // ver setOutputVolume.
  double outputVolume = 1.0;
  // Volumen POR USUARIO (identity → 0.0..2.0; 1.0 = normal). Persistido en
  // local: si te encuentras a la misma persona en otro canal, se respeta.
  final userVolumes = <String, double>{};
  // Volumen del AUDIO DEL SCREENSHARE por usuario (identity → 0.0..2.0),
  // SEPARADO del volumen del micro. Persistido en local igual que userVolumes.
  final shareVolumes = <String, double>{};

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
    rnnoise = prefs.getBool('mic_rnnoise') ?? false;
    outputVolume = prefs.getDouble('voice_output_volume') ?? 1.0;
    try {
      final raw = prefs.getString('voice_user_volumes');
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach(
            (k, v) => userVolumes[k] = (v as num).toDouble().clamp(0.0, 2.0));
      }
    } catch (_) {}
    try {
      final raw = prefs.getString('voice_share_volumes');
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach(
            (k, v) => shareVolumes[k] = (v as num).toDouble().clamp(0.0, 2.0));
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

  /// Volumen del AUDIO DEL SCREENSHARE de [identity] (0.0..2.0). Independiente
  /// del volumen del micro de esa persona. Se guarda en local y se aplica ya.
  Future<void> setShareVolume(String identity, double v) async {
    v = v.clamp(0.0, 2.0);
    (v - 1.0).abs() < 0.01
        ? shareVolumes.remove(identity)
        : shareVolumes[identity] = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('voice_share_volumes', jsonEncode(shareVolumes));
    _applyOutputVolumeAll();
    notifyListeners();
  }

  double shareVolume(String identity) => shareVolumes[identity] ?? 1.0;

  Future<void> _saveMicPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    micDeviceId == null
        ? await prefs.remove('mic_device_id')
        : await prefs.setString('mic_device_id', micDeviceId!);
    await prefs.setBool('mic_noise_suppression', noiseSuppression);
    await prefs.setBool('mic_echo_cancellation', echoCancellation);
    await prefs.setBool('mic_auto_gain', autoGainControl);
    await prefs.setBool('mic_rnnoise', rnnoise);
  }

  /// Activa/desactiva RNNoise. El APM es global del factory → NO reinicia el
  /// track (a diferencia de los flags clásicos). Persiste y aplica de inmediato.
  Future<void> setRnnoise(bool v) async {
    rnnoise = v;
    await _saveMicPrefs();
    await WebrtcApm.setRnnoise(v);
    notifyListeners();
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

  /// Aplica el volumen de salida a UNA publicación de audio remota,
  /// distinguiendo la fuente: el audio del SCREENSHARE usa shareVolume(identity)
  /// y el MICRO usa userVolume(identity) — son dos sliders distintos.
  void _applyOutputVolume(RemoteTrackPublication pub, String identity) {
    final t = pub.track;
    if (t is! RemoteAudioTrack) return;
    final perUser = pub.source == TrackSource.screenShareAudio
        ? shareVolume(identity)
        : userVolume(identity);
    try {
      rtc.Helper.setVolume(
          (outputVolume * perUser).clamp(0.0, 2.0), t.mediaStreamTrack);
    } catch (_) {}
  }

  void _applyOutputVolumeAll() {
    final r = room;
    if (r == null) return;
    for (final p in r.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        if (pub.track != null) _applyOutputVolume(pub, p.identity);
      }
    }
  }

  Future<void> join(String chId) async {
    if (channelId == chId) return;
    debugPrint('[voice] join canal=$chId — leave previo');
    await leave();
    connecting = true;
    notifyListeners();
    try {
      debugPrint('[voice] pidiendo voice-token');
      final t = await store.api.post('/api/channels/$chId/voice-token');
      final r = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioCaptureOptions: micOptions,
          // publicación del micro (96kbps, dtx/red ON): setMicrophoneEnabled no
          // acepta publish options en 2.8.0, así que se gobierna desde aquí.
          // El audio del screenshare NO usa este default (se publica a mano en
          // startShare con opciones de alta fidelidad estéreo).
          defaultAudioPublishOptions: _micPublishOptions,
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
      debugPrint('[voice] conectando a LiveKit…');
      await r.connect(t['url'], t['token']);
      debugPrint('[voice] conectado; montando listeners');
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
          _applyOutputVolume(e.publication, e.participant.identity);
          notifyListeners();
        })
        ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
        ..on<ParticipantConnectedEvent>((_) => notifyListeners())
        ..on<ParticipantDisconnectedEvent>((_) => notifyListeners());
      try {
        debugPrint('[voice] publicando micro (mute=$muted)');
        await r.localParticipant
            ?.setMicrophoneEnabled(!muted, audioCaptureOptions: micOptions);
      } catch (_) {/* sin permiso SPEAK: solo escucha */}
      // Post-procesado nativo del micro (RNNoise + efectos de voz). Reaplicamos
      // el estado persistido SOLO si hay algo encendido. Es optimización (no
      // instalar un post-procesador que igual haría no-op) y red de seguridad:
      // el fork tenía un bug por el que SetCapturePostProcessing(null) crasheaba
      // en Windows (libwebrtc m144) — ya arreglado en el fork (nunca se pasa
      // null), pero saltar la llamada cuando todo está apagado también protege
      // builds contra forks viejos.
      if (rnnoise) {
        debugPrint('[voice] aplicando RNNoise=$rnnoise');
        await WebrtcApm.setRnnoise(rnnoise);
      }
      if (VoiceFxEngine.instance.enabled) {
        debugPrint('[voice] aplicando voicefx');
        await _pushVoiceFx();
      }
      debugPrint('[voice] join OK');
      _startSelfSpeaking();
      store.gateway.send('VOICE_JOIN', {'channel_id': chId, 'mute': muted, 'deaf': deafened});
      // si el canal ya tenía un ambiente sonando, engánchate sincronizado
      _applyCurrentAmbience();
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
    AmbienceService.instance.stop(); // al salir del canal, calla su ambiente
    // apaga el monitor "escucharme" al salir (si no, reaparecería al reentrar)
    VoiceMonitor.instance.set(false);
    notifyListeners();
  }

  Future<void> toggleMute({bool fromDeafen = false}) async {
    muted = !muted;
    // si el usuario togglea el micro a mano, deja de ser "cerrado por ensordecer"
    // para no re-silenciarlo al desensordecer.
    if (!fromDeafen) _mutedByDeafen = false;
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
    // SFX solo si el usuario lo hizo a mano (no cuando el mute viene del deafen,
    // que ya suena con su propio selfDeafen).
    if (!fromDeafen) {
      SfxService.instance.play(muted ? UiSound.selfMute : UiSound.selfUnmute);
    }
    store.gateway.send('VOICE_STATE', {'mute': muted});
    notifyListeners();
  }

  Future<void> toggleDeafen() async {
    deafened = !deafened;
    // SfxService.muted sigue a deafened para callar todos los avisos mientras
    // estás sordo. Orden cuidado para que el propio aviso de (des)ensordecer SÍ
    // suene: al des-ensordecer abrimos el SFX ANTES de reproducir el undeafen;
    // al ensordecer reproducimos el deafen ANTES de silenciar.
    if (!deafened) SfxService.instance.muted = false;
    SfxService.instance
        .play(deafened ? UiSound.selfDeafen : UiSound.selfUndeafen);
    if (deafened) SfxService.instance.muted = true;
    if (deafened) {
      // al ensordecer, cierra el micro si estaba abierto y recuerda que fuimos
      // nosotros, para poder restaurarlo al desensordecer.
      if (!muted) { _mutedByDeafen = true; await toggleMute(fromDeafen: true); }
    } else if (_mutedByDeafen) {
      // al desensordecer, reabre el micro solo si lo cerró el ensordecer
      // (si el usuario lo había silenciado a mano, lo dejamos como estaba).
      _mutedByDeafen = false;
      await toggleMute(fromDeafen: true);
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
    // ensordecer = no oír NADA, tampoco el ambiente; al desensordecer reengancha
    // sincronizado.
    _applyCurrentAmbience();
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
    final lp = room?.localParticipant;
    if (lp == null) return;
    // el plugin solo captura fuentes de la ÚLTIMA enumeración (getSources
    // limpia la lista nativa) y el selector enumera ventanas al final: hay que
    // re-enumerar el tipo elegido aquí o getDisplayMedia da "source not found"
    await rtc.desktopCapturer.getSources(types: [source.type]);
    // captureOptions con el fix de crash de Windows intacto: maxFrameRate
    // SIEMPRE explícito (null → fastfail en ParseConstraints del plugin C++).
    final captureOptions = ScreenShareCaptureOptions(
      sourceId: source.id,
      captureScreenAudio: withAudio,
      maxFrameRate: fps.toDouble(),
      params: _shareParamsFor(fps),
    );
    if (withAudio) {
      // ALTA FIDELIDAD: setScreenShareEnabled(captureScreenAudio:true) publica
      // el audio del sistema con AudioPublishOptions por defecto (48kbps mono,
      // dtx/red ON) → "se oye lejano". livekit 2.8.0 no deja pasar opciones de
      // publicación del audio del screenshare ni por parámetro ni post-publish
      // sin re-publicar, así que se publican AMBOS tracks a mano:
      // createScreenShareTracksWithAudio captura video+audio en UNA sola
      // getDisplayMedia (en loopback no se pueden separar) usando el MISMO
      // captureOptions (fix de crash preservado), y aquí se publica el audio
      // con _sharePublishOptions (128kbps estéreo, dtx/red OFF).
      final tracks =
          await LocalVideoTrack.createScreenShareTracksWithAudio(captureOptions);
      for (final t in tracks) {
        if (t is LocalVideoTrack) {
          await lp.publishVideoTrack(t,
              publishOptions: const VideoPublishOptions(simulcast: false));
        } else if (t is LocalAudioTrack) {
          await lp.publishAudioTrack(t, publishOptions: _sharePublishOptions);
        }
      }
    } else {
      // sin audio: ruta probada de siempre (un solo track de video).
      await lp.setScreenShareEnabled(
        true,
        captureScreenAudio: false,
        screenShareCaptureOptions: captureOptions,
      );
    }
    sharing = true;
    store.gateway.send('VOICE_STATE', {'streaming': true});
    notifyListeners();
  }

  Future<void> stopShare() async {
    // setScreenShareEnabled(false) quita el track de video Y busca/quita el de
    // screenShareAudio por source, así que esto cierra también el audio que
    // publicamos a mano en startShare (mismo source = screenShareAudio).
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

  // ───────── ambiente de sala (cama compartida, sin WebRTC) ─────────

  /// Aplica al reproductor local el ambiente del canal en el que estoy. Lo llama
  /// el store cuando llega un AMBIENCE_STATE de mi canal, y join/leave/deafen.
  void _onAmbienceChange(String chId, m.AmbienceState? state) {
    if (chId != channelId) return; // solo me importa mi canal actual
    AmbienceService.instance.apply(state, active: !deafened);
  }

  void _applyCurrentAmbience() {
    final cid = channelId;
    if (cid == null) {
      AmbienceService.instance.stop();
      return;
    }
    AmbienceService.instance.apply(store.ambienceIn(cid), active: !deafened);
  }

  /// Activa/cambia el ambiente de la sala (lo oye TODO el canal). Requiere estar
  /// en el canal; el server valida permiso (CONTROL_AMBIENCE).
  Future<void> setAmbience(String ambienceId, {bool loop = true}) async {
    final cid = channelId;
    if (cid == null) return;
    store.gateway.send('AMBIENCE_SET',
        {'channel_id': cid, 'ambience_id': ambienceId, 'loop': loop});
  }

  /// Activa/desactiva el loop del ambiente actual para toda la sala.
  Future<void> setAmbienceLoop(bool loop) async {
    final cid = channelId;
    if (cid == null) return;
    store.gateway.send('AMBIENCE_LOOP', {'channel_id': cid, 'loop': loop});
  }

  /// Apaga el ambiente de la sala para todos.
  Future<void> stopAmbience() async {
    final cid = channelId;
    if (cid == null) return;
    store.gateway.send('AMBIENCE_STOP', {'channel_id': cid});
  }

  /// Pausa/reanuda el ambiente para todos (sincronizado).
  Future<void> toggleAmbiencePause() async {
    final cid = channelId;
    if (cid == null) return;
    final st = store.ambienceIn(cid);
    if (st == null) return;
    store.gateway.send('AMBIENCE_PAUSE', {'channel_id': cid, 'paused': !st.paused});
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

  /// Screenshares REMOTOS visibles, con quién comparte (para fullscreen y para
  /// el slider de volumen del screenshare). Filtra por source para distinguir
  /// el screenshare de una cámara.
  List<ScreenShare> get screenShares {
    final r = room;
    if (r == null) return [];
    final out = <ScreenShare>[];
    for (final p in r.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        final t = pub.track;
        if (t != null &&
            pub.subscribed &&
            pub.source == TrackSource.screenShareVideo) {
          out.add(ScreenShare(
              track: t, identity: p.identity, name: p.name.isEmpty ? null : p.name));
        }
      }
    }
    return out;
  }

  @override
  void dispose() {
    leave();
    _fxPushTimer?.cancel();
    VoiceFxEngine.instance.removeListener(_onVoiceFxChanged);
    _player.dispose();
    super.dispose();
  }
}
