#!/bin/bash
# AntLex OS — empaquetado de binarios para el release (lo invoca CI en cada tag)
# Genera en dist/: imagen de disco, tarball de código fuente y SHA256SUMS.
# Las fases posteriores añaden aquí la ISO y los bundles portables con QEMU
# (tools/mkiso.zig y tools/empaquetar_portable.sh se enganchan cuando existan).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${GITHUB_REF_NAME:-$(cat VERSION)}"
VER="${TAG#v}"
DIST=dist
rm -rf "$DIST"
mkdir -p "$DIST"

# 1) imagen de disco
cp zig-out/antlexos.img "$DIST/antlexos-v${VER}-x86_64.img"

# 2) código fuente reproducible (git archive del tag o del árbol actual)
if git rev-parse "v${VER}" >/dev/null 2>&1; then
    git archive --format=tar.gz --prefix="antlexos-v${VER}/" "v${VER}" \
        -o "$DIST/antlexos-v${VER}-src.tar.gz"
else
    git archive --format=tar.gz --prefix="antlexos-v${VER}/" HEAD \
        -o "$DIST/antlexos-v${VER}-src.tar.gz"
fi

# 3) extras opcionales (añadidos por fases posteriores)
[ -f zig-out/antlexos.iso ] && cp zig-out/antlexos.iso "$DIST/antlexos-v${VER}-x86_64.iso"
[ -d zig-out/portable-linux ] && cp -r zig-out/portable-linux "$DIST/"
[ -d zig-out/portable-windows ] && cp -r zig-out/portable-windows "$DIST/"

# 4) sumas de verificación
( cd "$DIST" && sha256sum * > SHA256SUMS )

# 5) notas del release (sección del CHANGELOG para este tag)
python3 - "$VER" > "$DIST/NOTAS.md" <<'EOF'
import re
import sys
ver = sys.argv[1]
texto = open("CHANGELOG.md", encoding="utf-8").read()
seccion = re.search(r"## \[v" + re.escape(ver) + r"\]\n(.*?)(?=\n## \[v|\Z)", texto, re.S)
print(seccion.group(1).strip() if seccion else f"AntLex OS v{ver}")
EOF

echo "== dist/ listo =="
ls -la "$DIST"
