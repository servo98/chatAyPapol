# Empaquetado del cliente

La versión de la app vive en `lib/version.dart` (`appVersion`). Súbela antes de publicar.

## Camino fácil: GitHub Releases (recomendado, no alojas nada)

1. Sube el repo a GitHub (público) y pon `GITHUB_REPO=usuario/repo` en el `.env` del server.
2. Publica con: `git tag v0.2.0 && git push origin v0.2.0`.
3. La CI (`.github/workflows/release.yml`) compila Windows + Linux y crea la release.
4. Los clientes preguntan a tu server → el server espeja `releases/latest` de GitHub →
   descargan el instalador directo del CDN de GitHub y se actualizan solos.

Lo de abajo es el camino manual (self-hosted), por si prefieres no depender de GitHub.

## Windows (instalador Inno Setup)

```powershell
flutter build windows --release
# instala Inno Setup 6 (winget install JRSoftware.InnoSetup) y luego:
iscc packaging\installer.iss
# → packaging\out\chatpapol-setup-<version>.exe
```

El updater ejecuta el instalador nuevo con `/SILENT /CLOSEAPPLICATIONS`, así que
publicar una versión = subirla al server:

```bash
curl -X POST $BASE/api/updates/windows \
  -H "Authorization: Bearer <token-admin>" \
  -F file=@packaging/out/chatpapol-setup-1.2.0.exe -F version=1.2.0 -F notes="fixes"
```

## Linux (AppImage)

```bash
flutter build linux --release
./packaging/make-appimage.sh        # → packaging/out/ChatPapol-<version>-x86_64.AppImage
curl -X POST $BASE/api/updates/linux \
  -H "Authorization: Bearer <token-admin>" \
  -F file=@packaging/out/ChatPapol-1.2.0-x86_64.AppImage -F version=1.2.0
```

En Linux el updater descarga el AppImage nuevo, lo hace ejecutable y reemplaza
el archivo actual (`$APPIMAGE`), relanzando la app.

## macOS

Fase 2 (firma + notarización). El updater ya soporta la plataforma `macos`
en el manifiesto cuando llegue el momento.
