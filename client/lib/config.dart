/// URL fija del servidor. Los usuarios no eligen server: esto ES ChatPapol.
/// Para desarrollo se puede sobreescribir sin tocar código:
///   flutter run -d windows --dart-define=CHATPAPOL_SERVER=http://localhost:3210
const serverUrl = String.fromEnvironment(
  'CHATPAPOL_SERVER',
  defaultValue: 'https://chat.aypapol.com',
);
