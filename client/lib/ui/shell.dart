import 'package:flutter/material.dart';
import '../store.dart';
import '../theme.dart';
import '../updater.dart';
import '../voice.dart';
import 'chat.dart';
import 'members.dart';
import 'sidebar.dart';
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
                          ChatView(store: store),
                          Positioned(
                            right: 8, top: 8,
                            child: SmallIconBtn(
                              showMembers ? Icons.people : Icons.people_outline,
                              'Miembros',
                              () => setState(() => showMembers = !showMembers),
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
          const Icon(Icons.system_update_alt, size: 16, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                '¡ChatPapol v${update!.version} disponible! '
                '${update!.notes.isNotEmpty ? '— ${update!.notes}' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: Colors.white)),
          ),
          TextButton(
            onPressed: () async {
              try {
                await Updater.apply(widget.store.api, update!);
              } catch (e) {
                if (mounted) showError(context, e);
              }
            },
            child: const Text('Actualizar ahora',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700,
                    fontSize: 12.5)),
          ),
          SmallIconBtn(Icons.close, 'Luego',
              () => setState(() => updateDismissed = true),
              color: Colors.white70, size: 15),
        ]),
      ),
    );
  }
}
