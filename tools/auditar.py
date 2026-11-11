#!/usr/bin/env python3
"""AntLex OS — auditoría rápida de seguridad y calidad (CI y uso local).

Comprueba:
  * que no haya secretos (tokens, claves, contraseñas) en el repositorio
  * que no queden marcadores TODO/FIXME/XXX en el código del kernel
  * que VERSION y src/kernel/version.zig estén sincronizadas
  * que la licencia esté presente

Sale con código 1 si encuentra cualquier problema.
"""
import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PATRONES_SECRETO = [
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{16,}"), "token de GitHub"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "token fino de GitHub"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "clave de acceso AWS"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "clave privada"),
    (re.compile(r"(?i)(password|passwd|secret)\s*[:=]\s*['\"][^'\"]{6,}"), "credencial"),
]

MARCADORES = re.compile(r"\b(TODO|FIXME|XXX)\b")

IGNORAR_DIRS = {".git", ".zig-cache", "zig-out", "build", "toolchain", "node_modules", "dist"}


def es_ignorada(nombre_dir):
    if nombre_dir in IGNORAR_DIRS:
        return True
    # toolchains de zig extraídos dentro del workspace (p. ej. por CI antigua)
    if nombre_dir.startswith("zig-x86_64") or nombre_dir.startswith("zig-aarch64"):
        return True
    return False
EXTENSIONES = {".zig", ".asm", ".py", ".sh", ".yml", ".yaml", ".md", ".txt", ".zon", ".ld"}

problemas = []


def escanear():
    for dirpath, dirnames, filenames in os.walk(RAIZ):
        dirnames[:] = [d for d in dirnames if not es_ignorada(d)]
        for nombre in filenames:
            ruta = os.path.join(dirpath, nombre)
            ext = os.path.splitext(nombre)[1]
            if ext not in EXTENSIONES:
                continue
            try:
                with open(ruta, "r", errors="replace") as f:
                    contenido = f.read()
            except OSError:
                continue
            rel = os.path.relpath(ruta, RAIZ)
            for patron, descripcion in PATRONES_SECRETO:
                if patron.search(contenido):
                    problemas.append(f"SECRETO ({descripcion}): {rel}")
            if rel.startswith("src/") and ext == ".zig" and MARCADORES.search(contenido):
                problemas.append(f"MARCADOR TODO/FIXME en código del kernel: {rel}")


def comprobar_version():
    version_txt = None
    try:
        with open(os.path.join(RAIZ, "VERSION")) as f:
            version_txt = f.read().strip()
    except FileNotFoundError:
        problemas.append("Falta el archivo VERSION")
    try:
        with open(os.path.join(RAIZ, "src/kernel/version.zig")) as f:
            contenido = f.read()
        m = re.search(r'pub const VERSION = "([^"]+)"', contenido)
        if not m:
            problemas.append("src/kernel/version.zig sin VERSION")
        elif version_txt and m.group(1) != version_txt:
            problemas.append(
                f"Versión desincronizada: VERSION={version_txt} version.zig={m.group(1)}"
            )
    except FileNotFoundError:
        problemas.append("Falta src/kernel/version.zig")
    if not os.path.exists(os.path.join(RAIZ, "LICENSE")):
        problemas.append("Falta LICENSE")


if __name__ == "__main__":
    escanear()
    comprobar_version()
    if problemas:
        print("== AUDITORÍA: FALLA ==")
        for p in problemas:
            print("  -", p)
        sys.exit(1)
    print("== AUDITORÍA: PASA (sin secretos, sin marcadores, versión sincronizada) ==")
