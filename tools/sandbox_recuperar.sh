#!/bin/bash
# Recuperación completa del sandbox de desarrollo de AntLex OS.
# El sandbox se recicla entre sesiones (vuelve a un snapshot viejo); todo
# el trabajo duradero vive en GitHub. Este script reconstruye el entorno:
#   1) sincroniza el repo a origin/main (token de /home/z/my-project/.token)
#   2) instala zig 0.14.1, nasm y QEMU+OVMF en /home/z/my-project/toolchain
#   3) verifica con un build completo
# Uso:  cd /home/z/my-project/AntLexOS && bash tools/sandbox_recuperar.sh
set -euo pipefail
TC=/home/z/my-project/toolchain
REPO=/home/z/my-project/AntLexOS
mkdir -p "$TC"

# ---- 1) repo a origin/main -------------------------------------------------
cd "$REPO"
git config core.fileMode false
if [ -f /home/z/my-project/.token ]; then
  TOK=$(cat /home/z/my-project/.token)
  git remote set-url origin "https://juanruiz85:${TOK}@github.com/juanruiz85/AntLexOS.git"
  git fetch origin --tags --quiet
  git remote set-url origin "https://github.com/juanruiz85/AntLexOS.git"
  git config credential.helper '!f(){ echo username=juanruiz85; echo password=$(cat /home/z/my-project/.token); }; f'
  git config user.name juanruiz85
  git config user.email juanruiz85@users.noreply.github.com
fi
git pull --ff-only origin main
echo "repo en: $(git log --oneline -1)"

# ---- 2) toolchain -----------------------------------------------------------
if [ ! -x "$TC/zig-x86_64-linux-0.14.1/zig" ]; then
  echo "== instalando zig 0.14.1 =="
  cd "$TC"
  curl -sL https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz -o zig.tar.xz
  tar -xJf zig.tar.xz
fi
"$TC/zig-x86_64-linux-0.14.1/zig" version
if [ ! -x "$TC/nasm/bin/nasm" ]; then
  echo "== compilando nasm 2.16.03 =="
  mkdir -p "$TC/nasm-build" && cd "$TC/nasm-build"
  curl -sL https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/nasm-2.16.03.tar.gz -o nasm.tar.gz
  tar -xzf nasm.tar.gz && cd nasm-2.16.03
  ./configure --prefix="$TC/nasm" > /dev/null && make -j2 > /dev/null && make install > /dev/null
fi
"$TC/nasm/bin/nasm" -v
if [ ! -x "$TC/qemu-root/usr/bin/qemu-system-x86_64" ]; then
  echo "== instalando QEMU+OVMF (extracción de .deb) =="
  bash "$REPO/tools/sandbox_qemu.sh"
fi
"$TC/qemu-root/usr/bin/qemu-system-x86_64" --version | head -1

# ---- 3) verificación --------------------------------------------------------
source "$REPO/tools/sandbox_entorno.sh"
cd "$REPO"
zig build -Drelease=true 2>&1 | grep -E "kernel:|ISO lista" | head -3 || true
echo "RECUPERACIÓN COMPLETA (source tools/sandbox_entorno.sh para trabajar)"
