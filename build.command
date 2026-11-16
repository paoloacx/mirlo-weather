#!/bin/bash
# Compila Mirlo Weather.app (app nativa de barra de menus). No instala nada:
# usa las herramientas de desarrollo de Apple que haya en el Mac.
# Uso: doble clic en este archivo o ./build.command
cd "$(dirname "$0")" || exit 1
echo "== Compilando Mirlo Weather.app =="

SWIFTC="$(xcrun -f swiftc 2>/dev/null)"
if [ -z "$SWIFTC" ]; then
  echo "ERROR: no encuentro swiftc."
  echo "Instala las herramientas de desarrollo con: xcode-select --install"
  exit 1
fi
echo "swiftc: $SWIFTC ($("$SWIFTC" --version 2>&1 | head -1))"

SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"
if [ -z "$SDK" ]; then
  echo "ERROR: no encuentro el SDK de macOS. Abre Xcode una vez o instala"
  echo "las Command Line Tools con: xcode-select --install"
  exit 1
fi
echo "SDK: $SDK"

ARCH="$(uname -m)"
DESTINO="$ARCH-apple-macosx12.0"
echo "Destino: $DESTINO (compatible macOS 12 en adelante)"

# Se compila y firma fuera del Escritorio: iCloud/FileProvider mete atributos
# extendidos que hacen fallar a codesign.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/netatmo-free-build.XXXXXX")"
TMP="$STAGE/Mirlo Weather.app"
mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources"
trap 'rm -rf "$STAGE"' EXIT

if ! "$SWIFTC" -O -sdk "$SDK" -target "$DESTINO" main.swift Avisos.swift Updater.swift SettingsWindow.swift BuscarEstacionWindow.swift Localidad.swift OnboardingWindow.swift Localization.swift \
    -o "$TMP/Contents/MacOS/NetatmoFree" 2> build-errores.txt; then
  echo "ERROR de compilación (salida exacta en build-errores.txt):"
  cat build-errores.txt
  echo "No se ha tocado la app anterior."
  exit 1
fi

cp Info.plist "$TMP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$TMP/Contents/Resources/AppIcon.icns"
fi
if [ -d AppStore/es.lproj ]; then
  cp -R AppStore/es.lproj "$TMP/Contents/Resources/"
fi
if [ -d AppStore/en.lproj ]; then
  cp -R AppStore/en.lproj "$TMP/Contents/Resources/"
fi
xattr -cr "$TMP" 2>/dev/null

IDENTIDAD="${CODESIGN_IDENTITY:-}"
NOMBRE_IDENTIDAD=""
if [ -z "$IDENTIDAD" ]; then
  LINEA=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' | head -1)
  if [ -z "$LINEA" ]; then
    LINEA=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development:' | head -1)
  fi
  if [ -n "$LINEA" ]; then
    IDENTIDAD=$(printf '%s\n' "$LINEA" | awk '{print $2}')
    NOMBRE_IDENTIDAD=$(printf '%s\n' "$LINEA" | awk -F'"' '{print $2}')
  fi
fi

FIRMA_OK=0
if [ -n "$IDENTIDAD" ]; then
  echo "Firma: ${NOMBRE_IDENTIDAD:-$IDENTIDAD}"
  if codesign --force --options runtime --timestamp --sign "$IDENTIDAD" "$TMP" 2> firma-errores.txt; then
    FIRMA_OK=1
  elif codesign --force --options runtime --sign "$IDENTIDAD" "$TMP" 2> firma-errores.txt; then
    echo "(sin sello de tiempo: el servidor de Apple no respondió)"
    FIRMA_OK=1
  fi
else
  echo "Firma: ad-hoc (no hay identidad de desarrollador)"
fi
if [ "$FIRMA_OK" = "0" ]; then
  echo "Se intenta firma ad-hoc."
  if ! codesign --force --sign - "$TMP" 2> firma-errores.txt; then
    echo "ERROR al firmar (salida exacta en firma-errores.txt):"
    cat firma-errores.txt
    echo "No se ha tocado la app anterior."
    exit 1
  fi
fi

rm -rf "Mirlo Weather.app"
ditto "$TMP" "Mirlo Weather.app"
xattr -cr "Mirlo Weather.app" 2>/dev/null || true
chmod +x "Mirlo Weather.app/Contents/MacOS/NetatmoFree"

# Notification Center guarda el icono por bundle ID y puede quedarse con el
# genérico si la primera notificación llega antes de registrar el bundle.
# Registrarlo en Launch Services en cuanto está firmado evita ese estado.
LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSR" ]; then
  "$LSR" -f -R -trusted "$PWD/Mirlo Weather.app" >/dev/null 2>&1 || true
fi
echo "Listo: Mirlo Weather.app"
echo "Ábrela desde esta carpeta o muévela a Aplicaciones."
