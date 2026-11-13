#!/usr/bin/env python3
"""AntLex OS — clausura de DLLs para el portable de Windows (Fase 6).

Del árbol extraído del instalador qemu-w64 (Stefan Weil), calcula el
conjunto EXACTO de DLLs que qemu-system-x86_64.exe necesita (importaciones
recursivas por objdump, resolución insensible a mayúsculas) y copia exe +
DLLs al directorio destino.

Uso: resolver_dlls.py <dir_instalador_extraido> <dir_destino>
"""
import os
import shutil
import subprocess
import sys

# DLLs del propio Windows: no vienen en el instalador ni hay que llevarlas
SISTEMA = {
    "kernel32.dll", "user32.dll", "advapi32.dll", "shell32.dll", "ws2_32.dll",
    "winmm.dll", "msvcrt.dll", "ole32.dll", "oleaut32.dll", "uuid.dll",
    "gdi32.dll", "imm32.dll", "setupapi.dll", "version.dll", "dwmapi.dll",
    "shlwapi.dll", "crypt32.dll", "secur32.dll", "userenv.dll", "wininet.dll",
    "comdlg32.dll", "winspool.drv", "usp10.dll", "ntdll.dll", "dnsapi.dll",
    "iphlpapi.dll", "netapi32.dll", "wsock32.dll", "comctl32.dll", "mpr.dll",
    "netutils.dll", "wtsapi32.dll", "dbghelp.dll", "bcrypt.dll", "ncrypt.dll",
    "cryptui.dll", "wintrust.dll", "dwrite.dll", "rpcrt4.dll", "msimg32.dll",
    "gdiplus.dll", "opengl32.dll", "wldap32.dll", "mswsock.dll", "hid.dll",
    "api-ms-win-core-path-l1-1-0.dll", "api-ms-win-core-synch-l1-2-0.dll",
} | {
    f"api-ms-win-crt-{m}-l1-1-0.dll" for m in (
        "runtime", "math", "heap", "string", "stdio", "convert",
        "environment", "time", "locale", "filesystem", "misc", "utility",
    )
}


def imports(pe):
    out = subprocess.run(["objdump", "-p", pe], capture_output=True, text=True).stdout
    return sorted({l.split(":", 1)[1].strip() for l in out.splitlines() if "DLL Name" in l})


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    origen, destino = sys.argv[1], sys.argv[2]
    os.makedirs(destino, exist_ok=True)

    # índice insensible a mayúsculas de los archivos del instalador
    indice = {}
    for nombre in os.listdir(origen):
        if os.path.isfile(os.path.join(origen, nombre)):
            indice.setdefault(nombre.lower(), nombre)

    exe = "qemu-system-x86_64.exe"
    if exe not in indice:
        print(f"ERROR: {exe} no está en {origen}", file=sys.stderr)
        return 1

    necesarios = set()
    faltan = set()
    cola = [exe]
    vistos = set()
    while cola:
        actual = cola.pop()
        if actual in vistos:
            continue
        vistos.add(actual)
        ruta = os.path.join(origen, indice.get(actual, actual))
        if not os.path.exists(ruta):
            continue
        for dll in imports(ruta):
            d = dll.lower()
            if d in SISTEMA or d in vistos:
                continue
            if d in indice:
                necesarios.add(d)
                cola.append(d)
            else:
                faltan.add(dll)

    # copiar el exe + la clausura completa
    shutil.copy2(os.path.join(origen, indice[exe]), os.path.join(destino, indice[exe]))
    total = os.path.getsize(os.path.join(origen, indice[exe]))
    for d in sorted(necesarios):
        origen_f = os.path.join(origen, indice[d])
        shutil.copy2(origen_f, os.path.join(destino, indice[d]))
        total += os.path.getsize(origen_f)

    print(f"resolver_dlls: {len(necesarios) + 1} archivos "
          f"(exe + {len(necesarios)} DLLs), {total / 1048576:.1f} MiB")
    if faltan:
        # solo deben quedar DLLs del sistema no incluidas arriba
        print(f"resolver_dlls: AVISO, no halladas (¿sistema?): {', '.join(sorted(faltan))}",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
