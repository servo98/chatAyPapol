import 'package:flutter/material.dart';
import '../models.dart';
import '../perms.dart';
import '../store.dart';
import '../theme.dart';
import '../voice.dart';
import 'channel_perms.dart';
import 'settings.dart';
import 'widgets.dart';

class Sidebar extends StatefulWidget {
  final AppStore store;
  final VoiceManager voice;
  const Sidebar({super.key, required this.store, required this.voice});
  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final collapsed = <String>{};

  AppStore get store => widget.store;
  VoiceManager get voice => widget.voice;

  @override
  Widget build(BuildContext context) {
    final byCat = <String?, List<Channel>>{};
    for (final c in store.visibleChannels) {
      (byCat[c.categoryId] ??= []).add(c);
    }
    return Container(
      width: 248,
      color: Pal.bg1,
      child: Column(
        children: [
          _header(context),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 12),
              children: [
                ...?byCat[null]?.map(_channelTile),
                for (final cat in store.categories) ...[
                  if (byCat.containsKey(cat.id) || store.canI(P.manageChannels))
                    _categoryTile(cat),
                  if (!collapsed.contains(cat.id))
                    ...?byCat[cat.id]?.map(_channelTile),
                ],
              ],
            ),
          ),
          if (voice.connected) _voicePanel(),
          _userBar(context),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      offset: const Offset(0, 48),
      onSelected: (v) async {
        switch (v) {
          case 'invite':
            try {
              final r = await store.api.post('/api/invites', {'max_uses': 0});
              if (!context.mounted) return;
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Invitación creada', style: TextStyle(fontSize: 17)),
                  content: SelectableText(r['code'],
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w700, color: Pal.accent)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Listo'))
                  ],
                ),
              );
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          case 'category':
            final name = await promptText(context, 'Nueva categoría', hint: 'Gaming');
            if (name != null && name.isNotEmpty) {
              store.api.post('/api/categories', {'name': name});
            }
          case 'text':
          case 'voice':
            final name = await promptText(context, 'Nuevo canal de ${v == 'text' ? 'texto' : 'voz'}',
                hint: v == 'text' ? 'memes' : 'Sala de juegos');
            if (name != null && name.isNotEmpty) {
              store.api.post('/api/channels', {'name': name, 'type': v});
            }
          case 'settings':
            if (context.mounted) openSettings(context, store, voice);
        }
      },
      itemBuilder: (_) => [
        if (store.canI(P.createInvites))
          const PopupMenuItem(value: 'invite', child: Text('❯  invitar gente')),
        if (store.canI(P.manageChannels)) ...const [
          PopupMenuItem(value: 'text', child: Text('#  crear canal de texto')),
          PopupMenuItem(value: 'voice', child: Text('♪  crear canal de voz')),
          PopupMenuItem(value: 'category', child: Text('▸  crear categoría')),
        ],
        const PopupMenuItem(value: 'settings', child: Text('⚙  ajustes')),
      ],
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .3))),
        ),
        child: Row(
          children: [
            const Text('❯',
                style: TextStyle(
                    color: Pal.accent, fontSize: 18, fontWeight: FontWeight.w700,
                    height: 1)),
            const SizedBox(width: 9),
            const Expanded(
              child: Text.rich(
                TextSpan(
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  children: [
                    TextSpan(text: 'Chat', style: TextStyle(color: Pal.accent)),
                    TextSpan(text: 'Papol', style: TextStyle(color: Pal.text)),
                  ],
                ),
              ),
            ),
            Icon(Icons.expand_more, color: Pal.muted, size: 18),
            if (!store.wsConnected)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.wifi_off, color: Pal.yellow, size: 15),
              ),
          ],
        ),
      ),
    );
  }

  Widget _categoryTile(Category cat) {
    final isCollapsed = collapsed.contains(cat.id);
    return Hoverable(
      builder: (ctx, hover) => InkWell(
        onTap: () => setState(() => isCollapsed ? collapsed.remove(cat.id) : collapsed.add(cat.id)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
          child: Row(
            children: [
              Icon(isCollapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 13, color: Pal.faint),
              const SizedBox(width: 2),
              Expanded(
                child: Text(cat.name.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700,
                        color: Pal.faint, letterSpacing: 1.2)),
              ),
              if (hover && store.canI(P.manageChannels)) ...[
                SmallIconBtn(Icons.add, 'Crear canal aquí', () async {
                  final name = await promptText(ctx, 'Canal en ${cat.name}', hint: 'nombre');
                  if (name == null || name.isEmpty) return;
                  store.api.post('/api/channels',
                      {'name': name, 'type': 'text', 'category_id': cat.id});
                }, size: 14),
                SmallIconBtn(Icons.delete_outline, 'Borrar categoría', () async {
                  if (await confirm(ctx, '¿Borrar "${cat.name}"?',
                      'Los canales quedan sin categoría.')) {
                    store.api.delete('/api/categories/${cat.id}');
                  }
                }, size: 14),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _channelTile(Channel ch) {
    final selected = store.selectedChannelId == ch.id;
    final hasUnread = store.unread.contains(ch.id);
    final voiceUsers = ch.isVoice ? store.voiceUsersIn(ch.id) : const <VoiceState>[];
    return Column(
      children: [
        Hoverable(
          builder: (ctx, hover) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(
              color: selected
                  ? Pal.bg4
                  : hover
                      ? Pal.bg3
                      : null,
              borderRadius: BorderRadius.circular(5),
              // barra de acento verde con glow en el canal activo
              border: selected
                  ? const Border(
                      left: BorderSide(color: Pal.accent, width: 3))
                  : null,
              boxShadow: selected ? Pal.glowGreenSm : null,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () {
                store.selectChannel(ch.id);
                if (ch.isVoice) voice.join(ch.id);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    ch.isVoice
                        ? Icon(Icons.volume_up_rounded,
                            size: 17,
                            color: selected
                                ? Pal.accent
                                : hasUnread ? Pal.text : Pal.faint)
                        : SizedBox(
                            width: 17,
                            child: Text('#',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    height: 1,
                                    color: selected
                                        ? Pal.accent
                                        : hasUnread ? Pal.text : Pal.faint))),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(ch.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
                              color: selected
                                  ? Pal.text
                                  : hasUnread ? Pal.text : Pal.muted)),
                    ),
                    if (hasUnread)
                      Container(
                          width: 8, height: 8,
                          decoration: const BoxDecoration(
                              color: Pal.text, shape: BoxShape.circle)),
                    if (hover && store.canI(P.manageRoles))
                      SmallIconBtn(Icons.settings, 'Permisos del canal',
                          () => openChannelPerms(ctx, store, ch), size: 14),
                    if (hover && store.canI(P.manageChannels))
                      SmallIconBtn(Icons.delete_outline, 'Borrar canal', () async {
                        if (await confirm(ctx, '¿Borrar #${ch.name}?',
                            'Se borran todos sus mensajes. No hay vuelta atrás.')) {
                          store.api.delete('/api/channels/${ch.id}');
                        }
                      }, size: 14),
                  ],
                ),
              ),
            ),
          ),
        ),
        // usuarios conectados al canal de voz
        for (final vs in voiceUsers)
          Padding(
            padding: const EdgeInsets.only(left: 34, right: 12, top: 1, bottom: 1),
            child: Row(
              children: [
                Avatar(store.users[vs.userId], store, size: 20),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(store.users[vs.userId]?.username ?? '…',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          color: voice.speaking.contains(vs.userId)
                              ? Pal.green
                              : Pal.muted)),
                ),
                if (vs.streaming)
                  const Icon(Icons.screen_share, size: 13, color: Pal.green),
                if (vs.mute) const Icon(Icons.mic_off, size: 13, color: Pal.faint),
                if (vs.deaf)
                  const Icon(Icons.headset_off, size: 13, color: Pal.faint),
              ],
            ),
          ),
      ],
    );
  }

  Widget _voicePanel() {
    final ch = store.channels[voice.channelId];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Pal.bg0.withValues(alpha: .6),
        border: Border(top: BorderSide(color: Colors.black.withValues(alpha: .3))),
      ),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq, color: Pal.green, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Voz conectada',
                    style: TextStyle(
                        color: Pal.green, fontSize: 12.5, fontWeight: FontWeight.w700)),
                Text(ch?.name ?? '',
                    style: const TextStyle(color: Pal.muted, fontSize: 11.5),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          SmallIconBtn(Icons.call_end, 'Desconectar', () => voice.leave(),
              color: Pal.red),
        ],
      ),
    );
  }

  Widget _userBar(BuildContext context) {
    final me = store.me;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: Pal.bg0,
      child: Row(
        children: [
          Avatar(me, store, size: 32, showOnline: true),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(me?.username ?? '',
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                Text(store.wsConnected ? 'En línea' : 'Reconectando…',
                    style: TextStyle(
                        fontSize: 11,
                        color: store.wsConnected ? Pal.green : Pal.yellow)),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: voice,
            builder: (_, __) => Row(children: [
              SmallIconBtn(
                voice.muted ? Icons.mic_off : Icons.mic,
                voice.muted ? 'Activar micro' : 'Silenciar',
                () => voice.toggleMute(),
                color: voice.muted ? Pal.red : Pal.muted,
              ),
              SmallIconBtn(
                voice.deafened ? Icons.headset_off : Icons.headset,
                voice.deafened ? 'Activar sonido' : 'Ensordecer',
                () => voice.toggleDeafen(),
                color: voice.deafened ? Pal.red : Pal.muted,
              ),
              SmallIconBtn(Icons.settings, 'Ajustes',
                  () => openSettings(context, store, voice)),
            ]),
          ),
        ],
      ),
    );
  }
}
