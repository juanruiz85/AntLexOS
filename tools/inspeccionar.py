#!/usr/bin/env python3
"""Inspecciona memoria física de la QEMU en ejecución vía QMP (human-monitor-command)."""
import json
import socket
import subprocess
import sys
import time
import os

img = sys.argv[1] if len(sys.argv) > 1 else "zig-out/antlexos.img"
TC = "/home/z/my-project/toolchain"
sock = os.environ.get("INSP_SOCK", "/home/z/my-project/AntLexOS/build/pruebas/insp.sock")

proc = subprocess.Popen([
    f"{TC}/bin/qemu-system-x86_64", "-display", "none", "-serial", "null",
    "-qmp", f"unix:{sock},server,nowait", "-m", "512", "-vga", "std",
    "-L", f"{TC}/qemu-root/usr/share/qemu", "-L", f"{TC}/qemu-root/usr/share/seabios",
    "-hda", img,
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(3)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sock)
s.recv(65536)
s.sendall(b'{"execute":"qmp_capabilities"}\n')
s.recv(65536)


def hmp(cmd):
    s.sendall(json.dumps({"execute": "human-monitor-command",
                          "arguments": {"command-line": cmd}}).encode() + b"\n")
    r = json.loads(s.recv(65536).decode())
    return r.get("return", "")


for addr in (0x90000, 0x91000, 0x92000, 0x93000, 0x8290):
    print(f"--- {addr:#x} ---")
    print(hmp(f"xp /8gx {addr}"))

print("--- info registers ---")
print(hmp("info registers"))
s.close()
proc.terminate()
