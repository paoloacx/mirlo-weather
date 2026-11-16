#!/bin/bash
# Empaqueta la compilación independiente para pruebas locales.
#
# IMPORTANTE: este .zip es solo para uso interno. El canal oficial de
# distribución es la App Store. No publiques este archivo ni crees releases
# en GitHub con él.
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
ZIP="dist/MirloWeather-$VERSION-interno.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP" || exit 1

echo
echo "Listo: $ZIP"
shasum -a 256 "$ZIP"
echo
echo "Solo para pruebas internas. La descarga oficial es la App Store."
