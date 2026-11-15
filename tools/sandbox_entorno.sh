#!/bin/bash
# Entorno del sandbox de desarrollo de AntLexOS — source este archivo:
#   source tools/sandbox_entorno.sh   (desde el repo)
TC=/home/z/my-project/toolchain
export PATH="$TC/zig-x86_64-linux-0.14.1:$TC/nasm/bin:$PATH"
export LD_LIBRARY_PATH="$TC/qemu-root/usr/lib/x86_64-linux-gnu:$TC/qemu-root/lib/x86_64-linux-gnu:$TC/qemu-root/usr/lib"
export QEMU="$TC/qemu-root/usr/bin/qemu-system-x86_64"
export QEMU_BIN="$QEMU"
export OVMF_CODE="$TC/qemu-root/usr/share/OVMF/OVMF_CODE_4M.fd"
export OVMF_VARS="$TC/qemu-root/usr/share/OVMF/OVMF_VARS_4M.fd"
