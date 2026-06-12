import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sfx.dart';
import '../store.dart';
import '../theme.dart';
import 'widgets.dart';

/// Carpeta del pack de sonidos comprado en la máquina del dueño. Editable en la
/// UI y persistida; este es solo el valor por defecto la primera vez.
const kDefaultPackRoot =
    'C:\\Users\\ferna\\Documents\\code\\chatpapol\\client\\lib\\sounds';

const _packRootKey = 'sfx_pack_root';

/// Etiqueta humana en español de cada acción.
const Map<UiSound, String> _labels = {
  UiSound.messageReceived: 'mensaje recibido',
  UiSound.mention: 'me mencionan',
  UiSound.voiceUserJoin: 'alguien entra a voz',
  UiSound.voiceUserLeave: 'alguien sale de voz',
  UiSound.selfMute: 'silenciar mi micro',
  UiSound.selfUnmute: 'reactivar mi micro',
  UiSound.selfDeafen: 'ensordecerme',
  UiSound.selfUndeafen: 'des-ensordecerme',
  UiSound.connected: 'conectado',
  UiSound.disconnected: 'desconectado',
  UiSound.error: 'error / algo salió mal',
  UiSound.success: 'acción satisfactoria',
  UiSound.modalOpen: 'abrir modal',
  UiSound.modalClose: 'cerrar modal',
  UiSound.confirm: 'confirmación aceptada',
};

class SoundLabPanel extends StatefulWidget {
  final AppStore store;
  const SoundLabPanel(this.store, {super.key});
  @override
  State<SoundLabPanel> createState() => _SoundLabPanelState();
}

class _SoundLabPanelState extends State<SoundLabPanel> {
  final _rootCtrl = TextEditingController(text: kDefaultPackRoot);
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadRoot();
  }

  @override
  void dispose() {
    _rootCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRoot() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_packRootKey);
    if (saved != null && saved.isNotEmpty) _rootCtrl.text = saved;
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _saveRoot(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_packRootKey, v.trim());
  }

  String get _root => _rootCtrl.text.trim();

  static const _label = TextStyle(
      fontSize: 11, color: Pal.faint, fontWeight: FontWeight.w700,
      letterSpacing: 1.3);

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _title('laboratorio de sonidos'),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _exportManifest,
          icon: const Icon(LucideIcons.fileJson2, size: 16),
          label: const Text('Exportar manifest', style: TextStyle(fontSize: 12.5)),
        ),
      ]),
      const Text(
          'Asigna sonidos del pack a cada acción. Solo se prueban localmente; '
          'el manifest se hornea en el build final.',
          style: TextStyle(color: Pal.faint, fontSize: 12)),
      const SizedBox(height: 14),
      const Text('CARPETA DEL PACK', style: _label),
      const SizedBox(height: 6),
      TextField(
        controller: _rootCtrl,
        style: const TextStyle(fontSize: 12.5, fontFamily: Pal.fontMono, fontFamilyFallback: Pal.monoFallback),
        decoration: const InputDecoration(
            hintText: 'ruta absoluta a la carpeta de .wav'),
        onChanged: _saveRoot,
        onSubmitted: (v) {
          _saveRoot(v);
          setState(() {});
        },
      ),
      const SizedBox(height: 16),
      const Text('ACCIONES', style: _label),
      const SizedBox(height: 6),
      Expanded(
        child: ListView(
          children: UiSound.values.map(_actionRow).toList(),
        ),
      ),
    ]);
  }

  Widget _actionRow(UiSound s) {
    final path = SfxService.instance.pathFor(s);
    final base = path == null ? '—' : path.split(RegExp(r'[\\/]')).last;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
          color: Pal.bg0, borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_labels[s] ?? s.name,
                style: const TextStyle(fontSize: 13.5, color: Pal.text)),
            Text(s.name,
                style: const TextStyle(fontSize: 10.5, color: Pal.faint)),
          ]),
        ),
        Expanded(
          flex: 3,
          child: Text(base,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: Pal.fontMono, fontFamilyFallback: Pal.monoFallback,
                  color: path == null ? Pal.faint : Pal.accent)),
        ),
        SmallIconBtn(LucideIcons.play, 'Reproducir',
            path == null ? () {} : () => SfxService.instance.preview(path),
            color: path == null ? Pal.faint : Pal.accent),
        SmallIconBtn(LucideIcons.folderOpen, 'Asignar', () => _pickFor(s)),
        SmallIconBtn(LucideIcons.x, 'Quitar', () async {
          await SfxService.instance.clear(s);
          if (mounted) setState(() {});
        }, color: Pal.red),
      ]),
    );
  }

  Future<void> _pickFor(UiSound s) async {
    final dir = Directory(_root);
    if (!dir.existsSync()) {
      showError(context, 'La carpeta del pack no existe: $_root');
      return;
    }
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => _PackBrowser(root: _root),
    );
    if (chosen != null) {
      await SfxService.instance.assign(s, chosen);
      if (mounted) setState(() {});
    }
  }

  Future<void> _exportManifest() async {
    final json = await SfxService.instance.exportManifestJson();
    String? writtenTo;
    String? writeErr;
    try {
      // <packRoot>/../sfx_manifest.json
      final parent = Directory(_root).parent.path;
      final out = File('$parent${Platform.pathSeparator}sfx_manifest.json');
      out.writeAsStringSync(json);
      writtenTo = out.path;
    } catch (e) {
      writeErr = e.toString();
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('manifest de sonidos', style: TextStyle(fontSize: 17)),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (writtenTo != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Escrito en:\n$writtenTo',
                    style: const TextStyle(fontSize: 11.5, color: Pal.green, fontFamily: Pal.fontMono, fontFamilyFallback: Pal.monoFallback)),
              ),
            if (writeErr != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('No se pudo escribir a disco: $writeErr',
                    style: const TextStyle(fontSize: 11.5, color: Pal.red)),
              ),
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Pal.inset, borderRadius: BorderRadius.circular(6)),
              child: SingleChildScrollView(
                child: SelectableText(json,
                    style: const TextStyle(fontSize: 11.5, fontFamily: Pal.fontMono, fontFamilyFallback: Pal.monoFallback, color: Pal.text)),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
            },
            child: const Text('Copiar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}

/// Navegador del árbol del pack: lista subcarpetas y .wav bajo [root].
/// Al tocar un .wav lo previsualiza; "usar este" lo devuelve por el Navigator.
class _PackBrowser extends StatefulWidget {
  final String root;
  const _PackBrowser({required this.root});
  @override
  State<_PackBrowser> createState() => _PackBrowserState();
}

class _PackBrowserState extends State<_PackBrowser> {
  late String _cwd;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _cwd = widget.root;
  }

  List<Directory> get _subdirs {
    try {
      return Directory(_cwd)
          .listSync()
          .whereType<Directory>()
          .toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    } catch (_) {
      return const [];
    }
  }

  List<File> get _wavs {
    try {
      return Directory(_cwd)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.wav'))
          .toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    } catch (_) {
      return const [];
    }
  }

  bool get _atRoot =>
      _cwd == widget.root ||
      Directory(_cwd).path == Directory(widget.root).path;

  String _name(String p) => p.split(RegExp(r'[\\/]')).last;

  @override
  Widget build(BuildContext context) {
    final subdirs = _subdirs;
    final wavs = _wavs;
    return AlertDialog(
      title: Row(children: [
        if (!_atRoot)
          SmallIconBtn(LucideIcons.arrowLeft, 'Atrás', () {
            setState(() {
              _cwd = Directory(_cwd).parent.path;
              _selected = null;
            });
          }),
        Expanded(
          child: Text(_name(_cwd),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontFamily: Pal.fontMono, fontFamilyFallback: Pal.monoFallback)),
        ),
      ]),
      content: SizedBox(
        width: 460,
        height: 420,
        child: ListView(children: [
          ...subdirs.map((d) => ListTile(
                dense: true,
                leading: const Icon(LucideIcons.folder, size: 18, color: Pal.accent),
                title: Text(_name(d.path), style: const TextStyle(fontSize: 13)),
                onTap: () => setState(() {
                  _cwd = d.path;
                  _selected = null;
                }),
              )),
          ...wavs.map((f) {
            final sel = _selected == f.path;
            return ListTile(
              dense: true,
              selected: sel,
              selectedTileColor: Pal.bg3,
              leading: Icon(LucideIcons.music2, size: 18,
                  color: sel ? Pal.accent : Pal.muted),
              title: Text(_name(f.path), style: const TextStyle(fontSize: 13)),
              trailing: SmallIconBtn(LucideIcons.play, 'Escuchar',
                  () => SfxService.instance.preview(f.path), color: Pal.accent),
              onTap: () {
                setState(() => _selected = f.path);
                SfxService.instance.preview(f.path);
              },
            );
          }),
          if (subdirs.isEmpty && wavs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('(carpeta vacía)',
                  style: TextStyle(color: Pal.faint, fontSize: 12)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(context, _selected),
          child: const Text('Usar este'),
        ),
      ],
    );
  }
}

Widget _title(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    );
