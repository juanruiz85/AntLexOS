#!/usr/bin/env python3
"""AntLex OS — arnés de TCP (Fase 9b, escalera 2 del plan).

Levanta un servidor HTTP real (python3 -m http.server) en 127.0.0.1:8123 —
que la red de usuario de QEMU expone al invitado como 10.0.2.2 — y comprueba
el cliente TCP del kernel de punta a punta: handshake (SYN/SYN-ACK/ACK),
envío de una petición GET, recepción segmentada de la respuesta con ACKs,
lectura del FIN y cierre limpio. Termina con apagado ACPI real.

Uso:  probar_tcp.py <imagen.img> <dir_salida> [--tiempo SEG]
"""
import argparse
import http.server
import os
import shutil
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp, teclear, intro, esperar, FIRMWARE  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
PUERTO = 8123
CUERPO = b"HOLA-TCP-ANTLEX " * 32  # 512 bytes de cuerpo conocido

PASOS_OK = 0
PASOS_MAL = 0


def log(msg):
    print(f"[probar_tcp] {msg}", flush=True)


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


class Servidor(threading.Thread):
    """http.server en un hilo del propio arnés (127.0.0.1:8123)."""

    daemon = True

    def __init__(self, raiz):
        super().__init__()
        self.httpd = http.server.ThreadingHTTPServer(
            ("127.0.0.1", PUERTO),
            lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=raiz, **kw))

    def run(self):
        self.httpd.serve_forever()


def main():
    global PASOS_OK, PASOS_MAL
    ap = argparse.ArgumentParser()
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--tiempo", type=int, default=240)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    salida_abs = os.path.abspath(args.salida)
    serial_path = os.path.join(salida_abs, "serial_tcp.log")
    sock_path = os.path.join(salida_abs, "qmp.sock")
    img_prueba = os.path.join(salida_abs, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    # contenido servido: prueba.txt (512 B) y hola.txt (44 B)
    raiz = os.path.join(salida_abs, "www")
    os.makedirs(raiz, exist_ok=True)
    with open(os.path.join(raiz, "prueba.txt"), "wb") as f:
        f.write(CUERPO)
    with open(os.path.join(raiz, "hola.txt"), "wb") as f:
        f.write("HOLA desde el arnés de TCP de AntLex OS\n".encode("utf-8"))

    srv = Servidor(raiz)
    srv.start()
    time.sleep(0.5)

    # tamaño exacto de la respuesta HTTP (cabeceras incluidas) tal como la
    # verá el kernel, consultando nosotros mismos el servidor
    with socket.create_connection(("127.0.0.1", PUERTO), timeout=5) as s:
        s.sendall(b"GET /prueba.txt HTTP/1.1\r\nHost: 10.0.2.2\r\n"
                  b"User-Agent: AntLexOS\r\nConnection: close\r\n\r\n")
        esperado = b""
        while True:
            trozo = s.recv(4096)
            if not trozo:
                break
            esperado += trozo
    log(f"respuesta esperada: {len(esperado)} bytes (cuerpo {len(CUERPO)})")

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std"]
    for fw in FIRMWARE:
        if os.path.isdir(fw):
            cmd += ["-L", fw]
            break
    cmd += ["-netdev", "user,id=red0",
            "-device", "virtio-net-pci,netdev=red0,disable-legacy=on",
            "-hda", img_prueba]

    log(f"lanzando: {QEMU} -display ... (servidor HTTP en 127.0.0.1:{PUERTO})")
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

        # 1) GET del archivo grande: handshake + datos segmentados + FIN.
        # Orden del serial: conectado … cerrado y LUEGO el resumen
        # «tcp: N bytes · HTTP/1.0 200 OK» (cada paso busca a partir del
        # anterior, así que los marcadores van en este orden)
        teclear(qmp, f"tcp 10.0.2.2 {PUERTO} /prueba.txt"); intro(qmp)
        paso("conexión TCP (handshake)",
             f"red: tcp conectado 10.0.2.2:{PUERTO}", ref, serial_path, limite=30.0)
        paso("cierre limpio (FIN/ACK)", "red: tcp cerrado", ref, serial_path, limite=40.0)
        paso("longitud exacta de la respuesta",
             f"tcp: {len(esperado)} bytes", ref, serial_path, limite=10.0)
        paso("estado HTTP 200", "· HTTP/1.0 200 OK", ref, serial_path, limite=10.0)

        # 2) segunda conexión (puerto local distinto, caché ARP ya llena)
        teclear(qmp, f"tcp 10.0.2.2 {PUERTO} /hola.txt"); intro(qmp)
        paso("segunda conexión", f"red: tcp conectado 10.0.2.2:{PUERTO}", ref, serial_path, limite=30.0)
        paso("segundo cierre y cuerpo", "· HTTP/1.0 200 OK", ref, serial_path, limite=40.0)

        # 3) apagado limpio por ACPI
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
