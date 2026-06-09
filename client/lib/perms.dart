// Espejo exacto de server/src/perms.ts — misma resolución estilo Discord.
abstract final class P {
  static const administrator = 1 << 0;
  static const manageChannels = 1 << 1;
  static const manageRoles = 1 << 2;
  static const manageMessages = 1 << 3;
  static const manageWebhooks = 1 << 4;
  static const manageExpressions = 1 << 5;
  static const kickMembers = 1 << 6;
  static const banMembers = 1 << 7;
  static const createInvites = 1 << 8;
  static const viewChannel = 1 << 9;
  static const sendMessages = 1 << 10;
  static const embedLinks = 1 << 11;
  static const attachFiles = 1 << 12;
  static const mentionEveryone = 1 << 13;
  static const connect = 1 << 14;
  static const speak = 1 << 15;
  static const stream = 1 << 16;
  static const useSoundboard = 1 << 17;
  static const muteMembers = 1 << 18;
  static const moveMembers = 1 << 19;
}

const allPerms = (1 << 20) - 1;

/// Etiquetas en español para los editores de roles/permisos.
const permLabels = <int, (String, String)>{
  P.administrator: ('Administrador', 'Todos los permisos. Cuidado.'),
  P.manageChannels: ('Gestionar canales', 'Crear, editar y borrar canales y categorías'),
  P.manageRoles: ('Gestionar roles', 'Crear roles y editar permisos por canal'),
  P.manageMessages: ('Gestionar mensajes', 'Borrar mensajes de otros'),
  P.manageWebhooks: ('Gestionar webhooks', 'Crear y borrar webhooks'),
  P.manageExpressions: ('Gestionar stickers y sonidos', 'Subir y borrar stickers/sonidos'),
  P.kickMembers: ('Expulsar miembros', ''),
  P.banMembers: ('Banear miembros', ''),
  P.createInvites: ('Crear invitaciones', ''),
  P.viewChannel: ('Ver canal', 'Ver el canal y leer mensajes'),
  P.sendMessages: ('Enviar mensajes', ''),
  P.embedLinks: ('Insertar enlaces', 'Vista previa de enlaces'),
  P.attachFiles: ('Adjuntar archivos', 'Subir imágenes, GIFs y archivos'),
  P.mentionEveryone: ('Mencionar @everyone', ''),
  P.connect: ('Conectar a voz', ''),
  P.speak: ('Hablar', ''),
  P.stream: ('Compartir pantalla', ''),
  P.useSoundboard: ('Usar soundboard', ''),
  P.muteMembers: ('Silenciar miembros', ''),
  P.moveMembers: ('Mover miembros', ''),
};
