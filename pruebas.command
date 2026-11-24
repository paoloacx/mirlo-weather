#!/bin/bash
# Pruebas mínimas de la lógica de Mirlo Weather.
# Compilan el código real de Avisos.swift con unos apoyos de prueba y ejecutan
# la suite. No tocan la configuración real: usan una carpeta temporal.
cd "$(dirname "$0")" || exit 1

SWIFTC="$(xcrun -f swiftc 2>/dev/null)"
if [ -z "$SWIFTC" ]; then
  echo "ERROR: no encuentro swiftc."
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"
if [ -z "$SDK" ]; then
  echo "ERROR: no encuentro el SDK de macOS."
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mirlo-pruebas.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "== Compilando pruebas =="
if ! "$SWIFTC" -O -sdk "$SDK" -target "$(uname -m)-apple-macosx12.0" \
  Avisos.swift Localidad.swift Localization.swift Tests/Apoyo.swift Tests/main.swift \
  -o "$STAGE/pruebas"; then
  echo "ERROR: las pruebas no compilan."
  exit 1
fi

echo "== Ejecutando pruebas =="
"$STAGE/pruebas"
RESULTADO=$?

echo ""
echo "== Claves de localización =="
python3 Tests/claves.py || RESULTADO=1

exit $RESULTADO
