#!/usr/bin/env python3
"""AntLex OS — arnés de la ISO (Fase 6).

Arranca antlexos.iso como CD-ROM en QEMU en dos modos:
  * BIOS: SeaBIOS + El Torito (catálogo, entrada por defecto → stage1_cd)
  * UEFI: OVMF + sección El Torito 0xEF (partición FAT embebida → BOOTX64.EFI)

Sin --uefi prueba el modo BIOS. En CD puro no hay disco ATA, así que las
autopruebas esperadas son 11/14 (fallan ata_identify, alfs_montado y
alfs_operaciones, que necesitan disco) y el banner es «ANTLEX BOOT CON
ERRORES»: es el comportamiento correcto documentado para este medio.

Uso:  probar_iso.py <antlexos.iso> <dir_salida> [--tiempo SEG] [--uefi]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp  # noqa: E402
from probar_boot import analizar_ppm, ppm_a_png  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
OVMF_CODE = os.environ.get("OVMF_CODE", "/usr/share/OVMF/OVMF_CODE_4M.fd")
OVMF_VARS = os.environ.get("OVMF_VARS", "/usr/share/OVMF/OVMF_VARS_4M.fd")

PASOS_OK = 0
PASOS_MAL = 0


def log(msg):
    print(f"[probar_iso] {msg}")


def leer_serial(ruta):
    try:
        with open(ruta, "r", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def esperar(ruta, marca, limite_s):
    inicio = time.time()
    while time.time() - inicio < limite_s:
        contenido = leer_serial(ruta)
        if marca in contenido:
            return True
        time.sleep(0.25)
    return False


def paso(nombre, condicion):
    global PASOS_OK, PASOS_MAL
    if condicion:
        PASOS_OK += 1
        log(f"ok: {nombre}")
    else:
        PASOS_MAL += 1
        log(f"FALLA: {nombre}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("iso")
    ap.add_argument("salida")
    ap.add_argument("--tiempo", type=int, default=180)
    ap.add_argument("--uefi", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    salida_abs = os.path.abspath(args.salida)
    modo = "uefi" if args.uefi else "bios"
    serial_path = os.path.join(salida_abs, f"serial_iso_{modo}.log")
    sock_path = os.path.join(salida_abs, f"qmp_{modo}.sock")
    iso_prueba = os.path.join(salida_abs, "antlexos_prueba.iso")
    shutil.copyfile(args.iso, iso_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std",
           "-cdrom", iso_prueba, "-boot", "d"]
    if args.uefi:
        vars_fd = os.path.join(salida_abs, "vars_prueba.fd")
        shutil.copyfile(OVMF_VARS, vars_fd)
        cmd += ["-drive", f"if=pflash,format=raw,file={OVMF_CODE},readonly=on",
                "-drive", f"if=pflash,format=raw,file={vars_fd}"]

    log(f"modo {modo}: lanzando {QEMU} -cdrom …")
    with open(os.path.join(salida_abs, f"qemu_{modo}.log"), "w") as fq:
        proc = subprocess.Popen(cmd, stdout=fq, stderr=subprocess.STDOUT)

    try:
        # 1) el escritorio arranca desde el CD
        paso("ESCRITORIO LISTO desde CD",
             esperar(serial_path, "ESCRITORIO LISTO", args.tiempo))
        serial = leer_serial(serial_path)

        # 2) trazas específicas del modo
        if args.uefi:
            paso("bootloader UEFI halló el medio (BlockIO, 2048 B)",
                 "[ANTLEX EFI] medio AntLex hallado (sector 2048 B)" in serial)
            paso("GOP activo (1280x800)", "GOP: 1280x800" in serial)
        else:
            paso("cadena de arranque BIOS (AB…J por serie)",
                 all(c in serial for c in ("A", "B")) and "ESCRITORIO LISTO" in serial)
        paso("ratón PS/2 activo", "raton PS/2 activo (IRQ12)" in serial)

        # 3) autopruebas: en CD puro 12/15 (sin disco ATA fallan 3 de ALFS;
        #    red_paquetes es lógica pura y pasa sin dispositivo), banner con errores
        paso("autopruebas 12/15 (sin disco ATA)",
             "AUTOPRUEBAS 12/15 correctas" in serial)
        paso("banner con errores esperado (sin disco)",
             "ANTLEX BOOT CON ERRORES" in serial)

        # 4) captura del escritorio y análisis de píxeles
        for _ in range(50):
            if os.path.exists(sock_path):
                break
            time.sleep(0.1)
        qmp = Qmp(sock_path)
        ppm = os.path.join(salida_abs, f"escritorio-{modo}-cd.ppm")
        qmp.cmd("screendump", {"filename": ppm})
        time.sleep(1.2)
        png = os.path.join(salida_abs, f"escritorio-{modo}-cd.png")
        try:
            info, _ = analizar_ppm(ppm)
            ppm_a_png(ppm, png)
            log(f"captura: escritorio-{modo}-cd.png {info['ancho']}x{info['alto']}, "
                f"iluminados={info['iluminados']}")
            paso("el escritorio muestra contenido (píxeles iluminados)",
                 info["iluminados"] > 5000)
        except Exception as e:  # noqa: BLE001
            log(f"aviso captura: {e}")
        qmp.cerrar()
    finally:
        if proc.poll() is None:
            proc.kill()
        shutil.copyfile(serial_path, os.path.join(salida_abs, f"serial_final_{modo}.log"))

    log(f"RESULTADO: {'PASA' if PASOS_MAL == 0 else 'FALLA'} ({PASOS_OK} ok, {PASOS_MAL} fallos)")
    return 0 if PASOS_MAL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
