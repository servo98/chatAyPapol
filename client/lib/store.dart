import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' hide Category;
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'config.dart';
import 'gateway.dart';
import 'models.dart';
import 'notifications.dart';
import 'perms.dart';
import 'sfx.dart';

/// Username del dueño: única cuenta que ve el Sound Lab (auth username-only).
const _soundLabOwner = 'ferservo98';

/// Modo de notificación por canal (estilo Discord).
enum ChannelNotify { all, mentions, muted }

/// Estado global de la app. Singleton creado en main.dart.
class AppStore extends ChangeNotifier {
  final api = Api();
  final gateway = Gateway();

  User? me;
  bool wsConnected = false;
  bool restoring = true;

  final users = <String, User>{};
  final roles = <String, Role>{};
  var categories = <Category>[];
  final channels = <String, Channel>{};
  final memberRoles = <String, Set<String>>{};
  final overwrites = <String, List<Overwrite>>{}; // channelId -> ows
  var stickers = <Sticker>[];
  var sounds = <Sound>[];
  var commands = <BotCommand>[];
  final online = <String>{};
  final voiceStates = <String, VoiceState>{};
  String everyoneRoleId = 'everyone';

  String? selectedChannelId;
  final messages = <String, List<Message>>{};
  final _hasMore = <String, bool>{};
  final unread = <String>{};
  // Canales con una MENCIÓN sin leer (a mí o @everyone). Distinto de `unread`:
  // se pinta más fuerte. Se limpia en selectChannel().
  final mentionedChannels = <String>{};
  final typing = <String, Map<String, int>>{}; // channelId -> userId -> expiry

  // ---------- preferencias de notificaciones ----------
  /// Maestro global: si está en false, no se muestra ningún toast del SO.
  bool notificationsEnabled = true;
  /// No molestar: calla el sonido in-app y el toast (no toca `unread`).
  bool dnd = false;
  /// ¿La ventana de la app tiene el foco? Lo mantiene main.dart (WindowListener).
  /// Solo notificamos por toast del SO cuando la ventana NO está enfocada.
  bool windowFocused = true;
  /// Modo de notificación por canal. Default: ChannelNotify.mentions.
  final _channelNotify = <String, ChannelNotify>{};
  int _lastTypingSent = 0;
  Timer? _typingCleaner;

  /// El VoiceManager se cuelga aquí para reproducir soundboard y reaccionar a eventos.
  void Function(Sound sound, String channelId)? onSoundPlay;

  Channel? get selectedChannel => channels[selectedChannelId];
  bool get loggedIn => me != null;

  /// Solo el dueño ve el Sound Lab.
  bool get isSoundLabOwner => me?.username == _soundLabOwner;

  AppStore() {
    _loadNotifPrefs();
    gateway.onEvent = _handleEvent;
    gateway.onStatus = (c) {
      if (wsConnected != c) {
        wsConnected = c;
        notifyListeners();
      }
    };
    _typingCleaner = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      var changed = false;
      for (final m in typing.values) {
        final before = m.length;
        m.removeWhere((_, exp) => exp < now);
        changed |= m.length != before;
      }
      if (changed) notifyListeners();
    });
  }

  // ---------- sesión ----------
  Future<void> tryRestore() async {
    api.base = serverUrl;
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token != null) {
      api.token = token;
      try {
        final u = await api.get('/api/me');
        _start(User.fromJson(u));
      } catch (e) {
        // sin red o server caído: conserva el token y reintenta al reabrir;
        // solo descarta la sesión si el server la rechazó de verdad (401)
        if (e is ApiException && e.status == 401) {
          api.token = null;
          await prefs.remove('token');
        }
      }
    }
    restoring = false;
    notifyListeners();
  }

  /// QR de 2FA pendiente de confirmar tras un registro (uri otpauth + secreto).
  Map<String, dynamic>? pendingTotp;

  Future<void> login(String username, String password,
      {String? invite, bool register = false}) async {
    api.base = serverUrl;
    final body = {
      'username': username,
      'password': password,
      if (invite != null && invite.isNotEmpty) 'invite': invite,
    };
    final r = await api.post(register ? '/api/auth/register' : '/api/auth/login', body);
    api.token = r['token'];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', api.token!);
    pendingTotp = r['totp']; // solo el registro trae el QR de 2FA
    _start(User.fromJson(r['user']));
  }

  /// Recuperar contraseña con 2FA (sin email): deja la sesión iniciada.
  Future<void> recover(String username, String code, String password) async {
    api.base = serverUrl;
    final r = await api.post('/api/auth/recover',
        {'username': username, 'code': code, 'password': password});
    api.token = r['token'];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', api.token!);
    _start(User.fromJson(r['user']));
  }

  void _start(User user) {
    me = user;
    gateway.connect(api.base, api.token!);
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api.post('/api/auth/logout');
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    gateway.dispose();
    me = null;
    users.clear();
    roles.clear();
    channels.clear();
    messages.clear();
    selectedChannelId = null;
    notifyListeners();
  }

  // ---------- permisos (espejo del server) ----------
  int basePerms(String userId) {
    var p = roles[everyoneRoleId]?.permissions ?? 0;
    for (final rid in memberRoles[userId] ?? const <String>{}) {
      p |= roles[rid]?.permissions ?? 0;
    }
    return p;
  }

  int channelPerms(String userId, String channelId) {
    var p = basePerms(userId);
    if (p & P.administrator != 0) return allPerms;
    final ows = overwrites[channelId] ?? const [];
    final myRoles = memberRoles[userId] ?? const <String>{};

    for (final o in ows) {
      if (o.targetType == 'role' && o.targetId == everyoneRoleId) {
        p = (p & ~o.deny) | o.allow;
      }
    }
    var allow = 0, deny = 0;
    for (final o in ows) {
      if (o.targetType == 'role' && myRoles.contains(o.targetId)) {
        allow |= o.allow;
        deny |= o.deny;
      }
    }
    p = (p & ~deny) | allow;
    for (final o in ows) {
      if (o.targetType == 'member' && o.targetId == userId) {
        p = (p & ~o.deny) | o.allow;
      }
    }
    return p;
  }

  bool canI(int perm, [String? channelId]) {
    if (me == null) return false;
    final p = channelId == null ? basePerms(me!.id) : channelPerms(me!.id, channelId);
    return (p & P.administrator) != 0 || (p & perm) == perm;
  }

  // ---------- vistas computadas ----------
  List<Channel> get visibleChannels => channels.values
      .where((c) => canI(P.viewChannel, c.id))
      .toList()
    ..sort((a, b) => a.position.compareTo(b.position));

  List<Role> get sortedRoles => roles.values.toList()
    ..sort((a, b) => b.position.compareTo(a.position));

  Role? topRole(String userId) {
    Role? best;
    for (final rid in memberRoles[userId] ?? const <String>{}) {
      final r = roles[rid];
      if (r != null && (best == null || r.position > best.position)) best = r;
    }
    return best;
  }

  List<VoiceState> voiceUsersIn(String channelId) =>
      voiceStates.values.where((v) => v.channelId == channelId).toList();

  List<User> typingUsersIn(String channelId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (typing[channelId] ?? const <String, int>{})
        .entries
        .where((e) => e.value >= now && e.key != me?.id)
        .map((e) => users[e.key])
        .whereType<User>()
        .toList();
  }

  // ---------- preferencias de notificaciones ----------
  Future<void> _loadNotifPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    notificationsEnabled = prefs.getBool('notifs_enabled') ?? true;
    dnd = prefs.getBool('dnd') ?? false;
    final raw = prefs.getString('channel_notify');
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        map.forEach((k, v) {
          final mode = ChannelNotify.values
              .where((m) => m.name == v)
              .firstOrNull;
          if (mode != null) _channelNotify[k] = mode;
        });
      } catch (_) {}
    }
    notifyListeners();
  }

  ChannelNotify channelNotifyMode(String channelId) =>
      _channelNotify[channelId] ?? ChannelNotify.mentions;

  Future<void> setChannelNotify(String channelId, ChannelNotify mode) async {
    if (mode == ChannelNotify.mentions) {
      _channelNotify.remove(channelId); // el default no se persiste
    } else {
      _channelNotify[channelId] = mode;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('channel_notify',
        jsonEncode(_channelNotify.map((k, v) => MapEntry(k, v.name))));
  }

  Future<void> setNotificationsEnabled(bool v) async {
    notificationsEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifs_enabled', v);
  }

  Future<void> setDnd(bool v) async {
    dnd = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dnd', v);
  }

  void setWindowFocused(bool v) {
    if (windowFocused == v) return;
    windowFocused = v;
    notifyListeners();
  }

  // ---------- mensajes ----------
  Future<void> selectChannel(String id) async {
    selectedChannelId = id;
    unread.remove(id);
    mentionedChannels.remove(id);
    notifyListeners();
    if (!messages.containsKey(id) && channels[id]?.isVoice != true) {
      await loadMessages(id);
    }
  }

  Future<void> loadMessages(String channelId, {bool older = false}) async {
    final existing = messages[channelId] ?? [];
    if (older && (_hasMore[channelId] == false || existing.isEmpty)) return;
    final before = older ? '&before=${existing.first.id}' : '';
    final r = await api.get('/api/channels/$channelId/messages?limit=50$before') as List;
    final batch = r.map((m) => Message.fromJson(m)).toList();
    _hasMore[channelId] = batch.length >= 50;
    messages[channelId] = older ? [...batch, ...existing] : batch;
    notifyListeners();
  }

  bool hasMore(String channelId) => _hasMore[channelId] ?? false;

  void sendTyping(String channelId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTypingSent > 4000) {
      _lastTypingSent = now;
      gateway.send('TYPING', {'channel_id': channelId});
    }
  }

  /// ¿El texto me menciona? Mismo patrón que md.dart: @everyone o @miUsuario.
  bool _mentionsMe(String content) {
    final name = me?.username;
    if (name == null) return false;
    for (final m in RegExp(r'@(everyone|[a-zA-Z0-9_.]{2,32})').allMatches(content)) {
      final who = m.group(1);
      if (who == 'everyone' || who == name) return true;
    }
    return false;
  }

  // ---------- eventos del gateway ----------
  void _handleEvent(String t, dynamic d) {
    switch (t) {
      case 'READY':
        _applyReady(d);
        break;
      case 'MESSAGE_CREATE':
        final m = Message.fromJson(d);
        messages[m.channelId]?.add(m);
        (typing[m.channelId] ?? {}).remove(m.authorId);
        // Mis propios mensajes nunca notifican.
        if (m.authorId != me?.id) {
          final mode = channelNotifyMode(m.channelId);
          final isMention = _mentionsMe(m.content);
          final nonActive = m.channelId != selectedChannelId;
          // Badge de no leído: incluso en 'muted' (se ve tenue).
          if (nonActive) unread.add(m.channelId);
          if (isMention && nonActive) mentionedChannels.add(m.channelId);
          // Sonido in-app: respeta DND y el modo del canal. En 'mentions' los
          // mensajes normales NO suenan (solo el badge de no leído).
          if (!dnd && mode != ChannelNotify.muted) {
            if (isMention) {
              SfxService.instance.play(UiSound.mention);
            } else if (mode == ChannelNotify.all && nonActive) {
              SfxService.instance.play(UiSound.messageReceived);
            }
          }
          // Toast del SO: SOLO con la ventana sin foco (decisión del usuario).
          if (notificationsEnabled &&
              !dnd &&
              !windowFocused &&
              mode != ChannelNotify.muted &&
              (isMention || mode == ChannelNotify.all)) {
            final author = users[m.authorId]?.username ?? 'Alguien';
            final chName = channels[m.channelId]?.name ?? 'canal';
            var body = m.content.trim();
            if (body.length > 140) body = '${body.substring(0, 140)}…';
            NotificationService.instance.show(
              title: '$author en #$chName',
              body: body,
              channelId: m.channelId,
            );
          }
        }
        break;
      case 'MESSAGE_UPDATE':
        final m = Message.fromJson(d);
        final list = messages[m.channelId];
        if (list != null) {
          final i = list.indexWhere((x) => x.id == m.id);
          if (i >= 0) list[i] = m;
        }
        break;
      case 'MESSAGE_DELETE':
        messages[d['channel_id']]?.removeWhere((m) => m.id == d['id']);
        break;
      case 'TYPING':
        (typing[d['channel_id']] ??= {})[d['user_id']] =
            DateTime.now().millisecondsSinceEpoch + 8000;
        break;
      case 'PRESENCE_UPDATE':
        d['online'] == true ? online.add(d['user_id']) : online.remove(d['user_id']);
        break;
      case 'MEMBER_JOIN':
      case 'MEMBER_UPDATE':
        users[d['id']] = User.fromJson(d);
        break;
      case 'MEMBER_REMOVE':
        users.remove(d['user_id']);
        memberRoles.remove(d['user_id']);
        if (d['user_id'] == me?.id) logout();
        break;
      case 'MEMBER_ROLES_UPDATE':
        memberRoles[d['user_id']] = {...(d['role_ids'] as List).cast<String>()};
        break;
      case 'CHANNEL_CREATE':
      case 'CHANNEL_UPDATE':
        channels[d['id']] = Channel.fromJson(d);
        break;
      case 'CHANNEL_DELETE':
        channels.remove(d['id']);
        messages.remove(d['id']);
        if (selectedChannelId == d['id']) selectedChannelId = null;
        break;
      case 'CATEGORY_CREATE':
        categories.add(Category.fromJson(d));
        break;
      case 'CATEGORY_UPDATE':
        final i = categories.indexWhere((c) => c.id == d['id']);
        if (i >= 0) categories[i] = Category.fromJson(d);
        categories.sort((a, b) => a.position.compareTo(b.position));
        break;
      case 'CATEGORY_DELETE':
        categories.removeWhere((c) => c.id == d['id']);
        break;
      case 'ROLE_CREATE':
      case 'ROLE_UPDATE':
        roles[d['id']] = Role.fromJson(d);
        break;
      case 'ROLE_DELETE':
        roles.remove(d['id']);
        for (final s in memberRoles.values) {
          s.remove(d['id']);
        }
        break;
      case 'OVERWRITE_SET':
        final ow = Overwrite.fromJson(d);
        final list = overwrites[ow.channelId] ??= [];
        list.removeWhere((o) => o.targetId == ow.targetId);
        list.add(ow);
        break;
      case 'OVERWRITE_DELETE':
        overwrites[d['channel_id']]?.removeWhere((o) => o.targetId == d['target_id']);
        break;
      case 'VOICE_STATE':
        final uid = d['user_id'] as String;
        final prev = voiceStates[uid]?.channelId; // canal previo del usuario
        final next = d['channel_id'] as String?;  // canal nuevo (null = salió)
        if (next == null) {
          voiceStates.remove(uid);
        } else {
          voiceStates[uid] = VoiceState.fromJson(d);
        }
        // SFX: solo por OTROS usuarios, y solo respecto al canal en el que YO
        // estoy. Mi propio canal de voz = el voiceState de mi id.
        if (uid != me?.id) {
          final myChannel = voiceStates[me?.id]?.channelId;
          if (myChannel != null) {
            final enteredMine = next == myChannel && prev != myChannel;
            final leftMine = prev == myChannel && next != myChannel;
            if (enteredMine) {
              SfxService.instance.play(UiSound.voiceUserJoin);
            } else if (leftMine) {
              SfxService.instance.play(UiSound.voiceUserLeave);
            }
          }
        }
        break;
      case 'SOUND_PLAY':
        final snd = Sound.fromJson(d['sound']);
        onSoundPlay?.call(snd, d['channel_id']);
        break;
      case 'STICKER_CREATE':
        stickers = [...stickers, Sticker.fromJson(d)]..sort((a, b) => a.name.compareTo(b.name));
        break;
      case 'STICKER_DELETE':
        stickers = stickers.where((s) => s.id != d['id']).toList();
        break;
      case 'SOUND_CREATE':
        sounds = [...sounds, Sound.fromJson(d)]..sort((a, b) => a.name.compareTo(b.name));
        break;
      case 'SOUND_DELETE':
        sounds = sounds.where((s) => s.id != d['id']).toList();
        break;
      case 'COMMANDS_UPDATE':
        commands = (d as List).map((c) => BotCommand.fromJson(c)).toList();
        break;
    }
    notifyListeners();
  }

  void _applyReady(dynamic d) {
    me = User.fromJson(d['user']);
    everyoneRoleId = d['everyone_role_id'] ?? 'everyone';
    users
      ..clear()
      ..addEntries((d['users'] as List).map((u) => MapEntry(u['id'], User.fromJson(u))));
    roles
      ..clear()
      ..addEntries((d['roles'] as List).map((r) => MapEntry(r['id'], Role.fromJson(r))));
    categories = (d['categories'] as List).map((c) => Category.fromJson(c)).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    channels
      ..clear()
      ..addEntries((d['channels'] as List).map((c) => MapEntry(c['id'], Channel.fromJson(c))));
    memberRoles.clear();
    for (final mr in d['member_roles'] as List) {
      (memberRoles[mr['user_id']] ??= {}).add(mr['role_id']);
    }
    overwrites.clear();
    for (final o in d['overwrites'] as List) {
      (overwrites[o['channel_id']] ??= []).add(Overwrite.fromJson(o));
    }
    stickers = (d['stickers'] as List).map((s) => Sticker.fromJson(s)).toList();
    sounds = (d['sounds'] as List).map((s) => Sound.fromJson(s)).toList();
    commands = (d['commands'] as List).map((c) => BotCommand.fromJson(c)).toList();
    online
      ..clear()
      ..addAll((d['online'] as List).cast<String>());
    voiceStates
      ..clear()
      ..addEntries((d['voice_states'] as List)
          .map((v) => MapEntry(v['user_id'] as String, VoiceState.fromJson(v))));

    // selección inicial: primer canal de texto visible
    if (selectedChannelId == null || channels[selectedChannelId] == null) {
      final first = visibleChannels.where((c) => !c.isVoice).firstOrNull;
      if (first != null) selectChannel(first.id);
    }
  }

  @override
  void dispose() {
    _typingCleaner?.cancel();
    gateway.dispose();
    super.dispose();
  }
}
