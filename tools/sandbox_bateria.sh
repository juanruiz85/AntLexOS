#!/bin/bash
# Batería completa local de AntLexOS — mismo orden que release.yml.
# Uso:  source tools/sandbox_entorno.sh && bash tools/sandbox_bateria.sh
source /home/z/my-project/AntLexOS/tools/sandbox_entorno.sh
cd /home/z/my-project/AntLexOS

run() {
  local nombre="$1"; shift
  echo ""
  echo "=== $nombre ==="
  "$@" 2>&1 | tail -5
  local rc=${PIPESTATUS[0]}
  echo "--- $nombre rc=$rc"
  if [ "$rc" -ne 0 ]; then
    echo "BATERIA: FALLA en $nombre"
    exit "$rc"
  fi
}

run "fmt"        zig fmt --check .
run "build"      zig build -Drelease=true
run "host"       zig build test
run "entrenar"   zig build entrenar-verificar
run "boot BIOS"  python3 tools/probar_boot.py zig-out/antlexos.img build/pruebas --tiempo 60
run "boot UEFI"  python3 tools/probar_boot.py zig-out/antlexos.img build/pruebas_uefi --uefi --tiempo 150
run "ALFS"       python3 tools/probar_alfs.py zig-out/antlexos.img build/pruebas_alfs --tiempo 120
run "AntLex IA"  python3 tools/probar_antlex.py zig-out/antlexos.img build/pruebas_antlex --tiempo 240
run "ALX"        python3 tools/probar_alx.py zig-out/antlexos.img build/pruebas_alx --tiempo 120
run "escritorio" python3 tools/probar_escritorio.py zig-out/antlexos.img build/pruebas_escritorio --tiempo 300
run "red"        python3 tools/probar_red.py zig-out/antlexos.img build/pruebas_red --tiempo 240
run "TCP"        python3 tools/probar_tcp.py zig-out/antlexos.img build/pruebas_tcp --tiempo 240
run "TLS"        python3 tools/probar_tls.py zig-out/antlexos.img build/pruebas_tls --tiempo 300
run "descargar"  python3 tools/probar_descargar.py zig-out/antlexos.img build/pruebas_descargar --tiempo 300
run "ISO BIOS"   python3 tools/probar_iso.py zig-out/antlexos.iso build/iso_bios --tiempo 120
run "ISO UEFI"   python3 tools/probar_iso.py zig-out/antlexos.iso build/iso_uefi --uefi --tiempo 240
run "auditoría"  python3 tools/auditar.py

echo ""
echo "BATERIA COMPLETA: PASA"
