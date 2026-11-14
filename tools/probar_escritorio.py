#!/usr/bin/env python3
"""AntLex OS — arnés del escritorio clásico (Fase 8).

Arranca la imagen en QEMU y ejercita el escritorio estilo clásico:
Administrador de Programas con iconos, ventanas con cromo biselado 3D,
minimizar a icono sobre el escritorio, maximizar/restaurar, menú de
control (▼), menús Archivo/Ventana con cascada y mosaico, Alt+Tab,
Alt+F4, arrastre de ventana, navegación del explorador, edición y
guardado en ALFS, chat de AntLex, app .ALX desde el explorador y
apagado ACPI desde Archivo.

El ratón se mueve por HMP (mouse_move/mouse_button): input-send-event de
QMP NO llega al PS/2 en QEMU 11 — ver docs/PRUEBAS.md.

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
from probar_antlex import Qmp, teclear, teclear_con_igual  # teclado ES  # noqa: E402
from probar_alx import teclear_mas  # '+' y '*' con el mapa español (Fase 7)  # noqa: E402

QEMU = os.environ.get("QEMU_BIN", "qemu-system-x86_64")

PASOS_OK = 0
PASOS_MAL = 0

# geometría replicada de src/kernel/gui.zig (1024x768 en BIOS)
ANCHO, ALTO = 1024, 768

# ventanas: (x, y, an, al)
PM = (10, 8, 424, 210)        # Administrador de Programas (grupo Principal)
ACC = (60, 52, 330, 140)      # grupo Accesorios
TERM = (250, 120, 560, 420)   # Terminal (enfocado al arrancar)
CHATV = (210, 160, 500, 340)  # Chat de AntLex
EXPL = (300, 60, 360, 330)    # Explorador
EDIT = (170, 100, 480, 330)   # Editor
ADIV = (340, 190, 340, 230)   # Adivina
APPV = (300, 140, 320, 240)   # app externa .ALX

ICONO_PM = [  # iconos del grupo Principal (celdas de 100x76, 4 columnas)
    "Explorador", "Editor", "Terminal", "Chat", "Acerca de", "Accesorios",
]
ICONO_ACC = ["Adivina", "Calculadora", "Reloj"]


def icono_pm(i):
    """Centro del icono i del grupo Principal."""
    return (PM[0] + 12 + (i % 4) * 100 + 34 + 16, PM[1] + 42 + (i // 4) * 76 + 16)


def icono_acc(i):
    """Centro del icono i del grupo Accesorios (3 columnas)."""
    return (ACC[0] + 15 + (i % 3) * 100 + 34 + 16, ACC[1] + 42 + 16)


def btn_cerrar(v):
    return (v[0] + v[2] - 10, v[1] + 8)


def btn_max(v):
    return (v[0] + v[2] - 28, v[1] + 8)


def btn_ctrl(v):
    return (v[0] + v[2] - 46, v[1] + 8)


def titulo_v(v):
    return (v[0] + 120, v[1] + 8)


def menu_archivo(v):
    return (v[0] + 30, v[1] + 24)


def menu_ventana(v):
    return (v[0] + 108, v[1] + 24)


# filas del explorador (y_lista = y + 16 + 24)
EXPL_FILA = lambda i: (EXPL[0] + 60, EXPL[1] + 40 + i * 16 + 8)  # noqa: E731

# iconos del escritorio (ventanas minimizadas): franja inferior
ICONO_ESCR = lambda k: (12 + k * 92 + 16, ALTO - 72 + 16)  # noqa: E731


def log(msg):
    print(f"[probar_escritorio] {msg}")


def leer_serial(ruta):
    try:
        with open(ruta, "r", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def esperar(ruta, marca, limite, desde=0):
    """Espera a que `marca` aparezca en el serial desde la posición `desde`."""
    t0 = time.time()
    while time.time() - t0 < limite:
        contenido = leer_serial(ruta)
        pos = contenido.find(marca, desde)
        if pos >= 0:
            return True, pos
        time.sleep(0.25)
    return False, -1


def paso(nombre, marca, ref, serial_path, limite=25.0):
    """Comprueba un marcador serial EN ORDEN: ref solo avanza al hallarlo."""
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
        self.hmp("mouse_button 1")
        time.sleep(0.15)
        self.hmp("mouse_button 0")
        time.sleep(0.4)

    def doble_clic(self, x, y):
        """Dos pulsaciones seguidas (<400 ms entre presiones: el umbral del
        doble clic del kernel son 40 tics de 100 Hz)."""
        self.mover(x, y)
        self.hmp("mouse_button 1")
        time.sleep(0.1)
        self.hmp("mouse_button 0")
        time.sleep(0.08)
        self.hmp("mouse_button 1")
        time.sleep(0.1)
        self.hmp("mouse_button 0")
        time.sleep(0.4)

    def arrastrar(self, x0, y0, x1, y1):
        self.mover(x0, y0)
        self.hmp("mouse_button 1")
        time.sleep(0.15)
        pasos = 6
        for i in range(1, pasos + 1):
            xi = x0 + (x1 - x0) * i // pasos
            yi = y0 + (y1 - y0) * i // pasos
            self.hmp(f"mouse_move {xi - self.x} {yi - self.y}")
            self.x, self.y = xi, yi
            time.sleep(0.06)
        time.sleep(0.1)
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
        # 1) arranque: splash + escritorio clásico con Programas y Terminal
        _, pos = esperar(serial_path, "ESCRITORIO LISTO", args.tiempo)
        if pos < 0:
            log("FALLA: el escritorio no arrancó")
            return 1
        ref = [pos]
        PASOS_OK += 1
        log("ok: arranque hasta el escritorio")
        paso("splash visible", "SPLASH VISIBLE", ref, serial_path)
        paso("Programas abierto al arrancar", "gui: ventana abierta Programas", ref, serial_path)
        paso("Terminal abierto al arrancar", "gui: ventana abierta Terminal", ref, serial_path)
        paso("foco inicial en Terminal", "gui: foco ventana Terminal", ref, serial_path)

        qmp = Qmp(sock_path)
        r = Raton(qmp)
        time.sleep(1.0)

        # 2) teclas con el ratón en movimiento (S1 de REV-FASE5)
        for _ in range(6):
            r.mover(r.x + 5, r.y + 3)
            qmp.tecla("a")
            time.sleep(0.06)
        _, pos_b = esperar(serial_path, "aaaaaa", 10.0)
        if pos_b >= 0:
            PASOS_OK += 1
            log("ok: teclear con el ratón en movimiento (S1)")
            ref[0] = max(ref[0], pos_b)
        else:
            PASOS_MAL += 1
            log("FALLA: teclas perdidas con el ratón en movimiento (S1)")
        for _ in range(6):
            qmp.tecla("backspace")
            time.sleep(0.05)  # limpiar la línea

        # 3) abrir el Explorador con doble clic en su icono del grupo
        r.doble_clic(*icono_pm(0))
        paso("icono lanza Explorador", "gui: icono lanza Explorador", ref, serial_path)
        paso("ventana Explorador", "gui: ventana abierta Explorador", ref, serial_path)
        paso("foco Explorador", "gui: foco ventana Explorador", ref, serial_path)

        # 4) entrar en ejemplos/ (fila 3 del raíz) con clic + INTRO
        r.clic(*EXPL_FILA(3))
        qmp.tecla("ret")
        time.sleep(0.5)
        paso("explorador entra ejemplos", "gui: explorador entra ejemplos", ref, serial_path)

        # 5) abrir DATOS.TXT (fila 0) → editor
        r.clic(*EXPL_FILA(0))
        qmp.tecla("ret")
        time.sleep(0.6)
        paso("editor abre DATOS.TXT", "gui: editor abre DATOS.TXT", ref, serial_path)
        paso("ventana Editor", "gui: ventana abierta Editor", ref, serial_path)
        paso("foco Editor", "gui: foco ventana Editor", ref, serial_path)

        # 6) editar (FIN, flecha abajo) y guardar con F2
        qmp.tecla("end")
        time.sleep(0.2)
        qmp.tecla("down")
        time.sleep(0.2)
        teclear_con_igual(qmp, "Linea nueva del escritorio clasico.")
        qmp.tecla("ret")
        time.sleep(0.2)
        qmp.tecla("f2")
        time.sleep(0.6)
        paso("editor guarda", "gui: editor guarda DATOS.TXT", ref, serial_path)

        # 7) verificar desde el TERMINAL (clic en su interior para el foco)
        r.clic(TERM[0] + 200, TERM[1] + 200)
        paso("foco terminal", "gui: foco ventana Terminal", ref, serial_path)
        teclear_con_igual(qmp, "mostrar ejemplos/datos.txt")
        qmp.tecla("ret")
        time.sleep(1.0)
        paso("contenido editado visible", "Linea nueva del escritorio clasico.", ref, serial_path)

        # 8) chat de AntLex: doble clic en su icono del grupo
        r.doble_clic(*icono_pm(3))
        paso("icono lanza Chat", "gui: icono lanza Chat", ref, serial_path)
        paso("ventana Chat", "gui: ventana abierta Chat", ref, serial_path)
        paso("foco Chat", "gui: foco ventana Chat", ref, serial_path)
        teclear(qmp, "quien eres")
        qmp.tecla("ret")
        time.sleep(1.2)
        paso("chat eco del usuario", "chat> quien eres", ref, serial_path)
        paso("chat responde AntLex", "IA embebida", ref, serial_path)

        # 9) grupo Accesorios + Adivina
        r.doble_clic(*icono_pm(5))
        paso("icono lanza Accesorios", "gui: icono lanza Accesorios", ref, serial_path)
        paso("ventana Accesorios", "gui: ventana abierta Accesorios", ref, serial_path)
        r.doble_clic(*icono_acc(0))
        paso("icono lanza Adivina", "gui: icono lanza Adivina", ref, serial_path)
        paso("ventana Adivina", "gui: ventana abierta Adivina", ref, serial_path)
        paso("ronda nueva de Adivina", "gui: adivina nueva", ref, serial_path)
        qmp.tecla("5")
        time.sleep(0.15)
        qmp.tecla("0")
        time.sleep(0.15)
        qmp.tecla("ret")
        time.sleep(0.4)
        paso("intento de Adivina registrado", "gui: adivina intento", ref, serial_path)
        qmp.tecla("esc")
        time.sleep(0.4)
        paso("Adivina cerrada con ESC", "gui: ventana cerrada Adivina", ref, serial_path)

        # 10) app .ALX desde el explorador: raíz → APPS → CALC.ALX
        r.clic(*EXPL_FILA(0))               # re-enfocar el explorador
        qmp.tecla("backspace")              # subir a la raíz
        time.sleep(0.5)
        paso("explorador sube a la raíz", "gui: explorador sube", ref, serial_path)
        r.clic(*EXPL_FILA(4))               # fila 4 del raíz = APPS
        qmp.tecla("ret")
        time.sleep(0.5)
        paso("explorador entra APPS", "gui: explorador entra APPS", ref, serial_path)
        r.clic(*EXPL_FILA(0))               # CALC.ALX
        qmp.tecla("ret")
        time.sleep(0.8)
        paso("alx: cargada CALC", "alx: cargada CALC", ref, serial_path)
        paso("ventana Calculadora", "gui: ventana abierta Calculadora", ref, serial_path)
        paso("foco Calculadora", "gui: foco ventana Calculadora", ref, serial_path)
        teclear_mas(qmp, "12+34=")
        paso("la calculadora calcula", "calculadora: 12 + 34 = 46", ref, serial_path)
        qmp.tecla("esc")
        time.sleep(0.5)
        paso("app descargada", "alx: descargada CALC", ref, serial_path)
        paso("Calculadora cerrada", "gui: ventana cerrada Calculadora", ref, serial_path)

        # 11) minimizar el Editor a icono (menú ▼) y restaurar con doble clic
        r.clic(*btn_ctrl(EDIT))
        time.sleep(0.3)
        paso("menú de control abierto", "gui: menu abierto", ref, serial_path)
        # ítem 3 = Minimizar (el menú cae bajo ▼: x = EDIT+AN-60, y = EDIT+16)
        r.clic(EDIT[0] + EDIT[2] - 40, EDIT[1] + 16 + 3 + 3 * 18 + 9)
        paso("menú accion Minimizar", "gui: menu accion Minimizar", ref, serial_path)
        paso("ventana minimizada Editor", "gui: ventana minimizada Editor", ref, serial_path)
        r.doble_clic(*ICONO_ESCR(0))
        paso("icono del escritorio restaura", "gui: icono restaurado Editor", ref, serial_path)
        paso("foco Editor (restaurado)", "gui: foco ventana Editor", ref, serial_path)

        # 12) maximizar con doble clic en el título y restaurar con ▲
        r.doble_clic(*titulo_v(EDIT))
        paso("doble clic en título maximiza", "gui: ventana maximizada Editor", ref, serial_path)
        r.clic(ANCHO - 28, 8)               # ▲ de la ventana maximizada
        paso("botón ▲ restaura", "gui: ventana restaurada Editor", ref, serial_path)

        # 13) arrastrar el editor por el título
        r.arrastrar(EDIT[0] + 200, EDIT[1] + 8, EDIT[0] + 260, EDIT[1] + 60)
        paso("ventana Editor movida", "gui: ventana movida Editor", ref, serial_path)

        # 14) Alt+Tab: cambia el foco a otra ventana
        qmp.combo(["alt", "tab"])
        time.sleep(0.4)
        paso("alt-tab cambia de ventana", "gui: alt-tab -> ", ref, serial_path)

        # 15) Alt+F4 cierra la ventana enfocada (el Editor)
        qmp.combo(["alt", "f4"])
        time.sleep(0.5)
        paso("alt-f4 cierra ventana", "gui: ventana cerrada Editor", ref, serial_path)

        # 16) menú Ventana del Program Manager: cascada
        r.clic(*menu_ventana(PM))
        time.sleep(0.3)
        paso("menú Ventana abierto", "gui: menu abierto", ref, serial_path)
        r.clic(PM[0] + 78 + 40, PM[1] + 32 + 3 + 9)  # ítem 0: Cascada
        paso("menú accion Cascada", "gui: menu accion Cascada", ref, serial_path)
        paso("cascada ejecutada", "gui: cascada", ref, serial_path)

        # 17) mosaico
        r.clic(*menu_ventana(PM))
        time.sleep(0.3)
        r.clic(PM[0] + 78 + 40, PM[1] + 32 + 3 + 18 + 9)  # ítem 1: Mosaico
        paso("menú accion Mosaico", "gui: menu accion Mosaico", ref, serial_path)
        paso("mosaico ejecutado", "gui: mosaico", ref, serial_path)

        # 18) cerrar el Explorador con su botón ✕ (se reabre en su sitio)
        r.doble_clic(*icono_pm(0))
        paso("Explorador reabierto", "gui: ventana abierta Explorador", ref, serial_path)
        r.clic(*btn_cerrar(EXPL))
        paso("cierre con botón ✕", "gui: ventana cerrada Explorador", ref, serial_path)

        # 19) captura del escritorio y verificación por píxeles
        ppm = os.path.join(salida_abs, "escritorio.ppm")
        qmp.cmd("screendump", {"filename": ppm})
        time.sleep(1.0)
        try:
            from PIL import Image
            im = Image.open(ppm)
            im.save(os.path.join(salida_abs, "escritorio.png"))
            rgb = im.convert("RGB").load()
            teal = sum(1 for x in range(660, 1000, 4) for y in range(640, 760, 4)
                       if rgb[x, y] == (0, 0x7A, 0x7A))
            if teal > 300:
                PASOS_OK += 1
                log(f"ok: fondo teal del escritorio ({teal} muestras)")
            else:
                PASOS_MAL += 1
                log("FALLA: no se ve el fondo teal del escritorio")
            log(f"captura: escritorio.png {im.size}")
        except ImportError:
            log("sin PIL; queda escritorio.ppm")

        # 20) apagado limpio desde Archivo del Program Manager
        r.clic(*menu_archivo(PM))
        time.sleep(0.3)
        r.clic(PM[0] + 6 + 40, PM[1] + 32 + 3 + 9)  # ítem 0: Apagar el sistema
        _, pos = esperar(serial_path, "APAGANDO", 30.0, desde=ref[0])
        if pos >= 0:
            PASOS_OK += 1
            log("ok: apagar desde Archivo")
        else:
            PASOS_MAL += 1
            log("FALLA: apagar desde Archivo")
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

    log(f"RESULTADO: {'PASA' if PASOS_MAL == 0 and PASOS_OK >= 40 else 'FALLA'} "
        f"({PASOS_OK} ok, {PASOS_MAL} fallos)")
    return 0 if PASOS_MAL == 0 and PASOS_OK >= 40 else 1


if __name__ == "__main__":
    sys.exit(main())
