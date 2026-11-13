#!/usr/bin/env python3
"""AntLex OS — arnés del escritorio (Fase 5).

Arranca la imagen en QEMU y ejercita la GUI de verdad:
menú INICIO, apertura de ventanas, navegación del explorador por clic+INTRO,
edición y guardado en ALFS, verificación desde el TERMINAL, chat de AntLex,
arrastre de ventana, cierre por [X] y ESC, y apagado ACPI desde el menú.

El ratón se mueve por HMP (mouse_move/mouse_button vía human-monitor-command):
input-send-event de QMP NO llega al PS/2 en QEMU 11 — ver docs/PRUEBAS.md.

Uso:  probar_escritorio.py <imagen.img> <dir_salida> [--tiempo SEG]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_antlex import Qmp, teclear_con_igual  # teclado ES con = y /  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")

PASOS_OK = 0
PASOS_MAL = 0

# geometría replicada de src/kernel/gui.zig (1024x768 en BIOS)
ANCHO, ALTO = 1024, 768
Y_BARRA = ALTO - 28
BOTONES = {  # centros de los botones de la barra de tareas
    "inicio": (30, ALTO - 14),
    "terminal": (104, ALTO - 14),
    "chat": (176, ALTO - 14),
    "explorador": (256, ALTO - 14),
    "editor": (338, ALTO - 14),
    "acerca": (402, ALTO - 14),
}
MENU_Y = Y_BARRA - (5 * 20 + 8) - 2  # menú: 5 ítems de 20 px + borde
MENU_ITEM = lambda i: (100, MENU_Y + 4 + i * 20 + 10)  # noqa: E731

# ventana del explorador: (40, 40) 360x330; filas desde y=80, alto 16
EXPL_FILA = lambda i: (100, 80 + i * 16 + 8)  # noqa: E731

# ventana del editor: (150, 90) 480x330
EDIT_X, EDIT_Y, EDIT_AN, EDIT_AL = 150, 90, 480, 330


def log(msg):
    print(f"[probar_escritorio] {msg}")


def leer_serial(ruta):
    try:
        with open(ruta, "r", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def esperar(ruta, marca, limite_s, desde=0.0):
    inicio = time.time()
    while time.time() - inicio < limite_s:
        contenido = leer_serial(ruta)
        pos = contenido.find(marca, int(desde))
        if pos >= 0:
            return contenido, pos
        time.sleep(0.25)
    return leer_serial(ruta), -1


def paso(nombre, marca, ref, serial_path, limite=25.0):
    """Comprueba un marcador serial EN ORDEN: ref solo avanza al hallarlo.
    ¡El orden de las comprobaciones debe seguir al del serial!"""
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


class Raton:
    """Cursor lógico por HMP: QEMU PS/2 es relativo y el kernel parte del
    centro. NOTA: input-send-event de QMP NO llega al PS/2 en QEMU 11
    (verificado); los comandos HMP mouse_move/mouse_button sí."""

    def __init__(self, qmp):
        self.qmp = qmp
        self.x = ANCHO // 2
        self.y = ALTO // 2

    def hmp(self, comando):
        self.qmp.cmd("human-monitor-command", {"command-line": comando})

    def mover(self, x, y):
        dx, dy = x - self.x, y - self.y
        self.x, self.y = x, y
        if dx or dy:
            self.hmp(f"mouse_move {dx} {dy}")
        time.sleep(0.12)

    def clic(self, x, y):
        self.mover(x, y)
        self.hmp("mouse_button 1")   # botón izquierdo pulsado
        time.sleep(0.15)
        self.hmp("mouse_button 0")   # soltado
        time.sleep(0.4)

    def arrastrar(self, x0, y0, x1, y1):
        self.mover(x0, y0)
        self.hmp("mouse_button 1")
        time.sleep(0.15)
        # pasos intermedios para que el kernel vea el arrastre por ráfagas
        pasos = 5
        for i in range(1, pasos + 1):
            xi = x0 + (x1 - x0) * i // pasos
            yi = y0 + (y1 - y0) * i // pasos
            self.hmp(f"mouse_move {xi - self.x} {yi - self.y}")
            self.x, self.y = xi, yi
            time.sleep(0.12)
        self.hmp("mouse_button 0")
        time.sleep(0.4)


def main():
    global PASOS_OK, PASOS_MAL
    ap = argparse.ArgumentParser()
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--tiempo", type=int, default=300)
    args = ap.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    salida_abs = os.path.abspath(args.salida)
    serial_path = os.path.join(salida_abs, "serial_escritorio.log")
    sock_path = os.path.join(salida_abs, "qmp.sock")
    img_prueba = os.path.join(salida_abs, "antlexos_prueba.img")
    shutil.copyfile(args.imagen, img_prueba)
    for p in (serial_path, sock_path):
        if os.path.exists(p):
            os.unlink(p)

    cmd = [QEMU, "-display", "none", "-serial", f"file:{serial_path}",
           "-qmp", f"unix:{sock_path},server,nowait", "-m", "512", "-vga", "std",
           "-hda", img_prueba]
    log(f"lanzando: {QEMU} -display ... (imagen {args.imagen})")
    with open(os.path.join(salida_abs, "qemu_salida.log"), "w") as fq:
        proc = subprocess.Popen(cmd, stdout=fq, stderr=subprocess.STDOUT)

    try:
        # 1) arranque del escritorio con ratón
        _, pos = esperar(serial_path, "ESCRITORIO LISTO", args.tiempo)
        if pos < 0:
            log("FALLA: el escritorio no arrancó")
            return 1
        log("arranque: ESCRITORIO LISTO")
        # estos dos marcadores ocurren ANTES de ESCRITORIO LISTO en el serial
        paso("ratón PS/2 activo", "raton PS/2 activo (IRQ12)", [0.0], serial_path)
        paso("autopruebas 14/14", "AUTOPRUEBAS 14/14 correctas", [0.0], serial_path, limite=40.0)
        ref = [pos]

        for _ in range(50):
            if os.path.exists(sock_path):
                break
            time.sleep(0.1)
        qmp = Qmp(sock_path)
        r = Raton(qmp)

        # 2) mover el ratón sin bloquear el sistema
        r.mover(300, 200)
        r.mover(600, 400)
        time.sleep(0.3)
        PASOS_OK += 1
        log("ok: cursor mueve sin bloquear")

        # 2b) teclear mientras el ratón se mueve: ninguna tecla debe
        #     quedarse atascada detrás de los bytes del ratón (REV-FASE5 S1)
        for _ in range(6):
            r.mover(r.x + 5, r.y + 3)
            qmp.tecla("a")
            time.sleep(0.06)
        _, pos_b = esperar(serial_path, "aaaaaa", 10.0)
        if pos_b >= 0:
            PASOS_OK += 1
            log("ok: teclear con el ratón en movimiento (S1)")
        else:
            PASOS_MAL += 1
            log("FALLA: teclas perdidas con el ratón en movimiento (S1)")
        for _ in range(6):
            qmp.tecla("backspace"); time.sleep(0.05)  # limpiar la línea

        # 3) menú INICIO → Explorador (el orden de los marcadores sigue
        #    al del serial: primero la ventana, luego el foco, al final el
        #    cierre del menú)
        r.clic(*BOTONES["inicio"])
        paso("menú abierto", "gui: menu abierto", ref, serial_path)
        r.clic(*MENU_ITEM(0))
        paso("ventana Explorador", "gui: ventana abierta Explorador", ref, serial_path)
        paso("foco Explorador", "gui: foco ventana Explorador", ref, serial_path)
        paso("menú cierra", "gui: menu cerrado", ref, serial_path)

        # 4) entrar en ejemplos/ (fila 3 del raíz) con clic + INTRO
        r.clic(*EXPL_FILA(3))   # selecciona 'ejemplos'
        qmp.tecla("ret"); time.sleep(0.5)
        paso("explorador entra ejemplos", "gui: explorador entra ejemplos", ref, serial_path)

        # 5) abrir DATOS.TXT (fila 0 de /ejemplos) → editor
        r.clic(*EXPL_FILA(0))   # selecciona DATOS.TXT
        qmp.tecla("ret"); time.sleep(0.6)
        paso("editor abre DATOS.TXT", "gui: editor abre DATOS.TXT", ref, serial_path)
        paso("ventana Editor", "gui: ventana abierta Editor", ref, serial_path)
        paso("foco Editor", "gui: foco ventana Editor", ref, serial_path)

        # 6) editar (cursor al final: FIN) y guardar con F2
        qmp.tecla("end"); time.sleep(0.2)
        qmp.tecla("down"); time.sleep(0.2)
        teclear_con_igual(qmp, "Escribo desde el arnes del escritorio.")
        qmp.tecla("ret"); time.sleep(0.2)
        teclear_con_igual(qmp, "Linea nueva del editor.")
        qmp.tecla("f2"); time.sleep(0.6)
        paso("editor guarda", "gui: editor guarda DATOS.TXT", ref, serial_path)

        # 7) verificar el contenido desde el TERMINAL
        r.clic(*BOTONES["terminal"])
        paso("foco terminal", "gui: foco terminal", ref, serial_path)
        teclear_con_igual(qmp, "mostrar ejemplos/datos.txt"); qmp.tecla("ret"); time.sleep(1.0)
        paso("contenido editado visible", "Linea nueva del editor.", ref, serial_path)

        # 8) chat de AntLex
        r.clic(*BOTONES["chat"])
        paso("foco chat", "gui: foco chat", ref, serial_path)
        teclear_con_igual(qmp, "quien eres"); qmp.tecla("ret"); time.sleep(1.2)
        paso("chat eco del usuario", "chat> quien eres", ref, serial_path)
        paso("chat responde AntLex", "IA embebida", ref, serial_path)

        # 9) arrastrar la ventana del editor por el título (y 90..106),
        #    a la derecha de la ventana Explorador (que llega hasta x=400)
        r.arrastrar(EDIT_X + 330, EDIT_Y + 8, EDIT_X + 400, EDIT_Y + 60)
        paso("ventana Editor movida", "gui: ventana movida Editor", ref, serial_path)
        # el cierre [X] va con la NUEVA posición de la ventana
        nuevo_x, nuevo_y = EDIT_X + 70, EDIT_Y + 52  # +70,+52 desde el origen
        r.clic(nuevo_x + EDIT_AN - 11, nuevo_y + 8)
        paso("ventana Editor cerrada", "gui: ventana cerrada Editor", ref, serial_path)

        # 10) Acerca de + cierre con ESC
        r.clic(*BOTONES["inicio"])
        paso("menú reabierto", "gui: menu abierto", ref, serial_path)
        r.clic(*MENU_ITEM(2))
        paso("ventana Acerca de", "gui: ventana abierta Acerca de", ref, serial_path)
        paso("foco Acerca de", "gui: foco ventana Acerca de", ref, serial_path)
        paso("menú cierra (2ª vez)", "gui: menu cerrado", ref, serial_path)
        qmp.tecla("esc"); time.sleep(0.5)
        paso("Acerca cerrada con ESC", "gui: ventana cerrada Acerca de", ref, serial_path)

        # 11) explorador: cerrar con [X]
        r.clic(40 + 360 - 11, 48)
        paso("ventana Explorador cerrada", "gui: ventana cerrada Explorador", ref, serial_path)

        # 12) captura del escritorio para el registro visual
        ppm = os.path.join(salida_abs, "escritorio.ppm")
        qmp.cmd("screendump", {"filename": ppm})
        time.sleep(1.2)
        try:
            from PIL import Image
            im = Image.open(ppm)
            im.save(os.path.join(salida_abs, "escritorio.png"))
            os.unlink(ppm)
            log(f"captura: escritorio.png {im.size}")
        except ImportError:
            log("sin PIL; queda escritorio.ppm")

        # 13) apagado limpio desde el menú
        r.clic(*BOTONES["inicio"])
        r.clic(*MENU_ITEM(4))
        _, pos = esperar(serial_path, "APAGANDO", 30.0, desde=ref[0])
        if pos >= 0:
            PASOS_OK += 1
            log("ok: apagar desde el menú")
        else:
            PASOS_MAL += 1
            log("FALLA: apagar desde el menú")
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

    log(f"RESULTADO: {'PASA' if PASOS_MAL == 0 and PASOS_OK >= 26 else 'FALLA'} "
        f"({PASOS_OK} ok, {PASOS_MAL} fallos)")
    return 0 if PASOS_MAL == 0 and PASOS_OK >= 26 else 1


if __name__ == "__main__":
    sys.exit(main())
