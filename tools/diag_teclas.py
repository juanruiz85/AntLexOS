#!/usr/bin/env python3
"""AntLex OS — diagnóstico de pérdida de teclas.

Arranca el kernel, teclea `escribir /t1.b64 <96 chars>` a 45 ms y
`/t2.b64` a 150 ms, y comprueba `atributos` de ambos. Con la traza '!'
en teclado.empujar() (una '!' por tecla perdida del anillo) el serial
dice si las pérdidas son del anillo del kernel o de antes (cola PS/2
de QEMU). Uso:
  source tools/sandbox_entorno.sh && python3 tools/diag_teclas.py
"""
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
D = "/tmp/antlex_diag_teclas"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# mezcla realista de base64: mayúsculas, minúsculas, dígitos y '+'
CHUNK96 = ("zfgWGHQWzkx4U6qovNNxwohvCwZc1wW0g504YDIew0yjXxzyaW0zjxXzyasxgud"
           "XlecnLmWGGiasEqASGtdqosqXAUvqkjmrLDxlavDQhbvmhTUypzZxcvb+nm")


def main():
    shutil.rmtree(D, ignore_errors=True)
    os.makedirs(D)
    shutil.copyfile(os.path.join(REPO, "zig-out/antlexos.img"), f"{D}/prueba.img")

    # servidor TLS como el del arnés (para reproducir su secuencia exacta)
    for c in [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650",
         "-nodes", "-keyout", f"{D}/ca.key", "-out", f"{D}/ca.crt", "-subj", "/CN=CA AntLex"],
        ["openssl", "req", "-newkey", "rsa:2048", "-sha256", "-nodes",
         "-keyout", f"{D}/srv.key", "-out", f"{D}/srv.csr", "-subj", "/CN=antlex.test"],
        ["openssl", "x509", "-req", "-in", f"{D}/srv.csr", "-CA", f"{D}/ca.crt",
         "-CAkey", f"{D}/ca.key", "-CAcreateserial", "-out", f"{D}/srv.crt", "-days", "3650",
         "-sha256", "-extfile", "/dev/stdin"],
    ]:
        subprocess.run(c, input=b"subjectAltName=DNS:antlex.test\n" if "x509" in c[1] else None,
                       check=True, capture_output=True)
    os.makedirs(f"{D}/www", exist_ok=True)
    open(f"{D}/www/x.txt", "wb").write(b"X" * 1024)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8443),
                                          lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=f"{D}/www", **kw))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(f"{D}/srv.crt", f"{D}/srv.key")
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    serial_path = f"{D}/s.log"
    sock_path = f"{D}/qmp.sock"

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}", "-m", "512",
           "-vga", "std", "-qmp", f"unix:{sock_path},server,nowait",
           "-netdev", "user,id=red0",
           "-device", "virtio-net-pci,netdev=red0,disable-legacy=on",
           "-hda", f"{D}/prueba.img"]
    proc = subprocess.Popen(cmd, stdout=open(f"{D}/q.log", "w"), stderr=subprocess.STDOUT)

    _, pos = esperar(serial_path, "ESCRITORIO LISTO", 90)
    if pos < 0:
        print("no arrancó")
        proc.kill()
        return 1
    for _ in range(50):
        if os.path.exists(sock_path):
            break
        time.sleep(0.1)
    qmp = Qmp(sock_path)
    time.sleep(0.5)

    # reproducir el pre-estado del arnés: https fallido (sin CA anclada)
    teclear(qmp, "https 10.0.2.2 8443 antlex.test /x.txt")
    intro(qmp)
    time.sleep(12)  # deja que el handshake falle solo (timeout de 8 s)

    # t1: 45 ms por tecla (lo que usan los arneses), tras un limpiar
    teclear(qmp, "limpiar"); intro(qmp); time.sleep(0.4)
    teclear(qmp, f"escribir /t1.b64 {CHUNK96}", 0.045)
    intro(qmp)
    time.sleep(3)
    # t2: 150 ms por tecla, también con limpiar
    teclear(qmp, "limpiar"); intro(qmp); time.sleep(0.4)
    teclear(qmp, f"escribir /t2.b64 {CHUNK96}", 0.150)
    intro(qmp)
    time.sleep(3)

    for f in ("/t1.b64", "/t2.b64"):
        teclear(qmp, f"atributos {f}")
        intro(qmp)
        time.sleep(1)
        teclear(qmp, f"mostrar {f}")
        intro(qmp)
        time.sleep(2)
    teclear(qmp, "apagar")
    intro(qmp)
    time.sleep(6)
    proc.kill()

    s = open(serial_path, encoding="latin-1").read()
    perdidas = s.count("!")
    print(f"teclas perdidas en el anillo (!): {perdidas}")
    for linea in s.splitlines():
        if "t1.b64" in linea or "t2.b64" in linea or "creado" in linea:
            print("  " + linea.strip())
    # extraer el contenido volcado por leer
    import re
    for m in re.finditer(r"antlex:/> mostrar /t([12])\.b64\n(.*?)\nantlex", s, re.S):
        contenido = m.group(2).replace("\n", "")
        print(f"/t{m.group(1)}.b64 contenido ({len(contenido)} chars): {contenido!r}")
        esperado = CHUNK96
        faltan = [c for c in esperado if c not in contenido]
        # diff posicional
        i = j = 0
        while i < len(esperado) and j < len(contenido):
            if esperado[i] != contenido[j]:
                print(f"  primera divergencia en {i}: esperado {esperado[i]!r} obtenido {contenido[j]!r}")
                break
            i += 1
            j += 1
        else:
            print("  prefijo común completo hasta", i, j)
    print(f"(chunk tecleado: {len(CHUNK96)} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
