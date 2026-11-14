#!/usr/bin/env python3
"""AntLex OS — arnés de red (Fase 9a).

Arranca la imagen en QEMU con red de usuario (slirp) y un virtio-net-pci
MODERNO (disable-legacy=on: solo virtio 1.0) y comprueba de punta a punta:
detección e inicialización del dispositivo (PCI + capabilities + anillos),
autoprueba de paquetes, estado (`red`), ARP de la puerta de enlace, tres
ecos ICMP (`ping 10.0.2.2`) y la caché ARP visible después. Termina con
apagado ACPI real.

El resto de la batería arranca SIN `-netdev`: ahí el kernel debe trazar
«red: sin dispositivo virtio-net» y seguir igual (eso lo cubren los demás
arneses con su arranque normal).

Uso:  probar_red.py <imagen.img> <dir_salida> [--tiempo SEG]
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
    print(f"[probar_red] {msg}", flush=True)


def paso(nombre, marca, ref, serial_path, limite=25.0):
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
    serial_path = os.path.join(salida_abs, "serial_red.log")
    sock_path = os.path.join(salida_abs, "qmp.sock")
    img_prueba = os.path.join(salida_abs, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std"]
    for fw in FIRMWARE:  # directorios de firmware si existen (sandbox)
        if os.path.isdir(fw):
            cmd += ["-L", fw]
            break
    # la red de usuario de QEMU: 10.0.2.0/24, puerta 10.0.2.2 (slirp)
    cmd += ["-netdev", "user,id=red0",
            "-device", "virtio-net-pci,netdev=red0,disable-legacy=on",
            "-hda", img_prueba]

    log(f"lanzando: {QEMU} -display ... con virtio-net-pci moderno (imagen {args.imagen})")
    with open(os.path.join(salida_abs, "qemu_salida.log"), "w") as fq:
        proc = subprocess.Popen(cmd, stdout=fq, stderr=subprocess.STDOUT)

    ref = [0]
    try:
        # 1) arranque: el driver se inicializa ANTES de las autopruebas
        _, pos = esperar(serial_path, "ESCRITORIO LISTO", args.tiempo)
        if pos < 0:
            log("FALLA: el sistema no arrancó (sin ESCRITORIO LISTO)")
            return 1
        ref[0] = pos
        PASOS_OK += 1
        log("ok: arranque con red")

        # 2) init del dispositivo y autoprueba 15 (marcadores previos al
        #    arranque del escritorio: buscarlos desde el principio)
        paso("init: red", "init: red", [0], serial_path)
        paso("dispositivo virtio-net 1.0 detectado", "red: virtio-net 1.0 listo (MAC ", [0], serial_path)
        paso("autoprueba red_paquetes (15/15)", "AUTOPRUEBAS 15/15 correctas", [0], serial_path)

        # 3) QMP al terminal del escritorio
        for _ in range(50):
            if os.path.exists(sock_path):
                break
            time.sleep(0.1)
        qmp = Qmp(sock_path)
        time.sleep(0.5)

        # 4) estado de la red
        teclear(qmp, "red"); intro(qmp)
        paso("red: dispositivo y MAC", "virtio-net 1.0 — MAC ", ref, serial_path)
        paso("red: IP estática y puerta", "IP 10.0.2.15 · puerta 10.0.2.2", ref, serial_path)

        # 5) ping a la puerta: ARP + 3 ecos ICMP (márgenes amplios: la
        #    primera respuesta incluye la resolución ARP)
        teclear(qmp, "ping 10.0.2.2"); intro(qmp)
        paso("ARP de la puerta resuelto", "red: arp 10.0.2.2 -> ", ref, serial_path, limite=30.0)
        paso("ping 3/3 ecos", "ping 10.0.2.2: 3/3 ecos", ref, serial_path, limite=40.0)

        # 6) estado tras el ping: caché ARP y contadores de paquetes
        teclear(qmp, "red"); intro(qmp)
        paso("caché ARP visible", "ARP 10.0.2.2 -> ", ref, serial_path)
        paso("contadores de paquetes", "paquetes: ", ref, serial_path)

        # 7) apagado limpio por ACPI: el proceso debe salir solo
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
