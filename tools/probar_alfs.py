#!/usr/bin/env python3
"""AntLex OS — arnés de persistencia de ALFS.

Demuestra de extremo a extremo que el sistema de archivos es real:
  1. arranca la imagen y espera la consola
  2. teclea (por QMP send-key, teclado español) un comando que crea
     /prueba.txt con contenido conocido
  3. sincroniza el volumen al disco
  4. REINICIA la máquina virtual (system_reset)
  5. tras el segundo arranque, muestra el archivo y comprueba que el
     contenido persistió
  6. borra el archivo de prueba y sincroniza (limpieza)

Uso:  probar_alfs.py <imagen.img> <dir_salida> [--uefi] [--tiempo SEG]
"""
import argparse
import json
import os
import shutil
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
OVMF_CODE = os.environ.get("OVMF_CODE", f"{TC}/qemu-root/usr/share/OVMF/OVMF_CODE_4M.fd")
OVMF_VARS = os.environ.get("OVMF_VARS", f"{TC}/qemu-root/usr/share/OVMF/OVMF_VARS_4M.fd")

# caracteres seguros con el mapa español (letras minúsculas, dígitos,
# espacio, punto y guion se inyectan igual en ES que en US)
QCODES = {" ": "spc", ".": "dot", "-": "minus"}
CONTENIDO = "prueba de persistencia ok 2026"


def log(msg):
    print(f"[probar_alfs] {msg}")


class Qmp:
    def __init__(self, sock_path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(10)
        self.s.connect(sock_path)
        self.buf = b""
        self._leer_objeto()  # saludo del servidor
        self.cmd("qmp_capabilities")

    def _leer_linea(self):
        """Lee una línea JSON completa del búfer/socket (separa eventos)."""
        while b"\r\n" not in self.buf:
            trozo = self.s.recv(65536)
            if not trozo:
                raise ConnectionError("QMP cerró la conexión")
            self.buf += trozo
        linea, self.buf = self.buf.split(b"\r\n", 1)
        return linea

    def _leer_objeto(self):
        while True:
            obj = json.loads(self._leer_linea().decode())
            if "event" in obj:
                continue  # los eventos (RESET, etc.) se descartan
            return obj

    def cmd(self, execute, arguments=None):
        p = {"execute": execute}
        if arguments:
            p["arguments"] = arguments
        self.s.sendall(json.dumps(p).encode() + b"\n")
        return self._leer_objeto()

    def tecla(self, qcode):
        self.cmd("send-key", {
            "keys": [{"type": "qcode", "data": qcode}],
            "hold-time": 30,
        })

    def cerrar(self):
        self.s.close()


def teclear(qmp, texto, pausa=0.045):
    for c in texto:
        q = QCODES.get(c, c)
        if not (len(q) == 1 and q.isalnum()) and q not in QCODES.values():
            log(f"aviso: caracter no soportado en el arnés: {c!r}")
            continue
        qmp.tecla(q)
        time.sleep(pausa)


def intro(qmp):
    qmp.tecla("ret")
    time.sleep(0.15)


def leer_serial(ruta):
    try:
        with open(ruta, "r", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def esperar(ruta, marca, limite_s, desde=0.0):
    """Espera a que `marca` aparezca en el serial en una posición > desde."""
    inicio = time.time()
    while time.time() - inicio < limite_s:
        contenido = leer_serial(ruta)
        pos = contenido.find(marca, int(desde))
        if pos >= 0:
            return contenido, pos
        time.sleep(0.25)
    return leer_serial(ruta), -1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--uefi", action="store_true")
    ap.add_argument("--tiempo", type=int, default=90)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    serial_path = os.path.join(args.salida, "serial_alfs.log")
    sock_path = os.path.join(args.salida, "qmp_alfs.sock")
    # trabajar sobre una COPIA de la imagen: la prueba escribe de verdad en
    # disco y una limpieza fallida no dejaría el artefacto de build modificado
    img_prueba = os.path.join(args.salida, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std"]
    for fw in FIRMWARE:
        if os.path.isdir(fw):
            cmd += ["-L", fw]
    if args.uefi:
        vars_copia = os.path.join(args.salida, "OVMF_VARS.fd")
        shutil.copyfile(OVMF_VARS, vars_copia)
        cmd += ["-drive", f"if=pflash,format=raw,file={OVMF_CODE},readonly=on"]
        cmd += ["-drive", f"if=pflash,format=raw,file={vars_copia}"]
    cmd += ["-hda", img_prueba]

    log(f"arrancando ({'UEFI' if args.uefi else 'BIOS'}): {args.imagen}")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    ok = False
    qmp = None
    try:
        # 1) primer arranque hasta la consola
        _, pos_consola = esperar(serial_path, "CONSOLA LISTA", args.tiempo)
        if pos_consola < 0:
            log("ERROR: la consola no llegó a estar lista (primer arranque)")
            log("--- serial ---")
            for l in leer_serial(serial_path).splitlines():
                log("  " + l)
            return sys.exit(1)
        log("primer arranque listo")

        # 2) crear el archivo de prueba
        qmp = Qmp(sock_path)
        teclear(qmp, "escribir prueba.txt " + CONTENIDO)
        intro(qmp)
        contenido, pos = esperar(serial_path, "creado prueba.txt", 15, pos_consola)
        if pos < 0:
            log("ERROR: no se creó prueba.txt")
            for l in contenido.splitlines()[-12:]:
                log("  " + l)
            return sys.exit(1)
        log("prueba.txt creado")

        # 3) sincronizar al disco (con reintentos: en runners cargados QMP
        # puede perder la primera ráfaga de teclas)
        pos_sync = -1
        for intento in range(1, 4):
            teclear(qmp, "sincronizar")
            intro(qmp)
            _, pos_sync = esperar(serial_path, "ALFS SINCRONIZADO", 30, pos)
            if pos_sync >= 0:
                break
            log(f"aviso: sincronizar no respondió (intento {intento}/3), reintentando...")
            time.sleep(2)
        if pos_sync < 0:
            log("ERROR: la sincronización no completó")
            log("--- serial (últimas 25 líneas) ---")
            for l in leer_serial(serial_path).splitlines()[-25:]:
                log("  " + l)
            return sys.exit(1)
        log("volumen sincronizado al disco")

        # 4) reinicio completo de la máquina
        log("reiniciando la máquina virtual...")
        qmp.cmd("system_reset")
        time.sleep(1.0)
        contenido, pos_consola2 = esperar(serial_path, "CONSOLA LISTA", args.tiempo,
                                          desde=len(contenido))
        if pos_consola2 < 0:
            log("ERROR: la máquina no volvió a arrancar tras el reinicio")
            return sys.exit(1)
        log("segundo arranque listo")

        # 5) el archivo debe seguir ahí
        teclear(qmp, "mostrar prueba.txt")
        intro(qmp)
        contenido, pos_dato = esperar(serial_path, CONTENIDO, 15, pos_consola2)
        if pos_dato < 0:
            log("ERROR: el contenido NO persistió tras el reinicio")
            return sys.exit(1)
        _, pos_bytes = esperar(serial_path, f"[{len(CONTENIDO)} bytes]", 10, pos_dato)
        if pos_bytes < 0:
            log("ERROR: el volcado no terminó con el tamaño esperado")
            return sys.exit(1)
        log(f"persistencia verificada: '{CONTENIDO}' sobrevivió al reinicio")

        # 6) limpieza
        teclear(qmp, "borrar prueba.txt")
        intro(qmp)
        teclear(qmp, "sincronizar")
        intro(qmp)
        _, pos_fin = esperar(serial_path, "borrado prueba.txt", 15, pos_bytes)
        _, pos_fin2 = esperar(serial_path, "ALFS SINCRONIZADO", 30, max(pos_fin, 0))
        if pos_fin < 0 or pos_fin2 < 0:
            log("AVISO: la limpieza no completó (la imagen puede conservar prueba.txt)")
        else:
            log("limpieza completada")
        ok = True
    finally:
        if qmp:
            qmp.cerrar()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    log("RESULTADO: " + ("PASA" if ok else "FALLA"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
