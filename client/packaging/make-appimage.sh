#!/usr/bin/env bash
# Construye un AppImage a partir de flutter build linux --release
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(grep -oP "appVersion = '\K[^']+" ../lib/version.dart)
BUILD=../build/linux/x64/release/bundle
[ -d "$BUILD" ] || { echo "Primero: flutter build linux --release"; exit 1; }

rm -rf AppDir out && mkdir -p AppDir/usr out
cp -r "$BUILD"/* AppDir/usr/
cat > AppDir/AppRun <<'EOF'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/chatpapol" "$@"
EOF
chmod +x AppDir/AppRun
cat > AppDir/chatpapol.desktop <<EOF
[Desktop Entry]
Name=ChatPapol
Exec=chatpapol
Icon=chatpapol
Type=Application
Categories=Network;Chat;
EOF
# icono placeholder (cámbialo por uno real en assets/)
cp ../assets/icon.png AppDir/chatpapol.png 2>/dev/null || \
  python3 -c "print()" > /dev/null && touch AppDir/chatpapol.png

if ! command -v appimagetool >/dev/null; then
  curl -fsSL -o /tmp/appimagetool https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x /tmp/appimagetool; TOOL=/tmp/appimagetool
else TOOL=appimagetool; fi
ARCH=x86_64 "$TOOL" AppDir "out/ChatPapol-${VERSION}-x86_64.AppImage"
echo "✓ out/ChatPapol-${VERSION}-x86_64.AppImage"
