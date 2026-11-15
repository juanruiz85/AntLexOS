#!/usr/bin/env python3
"""AntLex OS — arnés de TLS 1.3 (Fase 9b, escalera 3 del plan).

Genera una CA de prueba RSA-2048/SHA-256 y un certificado de servidor
(CN=antlex.test), levanta un HTTPS real con Python (TLS 1.3, suite única
TLS_AES_128_GCM_SHA256) en 127.0.0.1:8443 — que slirp expone al invitado
como 10.0.2.2 — y comprueba el TLS del kernel de punta a punta:

  1. NEGATIVA: `https` contra el servidor SIN anclar la CA de pruebas debe
     fallar con «la cadena no llega a ninguna raíz anclada» (el pinning
     funciona de verdad: un certificado desconocido no pasa).
  2. Se escribe /ca.b64 en el ALFS del invitado por la consola (escribir +
     anexar en trozos de 96 caracteres) y `red ca /ca.b64` la ancla.
  3. POSITIVA: el handshake completo (X25519 + AES-128-GCM, Certificate,
  CertificateVerify RSA-PSS y Finished) y un GET con respuesta EXACTA.

Termina con apagado ACPI real. Uso:
  probar_tls.py <imagen.img> <dir_salida> [--tiempo SEG]
"""
import argparse
import base64
import http.server
import os
import shutil
import ssl
import socket
import ssl as ssl_mod
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp, teclear, intro, esperar, FIRMWARE  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
PUERTO = 8443
HOST = "antlex.test"
CUERPO = b"TLS-1.3-ANTLEX " * 64  # 1024 bytes

PASOS_OK = 0
PASOS_MAL = 0


def log(msg):
    print(f"[probar_tls] {msg}", flush=True)


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
    """CA de prueba + certificado del servidor (RSA-2048, SHA-256)."""
    cmds = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
         "-days", "3650", "-nodes", "-keyout", f"{d}/ca.key",
         "-out", f"{d}/ca.crt", "-subj", "/CN=CA AntLex Prueba"],
        ["openssl", "req", "-newkey", "rsa:2048", "-sha256", "-nodes",
         "-keyout", f"{d}/srv.key", "-out", f"{d}/srv.csr",
         "-subj", f"/CN={HOST}"],
        ["openssl", "x509", "-req", "-in", f"{d}/srv.csr",
         "-CA", f"{d}/ca.crt", "-CAkey", f"{d}/ca.key",
         "-CAcreateserial", "-out", f"{d}/srv.crt", "-days", "3650",
         "-sha256", "-extfile", "/dev/stdin"],
    ]
    ext = f"subjectAltName=DNS:{HOST}\n"
    for c in cmds[:-1]:
        subprocess.run(c, check=True, capture_output=True)
    subprocess.run(cmds[-1], input=ext.encode(), check=True, capture_output=True)
    subprocess.run(["openssl", "x509", "-in", f"{d}/ca.crt", "-outform", "DER",
                    "-out", f"{d}/ca.der"], check=True, capture_output=True)
    der = open(f"{d}/ca.der", "rb").read()
    log(f"CA de prueba: DER {len(der)} bytes → base64 {len(base64.b64encode(der))}")
    return der


class Servidor(threading.Thread):
    """HTTPS TLS 1.3 con la suite única del kernel, sirviendo un directorio."""

    daemon = True

    def __init__(self, raiz, d):
        super().__init__()
        self.httpd = http.server.ThreadingHTTPServer(
            ("127.0.0.1", PUERTO),
            lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=raiz, **kw))
        ctx = ssl_mod.SSLContext(ssl_mod.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl_mod.TLSVersion.TLSv1_3
        # sin set_ciphersuites (no está en este Python): el cliente solo
        # ofrece TLS_AES_128_GCM_SHA256, así que el servidor elige esa
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
    serial_path = os.path.join(salida_abs, "serial_tls.log")
    sock_path = os.path.join(salida_abs, "qmp.sock")
    img_prueba = os.path.join(salida_abs, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    der_ca = generar_certificados(salida_abs)
    b64 = base64.b64encode(der_ca).decode()

    # contenido servido
    raiz = os.path.join(salida_abs, "www")
    os.makedirs(raiz, exist_ok=True)
    with open(os.path.join(raiz, "tls.txt"), "wb") as f:
        f.write(CUERPO)

    srv = Servidor(raiz, salida_abs)
    srv.start()
    time.sleep(0.5)

    # respuesta exacta esperada, consultándola nosotros por TLS (verificando
    # contra la CA de pruebas, como hará el kernel con red ca)
    ctx = ssl_mod.create_default_context(cafile=os.path.join(salida_abs, "ca.crt"))
    with socket.create_connection(("127.0.0.1", PUERTO), timeout=10) as s:
        with ctx.wrap_socket(s, server_hostname=HOST) as ts:
            ts.sendall(f"GET /tls.txt HTTP/1.1\r\nHost: {HOST}\r\n"
                       "User-Agent: AntLexOS\r\nConnection: close\r\n\r\n".encode())
            esperado = b""
            while True:
                trozo = ts.recv(4096)
                if not trozo:
                    break
                esperado += trozo
    log(f"respuesta esperada: {len(esperado)} bytes")

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std"]
    for fw in FIRMWARE:
        if os.path.isdir(fw):
            cmd += ["-L", fw]
            break
    cmd += ["-netdev", "user,id=red0",
            "-device", "virtio-net-pci,netdev=red0,disable-legacy=on",
            "-hda", img_prueba]

    log(f"lanzando: {QEMU} -display ... (HTTPS TLS 1.3 en 127.0.0.1:{PUERTO})")
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

        # 1) NEGATIVA: sin la CA anclada el handshake debe llegar hasta la
        #    verificación de cadena y RECHAZAR (el pinning protege de verdad)
        teclear(qmp, f"https 10.0.2.2 {PUERTO} {HOST} /tls.txt"); intro(qmp)
        paso("certificado desconocido RECHAZADO",
             "tls: la cadena no llega a ninguna raíz anclada", ref, serial_path, limite=60.0)

        # 2) escribir la CA en el ALFS por la consola (trozos de 96) y anclarla
        trozos = [b64[i:i + 96] for i in range(0, len(b64), 96)]
        log(f"escribiendo /ca.b64 en {len(trozos)} trozos…")
        teclear(qmp, f"escribir /ca.b64 {trozos[0]}"); intro(qmp)
        paso("primer trozo de la CA", "creado /ca.b64", ref, serial_path, limite=30.0)
        for i, t in enumerate(trozos[1:], start=2):
            teclear(qmp, f"anexar /ca.b64 {t}"); intro(qmp)
            time.sleep(0.15)
        teclear(qmp, "red ca /ca.b64"); intro(qmp)
        paso("CA de pruebas anclada (red ca)", "red: ca extra anclada", ref, serial_path, limite=30.0)

        # 3) POSITIVA: handshake completo y GET con longitud exacta
        teclear(qmp, f"https 10.0.2.2 {PUERTO} {HOST} /tls.txt"); intro(qmp)
        paso("handshake TLS 1.3 completo y verificado",
             "tls: handshake completo y verificado", ref, serial_path, limite=60.0)
        paso("longitud exacta de la respuesta",
             f"https: {len(esperado)} bytes", ref, serial_path, limite=30.0)
        paso("estado HTTP 200", "· HTTP/1.1 200 OK", ref, serial_path, limite=10.0)

        # 4) apagado limpio por ACPI
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
