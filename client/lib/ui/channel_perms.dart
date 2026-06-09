import 'package:flutter/material.dart';
import '../models.dart';
import '../perms.dart';
import '../store.dart';
import '../theme.dart';

/// Editor de overwrites por canal, estilo Discord: por cada rol,
/// cada permiso puede estar en ✓ permitir / – heredar / ✗ denegar.
void openChannelPerms(BuildContext context, AppStore store, Channel ch) {
  showDialog(
    context: context,
    builder: (_) => Dialog(
      child: SizedBox(
        width: 560,
        height: 540,
        child: _ChannelPermsEditor(store: store, channel: ch),
      ),
    ),
  );
}

class _ChannelPermsEditor extends StatefulWidget {
  final AppStore store;
  final Channel channel;
  const _ChannelPermsEditor({required this.store, required this.channel});
  @override
  State<_ChannelPermsEditor> createState() => _ChannelPermsEditorState();
}

class _ChannelPermsEditorState extends State<_ChannelPermsEditor> {
  late String selectedRoleId = widget.store.everyoneRoleId;

  AppStore get store => widget.store;

  Overwrite? get currentOw => (store.overwrites[widget.channel.id] ?? [])
      .where((o) => o.targetId == selectedRoleId)
      .firstOrNull;

  // los permisos que tienen sentido por canal
  static const channelPerms = [
    P.viewChannel, P.sendMessages, P.embedLinks, P.attachFiles,
    P.mentionEveryone, P.manageMessages, P.connect, P.speak,
    P.stream, P.useSoundboard,
  ];

  Future<void> _set(int perm, int state) async {
    // state: 1 allow, 0 inherit, -1 deny
    var allow = currentOw?.allow ?? 0;
    var deny = currentOw?.deny ?? 0;
    allow &= ~perm;
    deny &= ~perm;
    if (state == 1) allow |= perm;
    if (state == -1) deny |= perm;
    if (allow == 0 && deny == 0) {
      await store.api
          .delete('/api/channels/${widget.channel.id}/overwrites/$selectedRoleId');
    } else {
      await store.api.put('/api/channels/${widget.channel.id}/overwrites', {
        'target_id': selectedRoleId,
        'target_type': 'role',
        'allow': allow,
        'deny': deny,
      });
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Icon(Icons.lock_outline, color: Pal.accent, size: 20),
            const SizedBox(width: 8),
            Text('Permisos de #${widget.channel.name}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Pal.muted)),
          ]),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // lista de roles
              Container(
                width: 160,
                color: Pal.bg0,
                child: ListView(
                  children: store.sortedRoles.map((r) {
                    final selected = r.id == selectedRoleId;
                    final hasOw = (store.overwrites[widget.channel.id] ?? [])
                        .any((o) => o.targetId == r.id);
                    return InkWell(
                      onTap: () => setState(() => selectedRoleId = r.id),
                      child: Container(
                        color: selected ? Pal.bg3 : null,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Row(children: [
                          Expanded(
                            child: Text(r.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: r.color != null
                                        ? Color(int.parse(
                                            r.color!.replaceFirst('#', '0xff')))
                                        : Pal.text)),
                          ),
                          if (hasOw)
                            const Icon(Icons.circle, size: 6, color: Pal.accent),
                        ]),
                      ),
                    );
                  }).toList(),
                ),
              ),
              // toggles
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: channelPerms.map((perm) {
                    final ow = currentOw;
                    final state = ow == null
                        ? 0
                        : (ow.allow & perm) != 0
                            ? 1
                            : (ow.deny & perm) != 0
                                ? -1
                                : 0;
                    final (label, desc) = permLabels[perm]!;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label, style: const TextStyle(fontSize: 13.5)),
                              if (desc.isNotEmpty)
                                Text(desc,
                                    style: const TextStyle(
                                        fontSize: 11, color: Pal.faint)),
                            ],
                          ),
                        ),
                        _tri(state, perm),
                      ]),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tri(int state, int perm) {
    Widget btn(IconData icon, int s, Color activeColor) {
      final active = state == s;
      return InkWell(
        onTap: () => _set(perm, s),
        child: Container(
          width: 30,
          height: 26,
          decoration: BoxDecoration(
            color: active ? activeColor : Pal.bg0,
            borderRadius: BorderRadius.horizontal(
              left: s == -1 ? const Radius.circular(6) : Radius.zero,
              right: s == 1 ? const Radius.circular(6) : Radius.zero,
            ),
          ),
          child: Icon(icon, size: 15, color: active ? Colors.white : Pal.faint),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      btn(Icons.close, -1, Pal.red),
      btn(Icons.remove, 0, Pal.bg4),
      btn(Icons.check, 1, Pal.green),
    ]);
  }
}
