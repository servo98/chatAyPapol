import 'package:flutter/material.dart';
import '../models.dart';
import '../perms.dart';
import '../store.dart';
import '../theme.dart';
import 'widgets.dart';

class MemberList extends StatelessWidget {
  final AppStore store;
  const MemberList({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final all = store.users.values.toList()
      ..sort((a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));
    final onlineUsers = all.where((u) => store.online.contains(u.id)).toList();
    final offline = all.where((u) => !store.online.contains(u.id)).toList();
    return Container(
      width: 224,
      color: Pal.bg1,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        children: [
          _section('EN LÍNEA — ${onlineUsers.length}'),
          ...onlineUsers.map((u) => _memberTile(context, u, true)),
          if (offline.isNotEmpty) _section('DESCONECTADO — ${offline.length}'),
          ...offline.map((u) => _memberTile(context, u, false)),
        ],
      ),
    );
  }

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
        child: Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Pal.faint, letterSpacing: 1.2)),
      );

  Widget _memberTile(BuildContext context, User u, bool isOnline) {
    final role = store.topRole(u.id);
    final color = role?.color != null
        ? Color(int.parse(role!.color!.replaceFirst('#', '0xff')))
        : Pal.muted;
    final canManage = store.canI(P.manageRoles) ||
        store.canI(P.kickMembers) ||
        store.canI(P.banMembers);

    Widget tile = Hoverable(
      builder: (_, hover) => Container(
        decoration: BoxDecoration(
            color: hover ? Pal.bg3 : null,
            borderRadius: BorderRadius.circular(5)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Opacity(
          opacity: isOnline ? 1 : .45,
          child: Row(children: [
            Avatar(u, store, size: 30, showOnline: isOnline),
            const SizedBox(width: 10),
            Expanded(
              child: Text(u.username,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: color)),
            ),
            if (u.isBot)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                    color: Pal.accent, borderRadius: BorderRadius.circular(3)),
                child: Text('BOT',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w800,
                        color: Pal.greenInk)),
              ),
          ]),
        ),
      ),
    );

    if (!canManage || u.id == store.me?.id) return tile;
    return GestureDetector(
      onSecondaryTapDown: (d) => _memberMenu(context, u, d.globalPosition),
      child: tile,
    );
  }

  void _memberMenu(BuildContext context, User u, Offset pos) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        if (store.canI(P.manageRoles))
          const PopupMenuItem(value: 'roles', child: Text('●  gestionar roles')),
        if (store.canI(P.kickMembers))
          const PopupMenuItem(value: 'kick', child: Text('→  expulsar')),
        if (store.canI(P.banMembers))
          PopupMenuItem(value: 'ban',
              child: Text('✕  banear', style: TextStyle(color: Pal.red))),
      ],
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'roles':
        _rolesDialog(context, u);
      case 'kick':
        if (await confirm(context, '¿Expulsar a ${u.username}?',
            'Podrá volver con otra invitación.')) {
          store.api.delete('/api/members/${u.id}');
        }
      case 'ban':
        if (await confirm(context, '¿Banear a ${u.username}?',
            'No podrá volver a entrar.')) {
          store.api.post('/api/bans/${u.id}');
        }
    }
  }

  void _rolesDialog(BuildContext context, User u) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final current = store.memberRoles[u.id] ?? <String>{};
          final assignable = store.sortedRoles.where((r) => !r.isEveryone);
          return AlertDialog(
            title: Text('Roles de ${u.username}', style: const TextStyle(fontSize: 17)),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: assignable.map((r) {
                  final has = current.contains(r.id);
                  return CheckboxListTile(
                    dense: true,
                    value: has,
                    activeColor: Pal.accent,
                    title: Text(r.name,
                        style: TextStyle(
                            fontSize: 14,
                            color: r.color != null
                                ? Color(int.parse(r.color!.replaceFirst('#', '0xff')))
                                : Pal.text)),
                    onChanged: (v) async {
                      final next = {...current};
                      v == true ? next.add(r.id) : next.remove(r.id);
                      await store.api.put('/api/members/${u.id}/roles',
                          {'role_ids': next.toList()});
                      setState(() {});
                    },
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Listo'))
            ],
          );
        },
      ),
    );
  }
}
