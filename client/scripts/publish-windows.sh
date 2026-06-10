#!/usr/bin/env bash
# Compila el cliente para Windows EN LOCAL y sube el instalador al release de
# GitHub (el CI solo hace Linux). Pensado para correr desde WSL usando el
# Flutter de Windows vía interop.
#
# Uso:
#   client/scripts/publish-windows.sh            # versión = último release de gh
#   client/scripts/publish-windows.sh 0.1.7      # versión explícita
#
# Requisitos: Flutter Windows en C:\src\flutter, Inno Setup 6, gh autenticado,
# Modo desarrollador de Windows activado.
set -euo pipefail
cd "$(dirname "$0")/.."   # client/

REPO="servo98/chatAyPapol"
FLUTTER='C:\src\flutter\bin\flutter.bat'
ISCC='C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
WIN_CLIENT='C:\Users\ferna\Documents\code\chatpapol\client'

# 1) Versión: argumento o el último release publicado por el CI.
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(gh release view --repo "$REPO" --json tagName -q '.tagName' | sed 's/^v//')"
fi
echo "▶ Publicando Windows para v$VERSION"

# 2) Sellar la versión que se compila (igual que hace el CI).
echo "const appVersion = '$VERSION';" > lib/version.dart

# 3) Compilar Windows en local (rápido).
#    IMPORTANTE: pub get con el Flutter de WINDOWS. Si se corrió `flutter pub get`
#    o `flutter analyze` con el Flutter de WSL, package_config.json queda con
#    rutas /root/... (Linux) y el build de Windows falla. Esto lo recompone.
echo "▶ flutter pub get (Windows) + build windows --release"
cmd.exe /c "cd /d $WIN_CLIENT && $FLUTTER pub get"
cmd.exe /c "cd /d $WIN_CLIENT && $FLUTTER build windows --release"

# 4) Empaquetar el .zip del bundle (sirve para primera instalación Y para el
#    updater in-app). Archivos en la RAÍZ del zip (chatpapol.exe, dll, data/).
CLIENT_DIR="$PWD"
BUNDLE="$CLIENT_DIR/build/windows/x64/runner/Release"
[ -f "$BUNDLE/chatpapol.exe" ] || { echo "✗ No se generó el build de Windows"; exit 1; }
mkdir -p "$CLIENT_DIR/packaging/out"
ZIP="$CLIENT_DIR/packaging/out/ChatPapol-windows-$VERSION.zip"
rm -f "$ZIP"
( cd "$BUNDLE" && zip -qr -X "$ZIP" . )
echo "▶ Paquete: $ZIP ($(du -h "$ZIP" 2>/dev/null | cut -f1))"

# 5) Subir al release vX.Y.Z (espera a que el CI lo haya creado). --clobber
#    reemplaza si ya existía.
echo "▶ Esperando a que exista el release v$VERSION..."
for i in $(seq 1 60); do
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then break; fi
  sleep 5
done
echo "▶ Subiendo paquete Windows al release"
gh release upload "v$VERSION" "$ZIP" --repo "$REPO" --clobber
echo "✓ Listo: Windows v$VERSION publicado en el release"
