import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart'
    show VideoTrack, VideoTrackRenderer, VideoViewFit;
import '../models.dart' as m;
import '../perms.dart';
import '../store.dart';
import '../theme.dart';
import '../voice.dart';
import 'widgets.dart';

/// Vista principal cuando el canal seleccionado es de voz:
/// tiles de participantes, screenshare grande y barra de controles.
class VoicePanel extends StatelessWidget {
  final AppStore store;
  final VoiceManager voice;
  final m.Channel channel;
  const VoicePanel(
      {super.key, required this.store, required this.voice, required this.channel});

  bool get joinedHere => voice.channelId == channel.id;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: voice,
      builder: (ctx, _) {
        final users = store.voiceUsersIn(channel.id);
        final videos = joinedHere ? voice.videoTracks : const <VideoTrack>[];
        return Container(
          color: Pal.bg0,
          child: Column(
            children: [
              _header(),
              Expanded(
                child: videos.isNotEmpty
                    ? _withScreenshare(videos, users)
                    : _tilesOnly(users),
              ),
              _controls(context),
            ],
          ),
        );
      },
    );
  }

  Widget _header() => Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          const Icon(Icons.volume_up_rounded, color: Pal.faint, size: 20),
          const SizedBox(width: 6),
          Text(channel.name,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ]),
      );

  Widget _withScreenshare(List<VideoTrack> videos, List<m.VoiceState> users) {
    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: VideoTrackRenderer(videos.first,
                fit: VideoViewFit.contain),
          ),
        ),
      ),
      SizedBox(
        height: 84,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: users.map((v) => _tile(v, small: true)).toList(),
        ),
      ),
      const SizedBox(height: 8),
    ]);
  }

  Widget _tilesOnly(List<m.VoiceState> users) {
    if (users.isEmpty) {
      return const Center(
          child: Text('Nadie por aquí todavía. ¡Únete! 🎙️',
              style: TextStyle(color: Pal.muted)));
    }
    return Center(
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        alignment: WrapAlignment.center,
        children: users.map((v) => _tile(v)).toList(),
      ),
    );
  }

  Widget _tile(m.VoiceState v, {bool small = false}) {
    final user = store.users[v.userId];
    final isSpeaking = voice.speaking.contains(v.userId);
    final size = small ? 64.0 : 160.0;
    return Container(
      width: small ? 110 : 220,
      height: small ? 80 : size,
      margin: small ? const EdgeInsets.only(right: 8) : null,
      decoration: BoxDecoration(
        color: Pal.bg2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isSpeaking ? Pal.green : Colors.transparent, width: 2),
      ),
      child: Stack(children: [
        Center(
            child:
                Avatar(user, store, size: small ? 36 : 64)),
        Positioned(
          left: 8,
          bottom: 6,
          child: Row(children: [
            Text(user?.username ?? '…',
                style: TextStyle(
                    fontSize: small ? 11 : 13, fontWeight: FontWeight.w600)),
            if (v.mute)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.mic_off, size: 12, color: Pal.red),
              ),
            if (v.streaming)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.screen_share, size: 12, color: Pal.green),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _controls(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: joinedHere
            ? [
                _roundBtn(
                  voice.muted ? Icons.mic_off : Icons.mic,
                  voice.muted ? 'Activar micro' : 'Silenciar',
                  voice.toggleMute,
                  active: !voice.muted,
                ),
                _roundBtn(
                  voice.deafened ? Icons.headset_off : Icons.headset,
                  voice.deafened ? 'Activar sonido' : 'Ensordecer',
                  voice.toggleDeafen,
                  active: !voice.deafened,
                ),
                if (store.canI(P.stream, channel.id))
                  _roundBtn(
                    voice.sharing ? Icons.stop_screen_share : Icons.screen_share,
                    voice.sharing ? 'Dejar de compartir' : 'Compartir pantalla',
                    () => voice.sharing ? voice.stopShare() : _pickShareSource(context),
                    active: voice.sharing,
                    activeColor: Pal.green,
                  ),
                if (store.canI(P.useSoundboard, channel.id))
                  _roundBtn(Icons.music_note, 'Soundboard',
                      () => _soundboard(context)),
                _roundBtn(Icons.call_end, 'Desconectar', voice.leave,
                    activeColor: Pal.red, active: true),
              ]
            : [
                ElevatedButton.icon(
                  onPressed: voice.connecting ? null : () => voice.join(channel.id),
                  icon: const Icon(Icons.headset, size: 18),
                  label: Text(voice.connecting ? 'Conectando…' : 'Unirse a la voz'),
                  style: ElevatedButton.styleFrom(backgroundColor: Pal.green,
                      foregroundColor: Colors.black),
                ),
              ],
      ),
    );
  }

  Widget _roundBtn(IconData icon, String tip, VoidCallback onTap,
      {bool active = false, Color activeColor = Pal.accent}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: CircleAvatar(
            radius: 23,
            backgroundColor: active ? activeColor : Pal.bg3,
            child: Icon(icon,
                size: 20, color: active ? Colors.white : Pal.muted),
          ),
        ),
      ),
    );
  }

  Future<void> _pickShareSource(BuildContext context) async {
    try {
      final sources = await voice.shareSources();
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Qué quieres compartir?', style: TextStyle(fontSize: 17)),
          content: SizedBox(
            width: 420,
            height: 320,
            child: ListView(
              children: sources.map((s) => ListTile(
                    leading: Icon(
                        s.type == rtc.SourceType.Screen
                            ? Icons.monitor
                            : Icons.window,
                        color: Pal.accent),
                    title: Text(s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5)),
                    onTap: () {
                      Navigator.pop(ctx);
                      voice.startShare(s).catchError((e) {
                        if (context.mounted) showError(context, e);
                      });
                    },
                  )).toList(),
            ),
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  void _soundboard(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Pal.bg1,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        height: 280,
        child: store.sounds.isEmpty
            ? const Center(
                child: Text('No hay sonidos.\nSúbelos en Ajustes → Soundboard.',
                    textAlign: TextAlign.center, style: TextStyle(color: Pal.muted)))
            : GridView.count(
                crossAxisCount: 5,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.6,
                children: store.sounds.map((s) => InkWell(
                      onTap: () => voice.triggerSound(s),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        decoration: BoxDecoration(
                            color: Pal.bg3,
                            borderRadius: BorderRadius.circular(10)),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(s.emoji ?? '🔊',
                                style: const TextStyle(fontSize: 22)),
                            const SizedBox(height: 4),
                            Text(s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 11.5, color: Pal.muted)),
                          ],
                        ),
                      ),
                    )).toList(),
              ),
      ),
    );
  }
}
