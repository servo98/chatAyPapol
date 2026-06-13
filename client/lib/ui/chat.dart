import 'package:cross_file/cross_file.dart' show XFile;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../md.dart';
import '../models.dart';
import '../perms.dart';
import '../store.dart';
import '../theme.dart';
import 'widgets.dart';

class ChatView extends StatefulWidget {
  final AppStore store;
  const ChatView({super.key, required this.store});
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  bool dragging = false; // hay archivos siendo arrastrados sobre el chat
  final input = TextEditingController();
  final scroll = ScrollController();
  final focus = FocusNode();
  Message? replyingTo;
  Message? editing;
  final pendingUploads = <Map<String, dynamic>>[];
  bool sending = false;

  // Canal del último build + si ya hicimos el scroll inicial al fondo (al abrir
  // o cambiar de canal el chat debe arrancar en el ÚLTIMO mensaje, no arriba).
  String? _lastChannelId;
  bool _didInitialScroll = false;

  // ── autocompletado de @menciones ──
  bool _mentionOpen = false; // hay overlay de menciones abierto
  int _mentionSel = 0; // índice resaltado en la lista
  List<User> _mentionMatches = const [];

  AppStore get store => widget.store;
  Channel? get channel => store.selectedChannel;

  @override
  void initState() {
    super.initState();
    scroll.addListener(() {
      if (scroll.position.pixels <= 60 && channel != null) {
        store.loadMessages(channel!.id, older: true);
      }
    });
  }

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ch = channel;
    if (ch == null || sending) return;
    final text = input.text.trim();
    if (text.isEmpty && pendingUploads.isEmpty) return;
    setState(() => sending = true);
    try {
      if (editing != null) {
        await store.api.patch(
            '/api/channels/${ch.id}/messages/${editing!.id}', {'content': text});
      } else {
        await store.api.post('/api/channels/${ch.id}/messages', {
          'content': text,
          if (pendingUploads.isNotEmpty) 'attachments': pendingUploads,
          if (replyingTo != null) 'reply_to': replyingTo!.id,
        });
      }
      input.clear();
      setState(() {
        replyingTo = null;
        editing = null;
        pendingUploads.clear();
        _mentionOpen = false;
        _mentionMatches = const [];
      });
      _scrollToBottom();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      setState(() => sending = false);
    }
  }

  // ── @menciones: detección/cálculo/inserción ──

  static final _mentionRe = RegExp(r'@([a-zA-Z0-9_.]*)$');

  // recalcula matches según el token bajo el cursor; abre/cierra el overlay
  void _updateMentions() {
    final sel = input.selection;
    if (!sel.isValid || !sel.isCollapsed) {
      if (_mentionOpen) setState(() => _mentionOpen = false);
      return;
    }
    final before = input.text.substring(0, sel.baseOffset);
    final m = _mentionRe.firstMatch(before);
    if (m == null) {
      if (_mentionOpen) setState(() => _mentionOpen = false);
      return;
    }
    final prefix = m.group(1)!.toLowerCase();
    final matches = store.users.values
        .where((u) => u.username.toLowerCase().startsWith(prefix))
        .toList()
      ..sort((a, b) {
        final ao = store.online.contains(a.id) ? 0 : 1;
        final bo = store.online.contains(b.id) ? 0 : 1;
        if (ao != bo) return ao - bo;
        return a.username.toLowerCase().compareTo(b.username.toLowerCase());
      });
    final top = matches.take(8).toList();
    setState(() {
      _mentionMatches = top;
      _mentionOpen = top.isNotEmpty;
      if (_mentionSel >= top.length) _mentionSel = 0;
    });
  }

  // inserta el usuario resaltado reemplazando el token '@prefijo'
  void _insertMention(User u) {
    final sel = input.selection;
    if (!sel.isValid) return;
    final cursor = sel.baseOffset;
    final before = input.text.substring(0, cursor);
    final m = _mentionRe.firstMatch(before);
    if (m == null) return;
    final start = m.start;
    final after = input.text.substring(cursor);
    final inserted = '@${u.username} ';
    final newText = input.text.substring(0, start) + inserted + after;
    input.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
    setState(() {
      _mentionOpen = false;
      _mentionMatches = const [];
      _mentionSel = 0;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  Future<void> _attach() async {
    final r = await FilePicker.pickFiles(withData: true);
    final f = r?.files.firstOrNull;
    if (f?.bytes == null) return;
    try {
      final up = await store.api.upload('/api/uploads', f!.bytes!, f.name);
      setState(() => pendingUploads.add(up));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _sendSticker(Sticker s) async {
    final ch = channel;
    if (ch == null) return;
    try {
      await store.api.post('/api/channels/${ch.id}/messages', {'sticker_id': s.id});
      _scrollToBottom();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ch = channel;
    if (ch == null) {
      return const Center(
          child: Text('❯ elige un canal para empezar',
              style: TextStyle(color: Pal.muted)));
    }
    final msgs = store.messages[ch.id] ?? [];
    // Al abrir o cambiar de canal, arranca en el último mensaje (no arriba). Como
    // los mensajes cargan async, se hace en el primer build con la lista ya
    // poblada para ese canal (jumpTo tras el frame).
    if (ch.id != _lastChannelId) {
      _lastChannelId = ch.id;
      _didInitialScroll = false;
    }
    if (!_didInitialScroll && msgs.isNotEmpty) {
      _didInitialScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
      });
    }
    final canSend = store.canI(P.sendMessages, ch.id);
    final body = Column(
      children: [
        _header(ch),
        Expanded(
          child: msgs.isEmpty
              ? _emptyChannel(ch)
              : ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: msgs.length,
                  itemBuilder: (ctx, i) => _messageRow(msgs, i),
                ),
        ),
        _typingBar(ch),
        if (canSend) _inputBar(ch) else _readOnlyBar(),
      ],
    );
    if (!store.canI(P.attachFiles, ch.id)) return body;
    // arrastrar archivos a la ventana = adjuntarlos (como el botón +)
    return DropTarget(
      onDragEntered: (_) => setState(() => dragging = true),
      onDragExited: (_) => setState(() => dragging = false),
      onDragDone: (detail) {
        setState(() => dragging = false);
        _attachDropped(detail.files);
      },
      child: Stack(children: [
        body,
        if (dragging)
          Positioned.fill(
            child: Container(
              color: Pal.bg0.withValues(alpha: .8),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    border: Border.all(color: Pal.accent, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(LucideIcons.upload, size: 40, color: Pal.accent),
                    SizedBox(height: 8),
                    Text('Suelta para adjuntar',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Future<void> _attachDropped(List<XFile> files) async {
    for (final f in files) {
      try {
        final bytes = await f.readAsBytes();
        final up = await store.api.upload('/api/uploads', bytes, f.name);
        if (mounted) setState(() => pendingUploads.add(up));
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  Widget _header(Channel ch) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Pal.borderSubtle)),
      ),
      child: Row(
        children: [
          const Text('#',
              style: TextStyle(
                  color: Pal.faint, fontSize: 20, fontWeight: FontWeight.w700,
                  height: 1)),
          const SizedBox(width: 8),
          Text(ch.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          if (ch.topic != null && ch.topic!.isNotEmpty) ...[
            Container(
                width: 1, height: 20, color: Pal.bg4,
                margin: const EdgeInsets.symmetric(horizontal: 12)),
            Expanded(
              child: Text(ch.topic!,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Pal.muted, fontSize: 13)),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }

  Widget _emptyChannel(Channel ch) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 68, height: 68,
            decoration: BoxDecoration(
                color: Pal.bg3,
                shape: BoxShape.circle,
                border: Border.all(color: Pal.borderStrong)),
            alignment: Alignment.center,
            child: const Text('#',
                style: TextStyle(
                    fontSize: 30, fontWeight: FontWeight.w700, color: Pal.accent)),
          ),
          const SizedBox(height: 12),
          Text('bienvenido a #${ch.name}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const Text('este es el principio del canal — di algo ▮',
              style: TextStyle(color: Pal.muted, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _messageRow(List<Message> msgs, int i) {
    final m = msgs[i];
    final prev = i > 0 ? msgs[i - 1] : null;
    final grouped = prev != null &&
        prev.authorId == m.authorId &&
        m.authorId != null &&
        prev.webhookName == m.webhookName &&
        m.replyTo == null &&
        m.createdAt - prev.createdAt < 5 * 60 * 1000;
    final showDate = prev == null || !sameDay(prev.createdAt, m.createdAt);
    return Column(
      children: [
        if (showDate) _dateDivider(m.createdAt),
        _MessageTile(
          store: store, message: m, grouped: grouped && !showDate,
          onReply: () => setState(() {
            replyingTo = m;
            editing = null;
            focus.requestFocus();
          }),
          onEdit: m.authorId == store.me?.id
              ? () => setState(() {
                    editing = m;
                    replyingTo = null;
                    input.text = m.content;
                    focus.requestFocus();
                  })
              : null,
          onDelete: (m.authorId == store.me?.id ||
                  store.canI(P.manageMessages, m.channelId))
              ? () async {
                  if (await confirm(context, '¿Borrar mensaje?', 'No hay vuelta atrás.')) {
                    store.api.delete('/api/channels/${m.channelId}/messages/${m.id}');
                  }
                }
              : null,
        ),
      ],
    );
  }

  Widget _dateDivider(int ms) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(fmtDate(ms),
              style: const TextStyle(
                  color: Pal.faint, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
        const Expanded(child: Divider()),
      ]),
    );
  }

  Widget _typingBar(Channel ch) {
    final names = store.typingUsersIn(ch.id).map((u) => u.username).toList();
    if (names.isEmpty) return const SizedBox(height: 4);
    final text = names.length == 1
        ? '${names[0]} está escribiendo…'
        : names.length <= 3
            ? '${names.join(', ')} están escribiendo…'
            : 'Varias personas están escribiendo…';
    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(text,
            style: const TextStyle(
                color: Pal.muted, fontSize: 12, fontStyle: FontStyle.italic)),
      ),
    );
  }

  Widget _readOnlyBar() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Pal.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Pal.borderDefault)),
      child: const Text('! no tienes permiso para escribir en este canal',
          style: TextStyle(color: Pal.muted, fontSize: 13)),
    );
  }

  Widget _inputBar(Channel ch) {
    final slashMatches = _slashMatches();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (slashMatches.isNotEmpty) _slashPopup(slashMatches),
          if (_mentionOpen && _mentionMatches.isNotEmpty) _mentionPopup(),
          if (replyingTo != null || editing != null) _contextBar(),
          if (pendingUploads.isNotEmpty) _uploadsBar(),
          ListenableBuilder(
            listenable: focus,
            builder: (_, child) => Container(
              decoration: BoxDecoration(
                  color: Pal.inset,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: focus.hasFocus ? Pal.accent : Pal.borderDefault,
                      width: focus.hasFocus ? 1.5 : 1),
                  boxShadow: focus.hasFocus ? Pal.glowGreen : null),
              child: child,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (store.canI(P.attachFiles, ch.id))
                  Padding(
                    padding: const EdgeInsets.only(left: 6, bottom: 6),
                    child: SmallIconBtn(
                        LucideIcons.plusCircle, 'Adjuntar archivo', _attach, size: 22),
                  ),
                const Padding(
                  padding: EdgeInsets.only(left: 10, right: 2, bottom: 12),
                  child: Text('❯',
                      style: TextStyle(
                          color: Pal.accent, fontSize: 14, height: 1,
                          fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, e) {
                      if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
                        return KeyEventResult.ignored;
                      }
                      // overlay de menciones abierto: ↑/↓ navegan,
                      // Enter/Tab insertan, Esc cierra (sin enviar).
                      if (_mentionOpen && _mentionMatches.isNotEmpty) {
                        final k = e.logicalKey;
                        if (k == LogicalKeyboardKey.arrowDown) {
                          setState(() => _mentionSel =
                              (_mentionSel + 1) % _mentionMatches.length);
                          return KeyEventResult.handled;
                        }
                        if (k == LogicalKeyboardKey.arrowUp) {
                          setState(() => _mentionSel =
                              (_mentionSel - 1 + _mentionMatches.length) %
                                  _mentionMatches.length);
                          return KeyEventResult.handled;
                        }
                        if (k == LogicalKeyboardKey.enter ||
                            k == LogicalKeyboardKey.tab) {
                          _insertMention(_mentionMatches[_mentionSel]);
                          return KeyEventResult.handled;
                        }
                        if (k == LogicalKeyboardKey.escape) {
                          setState(() => _mentionOpen = false);
                          return KeyEventResult.handled;
                        }
                      }
                      if (e.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        _send();
                        return KeyEventResult.handled;
                      }
                      if (e.logicalKey == LogicalKeyboardKey.escape) {
                        setState(() {
                          editing = null;
                          replyingTo = null;
                          input.clear();
                        });
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: input,
                      focusNode: focus,
                      maxLines: 6,
                      minLines: 1,
                      onChanged: (v) {
                        if (v.isNotEmpty) store.sendTyping(ch.id);
                        _updateMentions();
                        setState(() {});
                      },
                      decoration: InputDecoration(
                        hintText: 'Mensaje a #${ch.name}',
                        filled: false,
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 4, bottom: 6),
                  child: Row(children: [
                    SmallIconBtn(LucideIcons.smile, 'Stickers',
                        () => _stickerPicker(), size: 22),
                    SmallIconBtn(LucideIcons.send, 'Enviar', _send,
                        color: Pal.accent, size: 22),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<(String, String)> _slashMatches() {
    final t = input.text;
    if (!t.startsWith('/') || t.contains(' ') || t.length < 2) return const [];
    final q = t.substring(1).toLowerCase();
    const builtins = [
      ('me', 'Texto en cursiva'),
      ('shrug', '¯\\_(ツ)_/¯'),
      ('tableflip', '(╯°□°）╯︵ ┻━┻'),
      ('unflip', '┬─┬ ノ( ゜-゜ノ)'),
      ('spoiler', 'Marca el texto como spoiler'),
    ];
    return [
      ...builtins.where((b) => b.$1.startsWith(q)),
      ...store.commands
          .where((c) => c.name.startsWith(q))
          .map((c) => (c.name, '${c.description} — bot ${store.users[c.botId]?.username ?? ''}')),
    ];
  }

  Widget _slashPopup(List<(String, String)> matches) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
          color: Pal.bg0, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: matches.take(6).map((m) => InkWell(
              onTap: () {
                input.text = '/${m.$1} ';
                input.selection =
                    TextSelection.collapsed(offset: input.text.length);
                focus.requestFocus();
                setState(() {});
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  Text('/${m.$1}',
                      style: const TextStyle(
                          color: Pal.accent, fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(width: 10),
                  Flexible(
                      child: Text(m.$2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Pal.muted, fontSize: 12))),
                ]),
              ),
            )).toList(),
      ),
    );
  }

  Widget _mentionPopup() {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 264),
      decoration: BoxDecoration(
          color: Pal.bg0,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Pal.borderDefault)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _mentionMatches.length,
          itemBuilder: (_, i) {
            final u = _mentionMatches[i];
            final sel = i == _mentionSel;
            final online = store.online.contains(u.id);
            return InkWell(
              onTap: () => _insertMention(u),
              child: Container(
                color: sel ? Pal.bg3 : null,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(children: [
                  Avatar(u, store, size: 24, showOnline: true),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(u.username,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                sel ? FontWeight.w700 : FontWeight.w500,
                            color: sel ? Pal.text : Pal.muted)),
                  ),
                  if (online) ...[
                    const SizedBox(width: 8),
                    Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                            color: Pal.green, shape: BoxShape.circle)),
                  ],
                ]),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _contextBar() {
    final isEdit = editing != null;
    final name = isEdit
        ? 'Editando mensaje'
        : 'Respondiendo a ${store.users[replyingTo!.authorId]?.username ?? replyingTo!.webhookName ?? '?'}';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
          color: Pal.bg0,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8))),
      child: Row(children: [
        Icon(isEdit ? LucideIcons.pencil : LucideIcons.reply, size: 14, color: Pal.muted),
        const SizedBox(width: 8),
        Expanded(child: Text(name, style: const TextStyle(color: Pal.muted, fontSize: 12))),
        SmallIconBtn(LucideIcons.x, 'Cancelar', () => setState(() {
              replyingTo = null;
              editing = null;
              if (isEdit) input.clear();
            }), size: 14),
      ]),
    );
  }

  Widget _uploadsBar() {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 8,
        children: pendingUploads.map((u) => Chip(
              backgroundColor: Pal.bg3,
              label: Text(u['name'] ?? 'archivo', style: const TextStyle(fontSize: 12)),
              deleteIcon: const Icon(LucideIcons.x, size: 14),
              onDeleted: () => setState(() => pendingUploads.remove(u)),
            )).toList(),
      ),
    );
  }

  void _stickerPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Pal.bg1,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        height: 320,
        child: store.stickers.isEmpty
            ? const Center(
                child: Text('No hay stickers todavía.\nSúbelos en Ajustes → Stickers.',
                    textAlign: TextAlign.center, style: TextStyle(color: Pal.muted)))
            : GridView.count(
                crossAxisCount: 6,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                children: store.stickers.map((s) => Tooltip(
                      message: s.name,
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _sendSticker(s);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(store.api.fileUrl(s.url),
                              fit: BoxFit.contain),
                        ),
                      ),
                    )).toList(),
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────

class _MessageTile extends StatelessWidget {
  final AppStore store;
  final Message message;
  final bool grouped;
  final VoidCallback onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _MessageTile({
    required this.store, required this.message, required this.grouped,
    required this.onReply, this.onEdit, this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final m = message;
    final author = store.users[m.authorId];
    final name = m.webhookName ?? author?.username ?? 'desconocido';
    final roleColor = author != null ? store.topRole(author.id)?.color : null;
    final nameColor = roleColor != null
        ? Color(int.parse(roleColor.replaceFirst('#', '0xff')))
        : Pal.text;
    final replied = m.replyTo == null
        ? null
        : store.messages[m.channelId]?.where((x) => x.id == m.replyTo).firstOrNull;

    return Hoverable(
      builder: (ctx, hover) => Container(
        color: hover ? Pal.bg3.withValues(alpha: .4) : null,
        padding: EdgeInsets.only(
            left: 16, right: 16, top: grouped ? 1 : 10, bottom: 1),
        child: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 40,
                  child: grouped
                      ? (hover
                          ? Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(fmtTime(m.createdAt),
                                  style: const TextStyle(
                                      color: Pal.faint, fontSize: 11)))
                          : null)
                      : Avatar(author, store, size: 38),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (replied != null) _replyPreview(replied),
                      if (!grouped)
                        Row(children: [
                          Flexible(
                            child: Text(name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                    color: nameColor)),
                          ),
                          if (author?.isBot == true || m.webhookName != null)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                  color: Pal.accent,
                                  borderRadius: BorderRadius.circular(3)),
                              child: const Text('BOT',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.3,
                                      color: Pal.greenInk)),
                            ),
                          const SizedBox(width: 8),
                          Text(fmtTime(m.createdAt),
                              style:
                                  const TextStyle(color: Pal.faint, fontSize: 11)),
                        ]),
                      if (m.content.isNotEmpty)
                        ...renderMarkdown(m.content, store),
                      if (m.editedAt != null)
                        const Text('(editado)',
                            style: TextStyle(color: Pal.faint, fontSize: 11)),
                      if (m.stickerId != null) _sticker(),
                      ...m.attachments.map(_attachment),
                      ...m.embeds.map(_embed),
                    ],
                  ),
                ),
              ],
            ),
            if (hover)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  decoration: BoxDecoration(
                      color: Pal.bg0,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: Pal.borderDefault)),
                  child: Row(children: [
                    SmallIconBtn(LucideIcons.reply, 'Responder', onReply, size: 16),
                    if (onEdit != null)
                      SmallIconBtn(LucideIcons.pencil, 'Editar', onEdit!, size: 16),
                    if (onDelete != null)
                      SmallIconBtn(LucideIcons.trash2, 'Borrar', onDelete!,
                          color: Pal.red, size: 16),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _replyPreview(Message replied) {
    final author = store.users[replied.authorId];
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(children: [
        const Icon(LucideIcons.cornerDownRight, size: 14, color: Pal.faint),
        Text('${author?.username ?? replied.webhookName ?? '?'}: ',
            style: const TextStyle(
                color: Pal.accent, fontSize: 12, fontWeight: FontWeight.w700)),
        Flexible(
          child: Text(
              replied.content.isEmpty ? '[adjunto]' : replied.content,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Pal.muted, fontSize: 12)),
        ),
      ]),
    );
  }

  Widget _sticker() {
    final s = store.stickers.where((x) => x.id == message.stickerId).firstOrNull;
    if (s == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Image.network(store.api.fileUrl(s.url), width: 160, height: 160,
          fit: BoxFit.contain),
    );
  }

  Widget _attachment(Attachment a) {
    if (a.isImage) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 320),
            child: Image.network(store.api.fileUrl(a.url), fit: BoxFit.contain,
                alignment: Alignment.centerLeft),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        onTap: () => launchUrlString(store.api.fileUrl(a.url),
            mode: LaunchMode.externalApplication),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: Pal.bg0, borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(LucideIcons.paperclip, size: 18, color: Pal.accent),
            const SizedBox(width: 8),
            Text(a.name, style: const TextStyle(color: Pal.link, fontSize: 13)),
            const SizedBox(width: 8),
            Text('${(a.size / 1024).toStringAsFixed(0)} KB',
                style: const TextStyle(color: Pal.faint, fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  Widget _embed(Embed e) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxWidth: 440),
      decoration: BoxDecoration(
        color: Pal.bg0,
        borderRadius: BorderRadius.circular(8),
        border: const Border(left: BorderSide(color: Pal.accent, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.title != null)
            InkWell(
              onTap: e.url == null
                  ? null
                  : () => launchUrlString(e.url!,
                      mode: LaunchMode.externalApplication),
              child: Text(e.title!,
                  style: const TextStyle(
                      color: Pal.link, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
          if (e.description != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(e.description!,
                  style: const TextStyle(color: Pal.muted, fontSize: 12)),
            ),
          if (e.image != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Image.network(e.image!, fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
