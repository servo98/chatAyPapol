#!/usr/bin/env bash
# Release de UNA sola pasada (cierra el hueco del build de Windows manual):
#   1. Pushea lo que tengas commiteado en main.
#   2. Espera a que el CI cree el release nuevo (compila Linux/AppImage).
#   3. Compila + FIRMA + sube el Windows (Setup.exe + zip) a ese mismo release.
#
# Uso:
#   ./release.sh
#
# Notas:
#   - Commitea ANTES lo que quieras soltar (este script no commitea por ti).
#   - El CI solo crea release si el push toca client/** (o si empujas un tag
#     vX.Y.0 a mano para subir minor/major). Si no hay release nuevo, el script
#     te avisa y NO intenta subir Windows.
set -euo pipefail
cd "$(dirname "$0")"
REPO="servo98/chatAyPapol"

latest_tag() { gh release view --repo "$REPO" --json tagName -q '.tagName' 2>/dev/null || echo "none"; }

BEFORE="$(latest_tag)"
echo "▶ Release actual antes de pushear: $BEFORE"

echo "▶ git push"
git push

echo "▶ Esperando a que el CI cree un release nuevo (compila Linux)…"
NEWTAG=""
for i in $(seq 1 90); do          # hasta ~7.5 min
  cur="$(latest_tag)"
  if [ "$cur" != "$BEFORE" ] && [ "$cur" != "none" ]; then NEWTAG="$cur"; break; fi
  sleep 5
done

if [ -z "$NEWTAG" ]; then
  echo "⚠ No apareció un release nuevo (¿el push no tocó client/** o llevaba [skip release]?)."
  echo "  No hay Windows que subir. Si querías soltar versión, revisa el push."
  exit 0
fi

VERSION="${NEWTAG#v}"
echo "▶ Release nuevo: $NEWTAG → compilando Windows local"
client/scripts/publish-windows.sh "$VERSION"

echo ""
echo "✓ Release $NEWTAG completo:"
gh release view "$NEWTAG" --repo "$REPO" --json assets -q '.assets[] | "   - " + .name'
echo "   https://github.com/$REPO/releases/tag/$NEWTAG"
