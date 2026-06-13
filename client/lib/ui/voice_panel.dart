import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart'
    show
        VideoTrack,
        VideoTrackRenderer,
        VideoViewFit,
        LocalVideoTrack,
        RemoteVideoTrack;
import '../ambience.dart';
import '../audio/voice_fx.dart';
import '../models.dart' as m;
import '../perms.dart';
import '../store.dart';
import '../theme.dart';
import '../voice.dart';
import 'screenshare_fullscreen.dart';
import 'user_audio_popover.dart';
import 'voice_fx_ui.dart';
import 'widgets.dart';

// Tokens del design system que no viven en Pal (color-mix / washes).
const _inset = Color(0xFF070A09); // --surface-inset
Color get _washGreen => Pal.accent.withValues(alpha: 0.10); // sigue el acento
const _washRed = Color(0x1FFF4D4D); // rgba(255,77,77,0.12)

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
      listenable: Listenable.merge([voice, store, VoiceFxEngine.instance]),
      builder: (ctx, _) {
        final users = store.voiceUsersIn(channel.id);
        final videos = joinedHere ? voice.videoTracks : const <VideoTrack>[];
        // screenshares REMOTOS enriquecidos (track + identity + nombre) para
        // poder abrir fullscreen y controlar su volumen
        final shares = joinedHere ? voice.screenShares : const <ScreenShare>[];
        return Container(
          color: Pal.bg2,
          child: Column(
            children: [
              _header(users.length),
              Expanded(
                child: videos.isNotEmpty
                    ? _withScreenshare(context, videos, shares, users)
                    : _tilesOnly(users),
              ),
              _controls(context),
            ],
          ),
        );
      },
    );
  }

  // ----- header (.vhead): barras + nombre + "/ N conectados · baja latencia"
  Widget _header(int connected) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Pal.borderSubtle)),
        ),
        child: Row(children: [
          const _EqBars(height: 12),
          const SizedBox(width: 9),
          Text(channel.name,
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 16, color: Pal.text)),
          const SizedBox(width: 13),
          Container(width: 1, height: 16, color: Pal.borderDefault),
          const SizedBox(width: 13),
          Text.rich(TextSpan(children: [
            const TextSpan(text: '/ '),
            TextSpan(
                text: '$connected',
                style: TextStyle(
                    color: Pal.accent, fontWeight: FontWeight.w700)),
            const TextSpan(text: ' conectados · baja latencia'),
          ]),
              style: TextStyle(fontSize: 13, color: Pal.faint)),
          if (joinedHere) ...[
            const SizedBox(width: 14),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: _statusChips()),
              ),
            ),
          ],
        ]),
      );

  // Chips de estado del header: "hablas como X" (efecto activo) y "ambiente: Y".
  List<Widget> _statusChips() {
    final chips = <Widget>[];
    final fx = activeFxLabel();
    if (fx != null) {
      chips.add(_chip(LucideIcons.sparkles, 'hablas como $fx', Pal.accent,
          () => VoiceFxEngine.instance.setEnabled(false)));
    }
    final amb = store.ambienceIn(channel.id);
    if (amb != null) {
      final name = AmbienceService.instance.def(amb.ambienceId)?.name ?? amb.ambienceId;
      final canControl = store.canI(P.controlAmbience, channel.id);
      chips.add(_chip(LucideIcons.radioTower, 'ambiente: $name', Pal.link,
          canControl ? voice.stopAmbience : null));
    }
    return chips;
  }

  Widget _chip(IconData icon, String label, Color color, VoidCallback? onClose) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: EdgeInsets.fromLTRB(9, 5, onClose != null ? 4 : 9, 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
          if (onClose != null)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onClose,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(LucideIcons.x, size: 12, color: color),
              ),
            ),
        ]),
      );

  // ----- escenario con screenshare: frame grande + tira de participantes
  Widget _withScreenshare(BuildContext context, List<VideoTrack> videos,
      List<ScreenShare> shares, List<m.VoiceState> users) {
    final main = videos.first;
    // si el video principal es un screenshare remoto, tenemos su info para
    // abrir fullscreen y su volumen; si es el share local, share == null.
    ScreenShare? share;
    for (final s in shares) {
      if (s.track == main) {
        share = s;
        break;
      }
    }
    final sharerName = share != null
        ? (share.name ?? store.users[share.identity]?.username ?? 'alguien')
        : (store.me?.username ?? 'tú');

    // doble-clic / botón expandir: solo para screenshare REMOTO (share != null)
    VoidCallback? onFs;
    final sh = share;
    if (sh != null) {
      onFs = () => Navigator.of(context).push(MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => ScreenShareFullscreen(
              track: sh.track,
              identity: sh.identity,
              name: sh.name,
              voice: voice,
            ),
          ));
    }

    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          child: _ShareStage(
            track: main,
            share: share,
            sharerName: sharerName,
            voice: voice,
            onFullscreen: onFs,
          ),
        ),
      ),
      SizedBox(
        height: 96,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          children: users.map((v) => _tile(v, small: true)).toList(),
        ),
      ),
    ]);
  }

  // ----- escenario sin screenshare: grid de tiles centrado
  Widget _tilesOnly(List<m.VoiceState> users) {
    if (users.isEmpty) {
      return Center(
          child: Text('❯ nadie por aquí todavía — únete',
              style: TextStyle(color: Pal.muted)));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(22),
      child: Center(
        child: Wrap(
          spacing: 14,
          runSpacing: 14,
          alignment: WrapAlignment.center,
          children: users.map((v) => _tile(v)).toList(),
        ),
      ),
    );
  }

  // ----- tile de participante (.vtile)
  Widget _tile(m.VoiceState v, {bool small = false}) {
    final user = store.users[v.userId];
    final isSpeaking = voice.speaking.contains(v.userId);
    final isSelf = v.userId == store.me?.id;
    final avatar = small ? 34.0 : 56.0;
    final customVol = !isSelf && voice.userVolume(v.userId) != 1.0;

    final tile = AnimatedContainer(
      duration: Pal.dur,
      curve: Pal.ease,
      width: small ? 150 : 200,
      height: small ? 84 : 125, // 16:10
      margin: small ? const EdgeInsets.only(right: 12) : null,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _inset,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isSpeaking
                ? Pal.green.withValues(alpha: 0.60)
                : Pal.borderDefault),
        boxShadow: isSpeaking
            ? [
                BoxShadow(
                    color: Pal.green.withValues(alpha: 0.35),
                    blurRadius: 12,
                    spreadRadius: -2),
              ]
            : null,
      ),
      child: Stack(children: [
        // mic arriba-derecha (rojo si silenciado)
        Positioned(
          top: 0,
          right: 0,
          child: Icon(v.mute ? LucideIcons.micOff : LucideIcons.mic,
              size: 15, color: v.mute ? Pal.red : Pal.faint),
        ),
        // compartiendo: indicador arriba-izquierda
        if (v.streaming)
          Positioned(
            top: 0,
            left: 0,
            child: Icon(LucideIcons.screenShare, size: 15, color: Pal.green),
          ),
        // avatar + nombre + badge centrados
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: isSpeaking
                      ? [
                          BoxShadow(
                              color: Pal.green.withValues(alpha: 0.28),
                              blurRadius: 0,
                              spreadRadius: 3),
                        ]
                      : null,
                ),
                child: Avatar(user, store, size: avatar),
              ),
              const SizedBox(height: 9),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(
                    user?.username ?? '…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: small ? 12 : 13.5,
                        fontWeight: FontWeight.w700,
                        color: isSpeaking ? Pal.accent : Pal.text),
                  ),
                ),
                if (isSelf)
                  Text(' (tú)',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: Pal.faint)),
                if (customVol)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                        voice.userVolume(v.userId) == 0
                            ? LucideIcons.volumeX
                            : LucideIcons.volume1,
                        size: 13,
                        color: Pal.muted),
                  ),
              ]),
              if (!small && (isSpeaking || v.mute)) ...[
                const SizedBox(height: 5),
                _badge(isSpeaking),
              ],
            ],
          ),
        ),
      ]),
    );
    if (isSelf) return tile; // tu propio volumen no aplica
    // click derecho (o mantener presionado): volumen individual, como Discord
    return Builder(
      builder: (ctx) => GestureDetector(
        onSecondaryTap: () => showUserAudioPopover(ctx, voice, v.userId, user?.username),
        onLongPress: () => showUserAudioPopover(ctx, voice, v.userId, user?.username),
        child: tile,
      ),
    );
  }

  // badge "hablando" (verde + barras) o "silenciado" (rojo)
  Widget _badge(bool speaking) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: Pal.bg0.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: speaking
            ? [
                const _EqBars(height: 9),
                const SizedBox(width: 6),
                Text('hablando',
                    style: TextStyle(fontSize: 11, color: Pal.accent)),
              ]
            : [
                Icon(LucideIcons.micOff, size: 11, color: Pal.red),
                const SizedBox(width: 6),
                Text('silenciado',
                    style: TextStyle(fontSize: 11, color: Pal.red)),
              ]),
      );

  // _showUserVolume eliminado — reemplazado por showUserAudioPopover()
  // (lib/ui/user_audio_popover.dart): volumen + EQ + presets en un popover
  // compacto fiel al diseño voz-ajustes-popover.html del design system.

  // ----- controles (.vcontrols)
  Widget _controls(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
      decoration: BoxDecoration(
        color: Pal.bg0,
        border: Border(top: BorderSide(color: Pal.borderSubtle)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: joinedHere
            ? [
                _vctl(
                  voice.muted ? LucideIcons.micOff : LucideIcons.mic,
                  voice.muted ? 'Activar micro' : 'Silenciar',
                  voice.toggleMute,
                  danger: voice.muted,
                ),
                _vctl(
                  voice.deafened ? LucideIcons.volumeX : LucideIcons.headphones,
                  voice.deafened ? 'Activar sonido' : 'Ensordecer',
                  voice.toggleDeafen,
                  danger: voice.deafened,
                ),
                if (store.canI(P.stream, channel.id))
                  _vctl(
                    voice.sharing
                        ? LucideIcons.screenShareOff
                        : LucideIcons.screenShare,
                    voice.sharing ? 'Dejar de compartir' : 'Compartir pantalla',
                    () => voice.sharing
                        ? voice.stopShare()
                        : _pickShareSource(context),
                    active: voice.sharing,
                  ),
                if (store.canI(P.useSoundboard, channel.id))
                  _vctl(LucideIcons.music, 'Soundboard',
                      () => _soundboard(context)),
                // efectos de voz: transforman MI voz (la sala me oye así)
                _vctl(
                  LucideIcons.sparkles,
                  VoiceFxEngine.instance.enabled
                      ? 'Efectos de voz (activos)'
                      : 'Efectos de voz',
                  () => showVoiceFxPopover(context),
                  active: VoiceFxEngine.instance.enabled,
                ),
                // ambiente de sala: lo oye TODA la sala (no es mi voz)
                _vctl(
                  LucideIcons.radioTower,
                  store.ambienceIn(channel.id) != null
                      ? 'Ambiente de sala (activo)'
                      : 'Ambiente de sala',
                  () => showAmbiencePopover(context, voice, store, channel.id),
                  active: store.ambienceIn(channel.id) != null,
                ),
                const SizedBox(width: 4),
                _hangBtn(voice.leave),
              ]
            : [
                ElevatedButton.icon(
                  onPressed:
                      voice.connecting ? null : () => voice.join(channel.id),
                  icon: voice.connecting
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Pal.greenInk),
                        )
                      : const Icon(LucideIcons.headphones, size: 18),
                  label: Text(
                      voice.connecting ? 'conectando…' : '❯ unirse a la voz'),
                  // Estado "conectando" = deshabilitado: sin estos colores,
                  // Material pinta texto/ícono desvaídos sobre el verde
                  // (ilegible). Lo mantenemos verde con tinta oscura legible.
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Pal.accentDim,
                    foregroundColor: Pal.greenInk,
                    disabledBackgroundColor: Pal.accentDim.withValues(alpha: .65),
                    disabledForegroundColor: Pal.greenInk,
                  ),
                ),
              ],
      ),
    );
  }

  // botón circular de control con estados active(verde)/danger(rojo)
  Widget _vctl(IconData icon, String tip, VoidCallback onTap,
      {bool active = false, bool danger = false}) {
    final Color bg = danger
        ? _washRed
        : active
            ? _washGreen
            : Pal.bg3;
    final Color border = danger
        ? Pal.red.withValues(alpha: 0.45)
        : active
            ? Pal.green.withValues(alpha: 0.45)
            : Pal.borderDefault;
    final Color fg = danger
        ? Pal.red
        : active
            ? Pal.accent
            : Pal.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Tooltip(
        message: tip,
        child: Material(
          color: bg,
          shape: CircleBorder(side: BorderSide(color: border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
                width: 46, height: 46, child: Icon(icon, size: 20, color: fg)),
          ),
        ),
      ),
    );
  }

  // botón pill rojo "salir" (.vhang)
  Widget _hangBtn(VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Material(
          color: const Color(0xFFC42B2B), // --red-600
          borderRadius: BorderRadius.circular(999),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(LucideIcons.phoneOff, size: 18, color: Colors.white),
                SizedBox(width: 8),
                Text('salir',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ]),
            ),
          ),
        ),
      );

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
                  Text('Calidad: 1080p a',
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
                  subtitle: Text('Beta: avísanos si algo suena raro',
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
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(title.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Pal.muted,
                letterSpacing: 1.44)),
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
                    color: sel ? Pal.accent : Pal.borderDefault,
                    width: sel ? 2 : 1),
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
                                    ? LucideIcons.monitor
                                    : LucideIcons.appWindow,
                                color: Pal.muted,
                                size: 36)),
                  ),
                ),
                const SizedBox(height: 4),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      s.type == rtc.SourceType.Screen
                          ? LucideIcons.monitor
                          : LucideIcons.appWindow,
                      size: 14,
                      color: sel ? Pal.accent : Pal.muted),
                  const SizedBox(width: 8),
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
            ? Center(
                child: Text('No hay sonidos.\nSúbelos en Ajustes → Soundboard.',
                    textAlign: TextAlign.center, style: TextStyle(color: Pal.muted)))
            : GridView.count(
                crossAxisCount: 5,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.6,
                children: store.sounds.map((s) => InkWell(
                      onTap: () => voice.triggerSound(s),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        decoration: BoxDecoration(
                            color: Pal.bg3,
                            borderRadius: BorderRadius.circular(8)),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(s.emoji ?? '♪',
                                style: TextStyle(
                                    fontSize: 24, color: Pal.accent)),
                            const SizedBox(height: 4),
                            Text(s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11, color: Pal.muted)),
                          ],
                        ),
                      ),
                    )).toList(),
              ),
      ),
    );
  }

}

/// Frame de pantalla compartida (.share): video + barra de info que aparece
/// SOLO en hover (override del diseño: nada de [EN VIVO]/resolución permanente).
/// La resolución/fps son REALES, sondeadas vía stats de LiveKit mientras el
/// puntero está encima.
class _ShareStage extends StatefulWidget {
  final VideoTrack track;
  final ScreenShare? share;
  final String sharerName;
  final VoiceManager voice;
  final VoidCallback? onFullscreen;
  const _ShareStage({
    required this.track,
    required this.share,
    required this.sharerName,
    required this.voice,
    required this.onFullscreen,
  });

  @override
  State<_ShareStage> createState() => _ShareStageState();
}

class _ShareStageState extends State<_ShareStage>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  String? _stats; // "1920×1080 · 60fps"
  Timer? _poll;
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _poll?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _onEnter() {
    if (_hover) return;
    setState(() => _hover = true);
    _readStats(); // lectura inmediata
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _readStats());
  }

  void _onExit() {
    _poll?.cancel();
    _poll = null;
    if (mounted) setState(() => _hover = false);
  }

  Future<void> _readStats() async {
    final t = widget.track;
    try {
      num w = 0, h = 0, fps = 0;
      if (t is LocalVideoTrack) {
        // varias capas posibles: tomamos la de mayor ancho (la activa)
        for (final s in await t.getSenderStats()) {
          final sw = s.frameWidth ?? 0;
          if (sw > w) {
            w = sw;
            h = s.frameHeight ?? 0;
            fps = s.framesPerSecond ?? 0;
          }
        }
      } else if (t is RemoteVideoTrack) {
        final s = await t.getReceiverStats();
        w = s?.frameWidth ?? 0;
        h = s?.frameHeight ?? 0;
        fps = s?.framesPerSecond ?? 0;
      }
      final next = (w > 0 && h > 0)
          ? '${w.round()}×${h.round()} · ${fps.round()}fps'
          : null;
      if (mounted && next != _stats) setState(() => _stats = next);
    } catch (_) {/* stats best-effort */}
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onEnter(),
      onExit: (_) => _onExit(),
      child: GestureDetector(
        onDoubleTap: widget.onFullscreen,
        child: Container(
          decoration: BoxDecoration(
            color: _inset,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Pal.green.withValues(alpha: 0.42)),
            boxShadow: [
              BoxShadow(
                  color: Pal.green.withValues(alpha: 0.30),
                  blurRadius: 12,
                  spreadRadius: -2),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(children: [
            Positioned.fill(
              child: VideoTrackRenderer(widget.track, fit: VideoViewFit.contain),
            ),
            // barra de info SOLO en hover
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !_hover,
                child: AnimatedOpacity(
                  duration: Pal.durFast,
                  opacity: _hover ? 1.0 : 0.0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 9, 10, 14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.80),
                          Colors.black.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                    child: Row(children: [
                      // [EN VIVO] con punto pulsante
                      FadeTransition(
                        opacity: Tween(begin: 1.0, end: 0.35).animate(_pulse),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Pal.accent,
                            boxShadow: [
                              BoxShadow(
                                  color: Pal.green.withValues(alpha: 0.55),
                                  blurRadius: 8),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('EN VIVO',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.7,
                              color: Pal.accent)),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text('${widget.sharerName} comparte pantalla',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: Pal.text)),
                      ),
                      const Spacer(),
                      if (_stats != null)
                        Text(_stats!,
                            style: TextStyle(
                                fontSize: 12, color: Pal.muted)),
                      if (widget.onFullscreen != null) ...[
                        const SizedBox(width: 10),
                        InkWell(
                          onTap: widget.onFullscreen,
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(LucideIcons.expand,
                                size: 18, color: Pal.text),
                          ),
                        ),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Ecualizador animado (.bars): 4 barras verdes que "respiran".
class _EqBars extends StatefulWidget {
  final double height;
  const _EqBars({this.height = 11});

  @override
  State<_EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<_EqBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000))
    ..repeat();
  static const _base = [0.40, 1.00, 0.60, 0.85]; // alturas relativas
  static const _delay = [0.0, 0.15, 0.30, 0.45]; // desfases

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _c,
        builder: (ctx, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: List.generate(4, (i) {
            final phase = (_c.value - _delay[i]) % 1.0;
            // scaleY entre .5 y 1, como el @keyframes papol-eq
            final scale = 0.75 + 0.25 * math.sin(2 * math.pi * phase);
            return Padding(
              padding: EdgeInsets.only(right: i < 3 ? 2 : 0),
              child: Container(
                width: 2.5,
                height: widget.height * _base[i] * scale,
                decoration: BoxDecoration(
                  color: Pal.accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
