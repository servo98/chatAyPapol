import 'package:flutter/material.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';

// Paleta secundaria aypapol (sin blurple de Discord): verde, cian, magenta,
// ámbar, morado rolcito, teal facturas. Tinta oscura encima para legibilidad.
const avatarColors = [
  Color(0xFF2CE60F), Color(0xFF22D3EE), Color(0xFFFF2E9A),
  Color(0xFFFFB627), Color(0xFFB06CFF), Color(0xFF38E0A6),
];

class Avatar extends StatelessWidget {
  final User? user;
  final AppStore store;
  final double size;
  final bool showOnline;
  const Avatar(this.user, this.store,
      {super.key, this.size = 36, this.showOnline = false});

  @override
  Widget build(BuildContext context) {
    final u = user;
    final color = u == null
        ? Pal.bg4
        : avatarColors[u.id.hashCode.abs() % avatarColors.length];
    Widget circle = u?.avatar != null
        ? CircleAvatar(
            radius: size / 2,
            backgroundColor: Pal.bg4,
            foregroundImage: NetworkImage(store.api.fileUrl(u!.avatar!)))
        : CircleAvatar(
            radius: size / 2,
            backgroundColor: color,
            child: Text(
              (u?.username ?? '?').substring(0, 1).toUpperCase(),
              style: TextStyle(
                  color: Pal.greenInk,
                  fontSize: size * .42,
                  fontWeight: FontWeight.w700),
            ));
    if (!showOnline || u == null) return circle;
    final isOnline = store.online.contains(u.id);
    return Stack(children: [
      circle,
      Positioned(
        right: 0,
        bottom: 0,
        child: Container(
          width: size * .32,
          height: size * .32,
          decoration: BoxDecoration(
            color: isOnline ? Pal.green : Pal.faint,
            shape: BoxShape.circle,
            border: Border.all(color: Pal.bg1, width: 2),
          ),
        ),
      ),
    ]);
  }
}

class Hoverable extends StatefulWidget {
  final Widget Function(BuildContext, bool hover) builder;
  const Hoverable({super.key, required this.builder});
  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: widget.builder(context, hover),
      );
}

class SmallIconBtn extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final Color? color;
  final double size;
  const SmallIconBtn(this.icon, this.tip, this.onTap,
      {super.key, this.color, this.size = 18});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: size, color: color ?? Pal.muted),
          ),
        ),
      );
}

String fmtTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String fmtDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun',
                  'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

bool sameDay(int a, int b) {
  final da = DateTime.fromMillisecondsSinceEpoch(a);
  final db = DateTime.fromMillisecondsSinceEpoch(b);
  return da.year == db.year && da.month == db.month && da.day == db.day;
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(e.toString(), style: const TextStyle(color: Pal.red)),
  ));
}

Future<bool> confirm(BuildContext context, String title, String body) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      content: Text(body, style: const TextStyle(color: Pal.muted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Pal.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Confirmar'),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(BuildContext context, String title,
    {String hint = '', String initial = '', String action = 'Crear'}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: Text(action),
        ),
      ],
    ),
  );
}
