#!/usr/bin/env python3
"""AntLex OS — arnés de la IA AntLex (Fase 4).

Arranca la imagen en QEMU y conversa DE VERDAD con AntLex por teclado QMP:
intenciones del sistema, memoria aprendida (aprende → pregunta → persistir
en ALFS → olvida), explicabilidad (por qué) y rechazo educado de temas
ajenos. Termina con `pruebas` (14/14) y apagado ACPI real.

Uso:  probar_antlex.py <imagen.img> <dir_salida> [--tiempo SEG]
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

# caracteres seguros con el mapa español: letras, dígitos, espacio, punto,
# guion y barra se inyectan igual en ES que en US; '=' es shift+0 en ES
QCODES = {" ": "spc", ".": "dot", "-": "minus", "/": "slash"}

PASOS_OK = 0
PASOS_MAL = 0


def log(msg):
    print(f"[probar_antlex] {msg}")


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
        if c == "/":  # en el mapa español la barra es shift+7
            qmp.combo(["shift", "7"])
            time.sleep(pausa)
            continue
        q = QCODES.get(c, c)
        if not (len(q) == 1 and q.isalnum()) and q not in QCODES.values():
            log(f"aviso: caracter no soportado en el arnés: {c!r}")
            continue
        qmp.tecla(q)
        time.sleep(pausa)


def teclear_con_igual(qmp, texto):
    """teclea `texto` con mapa español: '=' → shift+0, '/' → shift+7 y
    las MAYÚSCULAS → shift+letra (los qcodes de QMP son solo minúsculas)."""
    for c in texto:
        if c == "=":
            qmp.combo(["shift", "0"])  # '=' es shift+0 en ES
            time.sleep(0.045)
            continue
        if c == "/":
            qmp.combo(["shift", "7"])  # '/' es shift+7 en ES
            time.sleep(0.045)
            continue
        if "A" <= c <= "Z":
            qmp.combo(["shift", c.lower()])  # mayúscula
            time.sleep(0.045)
            continue
        q = QCODES.get(c, c)
        if not (len(q) == 1 and q.isalnum()) and q not in QCODES.values():
            log(f"aviso: caracter no soportado: {c!r}")
            continue
        qmp.tecla(q)
        time.sleep(0.045)


def intro(qmp):
    qmp.tecla("ret")
    time.sleep(0.30)


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


def paso(nombre, marca, ref, serial_path, limite=25.0):
    global PASOS_OK, PASOS_MAL
    _, pos = esperar(serial_path, marca, limite, desde=ref[0])
    if pos >= 0:
        ref[0] = pos + len(marca)
        PASOS_OK += 1
        log(f"ok: {nombre}")
        return True
    PASOS_MAL += 1
    log(f"FALLA: {nombre} (no se halló «{marca}»)")
    return False


def main():
    global PASOS_OK, PASOS_MAL
    ap = argparse.ArgumentParser()
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--tiempo", type=int, default=240)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    salida_abs = os.path.abspath(args.salida)
    serial_path = os.path.join(salida_abs, "serial_antlex.log")
    sock_path = os.path.join(salida_abs, "qmp.sock")
    # copia de la imagen: la sesión escribe en ALFS y no debe ensuciar la original
    img_prueba = os.path.join(salida_abs, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std"]
    for fw in FIRMWARE:  # directorios de firmware si existen (sandbox)
        if os.path.isdir(fw):
            cmd += ["-L", fw]
            break
    cmd += ["-hda", img_prueba]

    log(f"lanzando: {QEMU} -display ... (imagen {args.imagen})")
    with open(os.path.join(salida_abs, "qemu_salida.log"), "w") as fq:
        proc = subprocess.Popen(cmd, stdout=fq, stderr=subprocess.STDOUT)

    ref = [0.0]
    try:
        # 1) arranque hasta la consola
        _, pos = esperar(serial_path, "CONSOLA LISTA", args.tiempo)
        if pos < 0:
            log("FALLA: el sistema no arrancó (sin CONSOLA LISTA)")
            return 1
        ref[0] = pos
        log("arranque: CONSOLA LISTA")

        # pequeña espera al QMP
        for _ in range(50):
            if os.path.exists(sock_path):
                break
            time.sleep(0.1)
        qmp = Qmp(sock_path)

        # 2) presentación sin argumentos
        teclear(qmp, "antlex"); intro(qmp)
        paso("antlex: presentación", "a tu servicio", ref, serial_path)

        # 3) saludo
        teclear(qmp, "antlex hola"); intro(qmp)
        paso("saludo", "IA de este sistema", ref, serial_path)

        # 4) identidad (red neuronal)
        teclear(qmp, "antlex quien eres"); intro(qmp)
        paso("identidad", "IA embebida", ref, serial_path)

        # 5) memoria con datos en vivo
        teclear(qmp, "antlex cuanta memoria tienes"); intro(qmp)
        paso("memoria en vivo", "MiB totales", ref, serial_path)

        # 6) hora en vivo
        teclear(qmp, "antlex que hora es"); intro(qmp)
        paso("hora en vivo", "UTC", ref, serial_path)

        # 7) versión en vivo
        teclear(qmp, "antlex que version tienes"); intro(qmp)
        paso("versión en vivo", "AntLex OS v", ref, serial_path)

        # 8) ALFS
        teclear(qmp, "antlex que es alfs"); intro(qmp)
        paso("qué es ALFS", "AntLex File System", ref, serial_path)

        # 9) espacio en vivo
        teclear(qmp, "antlex cuanto espacio queda"); intro(qmp)
        paso("espacio en vivo", "bloques libres", ref, serial_path)

        # 10) explicar una respuesta de red
        teclear(qmp, "antlex por que"); intro(qmp)
        paso("por qué (red)", "red neuronal", ref, serial_path)
        paso("por qué (confianza)", "confianza", ref, serial_path)

        # 11) aprender un par nuevo
        teclear_con_igual(qmp, "antlex aprende color favorito = azul"); intro(qmp)
        paso("aprende", "aprendido: 'color favorito'", ref, serial_path)

        # 12) preguntar lo aprendido (la clave coincide por normalización)
        teclear(qmp, "antlex cual es tu color favorito"); intro(qmp)
        paso("respuesta aprendida", "(aprendido) azul", ref, serial_path)

        # 13) explicarlo: origen memoria aprendida
        teclear(qmp, "antlex por que"); intro(qmp)
        paso("por qué (aprendida)", "memoria aprendida", ref, serial_path)

        # 14) persistir en ALFS y verificar el archivo.
        #     Margen amplio (60 s): la escritura ATA emulada por TCG puede
        #     tardar cuando el runner va cargado (falló así en el CI del tag
        #     v1.2.0, lanzado en paralelo con el workflow de Release)
        teclear(qmp, "sincronizar"); intro(qmp)
        paso("sincronizar", "SINCRONIZADO", ref, serial_path, limite=60.0)
        teclear(qmp, "mostrar memoria/antlex.txt"); intro(qmp)
        paso("archivo de memoria en ALFS", "color favorito = azul", ref, serial_path)

        # 15) listar la memoria
        teclear(qmp, "antlex memoria"); intro(qmp)
        paso("memoria: lista", "memoria aprendida (1 de 64)", ref, serial_path)

        # 16) rechazo educado de temas ajenos (dos variedades)
        teclear(qmp, "antlex cual es la capital de francia"); intro(qmp)
        paso("rechazo: sin palabras conocidas", "No reconoc", ref, serial_path)
        teclear(qmp, "antlex como hacer una tarta de queso"); intro(qmp)
        paso("rechazo: cobertura insuficiente", "solo hablo de", ref, serial_path)
        teclear(qmp, "antlex por que"); intro(qmp)
        paso("por qué (rechazo)", "motivo", ref, serial_path)

        # 17) olvida
        teclear(qmp, "antlex olvida color favorito"); intro(qmp)
        paso("olvida", "olvidado: 'color favorito'", ref, serial_path)
        teclear(qmp, "antlex memoria"); intro(qmp)
        paso("memoria: vacía", "memoria vac", ref, serial_path)

        # 18) autopruebas bajo demanda (14/14 con la de AntLex)
        teclear(qmp, "pruebas"); intro(qmp)
        paso("autopruebas 14/14", "AUTOPRUEBAS 14/14 correctas", ref, serial_path, limite=40.0)

        # 19) apagado real por ACPI
        teclear(qmp, "apagar"); intro(qmp)
        _, pos = esperar(serial_path, "APAGANDO", 30.0, desde=ref[0])
        if pos >= 0:
            PASOS_OK += 1
            log("ok: apagar: marcador")
        else:
            PASOS_MAL += 1
            log("FALLA: apagar: marcador")

        # esperar a que QEMU muera solo (ACPI)
        t0 = time.time()
        while time.time() - t0 < 30:
            if proc.poll() is not None:
                break
            time.sleep(0.5)
        if proc.poll() is None:
            log("FALLA: QEMU sigue vivo tras apagar (ACPI no cerró)")
            PASOS_MAL += 1
            proc.kill()
        else:
            PASOS_OK += 1
            log(f"ok: QEMU cerró solo por ACPI (código {proc.returncode})")

        qmp.cerrar()
    finally:
        if proc.poll() is None:
            proc.kill()
        # copia del serial para el registro de la corrida
        destino = os.path.join(args.salida, "serial_final.log")
        if os.path.exists(serial_path):
            shutil.copyfile(serial_path, destino)

    log(f"RESULTADO: {'PASA' if PASOS_MAL == 0 and PASOS_OK >= 24 else 'FALLA'} "
        f"({PASOS_OK} ok, {PASOS_MAL} fallos)")
    return 0 if PASOS_MAL == 0 and PASOS_OK >= 24 else 1


if __name__ == "__main__":
    sys.exit(main())
