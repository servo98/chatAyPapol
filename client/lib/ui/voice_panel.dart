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
          child: Text('❯ nadie por aquí todavía — únete',
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
    final tile = Container(
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
            if (voice.userVolume(v.userId) != 1.0)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                    voice.userVolume(v.userId) == 0
                        ? Icons.volume_off
                        : Icons.volume_down,
                    size: 12,
                    color: Pal.muted),
              ),
          ]),
        ),
      ]),
    );
    if (v.userId == store.me?.id) return tile; // tu propio volumen no aplica
    // click derecho (o mantener presionado): volumen individual, como Discord
    return Builder(
      builder: (ctx) => GestureDetector(
        onSecondaryTap: () => _showUserVolume(ctx, v.userId, user?.username),
        onLongPress: () => _showUserVolume(ctx, v.userId, user?.username),
        child: tile,
      ),
    );
  }

  void _showUserVolume(BuildContext context, String userId, String? name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Volumen de ${name ?? 'usuario'}',
            style: const TextStyle(fontSize: 16)),
        content: StatefulBuilder(
          builder: (ctx, setSt) {
            final v = voice.userVolume(userId);
            return Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(v == 0 ? Icons.volume_off : Icons.volume_up,
                  size: 18, color: Pal.muted),
              SizedBox(
                width: 260,
                child: Slider(
                  value: v,
                  max: 2.0,
                  divisions: 40,
                  activeColor: Pal.accent,
                  label: '${(v * 100).round()}%',
                  onChanged: (nv) {
                    voice.setUserVolume(userId, nv);
                    setSt(() {});
                  },
                ),
              ),
              SizedBox(
                  width: 44,
                  child: Text('${(v * 100).round()}%',
                      style: const TextStyle(fontSize: 12, color: Pal.muted))),
            ]);
          },
        ),
        actions: [
          TextButton(
              onPressed: () {
                voice.setUserVolume(userId, 1.0);
                Navigator.pop(ctx);
              },
              child: const Text('Restablecer')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Listo')),
        ],
      ),
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
      rtc.DesktopCapturerSource? selected;
      var fps = 60;
      var withAudio = true; // loopback nuevo: compartir CON audio por default
      final screens =
          sources.where((s) => s.type == rtc.SourceType.Screen).toList();
      final windows =
          sources.where((s) => s.type == rtc.SourceType.Window).toList();
      // las miniaturas llegan DESPUÉS de getSources (eventos async del
      // plugin): redibuja el diálogo cuando aterricen, no al primer click
      StateSetter? refresh;
      final thumbSub = rtc.desktopCapturer.onThumbnailChanged.stream
          .listen((_) => refresh?.call(() {}));
      showDialog(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSt) {
            refresh = setSt;
            return _shareDialog(context, ctx, setSt, screens, windows,
                () => selected, (s) => selected = s, () => fps, (v) => fps = v,
                () => withAudio, (v) => withAudio = v);
          },
        ),
      ).whenComplete(() {
        refresh = null;
        thumbSub.cancel();
      });
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Widget _shareDialog(
      BuildContext outerContext,
      BuildContext ctx,
      StateSetter setSt,
      List<rtc.DesktopCapturerSource> screens,
      List<rtc.DesktopCapturerSource> windows,
      rtc.DesktopCapturerSource? Function() getSel,
      void Function(rtc.DesktopCapturerSource?) setSel,
      int Function() getFps,
      void Function(int) setFps,
      bool Function() getAudio,
      void Function(bool) setAudio) {
    final selected = getSel();
    final fps = getFps();
    final withAudio = getAudio();
    return AlertDialog(
            title: const Text('¿Qué quieres compartir?',
                style: TextStyle(fontSize: 17)),
            content: SizedBox(
              width: 560,
              height: 460,
              child: Column(children: [
                Expanded(
                  child: ListView(children: [
                    if (screens.isNotEmpty)
                      _sourceSection('Pantallas', screens, selected,
                          (s) => setSt(() => setSel(s))),
                    if (windows.isNotEmpty)
                      _sourceSection('Ventanas', windows, selected,
                          (s) => setSt(() => setSel(s))),
                  ]),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  const Text('Calidad: 1080p a',
                      style: TextStyle(fontSize: 13, color: Pal.muted)),
                  const SizedBox(width: 8),
                  SegmentedButton<int>(
                    style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    segments: const [
                      ButtonSegment(value: 15, label: Text('15 fps')),
                      ButtonSegment(value: 30, label: Text('30 fps')),
                      ButtonSegment(value: 60, label: Text('60 fps')),
                    ],
                    selected: {fps},
                    onSelectionChanged: (v) => setSt(() => setFps(v.first)),
                  ),
                ]),
                // loopback WASAPI (flutter-webrtc main pineado): verificado
                // con --diag-share variant=audio (el track sí se publica)
                CheckboxListTile(
                  dense: true,
                  value: withAudio,
                  activeColor: Pal.accent,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Compartir también el audio del sistema',
                      style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Beta: avísanos si algo suena raro',
                      style: TextStyle(fontSize: 11, color: Pal.faint)),
                  onChanged: (v) => setSt(() => setAudio(v ?? true)),
                ),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancelar')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Pal.accent),
                onPressed: selected == null
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        voice
                            .startShare(selected,
                                withAudio: withAudio, fps: fps)
                            .catchError((e) {
                          if (outerContext.mounted) showError(outerContext, e);
                        });
                      },
                child: const Text('Compartir'),
              ),
            ],
          );
  }

  /// Sección del selector: título + grid de miniaturas (estilo Discord).
  Widget _sourceSection(
      String title,
      List<rtc.DesktopCapturerSource> items,
      rtc.DesktopCapturerSource? selected,
      void Function(rtc.DesktopCapturerSource) onTap) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(title,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Pal.muted,
                letterSpacing: 0.5)),
      ),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 16 / 11,
        children: items.map((s) {
          final sel = selected?.id == s.id;
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onTap(s),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: sel ? Pal.accent : Pal.bg3, width: sel ? 2 : 1),
                color: Pal.bg3,
              ),
              padding: const EdgeInsets.all(4),
              child: Column(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: s.thumbnail != null && s.thumbnail!.isNotEmpty
                        ? Image.memory(s.thumbnail!,
                            fit: BoxFit.contain,
                            width: double.infinity,
                            gaplessPlayback: true)
                        : Center(
                            child: Icon(
                                s.type == rtc.SourceType.Screen
                                    ? Icons.monitor
                                    : Icons.window,
                                color: Pal.muted,
                                size: 36)),
                  ),
                ),
                const SizedBox(height: 4),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      s.type == rtc.SourceType.Screen
                          ? Icons.monitor
                          : Icons.window,
                      size: 13,
                      color: sel ? Pal.accent : Pal.muted),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                  ),
                ]),
              ]),
            ),
          );
        }).toList(),
      ),
      const SizedBox(height: 8),
    ]);
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
                            Text(s.emoji ?? '♪',
                                style: const TextStyle(
                                    fontSize: 22, color: Pal.accent)),
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
