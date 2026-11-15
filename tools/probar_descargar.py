#!/usr/bin/env python3
"""AntLex OS — arnés de la tienda (Fase 9b, escalera 4).

Sirve por HTTPS local (con la misma CA de pruebas de probar_tls.py) la
estructura del repo de la tienda juanruiz85/AntLexApps —INDICE y
APPS/CALC.ALX con el sha256 real— y comprueba de punta a punta:

  1. anclar la CA con `red ca` (base64 por la consola),
  2. `red tienda 10.0.2.2 8443 antlex.test` (objetivo editable),
  3. `tienda` — listado con el nombre y la descripción,
  4. `descargar CALC` — descarga, verificación de sha256 e instalación en
     /APPS/CALC.ALX con bit de ejecutable,
  5. `atributos /APPS/CALC.ALX` — tamaño exacto y bit de ejecutable,
  6. negativa: `descargar INEXISTENTE` no debe instalar nada.

Termina con apagado ACPI real. Uso:
  probar_descargar.py <imagen.img> <dir_salida> [--tiempo SEG]
"""
import argparse
import base64
import hashlib
import http.server
import os
import shutil
import ssl
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp, teclear, intro, esperar, FIRMWARE  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
PUERTO = 8443
HOST = "antlex.test"

PASOS_OK = 0
PASOS_MAL = 0


def log(msg):
    print(f"[probar_descargar] {msg}", flush=True)


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


def generar_certificados(d):
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                    "-days", "3650", "-nodes", "-keyout", f"{d}/ca.key",
                    "-out", f"{d}/ca.crt", "-subj", "/CN=CA AntLex Prueba"],
                   check=True, capture_output=True)
    subprocess.run(["openssl", "req", "-newkey", "rsa:2048", "-sha256", "-nodes",
                    "-keyout", f"{d}/srv.key", "-out", f"{d}/srv.csr",
                    "-subj", f"/CN={HOST}"], check=True, capture_output=True)
    subprocess.run(["openssl", "x509", "-req", "-in", f"{d}/srv.csr",
                    "-CA", f"{d}/ca.crt", "-CAkey", f"{d}/ca.key",
                    "-CAcreateserial", "-out", f"{d}/srv.crt", "-days", "3650",
                    "-sha256", "-extfile", "/dev/stdin"],
                   input=f"subjectAltName=DNS:{HOST}\n".encode(),
                   check=True, capture_output=True)
    subprocess.run(["openssl", "x509", "-in", f"{d}/ca.crt", "-outform", "DER",
                    "-out", f"{d}/ca.der"], check=True, capture_output=True)
    return open(f"{d}/ca.der", "rb").read()


class Servidor(threading.Thread):
    """HTTPS con la estructura del repo de la tienda."""

    daemon = True

    def __init__(self, raiz, d):
        super().__init__()

        class Handler(http.server.SimpleHTTPRequestHandler):
            protocol_version = "HTTP/1.1"  # GitHub habla 1.1, no 1.0

        self.httpd = http.server.ThreadingHTTPServer(
            ("127.0.0.1", PUERTO),
            lambda *a, **kw: Handler(*a, directory=raiz, **kw))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(f"{d}/srv.crt", f"{d}/srv.key")
        self.httpd.socket = ctx.wrap_socket(self.httpd.socket, server_side=True)

    def run(self):
        self.httpd.serve_forever()


def main():
    global PASOS_OK, PASOS_MAL
    ap = argparse.ArgumentParser()
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--tiempo", type=int, default=300)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    salida_abs = os.path.abspath(args.salida)
    serial_path = os.path.join(salida_abs, "serial_descargar.log")
    sock_path = os.path.join(salida_abs, "qmp.sock")
    img_prueba = os.path.join(salida_abs, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    # CALC.ALX real de la build (zig-out/apps/CALC.ALX)
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    alx = os.path.join(repo, "zig-out", "apps", "CALC.ALX")
    if not os.path.exists(alx):
        log(f"FALLA: no existe {alx} (ejecuta zig build antes)")
        return 1
    calc = open(alx, "rb").read()
    sha = hashlib.sha256(calc).hexdigest()
    log(f"CALC.ALX: {len(calc)} bytes, sha256 {sha[:16]}…")

    der_ca = generar_certificados(salida_abs)
    b64 = base64.b64encode(der_ca).decode()

    # estructura del repo tal como la pide el kernel
    raiz = os.path.join(salida_abs, "www", "juanruiz85", "AntLexApps", "main")
    os.makedirs(os.path.join(raiz, "APPS"), exist_ok=True)
    indice = (f"CALC|APPS/CALC.ALX|{len(calc)}|{sha}|calculadora con IA (suma y resta por lenguaje natural)\n"
              f"RELOJ|APPS/RELOJ.ALX|0|{'0'*64}|reloj analogico y digital (placeholder)\n")
    open(os.path.join(raiz, "INDICE"), "w").write(indice)
    open(os.path.join(raiz, "APPS", "CALC.ALX"), "wb").write(calc)

    srv = Servidor(os.path.join(salida_abs, "www"), salida_abs)
    srv.start()
    time.sleep(0.5)

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std"]
    for fw in FIRMWARE:
        if os.path.isdir(fw):
            cmd += ["-L", fw]
            break
    cmd += ["-netdev", "user,id=red0",
            "-device", "virtio-net-pci,netdev=red0,disable-legacy=on",
            "-object", f"filter-dump,id=f0,netdev=red0,file={salida_abs}/dump.pcap",
            "-hda", img_prueba]

    log(f"lanzando: {QEMU} -display … (tienda local en 127.0.0.1:{PUERTO})")
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

        # 1) anclar la CA de pruebas (limpiar cada 4 trozos: ver probar_tls.py)
        trozos = [b64[i:i + 96] for i in range(0, len(b64), 96)]
        log(f"escribiendo /ca.b64 en {len(trozos)} trozos…")
        teclear(qmp, "limpiar"); intro(qmp); time.sleep(0.4)
        teclear(qmp, f"escribir /ca.b64 {trozos[0]}"); intro(qmp)
        paso("primer trozo de la CA", "creado /ca.b64", ref, serial_path, limite=30.0)
        for i, t in enumerate(trozos[1:]):
            if i % 4 == 3:
                teclear(qmp, "limpiar"); intro(qmp); time.sleep(0.4)
            teclear(qmp, f"anexar /ca.b64 {t}"); intro(qmp)
            time.sleep(0.2)
        teclear(qmp, "atributos /ca.b64"); intro(qmp)
        paso("CA completa en disco", f"/ca.b64: archivo, {len(b64)} bytes", ref, serial_path, limite=15.0)
        teclear(qmp, "red ca /ca.b64"); intro(qmp)
        paso("CA anclada", "red: ca extra anclada", ref, serial_path, limite=30.0)

        # 2) apuntar la tienda al servidor local
        teclear(qmp, f"red tienda 10.0.2.2 {PUERTO} {HOST}"); intro(qmp)
        paso("objetivo de la tienda", "red: tienda ->", ref, serial_path, limite=20.0)

        # 3) listado
        teclear(qmp, "tienda"); intro(qmp)
        paso("handshake TLS de la tienda", "tls: handshake completo y verificado", ref, serial_path, limite=60.0)
        paso("entrada CALC del índice", "tienda: CALC - calculadora", ref, serial_path, limite=10.0)
        paso("recuento de aplicaciones", "tienda: 2 aplicaciones", ref, serial_path, limite=10.0)

        # 4) descarga + verificación + instalación
        teclear(qmp, "descargar CALC"); intro(qmp)
        paso("sha256 verificado", "descargar: CALC verificado (sha256 ok", ref, serial_path, limite=60.0)
        paso("instalado en /APPS", "descargar: instalado /APPS/CALC.ALX", ref, serial_path, limite=15.0)

        # 5) atributos: tamaño exacto y bit de ejecutable
        teclear(qmp, "atributos /APPS/CALC.ALX"); intro(qmp)
        paso("tamaño exacto del archivo", f", {len(calc)} bytes", ref, serial_path, limite=15.0)
        paso("bit de ejecutable activo", "EJECUTABLE", ref, serial_path, limite=10.0)

        # 6) negativa: app inexistente
        teclear(qmp, "descargar INEXISTENTE"); intro(qmp)
        paso("app inexistente rechazada", "no hay ninguna aplicacion llamada INEXISTENTE", ref, serial_path, limite=60.0)

        # 7) apagado limpio por ACPI
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
