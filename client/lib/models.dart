class User {
  final String id;
  String username;
  String? avatar;
  final bool isBot;
  User.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        username = j['username'],
        avatar = j['avatar'],
        isBot = (j['is_bot'] ?? 0) != 0;
}

class Role {
  final String id;
  String name;
  String? color;
  int permissions;
  int position;
  final bool isEveryone;
  Role.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        color = j['color'],
        permissions = j['permissions'] ?? 0,
        position = j['position'] ?? 0,
        isEveryone = (j['is_everyone'] ?? 0) != 0;
}

class Category {
  final String id;
  String name;
  int position;
  Category.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        position = j['position'] ?? 0;
}

class Channel {
  final String id;
  String name;
  final String type; // text | voice
  String? categoryId;
  String? topic;
  int position;
  bool get isVoice => type == 'voice';
  Channel.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        type = j['type'],
        categoryId = j['category_id'],
        topic = j['topic'],
        position = j['position'] ?? 0;
}

class Attachment {
  final String name, url;
  final int size;
  final String type;
  bool get isImage => type.startsWith('image/');
  Attachment.fromJson(Map<String, dynamic> j)
      : name = j['name'] ?? 'archivo',
        url = j['url'] ?? '',
        size = j['size'] ?? 0,
        type = j['type'] ?? '';
}

class Embed {
  final String? url, title, description, image;
  Embed.fromJson(Map<String, dynamic> j)
      : url = j['url'],
        title = j['title'],
        description = j['description'],
        image = j['image'];
}

class Message {
  final String id, channelId;
  final String? authorId;
  String content;
  List<Attachment> attachments;
  List<Embed> embeds;
  final String? stickerId, replyTo, webhookName, webhookAvatar;
  final int createdAt;
  int? editedAt;
  Message.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        channelId = j['channel_id'],
        authorId = j['author_id'],
        content = j['content'] ?? '',
        attachments = ((j['attachments'] ?? []) as List)
            .map((a) => Attachment.fromJson(a)).toList(),
        embeds = ((j['embeds'] ?? []) as List).map((e) => Embed.fromJson(e)).toList(),
        stickerId = j['sticker_id'],
        replyTo = j['reply_to'],
        webhookName = j['webhook_name'],
        webhookAvatar = j['webhook_avatar'],
        createdAt = j['created_at'] ?? 0,
        editedAt = j['edited_at'];
}

class Sticker {
  final String id, name, url;
  Sticker.fromJson(Map<String, dynamic> j)
      : id = j['id'], name = j['name'], url = j['url'];
}

class Sound {
  final String id, name, url;
  final String? emoji;
  Sound.fromJson(Map<String, dynamic> j)
      : id = j['id'], name = j['name'], url = j['url'], emoji = j['emoji'];
}

class Overwrite {
  final String channelId, targetId, targetType;
  int allow, deny;
  Overwrite.fromJson(Map<String, dynamic> j)
      : channelId = j['channel_id'],
        targetId = j['target_id'],
        targetType = j['target_type'],
        allow = j['allow'] ?? 0,
        deny = j['deny'] ?? 0;
}

class VoiceState {
  final String userId;
  String channelId;
  bool mute, deaf, streaming;
  VoiceState.fromJson(Map<String, dynamic> j)
      : userId = j['user_id'],
        channelId = j['channel_id'],
        mute = j['mute'] ?? false,
        deaf = j['deaf'] ?? false,
        streaming = j['streaming'] ?? false;
}

class BotCommand {
  final String botId, name, description;
  BotCommand.fromJson(Map<String, dynamic> j)
      : botId = j['bot_id'], name = j['name'], description = j['description'] ?? '';
}
