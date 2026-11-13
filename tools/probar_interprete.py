#!/usr/bin/env python3
"""AntLex OS — arnés del intérprete de comandos (Fase 3).

Arranca la imagen en QEMU y ejerce de verdad el intérprete por teclado QMP:
eco/ver, reloj (fecha/hora), sistema, historial con flechas, autocompletado
con TAB (comandos y rutas), renombrar/buscar y apagado limpio por ACPI.

Uso:  probar_interprete.py <imagen.img> <dir_salida> [--tiempo SEG]
"""
import argparse
import json
import os
import re
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

# caracteres seguros con el mapa español (letras, dígitos, espacio, punto y
# guion se inyectan igual en ES que en US)
QCODES = {" ": "spc", ".": "dot", "-": "minus", "/": "slash"}


def log(msg):
    print(f"[probar_interprete] {msg}")


class Qmp:
    def __init__(self, sock_path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(10)
        self.s.connect(sock_path)
        self.buf = b""
        self._leer_objeto()  # saludo del servidor
        self.cmd("qmp_capabilities")

    def _leer_linea(self):
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

    def combo(self, qcodes):
        self.cmd("send-key", {
            "keys": [{"type": "qcode", "data": q} for q in qcodes],
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
    time.sleep(0.18)


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
    ap.add_argument("--tiempo", type=int, default=180)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    serial_path = os.path.join(args.salida, "serial_interprete.log")
    sock_path = os.path.join(args.salida, "qmp_interprete.sock")
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
    cmd += ["-hda", img_prueba]

    log(f"arrancando: {args.imagen}")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    qmp = None
    fallos = []

    def paso(nombre, marca, limite=15, desde_ref=[0.0]):
        """Ejecuta 'esperar marca' actualizando la posición de referencia.
        La referencia queda TRAS la marca (pos+len) para que un marcador
        repetido no reencuentre la ocurrencia anterior (falso positivo)."""
        contenido, pos = esperar(serial_path, marca, limite, desde_ref[0])
        if pos < 0:
            fallos.append(nombre)
            log(f"FALLA: {nombre} (no apareció {marca!r})")
            for l in contenido.splitlines()[-8:]:
                log("    " + l)
            return False
        desde_ref[0] = pos + len(marca)
        log(f"ok: {nombre}")
        return True

    try:
        contenido, pos = esperar(serial_path, "CONSOLA LISTA", args.tiempo)
        if pos < 0:
            log("ERROR: la consola no llegó a estar lista")
            for l in contenido.splitlines()[-14:]:
                log("  " + l)
            return sys.exit(1)
        ref = [pos + len("CONSOLA LISTA")]
        log("consola lista")

        qmp = Qmp(sock_path)

        # 1) eco y ver
        teclear(qmp, "eco hola 42")
        intro(qmp)
        paso("eco", "hola 42\n", desde_ref=ref)
        teclear(qmp, "ver")
        intro(qmp)
        paso("ver (reloj nuevo)", "reloj: ", desde_ref=ref)

        # 2) reloj
        teclear(qmp, "fecha")
        intro(qmp)
        paso("fecha: texto largo", "Hoy es ", desde_ref=ref)
        contenido = leer_serial(serial_path)
        m = re.search(r"20\d\d-\d\d-\d\d \d\d:\d\d:\d\d", contenido[ref[0]:])
        if m is None:
            fallos.append("fecha-iso")
            log("FALLA: fecha sin formato ISO")
        else:
            ref[0] += m.end()
            log(f"ok: fecha ISO ({m.group(0)})")

        teclear(qmp, "hora")
        intro(qmp)
        paso("hora + encendido", "encendido: ", desde_ref=ref)

        # 3) sistema (sysinfo)
        teclear(qmp, "sistema")
        intro(qmp)
        paso("sistema: cpu QEMU", "QEMU", desde_ref=ref)
        paso("sistema: memoria", "MiB totales", desde_ref=ref)

        # 4) historial: listado numerado
        teclear(qmp, "historia")
        intro(qmp)
        paso("historia: lista numerada", "  1  eco hola 42", desde_ref=ref)

        # 5) flecha arriba → repite "historia"
        qmp.tecla("up")
        time.sleep(0.3)
        intro(qmp)
        paso("flecha arriba recupera comando", "  1  eco hola 42", desde_ref=ref)

        # 6) autocompletado de comando: "hor" + TAB → "hora "
        teclear(qmp, "hor")
        qmp.tecla("tab")
        time.sleep(0.3)
        intro(qmp)
        paso("TAB completa comando", "encendido: ", desde_ref=ref)

        # 7) autocompletado múltiple: "e" + TAB → lista de opciones
        teclear(qmp, "e")
        qmp.tecla("tab")
        time.sleep(0.3)
        paso("TAB multiple muestra opciones", "espacio  ", desde_ref=ref)
        qmp.combo(["ctrl", "c"])
        time.sleep(0.3)
        paso("Ctrl+C cancela línea", "^C", desde_ref=ref)

        # 8) autocompletado de ruta: "mos" TAB "le" TAB → mostrar LEEME.txt
        teclear(qmp, "mos")
        qmp.tecla("tab")
        time.sleep(0.25)
        teclear(qmp, "le")
        qmp.tecla("tab")
        time.sleep(0.3)
        intro(qmp)
        paso("TAB completa comando+ruta", "bytes]", desde_ref=ref)

        # 9) archivos: escribir → lista con tamaños → renombrar → buscar → mostrar → borrar
        teclear(qmp, "escribir notas.tmp hola mundo")
        intro(qmp)
        paso("escribir", "creado notas.tmp", desde_ref=ref)
        teclear(qmp, "lista")
        intro(qmp)
        paso("lista muestra columna de tamano", " blk", desde_ref=ref)
        teclear(qmp, "renombrar notas.tmp notas2.tmp")
        intro(qmp)
        paso("renombrar", "renombrado a notas2.tmp", desde_ref=ref)
        teclear(qmp, "buscar notas")
        intro(qmp)
        paso("buscar", "/notas2.tmp", desde_ref=ref)
        teclear(qmp, "mostrar notas2.tmp")
        intro(qmp)
        paso("mostrar renombrado", "hola mundo", desde_ref=ref)
        teclear(qmp, "borrar notas2.tmp")
        intro(qmp)
        paso("borrar", "borrado notas2.tmp", desde_ref=ref)

        # 10) pruebas bajo demanda (14/14)
        teclear(qmp, "pruebas")
        intro(qmp)
        paso("pruebas: resumen", "AUTOPRUEBAS 14/14 correctas", desde_ref=ref)

        # 11) apagado limpio por ACPI: el proceso debe salir solo
        teclear(qmp, "apagar")
        intro(qmp)
        paso("apagar: marcador", "APAGANDO", desde_ref=ref)
        inicio = time.time()
        salio = False
        while time.time() - inicio < 20:
            if proc.poll() is not None:
                salio = True
                break
            time.sleep(0.5)
        if salio:
            log(f"ok: QEMU cerró solo por ACPI (código {proc.returncode})")
        else:
            fallos.append("apagar-acpi")
            log("FALLA: QEMU no cerró tras 'apagar'")

        qmp.cerrar()
        qmp = None
    finally:
        if qmp:
            qmp.cerrar()
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.kill()

    log("RESULTADO: " + ("PASA" if not fallos else f"FALLA ({len(fallos)} fallos: {', '.join(fallos)})"))
    sys.exit(0 if not fallos else 1)


if __name__ == "__main__":
    main()
