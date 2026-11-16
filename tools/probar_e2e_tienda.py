#!/usr/bin/env python3
"""AntLex OS — e2e de la tienda contra GitHub REAL (fase 9b).

Arranca el kernel con red user (slirp con salida a internet) y consulta
la tienda real https://raw.githubusercontent.com/juanruiz85/AntLexApps
(sin CA local: el kernel verifica contra la ISRG Root X1 embebida y la
cadena de GitHub hoy es leaf <- YR1 <- Root YR <- X1, cross-firmada).

  1. `tienda` — listado real del INDICE (CALC y RELOJ),
  2. `descargar RELOJ` — descarga real (~52 KiB), sha256 e instalación,
  3. `atributos /APPS/RELOJ.ALX` — tamaño exacto y bit de ejecutable,
  4. apagado ACPI.

Uso:  probar_e2e_tienda.py <imagen.img> <dir_salida> [--tiempo SEG]
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp, teclear, intro, esperar, FIRMWARE  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PASOS_OK = 0
PASOS_MAL = 0


def log(msg):
    print(f"[e2e_tienda] {msg}", flush=True)


def paso(nombre, marca, ref, serial_path, limite=60.0):
    global PASOS_OK, PASOS_MAL
    _, pos = esperar(serial_path, marca, limite, ref[0])
    if pos >= 0:
        ref[0] = pos + len(marca)
        PASOS_OK += 1
        log(f"ok: {nombre}")
        return True
    PASOS_MAL += 1
    log(f"FALLA: {nombre} (no se halló «{marca}»)")
    return False


def main():
    global PASOS_OK, PASOS_MAL
    ap = argparse.ArgumentParser()
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--tiempo", type=int, default=420)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    salida_abs = os.path.abspath(args.salida)
    serial_path = os.path.join(salida_abs, "serial_e2e.log")
    sock_path = os.path.join(salida_abs, "qmp.sock")
    img_prueba = os.path.join(salida_abs, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    # tamaño y sha256 esperados del RELOJ.ALX publicado (misma build)
    alx = os.path.join(REPO, "zig-out", "apps", "RELOJ.ALX")
    if not os.path.exists(alx):
        log("FALLA: no existe zig-out/apps/RELOJ.ALX (ejecuta zig build)")
        return 1
    reloj = open(alx, "rb").read()
    log(f"esperado: RELOJ.ALX {len(reloj)} bytes")

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std"]
    for fw in FIRMWARE:
        if os.path.isdir(fw):
            cmd += ["-L", fw]
            break
    cmd += ["-netdev", "user,id=red0",
            "-device", "virtio-net-pci,netdev=red0,disable-legacy=on",
            "-hda", img_prueba]
    log(f"lanzando QEMU con salida a internet (tienda real de GitHub)")
    with open(os.path.join(salida_abs, "qemu_salida.log"), "w") as fq:
        proc = subprocess.Popen(cmd, stdout=fq, stderr=subprocess.STDOUT)

    ref = [0]
    try:
        _, pos = esperar(serial_path, "ESCRITORIO LISTO", args.tiempo)
        if pos < 0:
            log("FALLA: el sistema no arrancó")
            return 1
        ref[0] = pos
        PASOS_OK += 1
        log("ok: arranque con red")

        for _ in range(50):
            if os.path.exists(sock_path):
                break
            time.sleep(0.1)
        qmp = Qmp(sock_path)
        time.sleep(0.5)

        # 1) listado real (handshake contra raw.githubusercontent.com)
        teclear(qmp, "tienda"); intro(qmp)
        paso("handshake TLS real (raw.githubusercontent.com)",
             "tls: handshake completo y verificado", ref, serial_path, limite=90.0)
        paso("entrada CALC del índice real", "tienda: CALC - calculadora", ref, serial_path, limite=15.0)
        paso("entrada RELOJ del índice real", "tienda: RELOJ - reloj", ref, serial_path, limite=15.0)

        # 2) descarga real de RELOJ (~52 KiB) + sha256 + instalación
        teclear(qmp, "descargar RELOJ"); intro(qmp)
        paso("sha256 verificado (real)", "descargar: RELOJ verificado (sha256 ok", ref, serial_path, limite=120.0)
        paso("instalado en /APPS", "descargar: instalado /APPS/RELOJ.ALX", ref, serial_path, limite=15.0)

        # 3) atributos
        teclear(qmp, "atributos /APPS/RELOJ.ALX"); intro(qmp)
        paso("tamaño exacto", f", {len(reloj)} bytes", ref, serial_path, limite=15.0)
        paso("bit de ejecutable", "EJECUTABLE", ref, serial_path, limite=10.0)

        # 4) apagado
        teclear(qmp, "apagar"); intro(qmp)
        _, pos = esperar(serial_path, "APAGANDO", 30.0, ref[0])
        if pos >= 0:
            PASOS_OK += 1
            log("ok: apagar por ACPI")
        else:
            PASOS_MAL += 1
            log("FALLA: apagar por ACPI")
        t0 = time.time()
        while time.time() - t0 < 30:
            if proc.poll() is not None:
                break
            time.sleep(0.5)
        if proc.poll() is None:
            PASOS_MAL += 1
            log("FALLA: QEMU sigue vivo tras apagar")
            proc.kill()
        else:
            PASOS_OK += 1
            log(f"ok: QEMU cerró solo por ACPI (código {proc.returncode})")
        qmp.cerrar()
    finally:
        if proc.poll() is None:
            proc.kill()
        if os.path.exists(serial_path):
            shutil.copyfile(serial_path, os.path.join(salida_abs, "serial_final.log"))

    log(f"RESULTADO: {'PASA' if PASOS_MAL == 0 else 'FALLA'} ({PASOS_OK} ok, {PASOS_MAL} fallos)")
    return 0 if PASOS_MAL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
