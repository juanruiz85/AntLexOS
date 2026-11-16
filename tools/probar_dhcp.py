#!/usr/bin/env python3
"""AntLex OS — arnés de DHCP (fase 9c, v1.4.1).

Arranca el kernel con la red de usuario de QEMU (slirp), cuyo servidor
DHCP responde en milisegundos, y verifica:

  1. la concesión automática en el arranque (IP 10.0.2.15, puerta
     10.0.2.2, DNS 10.0.2.3 — los valores fijos de slirp),
  2. el comando `red` muestra la configuración viva con origen dhcp,
  3. ping a la puerta funciona sobre la configuración dinámica,
  4. la TIENDA real completa (TLS contra raw.githubusercontent.com con
     la configuración obtenida por DHCP),
  5. apagado por ACPI.

Uso:  probar_dhcp.py <imagen.img> <dir_salida> [--tiempo SEG]
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp, teclear, intro, esperar, FIRMWARE  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")

PASOS_OK = 0
PASOS_MAL = 0


def log(msg):
    print(f"[probar_dhcp] {msg}", flush=True)


def paso(nombre, marca, ref, serial_path, limite=30.0):
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
    ap.add_argument("--tiempo", type=int, default=240)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    salida_abs = os.path.abspath(args.salida)
    serial_path = os.path.join(salida_abs, "serial_dhcp.log")
    sock_path = os.path.join(salida_abs, "qmp.sock")
    img_prueba = os.path.join(salida_abs, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std"]
    for fw in FIRMWARE:
        if os.path.isdir(fw):
            cmd += ["-L", fw]
            break
    cmd += ["-netdev", "user,id=red0",
            "-device", "virtio-net-pci,netdev=red0,disable-legacy=on",
            "-hda", img_prueba]
    log("lanzando QEMU con red de usuario (servidor DHCP de slirp)")
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
        log("ok: arranque")

        # 1) concesión DHCP en el arranque (valores fijos de slirp):
        #    estas trazas van ANTES del escritorio, se buscan desde el
        #    principio del serial
        ref[0] = 0
        paso("driver virtio-net", "red: virtio-net 1.0 listo", ref, serial_path, limite=10.0)
        paso("IP por DHCP", "red: ip 10.0.2.15 por dhcp", ref, serial_path, limite=15.0)
        paso("puerta de la concesión", "puerta 10.0.2.2", ref, serial_path, limite=10.0)
        paso("DNS de la concesión", "dns 10.0.2.3", ref, serial_path, limite=10.0)
        ref[0] = pos  # seguir desde ESCRITORIO LISTO para lo interactivo

        for _ in range(50):
            if os.path.exists(sock_path):
                break
            time.sleep(0.1)
        qmp = Qmp(sock_path)
        time.sleep(0.5)

        # 2) `red` muestra la configuración viva
        teclear(qmp, "red"); intro(qmp)
        paso("red: IP con origen dhcp", "IP 10.0.2.15 (dhcp)", ref, serial_path, limite=15.0)
        paso("red: mascara viva", "mascara 255.255.255.0", ref, serial_path, limite=10.0)
        paso("red: dns vivo", "dns 10.0.2.3", ref, serial_path, limite=10.0)

        # 3) ICMP sobre la configuración dinámica
        teclear(qmp, "ping 10.0.2.2"); intro(qmp)
        paso("ping a la puerta (3/3)", "ping 10.0.2.2: 3/3 ecos", ref, serial_path, limite=30.0)

        # 4) tienda real: TLS completo con la IP obtenida por DHCP
        teclear(qmp, "tienda"); intro(qmp)
        paso("tienda real sobre DHCP (handshake TLS)",
             "tls: handshake completo y verificado", ref, serial_path, limite=90.0)
        paso("tienda real sobre DHCP (índice)", "tienda: CALC - calculadora", ref, serial_path, limite=20.0)

        # 5) apagado
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
