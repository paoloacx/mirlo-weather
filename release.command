#!/bin/bash
# Genera el .zip que se adjunta a una release de GitHub.
# Uso: ./release.command
cd "$(dirname "$0")" || exit 1

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null)"
if [ -z "$VERSION" ]; then
  echo "ERROR: no se pudo leer CFBundleShortVersionString de Info.plist."
  exit 1
fi

./build.command || exit 1

APP="Mirlo Weather.app"
if [ ! -d "$APP" ]; then
  echo "ERROR: no se generó $APP."
  exit 1
fi

if ! codesign --verify --deep --strict "$APP" 2> /tmp/mirlo-release-sign.txt; then
  echo "ERROR: la firma de la app no es válida:"
  cat /tmp/mirlo-release-sign.txt
  exit 1
fi

mkdir -p dist
ZIP="dist/MirloWeather-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP" || exit 1

echo
echo "Listo: $ZIP"
shasum -a 256 "$ZIP"
echo
echo "Siguiente paso:"
echo "  1. Crea una release en GitHub con etiqueta v$VERSION."
echo "  2. Adjunta $ZIP como asset."
echo "  3. Publica la release."
