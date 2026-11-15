#!/bin/bash
# Instala QEMU + OVMF en el espacio de usuario (sin sudo) extrayendo .deb
# de Debian, y crea el envoltorio que aporta librerías y firmware (-L).
# Resultado: /home/z/my-project/toolchain/qemu-root/usr/bin/qemu-system-x86_64
set -uo pipefail
TC=/home/z/my-project/toolchain
ROOT=$TC/qemu-root
DL=$TC/qemu-debs
mkdir -p "$ROOT" "$DL"
cd "$DL"

# Cierre de dependencias de qemu-system-x86 + ovmf (sin recommends)
apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
  --no-breaks --no-replaces --no-enhances qemu-system-x86 ovmf 2>/dev/null \
  | grep -E '^[a-z0-9]' | sort -u > pkgs.txt
echo "paquetes en el cierre: $(wc -l < pkgs.txt)"

fallos=0
while read -r p; do
  if ! ls "${p}"_*.deb >/dev/null 2>&1 && ! apt-get download "$p" >/dev/null 2>&1; then
    fallos=$((fallos+1))
  fi
done < pkgs.txt
echo "descargas fallidas (virtuales, tolerable): $fallos"

for f in *.deb; do dpkg-deb -x "$f" "$ROOT" 2>/dev/null; done

# Envoltorio: librerías del prefijo + rutas de firmware (-L), igual que en
# el portable Linux. El binario real queda como qemu-system-x86_64.real.
BIN=$ROOT/usr/bin/qemu-system-x86_64
if [ ! -f "$BIN.real" ]; then mv "$BIN" "$BIN.real"; fi
cat > "$BIN" <<'EOF'
#!/bin/sh
# Envoltorio: librerías y firmware del prefijo extraído (sin sudo).
export LD_LIBRARY_PATH="/home/z/my-project/toolchain/qemu-root/usr/lib/x86_64-linux-gnu:/home/z/my-project/toolchain/qemu-root/lib/x86_64-linux-gnu:/home/z/my-project/toolchain/qemu-root/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /home/z/my-project/toolchain/qemu-root/usr/bin/qemu-system-x86_64.real "$@" \
  -L /home/z/my-project/toolchain/qemu-root/usr/share/qemu \
  -L /home/z/my-project/toolchain/qemu-root/usr/share/seabios
EOF
chmod +x "$BIN"

"$BIN" --version 2>&1 | head -1
ls "$ROOT/usr/share/OVMF/OVMF_CODE_4M.fd" >/dev/null 2>&1 && echo "OVMF OK"
