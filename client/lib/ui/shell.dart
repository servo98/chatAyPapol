import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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
