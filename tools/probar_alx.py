#!/usr/bin/env python3
"""AntLex OS — arnés de la Fase 7: ejecutables `.ALX` de punta a punta.

Arranca la imagen por BIOS y verifica por serie:
  1. bit de ejecutable visible con `atributos`
  2. `ejecutar /apps/calc.alx`: carga, ventana y foco
  3. la calculadora calcula con teclado real (12+34=46, 5*2=10, 7/2=3, 9/0=E)
  4. cierre con ESC (EV_CERRAR + descarga)
  5. `asociar` (tabla por defecto) y `abrir` con asociación
  6. el Reloj se abre con `abrir` y redibuja (captura con píxeles pintados)
  7. errores útiles: ejecutar sin bit, instalar un no-.ALX

Uso: probar_alx.py <imagen> <dir_salida> [--tiempo 120]
"""

import argparse
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp, teclear

PASOS_OK = 0
PASOS_MAL = 0


def log(msg):
    print(f"[probar_alx] {msg}")


def paso(nombre, marca, serial_path, desde=0.0, limite=20):
    """Espera a que `marca` aparezca en el serial tras la posición `desde`."""
    global PASOS_OK, PASOS_MAL
    t0 = time.time()
    pos = -1
    contenido = ""
    while time.time() - t0 < limite:
        try:
            with open(serial_path, "r", errors="replace") as f:
                contenido = f.read()
        except FileNotFoundError:
            pass
        pos = contenido.find(marca, int(desde))
        if pos >= 0:
            break
        time.sleep(0.25)
    if pos >= 0:
        PASOS_OK += 1
        log(f"ok: {nombre}")
        return pos, contenido
    PASOS_MAL += 1
    log(f"FALLO: {nombre} (no apareció «{marca}»)")
    for l in contenido.splitlines()[-14:]:
        log("   " + l)
    sys.exit(1)  # aborta: los pasos siguientes dependen de este


def intro(qmp):
    qmp.tecla("ret")
    time.sleep(0.2)


def teclear_mas(qmp, texto):
    """teclea con el mapa español del sistema (ver src/kernel/teclado.zig):
    '+' = sc 0x1B sin shift (qcode bracketright), '*' = shift+0x1B,
    '=' = shift+0, '/' = shift+7 (esto último ya lo hace teclear)."""
    for c in texto:
        if c == "+":
            qmp.tecla("bracket_right")
            time.sleep(0.05)
        elif c == "=":
            qmp.combo(["shift", "0"])
            time.sleep(0.05)
        elif c == "*":
            qmp.combo(["shift", "bracket_right"])
            time.sleep(0.05)
        else:
            teclear(qmp, c)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--tiempo", type=int, default=120)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    serial_path = os.path.join(args.salida, "serial.log")
    sock = os.path.join(args.salida, "qmp.sock")
    for p in (serial_path, sock):
        if os.path.exists(p):
            os.unlink(p)

    qemu = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
    cmd = [qemu, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock},server,nowait", "-m", "512", "-vga", "std",
           "-hda", args.imagen]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    qmp = None
    ok = False
    try:
        pos0, _ = paso("arranque hasta la consola", "CONSOLA LISTA", serial_path, limite=args.tiempo)
        base = pos0
        qmp = Qmp(sock)
        time.sleep(0.5)

        # 1) bit de ejecutable visible
        teclear(qmp, "atributos /apps/calc.alx"); intro(qmp)
        p, cont = paso("atributos muestra el bit EJECUTABLE", "EJECUTABLE", serial_path, pos0)
        base = p

        # 2) ejecutar la calculadora
        teclear(qmp, "ejecutar /apps/calc.alx"); intro(qmp)
        p, _ = paso("alx: cargada CALC", "alx: cargada CALC", serial_path, base); base = p
        p, _ = paso("ventana Calculadora abierta", "gui: ventana abierta Calculadora", serial_path, base); base = p
        p, _ = paso("foco en Calculadora", "gui: foco ventana Calculadora", serial_path, base); base = p

        # 3) cálculos con teclado real (el foco está en la ventana de la app)
        teclear_mas(qmp, "12+34=")
        p, _ = paso("12 + 34 = 46", "calculadora: 12 + 34 = 46", serial_path, base); base = p
        teclear_mas(qmp, "5*2=")
        p, _ = paso("5 * 2 = 10", "calculadora: 5 * 2 = 10", serial_path, base); base = p
        teclear_mas(qmp, "7/2=")
        p, _ = paso("7 / 2 = 3", "calculadora: 7 / 2 = 3", serial_path, base); base = p
        teclear_mas(qmp, "9/0=")
        p, _ = paso("9 / 0 = E (error controlado)", "calculadora: 9 / 0 = E", serial_path, base); base = p
        teclear_mas(qmp, "c")  # limpiar el error
        time.sleep(0.4)

        # 4) cierre con ESC: el kernel descarga la app y luego cierra la ventana
        qmp.tecla("esc"); time.sleep(0.5)
        p, _ = paso("app descargada (EV_CERRAR)", "alx: descargada CALC", serial_path, base); base = p
        p, _ = paso("ventana Calculadora cerrada", "gui: ventana cerrada Calculadora", serial_path, base); base = p

        # 5) tabla de asociaciones por defecto (imprime TXT antes que ALX)
        teclear(qmp, "asociar"); intro(qmp)
        p, _ = paso("asociación por defecto .TXT -> editor", ".TXT -> editor", serial_path, base); base = p
        p, _ = paso("asociación por defecto .ALX -> ejecutar", ".ALX -> ejecutar", serial_path, base); base = p

        # 6) abrir con asociación: el Reloj
        teclear(qmp, "abrir /apps/reloj.alx"); intro(qmp)
        p, _ = paso("abrir usa la asociación: cargada RELOJ", "alx: cargada RELOJ", serial_path, base); base = p
        p, _ = paso("ventana Reloj abierta", "gui: ventana abierta Reloj", serial_path, base); base = p

        # captura: el área del reloj debe tener píxeles pintados
        time.sleep(1.5)  # un par de ticks para que dibuje
        ppm = os.path.join(args.salida, "reloj.ppm")
        qmp.cmd("screendump", {"filename": ppm})
        time.sleep(1.0)
        try:
            from PIL import Image
            im = Image.open(ppm).convert("RGB")
            region = im.crop((310, 160, 520, 250))  # ventana del reloj
            litidos = sum(1 for px in region.getdata() if px != (16, 22, 32) and sum(px) > 90)
            if litidos > 60:
                log(f"ok: captura del Reloj con contenido ({litidos} píxeles)")
                global PASOS_OK
                PASOS_OK += 1
            else:
                log(f"FALLO: captura del Reloj casi vacía ({litidos} píxeles)")
                global PASOS_MAL
                PASOS_MAL += 1
        except ImportError:
            log("aviso: sin PIL, se omite la comprobación de píxeles")

        qmp.tecla("esc"); time.sleep(0.5)
        p, _ = paso("ventana Reloj cerrada", "gui: ventana cerrada Reloj", serial_path, base); base = p

        # 7) errores útiles
        teclear(qmp, "ejecutar /leeme.txt"); intro(qmp)
        p, _ = paso("ejecutar un .TXT se rechaza", "terminan en .ALX", serial_path, base); base = p
        teclear(qmp, "instalar /leeme.txt"); intro(qmp)
        p, _ = paso("instalar un .TXT se rechaza", "solo se instalan ejecutables .ALX", serial_path, base); base = p
        teclear(qmp, "abrir /apps/calc.alx"); intro(qmp)
        p, _ = paso("abrir CALC de nuevo (asociación)", "alx: cargada CALC", serial_path, base); base = p
        qmp.tecla("esc"); time.sleep(0.4)

        ok = True
    finally:
        if qmp:
            qmp.cerrar()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    log("RESULTADO: " + ("PASA" if ok else "FALLA") + f" ({PASOS_OK} ok, {PASOS_MAL} fallos)")
    sys.exit(0 if ok and PASOS_MAL == 0 else 1)


if __name__ == "__main__":
    main()
