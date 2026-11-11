#!/bin/bash
# AntLex OS — CLI de publicación de versiones.
#
#   ./tools/release.sh <versión> "<resumen corto>"
#
# Qué hace:
#   1. comprueba que el árbol esté limpio y las pruebas pasen
#   2. sincroniza VERSION y src/kernel/version.zig
#   3. añade la entrada al CHANGELOG (sección del tag)
#   4. commitea (autor: juanruiz85), etiqueta v<versión> y empuja
#   5. GitHub Actions construye y publica el release con binarios
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 2 ]; then
    echo "uso: tools/release.sh <versión> \"<resumen>\"   (ej: tools/release.sh 0.2.0 \"Sistema de archivos ALFS\")"
    exit 1
fi

VER="$1"
RESUMEN="$2"

if ! command -v zig >/dev/null || ! command -v nasm >/dev/null; then
    echo "error: se necesitan zig y nasm en PATH" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "error: hay cambios sin commitear; haz commit primero" >&2
    exit 1
fi

echo "== compilando y probando antes de publicar =="
zig build -Drelease=true
zig build test
python3 tools/probar_boot.py zig-out/antlexos.img build/pruebas --tiempo 60
python3 tools/auditar.py

echo "$VER" > VERSION
sed -i "s/pub const VERSION = \"[^\"]*\";/pub const VERSION = \"$VER\";/" src/kernel/version.zig

FECHA=$(date +%Y-%m-%d)
python3 - "$VER" "$FECHA" "$RESUMEN" <<'EOF'
import sys
ver, fecha, resumen = sys.argv[1:4]
ruta = "CHANGELOG.md"
viejo = open(ruta, encoding="utf-8").read()
entrada = f"## [v{ver}] - {fecha}\n\n### {resumen}\n\n- Arranque, pruebas y artefactos: ver `docs/PRUEBAS.md` (versión {ver}).\n\n"
open(ruta, "w", encoding="utf-8").write(entrada + viejo)
EOF

git add -A
git commit -m "v${VER}: ${RESUMEN}"
git tag -a "v${VER}" -m "AntLex OS v${VER} — ${RESUMEN}"
git push origin main --tags

echo "== v${VER} publicada: GitHub Actions está construyendo el release =="
