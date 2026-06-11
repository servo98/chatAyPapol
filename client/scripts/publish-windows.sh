#!/usr/bin/env bash
# Compila el cliente para Windows EN LOCAL, FIRMA los binarios, arma el
# instalador (Setup.exe auto-extraíble) y sube todo al release de GitHub.
# El CI solo hace Linux. Pensado para correr desde WSL con el Flutter de Windows.
#
# Uso:
#   client/scripts/publish-windows.sh            # versión = último release de gh
#   client/scripts/publish-windows.sh 0.1.8      # versión explícita
#
# Requisitos: Flutter Windows en C:\src\flutter, 7zip (WSL), gh autenticado,
# Modo desarrollador de Windows activado. Para FIRMAR (recomendado): el PFX en
# CHATPAPOL_PFX (default abajo) — evita que Windows Defender borre el Setup.
set -euo pipefail
cd "$(dirname "$0")/.."   # client/
CLIENT_DIR="$PWD"

REPO="servo98/chatAyPapol"
FLUTTER='C:\src\flutter\bin\flutter.bat'
WIN_CLIENT='C:\Users\ferna\Documents\code\chatpapol\client'
SIGNTOOL="/mnt/c/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/signtool.exe"
PFX="${CHATPAPOL_PFX:-/mnt/c/Users/ferna/Downloads/chatpapol-toolchain/chatpapol-signing.pfx}"
PFX_PASS="${CHATPAPOL_PFX_PASS:-chatpapol}"
PFX_WIN="$(wslpath -w "$PFX" 2>/dev/null || echo "$PFX")"

sign() { # firma un .exe (ruta Windows). No-op si no hay PFX.
  [ -f "$PFX" ] || { echo "  (sin PFX: $1 sin firmar)"; return 0; }
  "$SIGNTOOL" sign /f "$PFX_WIN" /p "$PFX_PASS" /fd SHA256 /d ChatPapol "$1" >/dev/null
  echo "  firmado: $(basename "$1")"
}

# 1) Versión.
VERSION="${1:-}"
[ -z "$VERSION" ] && VERSION="$(gh release view --repo "$REPO" --json tagName -q '.tagName' | sed 's/^v//')"
echo "▶ Publicando Windows v$VERSION"

# 2) Sellar versión (igual que el CI). pub get + build con Flutter de WINDOWS
#    (si se usó el Flutter de WSL, package_config.json queda con rutas Linux).
echo "const appVersion = '$VERSION';" > lib/version.dart
echo "▶ flutter pub get + build windows --release"
cmd.exe /c "cd /d $WIN_CLIENT && $FLUTTER pub get"
cmd.exe /c "cd /d $WIN_CLIENT && $FLUTTER build windows --release"

BUNDLE="$CLIENT_DIR/build/windows/x64/runner/Release"
BUNDLE_WIN='C:\Users\ferna\Documents\code\chatpapol\client\build\windows\x64\runner\Release'
[ -f "$BUNDLE/chatpapol.exe" ] || { echo "✗ No se generó el build"; exit 1; }

# 3) Firmar el ejecutable de la app.
echo "▶ Firmando binarios"
sign "$BUNDLE_WIN\\chatpapol.exe"

mkdir -p "$CLIENT_DIR/packaging/out"

# 4) .zip del bundle (para el updater in-app). Archivos en la raíz.
ZIP="$CLIENT_DIR/packaging/out/ChatPapol-windows-$VERSION.zip"
rm -f "$ZIP"; ( cd "$BUNDLE" && zip -qr -X "$ZIP" . )
echo "▶ Paquete update: $(du -h "$ZIP" | cut -f1)"

# 5) Setup.exe auto-extraíble (primera instalación) = 7zSD.sfx + config + .7z,
#    luego firmado para que Defender no lo borre.
APP7Z="$CLIENT_DIR/packaging/out/app.7z"
rm -f "$APP7Z"; ( cd "$BUNDLE" && 7z a -t7z -mx=5 "$APP7Z" . >/dev/null )
SETUP="$CLIENT_DIR/packaging/out/ChatPapolSetup-$VERSION.exe"
cat "$CLIENT_DIR/packaging/7zSD.sfx" "$CLIENT_DIR/packaging/sfx-config.txt" "$APP7Z" > "$SETUP"
rm -f "$APP7Z"
echo "▶ Instalador: $(du -h "$SETUP" | cut -f1)"
sign "$(wslpath -w "$SETUP")"

# Copia con nombre FIJO (sin versión): permite que la landing use un link
# permanente .../releases/latest/download/ChatPapolSetup.exe (HTML puro, sin JS).
SETUP_LATEST="$CLIENT_DIR/packaging/out/ChatPapolSetup.exe"
cp "$SETUP" "$SETUP_LATEST"

# 6) Subir al release (espera a que el CI lo cree).
echo "▶ Esperando release v$VERSION…"
for i in $(seq 1 90); do
  gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && break || sleep 5
done
echo "▶ Subiendo Setup (versionado + fijo) + zip"
gh release upload "v$VERSION" "$SETUP" "$SETUP_LATEST" "$ZIP" --repo "$REPO" --clobber
git checkout lib/version.dart 2>/dev/null || true
echo "✓ Listo: Windows v$VERSION (Setup firmado + zip) publicado"