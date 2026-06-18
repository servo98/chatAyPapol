import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../config.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../updater.dart';
import '../voice.dart';
import 'bootstrap_runner.dart';
import 'chat.dart';
import 'members.dart';
import 'sidebar.dart';
import 'totp.dart';
import 'voice_panel.dart';
import 'widgets.dart';

class Shell extends StatefulWidget {
  final AppStore store;
  final VoiceManager voice;
  const Shell({super.key, required this.store, required this.voice});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool showMembers = true;
  UpdateInfo? update;
  bool updateDismissed = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _lastChId; // para cerrar el Drawer al cambiar de canal en móvil

  @override
  void initState() {
    super.initState();
    _checkUpdates();
    // recién registrado: muestra el QR de 2FA para enrolar la cuenta
    final totp = widget.store.pendingTotp;
    if (totp != null) {
      widget.store.pendingTotp = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showTotpEnroll(context, widget.store,
              uri: totp['uri'], secret: totp['secret']);
        }
      });
    }
  }

  Future<void> _checkUpdates() async {
    if (!isDesktop) return; // el auto-updater es solo de escritorio
    update = await Updater.check(widget.store.api);
    if (mounted) setState(() {});
    // re-chequea cada 6 horas
    Future.delayed(const Duration(hours: 6), () {
      if (mounted) _checkUpdates();
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final ch = store.selectedChannel;
    // Ventana estrecha / móvil → navegación por Drawer; ancho → 3 columnas.
    final phone = MediaQuery.sizeOf(context).width < 600;
    return phone ? _mobileLayout(store, ch) : _desktopLayout(store, ch);
  }

  // ─────────────────────── escritorio: 3 columnas ───────────────────────
  Widget _desktopLayout(AppStore store, Channel? ch) {
    return Scaffold(
      body: Column(
        children: [
          if (update != null && !updateDismissed) _updateBanner(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Sidebar(store: store, voice: widget.voice),
                Expanded(
                  child: ch?.isVoice == true
                      ? VoicePanel(
                          store: store, voice: widget.voice, channel: ch!)
                      : Stack(children: [
                          PapolCanvas(child: ChatView(store: store)),
                          Positioned(
                            right: 8, top: 8,
                            child: SmallIconBtn(
                              showMembers
                                  ? LucideIcons.panelRightClose
                                  : LucideIcons.users,
                              'Miembros',
                              () => setState(() => showMembers = !showMembers),
                              color: showMembers ? Pal.accent : null,
                            ),
                          ),
                        ]),
                ),
                if (showMembers && ch?.isVoice != true)
                  MemberList(store: store),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── móvil: Drawer nav ─────────────────────────
  Widget _mobileLayout(AppStore store, Channel? ch) {
    final isVoice = ch?.isVoice == true;
    // Elegir un canal en el Drawer notifica al store y reconstruye: cerramos
    // el Drawer para mostrar el canal a pantalla completa.
    if (_lastChId != ch?.id) {
      _lastChId = ch?.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scaffoldKey.currentState?.closeDrawer();
      });
    }
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        titleSpacing: 4,
        title: Row(children: [
          Icon(isVoice ? LucideIcons.volume2 : LucideIcons.hash,
              size: 17, color: Pal.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(ch?.name ?? 'ChatPapol',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ]),
        actions: [
          if (ch != null && !isVoice)
            IconButton(
              icon: const Icon(LucideIcons.users, size: 20),
              tooltip: 'Miembros',
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
        ],
      ),
      drawer: Drawer(
        width: 300,
        backgroundColor: Pal.bg1,
        child: SafeArea(
          child:
              Sidebar(store: store, voice: widget.voice, width: double.infinity),
        ),
      ),
      endDrawer: Drawer(
        width: 280,
        backgroundColor: Pal.bg1,
        child:
            SafeArea(child: MemberList(store: store, width: double.infinity)),
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: ch == null
                ? _mobileEmpty()
                : isVoice
                    ? VoicePanel(store: store, voice: widget.voice, channel: ch)
                    : PapolCanvas(child: ChatView(store: store)),
          ),
          if (widget.voice.connected && !isVoice) _miniVoiceBar(store),
        ]),
      ),
    );
  }

  Widget _mobileEmpty() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(LucideIcons.hash, size: 44, color: Pal.faint),
        const SizedBox(height: 12),
        Text('Elige un canal',
            style: TextStyle(
                color: Pal.muted, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Desliza desde el borde o toca ☰',
            style: TextStyle(color: Pal.faint, fontSize: 12)),
      ]),
    );
  }

  /// Barra compacta cuando sigues conectado a voz pero estás viendo un canal de
  /// texto: tap para volver al canal de voz; mute/ensordecer/colgar rápidos.
  Widget _miniVoiceBar(AppStore store) {
    final voice = widget.voice;
    final vch = store.channels[voice.channelId];
    return Material(
      color: Pal.bg2,
      child: InkWell(
        onTap: () {
          final id = voice.channelId;
          if (id != null) store.selectChannel(id);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(children: [
            Icon(LucideIcons.volume2, size: 16, color: Pal.green),
            const SizedBox(width: 8),
            Expanded(
              child: Text(vch?.name ?? 'En voz',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Pal.green)),
            ),
            _miniBtn(voice.muted ? LucideIcons.micOff : LucideIcons.mic,
                voice.muted ? Pal.red : Pal.muted, () => voice.toggleMute()),
            _miniBtn(
                voice.deafened ? LucideIcons.volumeX : LucideIcons.headphones,
                voice.deafened ? Pal.red : Pal.muted,
                () => voice.toggleDeafen()),
            _miniBtn(LucideIcons.phoneOff, Pal.red, () => voice.leave()),
          ]),
        ),
      ),
    );
  }

  Widget _miniBtn(IconData icon, Color color, VoidCallback onTap) {
    return IconButton(
      icon: Icon(icon, size: 19, color: color),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      splashRadius: 20,
    );
  }

  Widget _updateBanner() {
    return Material(
      color: Pal.accentDim,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          Icon(LucideIcons.download, size: 16, color: Pal.greenInk),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                '❯ ChatPapol v${update!.version} disponible '
                '${update!.notes.isNotEmpty ? '— ${update!.notes}' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Pal.greenInk)),
          ),
          TextButton(
            onPressed: () => startUpdate(context, widget.store.api, update!),
            child: Text('actualizar ahora',
                style: TextStyle(
                    color: Pal.greenInk, fontWeight: FontWeight.w700,
                    fontSize: 13)),
          ),
          SmallIconBtn(LucideIcons.x, 'Luego',
              () => setState(() => updateDismissed = true),
              color: Pal.greenInk, size: 16),
        ]),
      ),
    );
  }
}
