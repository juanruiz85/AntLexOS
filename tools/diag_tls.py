#!/usr/bin/env python3
"""AntLex OS — diagnóstico TLS: servidor local + captura pcap + serial.

Lanza el kernel con `https` contra un servidor Python TLS 1.3 local y
captura el tráfico (filter-dump) y el serial para depurar el handshake.
Uso:  source tools/sandbox_entorno.sh && python3 tools/diag_tls.py
"""
import http.server
import os
import shutil
import ssl
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp, teclear, intro  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
D = "/tmp/antlex_diag_tls"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    shutil.rmtree(D, ignore_errors=True)
    os.makedirs(D)
    shutil.copyfile(os.path.join(REPO, "zig-out/antlexos.img"), f"{D}/prueba.img")

    for c in [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650",
         "-nodes", "-keyout", f"{D}/ca.key", "-out", f"{D}/ca.crt", "-subj", "/CN=CA AntLex Prueba"],
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

    cmd = [QEMU, "-display", "none", "-serial", f"file:{D}/s.log", "-m", "512",
           "-vga", "std", "-qmp", f"unix:{D}/qmp.sock,server,nowait",
           "-netdev", "user,id=red0", "-device", "virtio-net-pci,netdev=red0,disable-legacy=on",
           "-object", f"filter-dump,id=f0,netdev=red0,file={D}/dump.pcap",
           "-hda", f"{D}/prueba.img"]
    proc = subprocess.Popen(cmd, stdout=open(f"{D}/q.log", "w"), stderr=subprocess.STDOUT)

    t0 = time.time()
    while time.time() - t0 < 60 and not os.path.exists(f"{D}/qmp.sock"):
        time.sleep(0.2)
    time.sleep(12)
    qmp = Qmp(f"{D}/qmp.sock")
    teclear(qmp, "https 10.0.2.2 8443 antlex.test /x.txt")
    intro(qmp)
    time.sleep(25)
    proc.kill()

    print("=== serial ===")
    os.system(f"grep -a 'tls:' {D}/s.log | head -20")
    print("=== pcap ===")
    data = open(f"{D}/dump.pcap", "rb").read()
    off, n = 24, 0
    while off + 16 <= len(data):
        _, _, cap, _ = struct.unpack("<IIII", data[off:off + 16])
        if cap > 65535:
            break
        pkt = data[off + 16:off + 16 + cap]
        off += 16 + cap
        n += 1
        if len(pkt) < 38:
            continue
        if struct.unpack(">H", pkt[12:14])[0] != 0x0800:
            continue
        ipp = pkt[14:]
        ihl = (ipp[0] & 0xF) * 4
        if ipp[9] != 6 or len(ipp) < ihl + 14:
            continue
        src = ".".join(map(str, ipp[12:16]))
        dst = ".".join(map(str, ipp[16:20]))
        tcp = ipp[ihl:]
        sport = struct.unpack(">H", tcp[0:2])[0]
        dport = struct.unpack(">H", tcp[2:4])[0]
        flags = tcp[13]
        doff = (tcp[12] >> 4) * 4
        payload = tcp[doff:] if len(tcp) > doff else b""
        f = "".join(x for x, b in zip("FSRPAU", [1, 2, 4, 8, 16, 32]) if flags & b)
        info = ""
        if payload:
            rt = payload[0]
            if rt in (20, 21, 22, 23):
                rl = struct.unpack(">H", payload[3:5])[0]
                info = f"TLS tipo={rt} len={rl}"
                if rt == 23 and len(payload) > 5:
                    # listar todos los registros del segmento
                    o = 0
                    regs = []
                    while o + 5 <= len(payload):
                        t2 = payload[o]
                        l2 = struct.unpack(">H", payload[o + 3:o + 5])[0]
                        regs.append(f"{t2}/{l2}")
                        o += 5 + l2
                    info = "registros " + " ".join(regs)
        print(f"#{n} {src}:{sport}->{dst}:{dport} [{f}] len={len(payload)} {info}")


if __name__ == "__main__":
    main()
