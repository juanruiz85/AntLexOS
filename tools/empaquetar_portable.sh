#!/bin/bash
# =============================================================================
# AntLex OS — empaquetado portable (Fase 6)
#
#   ./tools/empaquetar_portable.sh <dir_zig_out> <dir_salida> <versión>
#
# Crea dos ZIP autónomos («descargar y probar sin instalar nada»):
#
#   antlexos-portable-linux-x86_64.zip
#     · QEMU 11 estático (hermeticbuild/qemu-prebuilt) + wrapper -L fw
#     · firmware propio (SeaBIOS/VGA BIOS/OVMF de los .deb de Debian)
#     · antlexos.img + antlexos.iso + lanzar.sh + lanzar-uefi.sh
#
#   antlexos-portable-windows-x86_64.zip
#     · qemu-system-x86_64.exe + la clausura EXACTA de DLLs extraída del
#       instalador oficial de Stefan Weil (7zz + tools/resolver_dlls.py)
#     · mismo firmware (son solo datos) + lanzar.bat + lanzar-uefi.bat
#
# Idempotente en las descargas (caché en <dir_salida>/cache) y verificable:
# el SHA-512 del instalador se comprueba contra el publicado por el autor.
# =============================================================================
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "uso: tools/empaquetar_portable.sh <dir_zig_out> <dir_salida> <version>" >&2
    exit 1
fi

ZIG_OUT=$(realpath "$1")
SALIDA=$(realpath "$2")
VER="$3"
CACHE="$SALIDA/cache"
mkdir -p "$SALIDA" "$CACHE"

IMG="$ZIG_OUT/antlexos.img"
ISO="$ZIG_OUT/antlexos.iso"
for f in "$IMG" "$ISO"; do
    [ -f "$f" ] || { echo "ERROR: falta $f (ejecuta zig build antes)" >&2; exit 1; }
done

descargar() { # descargar <url> <destino>
    if [ ! -s "$2" ]; then
        echo "  descargando $(basename "$2") …"
        curl -sL --retry 3 -o "$2" "$1"
    fi
}

# -----------------------------------------------------------------------------
# firmware común (SeaBIOS + VGA BIOS + OVMF + roms de red) desde los .deb
# -----------------------------------------------------------------------------
FW="$CACHE/fw"
if [ ! -f "$FW/bios-256k.bin" ]; then
    echo "== firmware (Debian: seabios, ovmf, ipxe, qemu-system-data) =="
    mkdir -p "$FW" "$CACHE/debs"
    cd "$CACHE/debs"
    curl -sL --retry 3 -o sb.deb "http://deb.debian.org/debian/pool/main/s/seabios/seabios_1.17.0-1_all.deb"
    curl -sL --retry 3 -o ovmf.deb "http://deb.debian.org/debian/pool/main/e/edk2/ovmf_2025.02-8+deb13u1_all.deb"
    curl -sL --retry 3 -o ipxe.deb "http://deb.debian.org/debian/pool/main/i/ipxe/ipxe-qemu_2.0.0+dfsg-5_all.deb"
    curl -sL --retry 3 -o qsd.deb "http://deb.debian.org/debian/pool/main/q/qemu/qemu-system-data_11.1.3+ds-1_all.deb"
    for d in sb ovmf ipxe qsd; do dpkg-deb -x "$d.deb" "$d"; done
    cp sb/usr/share/seabios/*.bin sb/usr/share/seabios/*.rom "$FW/" 2>/dev/null || true
    cp ovmf/usr/share/OVMF/OVMF_CODE_4M.fd ovmf/usr/share/OVMF/OVMF_VARS_4M.fd "$FW/"
    cp ipxe/usr/share/qemu/*.rom "$FW/"
    cp qsd/usr/share/qemu/kvmvapic.bin qsd/usr/share/qemu/qboot.rom "$FW/" 2>/dev/null || true
    cd - > /dev/null
fi

LEEME_PORTABLE="# AntLex OS v$VER — paquete portable

Descarga este ZIP, descomprímelo y ejecuta el lanzador: no hay que
instalar nada (QEMU va incluido).

  Windows:  doble clic en lanzar.bat      (o lanzar-uefi.bat para UEFI)
  Linux:    ./lanzar.sh                   (o ./lanzar-uefi.sh)

Verás el escritorio con el terminal a la izquierda, el chat de AntLex a
la derecha y la barra de tareas abajo. Teclea 'ayuda' para los comandos.

AntLex OS se distribuye bajo GPL-3.0. QEMU se distribuye bajo GPL-2.0
(linux: build estático de hermeticbuild/qemu-prebuilt; windows: build de
Stefan Weil, qemu.weilnetz.de). El firmware SeaBIOS/OVMF es software
libre de sus respectivos proyectos.
"

# -----------------------------------------------------------------------------
# 1) portable Linux
# -----------------------------------------------------------------------------
LIN="$SALIDA/portable-linux/antlexos"
if [ ! -f "$SALIDA/antlexos-portable-linux-x86_64.zip" ]; then
    echo "== portable Linux =="
    rm -rf "$SALIDA/portable-linux"
    mkdir -p "$LIN/qemu" "$LIN/fw"
    descargar "https://github.com/hermeticbuild/qemu-prebuilt/releases/download/11.0.0.1/qemu-system-bin-linux-amd64-x86_64-softmmu-11.0.0.1.tar.gz" "$CACHE/qemu-linux.tar.gz"
    mkdir -p "$CACHE/qemu-linux" && tar xzf "$CACHE/qemu-linux.tar.gz" -C "$CACHE/qemu-linux"
    cp "$CACHE/qemu-linux/bin/qemu-system-x86_64" "$LIN/qemu/qemu-system-x86_64.real"
    # wrapper: el binario estático no trae blobs; -L apunta al firmware local
    printf '#!/bin/sh\nDIR=$(dirname "$0")\nexec "$DIR/qemu-system-x86_64.real" -L "$DIR/../fw" "$@"\n' > "$LIN/qemu/qemu-system-x86_64"
    chmod +x "$LIN/qemu/qemu-system-x86_64" "$LIN/qemu/qemu-system-x86_64.real"
    cp "$FW"/*.bin "$FW"/*.rom "$FW"/*.fd "$LIN/fw/"

    cp "$IMG" "$ISO" "$LIN/"
    printf '#!/bin/sh\n# AntLex OS portable — arranque BIOS\ncd "$(dirname "$0")"\nexec ./qemu/qemu-system-x86_64 -m 512 -vga std -drive format=raw,file=antlexos.img "$@"\n' > "$LIN/lanzar.sh"
    printf '#!/bin/sh\n# AntLex OS portable — arranque UEFI (OVMF)\ncd "$(dirname "$0")"\n[ -f ovmf-vars.fd ] || cp fw/OVMF_VARS_4M.fd ovmf-vars.fd\nexec ./qemu/qemu-system-x86_64 -m 512 -vga std -drive format=raw,file=antlexos.img \\\n  -drive if=pflash,format=raw,file=fw/OVMF_CODE_4M.fd,readonly=on \\\n  -drive if=pflash,format=raw,file=ovmf-vars.fd "$@"\n' > "$LIN/lanzar-uefi.sh"
    chmod +x "$LIN/lanzar.sh" "$LIN/lanzar-uefi.sh"
    printf '%s\n' "$LEEME_PORTABLE" > "$LIN/LEEME-PORTABLE.txt"

    (cd "$SALIDA/portable-linux" && zip -qr "$SALIDA/antlexos-portable-linux-x86_64.zip" antlexos)
    echo "  creado antlexos-portable-linux-x86_64.zip ($(du -h "$SALIDA/antlexos-portable-linux-x86_64.zip" | cut -f1))"
fi

# -----------------------------------------------------------------------------
# 2) portable Windows
# -----------------------------------------------------------------------------
if [ ! -f "$SALIDA/antlexos-portable-windows-x86_64.zip" ]; then
    echo "== portable Windows =="
    QEMU_W64_VER="20260811"
    descargar "https://qemu.weilnetz.de/w64/qemu-w64-setup-$QEMU_W64_VER.exe" "$CACHE/qemu-w64-setup.exe"
    descargar "https://qemu.weilnetz.de/w64/qemu-w64-setup-$QEMU_W64_VER.sha512" "$CACHE/qemu-w64-setup.sha512"
    # el .sha512 publica el nombre original; comparamos el valor directamente
    ESPERADO=$(awk '{print tolower($1)}' "$CACHE/qemu-w64-setup.sha512")
    REAL=$(sha512sum "$CACHE/qemu-w64-setup.exe" | awk '{print $1}')
    [ "$ESPERADO" = "$REAL" ] \
        || { echo "ERROR: sha512 del instalador qemu-w64 no coincide" >&2; exit 1; }

    # 7zz estático para extraer el NSIS (la versión actual se sirve desde
    # GitHub; la 23.01 clásica sigue en 7-zip.org)
    descargar "https://www.7-zip.org/a/7z2301-linux-x64.tar.xz" "$CACHE/7z.tar.xz"
    mkdir -p "$CACHE/7z" && tar xf "$CACHE/7z.tar.xz" -C "$CACHE/7z" 7zz

    if [ ! -d "$CACHE/qw64" ]; then
        "$CACHE/7z/7zz" x -y -o"$CACHE/qw64" "$CACHE/qemu-w64-setup.exe" -xr!'$PLUGINSDIR' > /dev/null
    fi

    WIN="$SALIDA/portable-windows/antlexos"
    rm -rf "$SALIDA/portable-windows"
    mkdir -p "$WIN/qemu" "$WIN/fw"
    python3 "$(dirname "$0")/resolver_dlls.py" "$CACHE/qw64" "$WIN/qemu"
    cp "$FW"/*.bin "$FW"/*.rom "$FW"/*.fd "$WIN/fw/"

    cp "$IMG" "$ISO" "$WIN/"
    printf '@echo off\r\nrem AntLex OS portable - arranque BIOS\r\nset "DIR=%%~dp0"\r\n"%%DIR%%qemu\\qemu-system-x86_64.exe" -L "%%DIR%%fw" -m 512 -vga std -drive format=raw,file="%%DIR%%antlexos.img" %%*\r\n' > "$WIN/lanzar.bat"
    printf '@echo off\r\nrem AntLex OS portable - arranque UEFI (OVMF)\r\nset "DIR=%%~dp0"\r\nif not exist "%%DIR%%ovmf-vars.fd" copy "%%DIR%%fw\\OVMF_VARS_4M.fd" "%%DIR%%ovmf-vars.fd" > nul\r\n"%%DIR%%qemu\\qemu-system-x86_64.exe" -L "%%DIR%%fw" -m 512 -vga std -drive format=raw,file="%%DIR%%antlexos.img" -drive if=pflash,format=raw,file="%%DIR%%fw\\OVMF_CODE_4M.fd",readonly=on -drive if=pflash,format=raw,file="%%DIR%%ovmf-vars.fd" %%*\r\n' > "$WIN/lanzar-uefi.bat"
    printf '%s\n' "$LEEME_PORTABLE" > "$WIN/LEEME-PORTABLE.txt"

    (cd "$SALIDA/portable-windows" && zip -qr "$SALIDA/antlexos-portable-windows-x86_64.zip" antlexos)
    echo "  creado antlexos-portable-windows-x86_64.zip ($(du -h "$SALIDA/antlexos-portable-windows-x86_64.zip" | cut -f1))"
fi

echo "== listos los portables en $SALIDA =="
