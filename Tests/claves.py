#!/usr/bin/env python3
"""Comprueba que toda clave usada con L("...") existe en los .strings.

La clave es el texto en español. Se ignoran los comentarios del código para no
confundir los ejemplos de la documentación con claves reales.
"""
import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
IDIOMAS = {
    "es": RAIZ / "AppStore/es.lproj/Localizable.strings",
    "en": RAIZ / "AppStore/en.lproj/Localizable.strings",
}


def sin_comentarios(texto: str) -> str:
    salida = []
    i = 0
    en_cadena = False
    while i < len(texto):
        c = texto[i]
        if en_cadena:
            salida.append(c)
            if c == "\\" and i + 1 < len(texto):
                salida.append(texto[i + 1])
                i += 2
                continue
            if c == '"':
                en_cadena = False
            i += 1
            continue
        if c == '"':
            en_cadena = True
            salida.append(c)
            i += 1
            continue
        if texto.startswith("//", i):
            fin = texto.find("\n", i)
            if fin == -1:
                break
            salida.append("\n")
            i = fin + 1
            continue
        salida.append(c)
        i += 1
    return "".join(salida)


def claves_usadas() -> set[str]:
    claves = set()
    for archivo in sorted(RAIZ.glob("*.swift")):
        texto = sin_comentarios(archivo.read_text(encoding="utf-8"))
        claves.update(re.findall(r'L\(\s*"((?:[^"\\]|\\.)*)"', texto))
    return claves


def claves_definidas(archivo: Path) -> set[str]:
    texto = archivo.read_text(encoding="utf-8")
    return set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"', texto, re.MULTILINE))


def main() -> int:
    usadas = claves_usadas()
    if not usadas:
        print("No se ha encontrado ninguna clave L(...).")
        return 1

    problemas = 0
    print(f"{len(usadas)} claves usadas en el código.")
    for idioma, archivo in IDIOMAS.items():
        definidas = claves_definidas(archivo)
        faltan = sorted(usadas - definidas)
        if faltan:
            problemas += len(faltan)
            print(f"  FALTAN en {idioma}: {len(faltan)}")
            for clave in faltan:
                print(f"    {clave}")
        else:
            print(f"  ok    {idioma}: todas traducidas")
    return 1 if problemas else 0


if __name__ == "__main__":
    sys.exit(main())
