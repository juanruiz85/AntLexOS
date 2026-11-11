#!/usr/bin/env python3
"""Diagnóstico UEFI: lanza QEMU+OVMF, espera, toma captura y muestra debugcon."""
import os
import socket
import subprocess
import sys
import time

TC = "/home/z/my-project/toolchain"
OUT = "/home/z/my-project/AntLexOS/build/depura"
os.makedirs(OUT, exist_ok=True)
img = sys.argv[1] if len(sys.argv) > 1 else "zig-out/antlexos.img"
sock = f"{OUT}/qmp.sock"
for f in (f"{OUT}/serial.log", f"{OUT}/ovmf.log", sock):
    if os.path.exists(f):
        os.unlink(f)

cmd = [
    f"{TC}/bin/qemu-system-x86_64", "-display", "none",
    "-serial", f"file:{OUT}/serial.log",
    "-qmp", f"unix:{sock},server,nowait",
    "-debugcon", f"file:{OUT}/ovmf.log", "-global", "isa-debugcon.iobase=0x402",
    "-m", "512", "-vga", "std",
    "-drive", f"if=pflash,format=raw,file={TC}/qemu-root/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on",
    "-drive", f"if=pflash,format=raw,file={OUT}/OVMF_VARS.fd",
    "-hda", img,
    "-L", f"{TC}/qemu-root/usr/share/qemu",
    "-L", f"{TC}/qemu-root/usr/share/seabios",
    "-L", f"{TC}/qemu-root/usr/lib/ipxe/qemu",
]
print("cmd:", " ".join(cmd[:6]), "...")
proc = subprocess.Popen(cmd)
time.sleep(1)
if proc.poll() is not None:
    print("QEMU MURIÓ, código", proc.returncode)
    sys.exit(1)
time.sleep(float(sys.argv[2]) if len(sys.argv) > 2 else 30)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sock)
s.recv(65536)
s.sendall(b'{"execute":"qmp_capabilities"}\n')
s.recv(65536)
s.sendall(b'{"execute":"screendump","arguments":{"filename":"%s/captura.ppm"}}\n' % OUT.encode())
try:
    print(s.recv(65536).decode())
except Exception as e:
    print("qmp:", e)
s.close()
proc.terminate()

print("=== serial.log ===")
try:
    print(open(f"{OUT}/serial.log", errors="replace").read()[-1500:])
except Exception as e:
    print(e)
print("=== ovmf.log (final) ===")
try:
    lineas = open(f"{OUT}/ovmf.log", errors="replace").read().splitlines()
    print("\n".join(lineas[-25:]))
except Exception as e:
    print(e)
