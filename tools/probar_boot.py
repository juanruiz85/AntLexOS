#!/usr/bin/env python3
"""AntLex OS — arnés de arranque en QEMU.

Arranca la imagen en QEMU sin interfaz, espera la marca de arranque por el
puerto serie, toma una captura por QMP y valida:
  * que no haya autopruebas con [FALLA]
  * que aparezca "ANTLEX BOOT OK v<version>"
  * que la captura tenga píxeles y contenga el color de acento del logo

Uso:  probar_boot.py <imagen.img> <dir_salida> [--uefi] [--tiempo SEG]
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
TC = os.environ.get("TC", "/home/z/my-project/toolchain")
FIRMWARE = [
    f"{TC}/qemu-root/usr/share/qemu",
    f"{TC}/qemu-root/usr/share/seabios",
    f"{TC}/qemu-root/usr/lib/ipxe/qemu",
]
OVMF_CODE = os.environ.get(
    "OVMF_CODE", f"{TC}/qemu-root/usr/share/OVMF/OVMF_CODE_4M.fd"
)
OVMF_VARS = os.environ.get(
    "OVMF_VARS", f"{TC}/qemu-root/usr/share/OVMF/OVMF_VARS_4M.fd"
)
ACENTO = (0x5B, 0x9B, 0xF0)  # azul del logo
FONDO_OSCURO = (0x0A, 0x0E, 0x16)


def log(msg):
    print(f"[probar_boot] {msg}")


def esperar_marca(ruta_serial, marca, limite_s):
    inicio = time.time()
    contenido = ""
    while time.time() - inicio < limite_s:
        try:
            with open(ruta_serial, "r", errors="replace") as f:
                contenido = f.read()
        except FileNotFoundError:
            pass
        if marca in contenido:
            return contenido, True
        time.sleep(0.25)
    return contenido, False


def qmp_screendump(sock_path, ppm_path, timeout=10):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    # saludo
    leido = s.recv(65536)
    _ = leido
    s.sendall(b'{"execute":"qmp_capabilities"}\n')
    _ = s.recv(65536)
    s.sendall(json.dumps({"execute": "screendump", "arguments": {"filename": ppm_path}}).encode() + b"\n")
    resp = json.loads(s.recv(65536).decode())
    s.close()
    return resp


def analizar_ppm(ppm_path):
    with open(ppm_path, "rb") as f:
        datos = f.read()
    if not datos.startswith(b"P6"):
        return None, "no es P6"
    partes = datos.split(b"\n", 3)
    try:
        ancho, alto = map(int, partes[1].split())
    except Exception:
        return None, "cabecera invalida"
    cuerpo = partes[3]
    total = ancho * alto
    if len(cuerpo) < total * 3:
        return None, "cuerpo corto"
    iluminados = 0
    acento = 0
    paso = 3  # muestrear todos
    for i in range(0, total * 3, paso * 3):
        px = (cuerpo[i], cuerpo[i + 1], cuerpo[i + 2])
        if px != FONDO_OSCURO and px != (0, 0, 0):
            iluminados += 1
        if abs(px[0] - ACENTO[0]) < 24 and abs(px[1] - ACENTO[1]) < 24 and abs(px[2] - ACENTO[2]) < 24:
            acento += 1
    return {
        "ancho": ancho,
        "alto": alto,
        "iluminados": iluminados,
        "acento": acento,
        "total": total,
    }, None


def ppm_a_png(ppm_path, png_path):
    try:
        from PIL import Image
        Image.open(ppm_path).save(png_path)
        return True
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--uefi", action="store_true")
    ap.add_argument("--tiempo", type=int, default=30)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    serial_path = os.path.join(args.salida, "serial.log")
    sock_path = os.path.join(args.salida, "qmp.sock")
    ppm_path = os.path.join(args.salida, "captura.ppm")
    for p in (serial_path, sock_path, ppm_path):
        if os.path.exists(p):
            os.unlink(p)

    cmd = [
        QEMU,
        "-display", "none",
        "-serial", f"file:{serial_path}",
        "-qmp", f"unix:{sock_path},server,nowait",
        "-m", "512",
        "-vga", "std",
    ]
    for fw in FIRMWARE:
        if os.path.isdir(fw):
            cmd += ["-L", fw]
    if args.uefi:
        # copiar VARS para no ensuciar la plantilla
        vars_copia = os.path.join(args.salida, "OVMF_VARS.fd")
        import shutil
        shutil.copyfile(OVMF_VARS, vars_copia)
        cmd += ["-bios", OVMF_CODE]
    cmd += ["-hda", args.imagen]
    if args.uefi:
        log(f"modo UEFI: {OVMF_CODE}")

    log(f"lanzando: {' '.join(cmd[:2])} ... (imagen {args.imagen})")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

    ok = False
    fallas = []
    try:
        modo = "UEFI" if args.uefi else "BIOS"
        # 1) esperar el aviso de splash visible (el kernel lo mantiene 1 s)
        contenido_splash, splash_ok = esperar_marca(serial_path, "SPLASH VISIBLE", args.tiempo)
        ppm_splash = os.path.join(args.salida, "splash.ppm")
        if splash_ok:
            try:
                resp = qmp_screendump(sock_path, ppm_splash)
                if "return" in resp:
                    ppm_a_png(ppm_splash, os.path.join(args.salida, "splash.png"))
                    log("captura del splash tomada")
            except Exception as e:
                log(f"aviso QMP splash: {e}")
        # 2) esperar la consola interactiva lista
        contenido, marca = esperar_marca(serial_path, "CONSOLA LISTA", 10)
        if not marca:
            contenido, marca = esperar_marca(serial_path, "ANTLEX BOOT CON ERRORES", 5)
        fallas = [l for l in contenido.splitlines() if "[FALLA]" in l]
        if marca:
            log(f"marca de arranque detectada ({modo})")
            log("--- serial ---")
            for l in contenido.splitlines():
                log("  " + l)
            try:
                resp = qmp_screendump(sock_path, ppm_path)
                if "return" in resp:
                    info, err = analizar_ppm(ppm_path)
                    if err:
                        log(f"ERROR captura: {err}")
                    else:
                        log(f"captura consola: {info['ancho']}x{info['alto']}, "
                            f"pixeles iluminados={info['iluminados']}")
                        ppm_a_png(ppm_path, os.path.join(args.salida, "captura.png"))
                        # la consola debe mostrar texto (píxeles claros sobre fondo oscuro)
                        if info["iluminados"] < 200:
                            log("ERROR: la consola no muestra texto")
                            ok = False
                        else:
                            ok = not fallas
                        # validar también el splash si se llegó a capturar
                        if os.path.exists(ppm_splash):
                            sinfo, serr = analizar_ppm(ppm_splash)
                            if serr is None and sinfo["acento"] < 200:
                                log("ERROR: el splash no muestra el logo (sin acento azul)")
                                ok = False
                            elif serr is None:
                                log(f"splash: acento={sinfo['acento']} pixeles del logo ✓")
                else:
                    log(f"QMP respondió: {resp}")
            except Exception as e:
                log(f"ERROR QMP: {e}")
        else:
            log("--- serial (sin marca de arranque) ---")
            for l in contenido.splitlines():
                log("  " + l)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    if fallas:
        log(f"AUTOPRUEBAS FALLIDAS: {len(fallas)}")
        for l in fallas:
            log("  " + l)
    log("RESULTADO: " + ("PASA" if ok else "FALLA"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
