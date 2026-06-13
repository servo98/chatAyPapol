import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../store.dart';
import '../theme.dart';

/// Ajustes de notificaciones: maestro global, no molestar (DND) y el modo por
/// canal (todos / menciones / silenciado), estilo Discord.
class NotificationsPanel extends StatelessWidget {
  final AppStore store;
  const NotificationsPanel(this.store, {super.key});

  static final _label = TextStyle(
      fontSize: 11,
      color: Pal.faint,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.3);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        // Canales de texto, ordenados por posición.
        final channels = store.channels.values.where((c) => !c.isVoice).toList()
          ..sort((a, b) => a.position.compareTo(b.position));
        return ListView(children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('Notificaciones',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeTrackColor: Pal.accent,
            value: store.notificationsEnabled,
            title: const Text('Activar notificaciones',
                style: TextStyle(fontSize: 13.5)),
            subtitle: Text(
                'Muestra un aviso del sistema cuando la ventana no está enfocada.',
                style: TextStyle(fontSize: 11, color: Pal.faint)),
            onChanged: (v) => store.setNotificationsEnabled(v),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeTrackColor: Pal.accent,
            value: store.dnd,
            title: const Text('No molestar', style: TextStyle(fontSize: 13.5)),
            subtitle: Text(
                'Silencia el sonido y los avisos del sistema (sigue marcando lo no leído).',
                style: TextStyle(fontSize: 11, color: Pal.faint)),
            onChanged: (v) => store.setDnd(v),
          ),
          const SizedBox(height: 18),
          Text('NOTIFICACIONES POR CANAL', style: _label),
          const SizedBox(height: 8),
          if (channels.isEmpty)
            Text('No hay canales de texto.',
                style: TextStyle(fontSize: 12.5, color: Pal.faint))
          else
            ...channels.map((c) {
              final mode = store.channelNotifyMode(c.id);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(LucideIcons.hash, size: 15, color: Pal.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(c.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5)),
                  ),
                  _ModeSelector(
                    mode: mode,
                    onChanged: (m) => store.setChannelNotify(c.id, m),
                  ),
                ]),
              );
            }),
        ]);
      },
    );
  }
}

/// Tres botones segmentados: todos / menciones / silenciado.
class _ModeSelector extends StatelessWidget {
  final ChannelNotify mode;
  final ValueChanged<ChannelNotify> onChanged;
  const _ModeSelector({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: Pal.bg0, borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.all(2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _seg(ChannelNotify.all, LucideIcons.bell, 'Todos'),
        _seg(ChannelNotify.mentions, LucideIcons.atSign, 'Solo menciones'),
        _seg(ChannelNotify.muted, LucideIcons.bellOff, 'Silenciado'),
      ]),
    );
  }

  Widget _seg(ChannelNotify m, IconData icon, String tip) {
    final on = mode == m;
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => onChanged(m),
        child: Container(
          decoration: BoxDecoration(
              color: on ? Pal.bg3 : null,
              borderRadius: BorderRadius.circular(5)),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: Icon(icon, size: 15, color: on ? Pal.text : Pal.muted),
        ),
      ),
    );
  }
}
