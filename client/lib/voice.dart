import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'models.dart' as m;
import 'store.dart';

/// Voz, screenshare y soundboard. LiveKit hace el trabajo duro (SFU);
/// el soundboard NO usa WebRTC: cada cliente reproduce el archivo localmente.
class VoiceManager extends ChangeNotifier {
  final AppStore store;
  VoiceManager(this.store) {
    store.onSoundPlay = _playSound;
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

  bool get connected => room != null && channelId != null;

  Future<void> join(String chId) async {
    if (channelId == chId) return;
    await leave();
    connecting = true;
    notifyListeners();
    try {
      final t = await store.api.post('/api/channels/$chId/voice-token');
      final r = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
            captureScreenAudio: true,
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
        ..on<TrackSubscribedEvent>((_) => notifyListeners())
        ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
        ..on<ParticipantConnectedEvent>((_) => notifyListeners())
        ..on<ParticipantDisconnectedEvent>((_) => notifyListeners());
      try {
        await r.localParticipant?.setMicrophoneEnabled(!muted);
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
    speaking.clear();
    notifyListeners();
  }

  Future<void> toggleMute() async {
    muted = !muted;
    try {
      await room?.localParticipant?.setMicrophoneEnabled(!muted);
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

  Future<void> startShare(rtc.DesktopCapturerSource source) async {
    await room?.localParticipant?.setScreenShareEnabled(
      true,
      screenShareCaptureOptions: ScreenShareCaptureOptions(
        sourceId: source.id,
        captureScreenAudio: true,
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
