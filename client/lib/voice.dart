import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart' as m;
import 'store.dart';

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
  bool sharing = false;
  bool connecting = false;
  final speaking = <String>{};
  final _player = AudioPlayer();

  // Opciones de micrófono persistidas (ajustes de "Voz y micrófono").
  String? micDeviceId;
  bool noiseSuppression = true;
  bool echoCancellation = true;
  bool autoGainControl = true;
  // Volumen de SALIDA (playout de tracks remotos). NO hay ganancia de captura:
  // ver setOutputVolume.
  double outputVolume = 1.0;

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
    notifyListeners();
  }

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

  void _applyOutputVolume(Track t) {
    if (t is! RemoteAudioTrack) return;
    try {
      rtc.Helper.setVolume(outputVolume, t.mediaStreamTrack);
    } catch (_) {}
  }

  void _applyOutputVolumeAll() {
    final r = room;
    if (r == null) return;
    for (final p in r.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t != null) _applyOutputVolume(t);
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
          defaultScreenShareCaptureOptions: const ScreenShareCaptureOptions(
            params: VideoParametersPresets.screenShareH1080FPS30,
          ),
        ),
      );
      await r.connect(t['url'], t['token']);
      room = r;
      channelId = chId;
      _listener = r.createListener()
        ..on<ActiveSpeakersChangedEvent>((e) {
          speaking
            ..clear()
            ..addAll(e.speakers.map((p) => p.identity));
          notifyListeners();
        })
        ..on<RoomDisconnectedEvent>((_) => _cleanup())
        ..on<TrackSubscribedEvent>((e) {
          _applyOutputVolume(e.track);
          notifyListeners();
        })
        ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
        ..on<ParticipantConnectedEvent>((_) => notifyListeners())
        ..on<ParticipantDisconnectedEvent>((_) => notifyListeners());
      try {
        await r.localParticipant
            ?.setMicrophoneEnabled(!muted, audioCaptureOptions: micOptions);
      } catch (_) {/* sin permiso SPEAK: solo escucha */}
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

  void _cleanup() {
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
    if (deafened && !muted) await toggleMute();
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

  /// Enumera pantallas/ventanas para que la UI muestre el selector.
  Future<List<rtc.DesktopCapturerSource>> shareSources() =>
      rtc.desktopCapturer.getSources(
          types: [rtc.SourceType.Screen, rtc.SourceType.Window]);

  /// [withAudio] es opt-in: el loopback "Remote App Audio" de Windows es
  /// inestable en el capturador nativo y puede tumbar la app; sin audio el
  /// screenshare es sólido.
  Future<void> startShare(rtc.DesktopCapturerSource source,
      {bool withAudio = false}) async {
    await room?.localParticipant?.setScreenShareEnabled(
      true,
      screenShareCaptureOptions: ScreenShareCaptureOptions(
        sourceId: source.id,
        captureScreenAudio: withAudio,
        params: VideoParametersPresets.screenShareH1080FPS30,
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
