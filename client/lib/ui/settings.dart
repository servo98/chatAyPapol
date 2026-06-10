import 'dart:async';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import '../models.dart';
import '../perms.dart';
import '../store.dart';
import '../theme.dart';
import '../updater.dart';
import '../version.dart';
import '../voice.dart';
import 'widgets.dart';

void openSettings(BuildContext context, AppStore store, VoiceManager voice) {
  showDialog(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: SettingsScreen(store: store, voice: voice),
    ),
  );
}

class SettingsScreen extends StatefulWidget {
  final AppStore store;
  final VoiceManager voice;
  const SettingsScreen({super.key, required this.store, required this.voice});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String tab = 'cuenta';
  AppStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final isAdmin = store.canI(P.administrator);
    final tabs = <(String, String, IconData)>[
      ('cuenta', 'Mi cuenta', Icons.person),
      ('voz', 'Voz y micrófono', Icons.mic),
      if (store.canI(P.manageRoles)) ('roles', 'Roles', Icons.theater_comedy),
      if (store.canI(P.createInvites)) ('invites', 'Invitaciones', Icons.mail),
      if (store.canI(P.manageExpressions)) ('stickers', 'Stickers', Icons.emoji_emotions),
      if (store.canI(P.manageExpressions)) ('sounds', 'Soundboard', Icons.music_note),
      if (isAdmin) ('automod', 'AutoMod', Icons.shield),
      if (store.canI(P.manageWebhooks)) ('webhooks', 'Webhooks', Icons.webhook),
      if (isAdmin) ('bots', 'Bots', Icons.smart_toy),
      ('updates', 'Actualizaciones', Icons.system_update_alt),
    ];
    return SizedBox(
      width: 860,
      height: 600,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 200,
            color: Pal.bg0,
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                    children: tabs.map((t) {
                      final selected = tab == t.$1;
                      return InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => setState(() => tab = t.$1),
                        child: Container(
                          decoration: BoxDecoration(
                              color: selected ? Pal.bg3 : null,
                              borderRadius: BorderRadius.circular(6)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          margin: const EdgeInsets.only(bottom: 2),
                          child: Row(children: [
                            Icon(t.$3, size: 16,
                                color: selected ? Pal.text : Pal.muted),
                            const SizedBox(width: 10),
                            Text(t.$2,
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: selected ? Pal.text : Pal.muted)),
                          ]),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    Text('ChatPapol v$appVersion',
                        style: const TextStyle(color: Pal.faint, fontSize: 11)),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () async {
                        Navigator.pop(context);
                        await store.logout();
                      },
                      icon: const Icon(Icons.logout, size: 15, color: Pal.red),
                      label: const Text('Cerrar sesión',
                          style: TextStyle(color: Pal.red, fontSize: 12.5)),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Pal.muted),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: _panel(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel() => switch (tab) {
        'cuenta' => _AccountPanel(store),
        'voz' => _VoicePanel(widget.voice),
        'roles' => _RolesPanel(store),
        'invites' => _InvitesPanel(store),
        'stickers' => _ExpressionsPanel(store, stickers: true),
        'sounds' => _ExpressionsPanel(store, stickers: false),
        'automod' => _AutomodPanel(store),
        'webhooks' => _WebhooksPanel(store),
        'bots' => _BotsPanel(store),
        'updates' => _UpdatesPanel(store),
        _ => const SizedBox.shrink(),
      };
}

Widget _title(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    );

// ───────────────────────── Mi cuenta ─────────────────────────
class _AccountPanel extends StatelessWidget {
  final AppStore store;
  const _AccountPanel(this.store);
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title('Mi cuenta'),
      Row(children: [
        Avatar(store.me, store, size: 72),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(store.me?.username ?? '',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton(
              onPressed: () async {
                final r = await FilePicker.pickFiles(
                    type: FileType.image, withData: true);
                final f = r?.files.firstOrNull;
                if (f?.bytes == null) return;
                try {
                  await store.api.upload('/api/avatar', f!.bytes!, f.name);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: const Text('Cambiar avatar', style: TextStyle(fontSize: 12.5)),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () async {
                final name = await promptText(context, 'Nuevo nombre',
                    initial: store.me?.username ?? '', action: 'Guardar');
                if (name == null || name.isEmpty) return;
                try {
                  await store.api.patch('/api/me', {'username': name});
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: const Text('Cambiar nombre', style: TextStyle(fontSize: 12.5)),
            ),
          ]),
        ]),
      ]),
    ]);
  }
}

// ───────────────────────── Voz y micrófono ─────────────────────────
class _VoicePanel extends StatefulWidget {
  final VoiceManager voice;
  const _VoicePanel(this.voice);
  @override
  State<_VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends State<_VoicePanel> {
  VoiceManager get voice => widget.voice;

  List<lk.MediaDevice> inputs = [];
  StreamSubscription<List<lk.MediaDevice>>? _devSub;

  // Prueba de micro: track local SIN sala (o el publicado si ya hay voz).
  lk.LocalAudioTrack? _testTrack;
  lk.AudioVisualizer? _vis;
  lk.EventsListener<lk.AudioVisualizerEvent>? _visListener;
  bool testing = false;
  double level = 0;
  // Guard de operaciones en vuelo: evita doble click en "Probar micrófono"
  // y cambios de opciones solapados.
  bool _busy = false;
  // Época de la prueba: dispose()/_stopTest la incrementan para CANCELAR
  // continuaciones de awaits en vuelo (p.ej. LocalAudioTrack.create esperando
  // el prompt de permisos); la continuación compara y libera lo que creó.
  int _gen = 0;

  static const _label = TextStyle(
      fontSize: 11, color: Pal.faint, fontWeight: FontWeight.w700);

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _devSub = lk.Hardware.instance.onDeviceChange.stream
        .listen((_) => _loadDevices());
    // si la voz se desconecta probando el track publicado, aborta la prueba
    voice.addListener(_onVoiceChanged);
  }

  @override
  void dispose() {
    _gen++; // cancela cualquier _startTest/_applyMicChange en vuelo
    voice.removeListener(_onVoiceChanged);
    _devSub?.cancel();
    _releaseTest(); // libera track/visualizer al cerrar el panel
    super.dispose();
  }

  void _onVoiceChanged() {
    // Probábamos el track PUBLICADO (sin track standalone) y la Room lo ha
    // disuelto al desconectar: para la prueba, el track ya no existe.
    if (testing && _testTrack == null && voice.micTrack == null) _stopTest();
  }

  Future<void> _loadDevices() async {
    final devs = await lk.Hardware.instance.audioInputs();
    if (mounted) setState(() => inputs = devs);
  }

  /// Crea (si hace falta) el track de prueba y su visualizer. Si la época
  /// cambia durante un await (panel cerrado, prueba detenida), libera todo
  /// lo creado y devuelve false sin tocar el estado.
  Future<bool> _acquireTest(int gen) async {
    // Si ya estamos en voz, medimos el track REAL publicado;
    // si no, creamos uno standalone con las mismas opciones.
    lk.AudioTrack? track = voice.micTrack;
    lk.LocalAudioTrack? created;
    if (track == null) {
      created = await lk.LocalAudioTrack.create(voice.micOptions);
      if (gen != _gen || !mounted) {
        await created.stop();
        await created.dispose();
        return false;
      }
      await created.start();
      track = created;
    }
    final vis = lk.createVisualizer(track,
        options: const lk.AudioVisualizerOptions(barCount: 7));
    final listener = vis.createListener()
      ..on<lk.AudioVisualizerEvent>((e) {
        final bands =
            e.event.whereType<num>().map((v) => v.toDouble()).toList();
        final peak = bands.isEmpty ? 0.0 : bands.reduce(math.max);
        if (mounted) setState(() => level = peak.clamp(0.0, 1.0));
      });
    await vis.start();
    if (gen != _gen || !mounted) {
      await listener.dispose();
      await vis.stop();
      await vis.dispose();
      await created?.stop();
      await created?.dispose();
      return false;
    }
    _testTrack = created;
    _vis = vis;
    _visListener = listener;
    return true;
  }

  Future<void> _startTest() async {
    if (testing || _busy) return;
    _busy = true;
    final gen = ++_gen;
    try {
      final ok = await _acquireTest(gen);
      if (ok && mounted) setState(() => testing = true);
    } catch (e) {
      await _releaseTest();
      if (mounted) {
        setState(() => testing = false);
        showError(context, e);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _stopTest() async {
    _gen++; // cancela arranques/reinicios en vuelo
    testing = false;
    level = 0;
    if (mounted) setState(() {});
    await _releaseTest();
  }

  Future<void> _releaseTest() async {
    final vis = _vis;
    _vis = null;
    _visListener?.dispose();
    _visListener = null;
    final track = _testTrack;
    _testTrack = null;
    try {
      await vis?.stop();
      await vis?.dispose();
      await track?.stop();
      await track?.dispose();
    } catch (_) {}
  }

  /// Aplica un cambio de dispositivo/opciones y, si la prueba está activa,
  /// la reinicia entera:
  /// - el visualizer se libera ANTES del cambio: tras un restartTrack su
  ///   EventChannel queda atado al id del mediaStreamTrack viejo y su stop()
  ///   usaría el id nuevo, fugando el visualizer nativo del track viejo;
  /// - el track standalone NO se puede restartTrack (sin publicar,
  ///   sender == null → TrackCreateException): se recrea con las nuevas
  ///   opciones vía LocalAudioTrack.create.
  Future<void> _applyMicChange(Future<void> Function() change) async {
    if (!testing || _busy) {
      await change();
      return;
    }
    _busy = true;
    final gen = ++_gen;
    try {
      await _releaseTest();
      await change(); // puede hacer restartTrack del track publicado
      if (gen != _gen || !mounted) return;
      final ok = await _acquireTest(gen);
      if (!ok && mounted) {
        setState(() {
          testing = false;
          level = 0;
        });
      }
    } catch (e) {
      await _releaseTest();
      if (mounted) {
        setState(() {
          testing = false;
          level = 0;
        });
        showError(context, e);
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: voice,
      builder: (ctx, _) {
        // si el dispositivo guardado ya no existe, mostramos "Predeterminado"
        final value = inputs.any((d) => d.deviceId == voice.micDeviceId)
            ? voice.micDeviceId
            : null;
        return ListView(children: [
          _title('Voz y micrófono'),
          const Text('DISPOSITIVO DE ENTRADA', style: _label),
          const SizedBox(height: 6),
          DropdownButtonFormField<String?>(
            // FormField solo lee initialValue en su initState: el primer build
            // ocurre con inputs == [] (value → null) y al cargar los
            // dispositivos NO se actualizaría. La key fuerza a recrear el
            // estado cuando cambia el valor efectivo.
            key: ValueKey<String?>(value),
            initialValue: value,
            dropdownColor: Pal.bg0,
            style: const TextStyle(fontSize: 13.5, color: Pal.text),
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('Predeterminado del sistema')),
              ...inputs.map((d) => DropdownMenuItem<String?>(
                    value: d.deviceId,
                    child: Text(d.label.isEmpty ? d.deviceId : d.label,
                        overflow: TextOverflow.ellipsis),
                  )),
            ],
            onChanged: (id) async {
              final dev =
                  inputs.where((d) => d.deviceId == id).firstOrNull;
              await _applyMicChange(() => voice.setMicDevice(dev));
            },
          ),
          const SizedBox(height: 20),
          const Text('PROBAR MICRÓFONO', style: _label),
          const SizedBox(height: 8),
          Row(children: [
            ElevatedButton.icon(
              onPressed: testing ? _stopTest : _startTest,
              icon: Icon(testing ? Icons.stop : Icons.graphic_eq, size: 16),
              label: Text(testing ? 'Detener' : 'Probar micrófono'),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                    color: Pal.bg0, borderRadius: BorderRadius.circular(5)),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: testing ? level : 0,
                  heightFactor: 1,
                  child: Container(
                    decoration: BoxDecoration(
                        color: Pal.green,
                        borderRadius: BorderRadius.circular(5)),
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
              testing
                  ? 'Habla: si la barra verde se mueve, se te escucha.'
                  : voice.connected
                      ? 'Mide el micro que ya está publicado en el canal de voz.'
                      : 'Crea una captura local sin entrar a ningún canal.',
              style: const TextStyle(color: Pal.faint, fontSize: 12)),
          const SizedBox(height: 20),
          const Text('PROCESADO DE VOZ', style: _label),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeTrackColor: Pal.accent,
            value: voice.noiseSuppression,
            title: const Text('Supresión de ruido',
                style: TextStyle(fontSize: 13.5)),
            subtitle: const Text('Filtra ventiladores, teclado y ruido de fondo.',
                style: TextStyle(fontSize: 11, color: Pal.faint)),
            onChanged: (v) =>
                _applyMicChange(() => voice.setNoiseSuppression(v)),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeTrackColor: Pal.accent,
            value: voice.echoCancellation,
            title: const Text('Cancelación de eco',
                style: TextStyle(fontSize: 13.5)),
            subtitle: const Text('Evita que se cuele el audio de tus altavoces.',
                style: TextStyle(fontSize: 11, color: Pal.faint)),
            onChanged: (v) =>
                _applyMicChange(() => voice.setEchoCancellation(v)),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeTrackColor: Pal.accent,
            value: voice.autoGainControl,
            title: const Text('Ganancia automática (AGC)',
                style: TextStyle(fontSize: 13.5)),
            subtitle: const Text('Nivela el volumen de tu voz automáticamente.',
                style: TextStyle(fontSize: 11, color: Pal.faint)),
            onChanged: (v) =>
                _applyMicChange(() => voice.setAutoGainControl(v)),
          ),
          const SizedBox(height: 12),
          const Text('VOLUMEN DE SALIDA', style: _label),
          Row(children: [
            const Icon(Icons.volume_down, size: 18, color: Pal.muted),
            Expanded(
              child: Slider(
                value: voice.outputVolume,
                activeColor: Pal.accent,
                onChanged: (v) => voice.setOutputVolume(v),
              ),
            ),
            const Icon(Icons.volume_up, size: 18, color: Pal.muted),
            SizedBox(
              width: 42,
              child: Text('${(voice.outputVolume * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12.5, color: Pal.muted)),
            ),
          ]),
          const Text(
              'Atenúa lo que oyes de los demás. El volumen de captura del micro '
              'no se puede ajustar por software en escritorio: usa la ganancia '
              'automática o el volumen de micrófono del sistema.',
              style: TextStyle(color: Pal.faint, fontSize: 12)),
        ]);
      },
    );
  }
}

// ───────────────────────── Roles ─────────────────────────
class _RolesPanel extends StatefulWidget {
  final AppStore store;
  const _RolesPanel(this.store);
  @override
  State<_RolesPanel> createState() => _RolesPanelState();
}

class _RolesPanelState extends State<_RolesPanel> {
  String? selectedId;
  AppStore get store => widget.store;

  static const swatches = [
    '#f23f43', '#f2a65a', '#ffc857', '#4ade80', '#5bc8af',
    '#6fa8ff', '#8b7cf7', '#e36fa0', '#95a0b4', null,
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final roles = store.sortedRoles;
        final sel = store.roles[selectedId];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _title('Roles'),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () async {
                final name = await promptText(context, 'Nuevo rol', hint: 'Mods');
                if (name == null || name.isEmpty) return;
                final r = await store.api.post('/api/roles',
                    {'name': name, 'permissions': 0});
                setState(() => selectedId = r['id']);
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Crear rol'),
            ),
          ]),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 170,
                child: ListView(
                  children: roles.map((r) => InkWell(
                        onTap: () => setState(() => selectedId = r.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                              color: selectedId == r.id ? Pal.bg3 : null,
                              borderRadius: BorderRadius.circular(6)),
                          child: Row(children: [
                            Icon(Icons.circle, size: 10,
                                color: r.color != null
                                    ? Color(int.parse(
                                        r.color!.replaceFirst('#', '0xff')))
                                    : Pal.faint),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(r.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13))),
                          ]),
                        ),
                      )).toList(),
                ),
              ),
              const VerticalDivider(),
              Expanded(
                child: sel == null
                    ? const Center(
                        child: Text('Elige un rol',
                            style: TextStyle(color: Pal.muted)))
                    : _roleEditor(sel),
              ),
            ]),
          ),
        ]);
      },
    );
  }

  Widget _roleEditor(Role role) {
    return ListView(padding: const EdgeInsets.only(left: 12), children: [
      Row(children: [
        Expanded(
          child: Text(role.name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        if (!role.isEveryone) ...[
          SmallIconBtn(Icons.edit, 'Renombrar', () async {
            final name = await promptText(context, 'Renombrar rol',
                initial: role.name, action: 'Guardar');
            if (name != null && name.isNotEmpty) {
              store.api.patch('/api/roles/${role.id}', {'name': name});
            }
          }),
          SmallIconBtn(Icons.arrow_upward, 'Subir jerarquía', () {
            store.api.patch('/api/roles/${role.id}',
                {'position': role.position + 1});
          }),
          SmallIconBtn(Icons.arrow_downward, 'Bajar jerarquía', () {
            store.api.patch('/api/roles/${role.id}',
                {'position': role.position - 1});
          }),
          SmallIconBtn(Icons.delete_outline, 'Borrar rol', () async {
            if (await confirm(context, '¿Borrar "${role.name}"?', '')) {
              setState(() => selectedId = null);
              store.api.delete('/api/roles/${role.id}');
            }
          }, color: Pal.red),
        ],
      ]),
      const SizedBox(height: 10),
      const Text('COLOR',
          style: TextStyle(fontSize: 11, color: Pal.faint, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        children: swatches.map((c) => InkWell(
              onTap: () => store.api.patch('/api/roles/${role.id}', {'color': c}),
              child: Container(
                width: 26, height: 26,
                decoration: BoxDecoration(
                  color: c != null
                      ? Color(int.parse(c.replaceFirst('#', '0xff')))
                      : Pal.bg4,
                  shape: BoxShape.circle,
                  border: role.color == c
                      ? Border.all(color: Colors.white, width: 2)
                      : null,
                ),
                child: c == null
                    ? const Icon(Icons.block, size: 14, color: Pal.faint)
                    : null,
              ),
            )).toList(),
      ),
      const SizedBox(height: 16),
      const Text('PERMISOS',
          style: TextStyle(fontSize: 11, color: Pal.faint, fontWeight: FontWeight.w700)),
      ...permLabels.entries.map((e) {
        final has = (role.permissions & e.key) != 0;
        return SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          activeTrackColor: Pal.accent,
          value: has,
          title: Text(e.value.$1, style: const TextStyle(fontSize: 13.5)),
          subtitle: e.value.$2.isEmpty
              ? null
              : Text(e.value.$2,
                  style: const TextStyle(fontSize: 11, color: Pal.faint)),
          onChanged: (v) {
            final next = v
                ? role.permissions | e.key
                : role.permissions & ~e.key;
            store.api.patch('/api/roles/${role.id}', {'permissions': next});
          },
        );
      }),
    ]);
  }
}

// ───────────────────────── Invitaciones ─────────────────────────
class _InvitesPanel extends StatefulWidget {
  final AppStore store;
  const _InvitesPanel(this.store);
  @override
  State<_InvitesPanel> createState() => _InvitesPanelState();
}

class _InvitesPanelState extends State<_InvitesPanel> {
  List<dynamic> invites = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    invites = await widget.store.api.get('/api/invites');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _title('Invitaciones'),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: () async {
            await widget.store.api.post('/api/invites', {'max_uses': 0});
            _load();
          },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Nueva'),
        ),
      ]),
      Expanded(
        child: ListView(
          children: invites.map((i) => ListTile(
                dense: true,
                leading: const Icon(Icons.mail_outline, color: Pal.accent, size: 18),
                title: SelectableText(i['code'],
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 14,
                        fontWeight: FontWeight.w700)),
                subtitle: Text(
                    'Usos: ${i['uses']}${i['max_uses'] > 0 ? '/${i['max_uses']}' : ' (∞)'}',
                    style: const TextStyle(fontSize: 11.5, color: Pal.faint)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  SmallIconBtn(Icons.copy, 'Copiar', () {
                    Clipboard.setData(ClipboardData(text: i['code']));
                  }),
                  SmallIconBtn(Icons.delete_outline, 'Revocar', () async {
                    await widget.store.api.delete('/api/invites/${i['code']}');
                    _load();
                  }, color: Pal.red),
                ]),
              )).toList(),
        ),
      ),
    ]);
  }
}

// ───────────────────── Stickers / Soundboard ─────────────────────
class _ExpressionsPanel extends StatelessWidget {
  final AppStore store;
  final bool stickers;
  const _ExpressionsPanel(this.store, {required this.stickers});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _title(stickers ? 'Stickers' : 'Soundboard'),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () => _upload(context),
              icon: const Icon(Icons.upload, size: 16),
              label: Text(stickers ? 'Subir sticker' : 'Subir sonido'),
            ),
          ]),
          Text(
              stickers
                  ? 'PNG/GIF/WebP, máx 2 MB.'
                  : 'MP3/OGG/WAV, máx 1 MB. Todos en el canal de voz lo oyen.',
              style: const TextStyle(color: Pal.faint, fontSize: 12)),
          const SizedBox(height: 12),
          Expanded(
            child: stickers
                ? GridView.count(
                    crossAxisCount: 5,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    children: store.stickers.map((s) => Stack(children: [
                          Container(
                            decoration: BoxDecoration(
                                color: Pal.bg0,
                                borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.all(8),
                            child: Center(
                                child: Image.network(
                                    store.api.fileUrl(s.url),
                                    fit: BoxFit.contain)),
                          ),
                          Positioned(
                            right: 2, top: 2,
                            child: SmallIconBtn(Icons.close, 'Borrar ${s.name}',
                                () => store.api.delete('/api/stickers/${s.id}'),
                                color: Pal.red, size: 14),
                          ),
                        ])).toList(),
                  )
                : ListView(
                    children: store.sounds.map((s) => ListTile(
                          dense: true,
                          leading: Text(s.emoji ?? '🔊',
                              style: const TextStyle(fontSize: 18)),
                          title: Text(s.name, style: const TextStyle(fontSize: 13.5)),
                          trailing: SmallIconBtn(Icons.delete_outline, 'Borrar',
                              () => store.api.delete('/api/sounds/${s.id}'),
                              color: Pal.red),
                        )).toList(),
                  ),
          ),
        ]);
      },
    );
  }

  Future<void> _upload(BuildContext context) async {
    final r = await FilePicker.pickFiles(withData: true);
    final f = r?.files.firstOrNull;
    if (f?.bytes == null || !context.mounted) return;
    final name = await promptText(context, 'Nombre', initial: f!.name.split('.').first,
        action: 'Subir');
    if (name == null || name.isEmpty) return;
    try {
      await store.api.upload(stickers ? '/api/stickers' : '/api/sounds',
          f.bytes!, f.name, fields: {'name': name});
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

// ───────────────────────── AutoMod ─────────────────────────
class _AutomodPanel extends StatefulWidget {
  final AppStore store;
  const _AutomodPanel(this.store);
  @override
  State<_AutomodPanel> createState() => _AutomodPanelState();
}

class _AutomodPanelState extends State<_AutomodPanel> {
  List<dynamic> rules = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    rules = await widget.store.api.get('/api/automod');
    if (mounted) setState(() {});
  }

  Future<void> _create() async {
    String type = 'words';
    final name = TextEditingController();
    final pattern = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Nueva regla AutoMod', style: TextStyle(fontSize: 17)),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name,
                  decoration: const InputDecoration(hintText: 'Nombre de la regla')),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: type,
                dropdownColor: Pal.bg0,
                items: const [
                  DropdownMenuItem(value: 'words',
                      child: Text('Palabras bloqueadas (separadas por coma)')),
                  DropdownMenuItem(value: 'regex', child: Text('Expresión regular')),
                  DropdownMenuItem(value: 'links', child: Text('Bloquear enlaces')),
                ],
                onChanged: (v) => setSt(() => type = v!),
              ),
              const SizedBox(height: 10),
              if (type != 'links')
                TextField(controller: pattern,
                    decoration: InputDecoration(
                        hintText: type == 'words' ? 'tonto, feo, spam' : '(regex)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: () async {
                await widget.store.api.post('/api/automod', {
                  'name': name.text.trim().isEmpty ? 'regla' : name.text.trim(),
                  'type': type,
                  'pattern': pattern.text,
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Crear'),
            ),
          ],
        ),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _title('AutoMod — filtros de mensajes'),
        const Spacer(),
        ElevatedButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Nueva regla')),
      ]),
      const Text('Los administradores están exentos de los filtros.',
          style: TextStyle(color: Pal.faint, fontSize: 12)),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(
          children: rules.map((r) => ListTile(
                dense: true,
                leading: Icon(
                    r['type'] == 'links'
                        ? Icons.link_off
                        : r['type'] == 'regex'
                            ? Icons.code
                            : Icons.block,
                    size: 18,
                    color: r['enabled'] == 1 ? Pal.accent : Pal.faint),
                title: Text(r['name'], style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(r['pattern'],
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Pal.faint)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(
                    value: r['enabled'] == 1,
                    activeTrackColor: Pal.accent,
                    onChanged: (v) async {
                      await widget.store.api
                          .patch('/api/automod/${r['id']}', {'enabled': v});
                      _load();
                    },
                  ),
                  SmallIconBtn(Icons.delete_outline, 'Borrar', () async {
                    await widget.store.api.delete('/api/automod/${r['id']}');
                    _load();
                  }, color: Pal.red),
                ]),
              )).toList(),
        ),
      ),
    ]);
  }
}

// ───────────────────────── Webhooks ─────────────────────────
class _WebhooksPanel extends StatefulWidget {
  final AppStore store;
  const _WebhooksPanel(this.store);
  @override
  State<_WebhooksPanel> createState() => _WebhooksPanelState();
}

class _WebhooksPanelState extends State<_WebhooksPanel> {
  List<dynamic> hooks = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    hooks = await widget.store.api.get('/api/webhooks');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final textChannels =
        store.visibleChannels.where((c) => !c.isVoice).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _title('Webhooks'),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: textChannels.isEmpty
              ? null
              : () async {
                  final name = await promptText(context, 'Nombre del webhook',
                      hint: 'GitHub CI');
                  if (name == null || name.isEmpty) return;
                  await store.api.post(
                      '/api/channels/${textChannels.first.id}/webhooks',
                      {'name': name});
                  _load();
                },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Crear'),
        ),
      ]),
      const Text('POST {content, username?, avatar_url?} a la URL → mensaje en el canal.',
          style: TextStyle(color: Pal.faint, fontSize: 12)),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(
          children: hooks.map((h) {
            final url =
                '${store.api.base}/api/webhooks/${h['id']}/${h['token']}';
            return ListTile(
              dense: true,
              leading: const Icon(Icons.webhook, color: Pal.accent, size: 18),
              title: Text(
                  '${h['name']}  →  #${store.channels[h['channel_id']]?.name ?? '?'}',
                  style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(url,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11, color: Pal.faint, fontFamily: 'monospace')),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                SmallIconBtn(Icons.copy, 'Copiar URL', () {
                  Clipboard.setData(ClipboardData(text: url));
                }),
                SmallIconBtn(Icons.delete_outline, 'Borrar', () async {
                  await store.api.delete('/api/webhooks/${h['id']}');
                  _load();
                }, color: Pal.red),
              ]),
            );
          }).toList(),
        ),
      ),
    ]);
  }
}

// ───────────────────────── Bots ─────────────────────────
class _BotsPanel extends StatefulWidget {
  final AppStore store;
  const _BotsPanel(this.store);
  @override
  State<_BotsPanel> createState() => _BotsPanelState();
}

class _BotsPanelState extends State<_BotsPanel> {
  List<dynamic> bots = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    bots = await widget.store.api.get('/api/bots');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _title('Bots'),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: () async {
            final name = await promptText(context, 'Nombre del bot', hint: 'dado.bot');
            if (name == null || name.isEmpty) return;
            try {
              await widget.store.api.post('/api/bots', {'username': name});
              _load();
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Crear bot'),
        ),
      ]),
      const Text(
          'El bot usa su token en la misma API y gateway. Ejemplo en examples/dice-bot.ts.',
          style: TextStyle(color: Pal.faint, fontSize: 12)),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(
          children: bots.map((b) => ListTile(
                dense: true,
                leading: const Icon(Icons.smart_toy, color: Pal.accent, size: 18),
                title: Text(b['username'], style: const TextStyle(fontSize: 13.5)),
                subtitle: Text('token: ${b['token']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: Pal.faint, fontFamily: 'monospace')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  SmallIconBtn(Icons.copy, 'Copiar token', () {
                    Clipboard.setData(ClipboardData(text: b['token']));
                  }),
                  SmallIconBtn(Icons.delete_outline, 'Borrar bot', () async {
                    await widget.store.api.delete('/api/bots/${b['id']}');
                    _load();
                  }, color: Pal.red),
                ]),
              )).toList(),
        ),
      ),
    ]);
  }
}

// ───────────────────────── Actualizaciones ─────────────────────────
class _UpdatesPanel extends StatefulWidget {
  final AppStore store;
  const _UpdatesPanel(this.store);
  @override
  State<_UpdatesPanel> createState() => _UpdatesPanelState();
}

class _UpdatesPanelState extends State<_UpdatesPanel> {
  UpdateInfo? available;
  bool checked = false;
  bool applying = false;

  @override
  void initState() {
    super.initState();
    Updater.check(widget.store.api).then((u) {
      if (mounted) {
        setState(() {
          available = u;
          checked = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title('Actualizaciones'),
      Text('Versión instalada: v$appVersion',
          style: const TextStyle(color: Pal.muted, fontSize: 13.5)),
      const SizedBox(height: 16),
      if (!checked)
        const CircularProgressIndicator(strokeWidth: 2)
      else if (available == null)
        const Row(children: [
          Icon(Icons.check_circle, color: Pal.green, size: 18),
          SizedBox(width: 8),
          Text('Estás al día ✨', style: TextStyle(fontSize: 14)),
        ])
      else ...[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Pal.bg0, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('🎉 Nueva versión: v${available!.version}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            if (available!.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(available!.notes,
                    style: const TextStyle(color: Pal.muted, fontSize: 12.5)),
              ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: applying
                  ? null
                  : () async {
                      setState(() => applying = true);
                      try {
                        await Updater.apply(widget.store.api, available!);
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      } finally {
                        if (mounted) setState(() => applying = false);
                      }
                    },
              icon: const Icon(Icons.download, size: 16),
              label: Text(applying
                  ? 'Descargando…'
                  : 'Actualizar y reiniciar'),
            ),
          ]),
        ),
      ],
      const Spacer(),
      if (widget.store.canI(P.administrator))
        const Text(
            'Publicar release: POST /api/updates/:platform con el instalador '
            '(ver client/packaging/README.md).',
            style: TextStyle(color: Pal.faint, fontSize: 11.5)),
    ]);
  }
}
