# Manual de aplicaciones — AntLex OS

Cómo crear aplicaciones para AntLex OS. Desde **v1.2.0** el sistema abre
**ejecutables `.ALX`** desde disco: los ejemplos reales del repositorio son
la **Calculadora** y el **Reloj** (`apps/*.zig`), que se compilan, se
convierten con `tools/mkalx.zig` y se instalan en `/APPS` con el bit de
ejecutable — todo dentro del propio `zig build`.

> Versión del documento: v1.2.0-dev · Formato y API: `src/kernel/alx_def.zig`
> (fuente única de verdad, compartida por kernel, apps y mkalx) ·
> Diseño por fases: `docs/PLAN_FASES_7-9.md` · Captura: `docs/img/calculadora.png`

---

## 1. Los dos tipos de aplicación

### 1.1 Apps externas `.ALX` (la vía recomendada)

Un `.ALX` es un archivo ejecutable del sistema: el kernel lo carga desde
ALFS a una región fija de memoria y lo ejecuta por eventos. «Instalar» una
app = ponerle el **bit de ejecutable** (`instalar CALC.ALX` o, en el build,
`mkalfs` lo hace por ti para `/APPS/*.ALX`).

```
apps/calculadora.zig ──(zig build-exe, apps/app.ld, enlazado en 16 MiB)──▶ ELF
                        ──(tools/mkalx.zig: cabecera + imagen)─────────▶ CALC.ALX
                        ──(mkalfs --app: /APPS con bit ejecutable)─────▶ imagen
```

Formato del archivo (64 B de cabecera + imagen):

```
"ALX1" · u16 versión · u16 flags · u32 bss_len · u32 entry_off (alx_evento)
u32 image_len · nombre[16] · reservado[28] · imagen (código+datos en 16 MiB)
```

**Qué NO hay todavía** (trabajo futuro, ver el plan de fases): aislamiento
— la app corre en ring 0 como todo el sistema y una app defectuosa puede
colgarlo (documentado en la auditoría REV-v1.2.0); por eso el bit de
ejecutable se pone de forma explícita y no hay autoarranque. El formato
`.ALX` es diseño propio del proyecto, sin patentes de terceros.

### 1.2 Apps internas (compiladas en el kernel)

El Explorador, el Editor, el juego Adivina o los paneles del escritorio son
módulos Zig compilados DENTRO del kernel: no están en ALFS y no se pueden
desinstalar. Son «apps del sistema», como el propio shell. El juego
**Adivina** se documentó así en su día y sigue siendo el ejemplo canónico
de app interna (§4); la Calculadora demuestra la misma disciplina como app
externa `.ALX`.

### 1.3 ¿Por qué el Explorador no muestra los archivos del sistema?

Es **intencional**: el kernel solo monta el volumen ALFS (13 MiB, la
partición de datos). La cadena de arranque y el propio kernel viven en
regiones crudas leídas por LBA fijo (ver el layout en el manual técnico):
no son archivos, no se pueden listar, modificar ni borrar desde ALFS.
Consecuencias: no puedes borrar el sistema por accidente, y todo lo que ves
en el explorador son tus datos (incluidas las apps `.ALX` de `/APPS`).

### 1.4 ¿Qué es un archivo en ALFS?

ALFS tiene directorios y archivos con **un byte de atributos** cuyo bit
`0x01` = ejecutable (`.ALX` instalado). No hay permisos por usuario: las
**asociaciones por extensión** (TXT→editor, ALX→ejecutar) viven en una
tabla del kernel que se consulta con `abrir`, el doble clic del explorador
o `asociar <ext> <accion>`.

---

## 2. Cómo meter DATOS y APPS en el sistema (sin USB ni red)

AntLex OS v1.x no tiene pila USB ni de red (la red llega en la Fase 9 con
la tienda de apps; ver el plan). Los canales reales:

### 2.1 Al construir la imagen (recomendado para apps)

- Todo lo que pongas en `fsroot/` acaba en ALFS: `cp miapp.ALX AntLexOS/fsroot/`
  — `mkalfs` marca los `.ALX` con el bit automáticamente.
- Las apps del repositorio se construyen solas: añade tu `.zig` en `apps/`,
  regístralo en `build.zig` (lista `apps_alx`) y `zig build -Drelease=true`
  lo compila, lo convierte y lo instala en `/APPS`.

### 2.2 En vivo, desde el TERMINAL

```
antlex:/?> instalar /apps/calc.alx       ← pone el bit de ejecutable
antlex:/?> ejecutar /apps/calc.alx       ← la abre en su ventana
antlex:/?> atributos /apps/calc.alx      ← "archivo, N bytes, EJECUTABLE"
antlex:/?> abrir nota.txt                ← sigue la asociación (editor)
antlex:/?> asociar log mostrar           ← cambia la tabla
antlex:/?> sincronizar                   ← obligatorio antes de apagar
```

### 2.3 En vivo, desde la GUI

Doble clic (o clic + INTRO) sobre `CALC.ALX` en el explorador: si tiene el
bit, se ejecuta; si no, la consola explica cómo instalarlo. Sobre un `.TXT`
lo abre el editor. Los datos se escriben con el Editor (F2 guarda en ALFS)
o con `escribir`/`anexar`.

> La persistencia es real: `sincronizar` (o apagar) escribe al disco y los
> datos sobreviven al reinicio — lo verifica `tools/probar_alfs.py`.

---

## 3. Tutorial: tu primera app `.ALX` paso a paso

La **Calculadora** del repositorio (`apps/calculadora.zig`) es el ejemplo
completo; aquí se explica cada pieza.

### 3.1 Regla de oro: lógica PURA + capa fina de eventos

Divide la app en dos: la **lógica** (structs y funciones puras, sin
hardware) y la **capa ALX** (eventos y dibujo). Así pruebas la lógica en el
host con `zig build test` en milisegundos — los tests de la calculadora
(sumas, cadena a la izquierda, `9/0=E`, límites de dígitos) corren ahí.

### 3.2 El contrato: `alx_evento(api, ev)` con ABI C

```zig
const std = @import("std");
const alx = @import("alx_def");   // módulo compartido con el kernel

export fn alx_evento(api: *const alx.Api, ev: *const alx.Evento) callconv(.c) void {
    switch (ev.tipo) {
        alx.EV_INIT    => { api.titulo("Calculadora"); api.tam(280, 190); },
        alx.EV_TECLA   => { /* tu lógica con ev.tecla */ },
        alx.EV_DIBUJAR => { /* pintar el área de cliente (ev.x, ev.y, ev.an, ev.al) */ },
        alx.EV_TICK    => {},   // ≈1 Hz (relojes)
        alx.EV_CERRAR  => {},   // la ventana se cierra
        else => {},
    }
}
```

La **API** (tabla de funciones del kernel; el detalle exacto, en
`src/kernel/alx_def.zig`):

| Función | Qué hace |
|---|---|
| `texto` / `textoLim` / `rect` | dibujar en coordenadas del área de cliente |
| `bisel(x, y, an, al, hundido)` | relieve 3D (el estilo del escritorio clásico) |
| `tam(an, al)` | tamaño de la ventana — **solo durante EV_INIT** (120×80..600×400) |
| `titulo(s)` | cambia el título de la ventana |
| `tics()` / `hora()` | tics del PIT (≈100 Hz) / hora del RTC como HHMMSS |
| `consola(s)` | imprime en la consola del sistema (se refleja por serie) |
| `leer(ruta, buf, cap)` / `escribir(ruta, buf, len)` | archivos de ALFS |

Toda app necesita además un manejador de pánico (una pánica detiene el
sistema: sin aislamiento todavía — el de la calculadora deja rastro por
consola antes de detenerse).

### 3.3 Detalles que ahorran horas

- **Cadenas C**: la API usa `[*:0]const u8`. Para formatear, escribe en un
  búfer propio y NUL-termina con `buf[s.len] = 0` (¡no copies con
  `@memcpy` un slice que ya vive en el mismo búfer: ReleaseSafe lo detecta
  como alias y pánica — nos pasó con la Calculadora y el Reloj!).
- **Colores**: `alx.rgb(r, g, b)` (0x00RRGGBB, como `pantalla.rgb`).
- **Métricas de fuente**: `alx.ANCHO_CARACTER` (8) y `alx.ALTO_CARACTER` (16).
- **Estado**: variables globales `var` — viven en `.bss` y el loader las
  pone a cero en cada carga.
- **Teclado español en los arneses**: en QMP, `+` es `bracket_right`,
  `*` es `shift+bracket_right` y `=` es `shift+0` (ver
  `tools/probar_alx.py::teclear_mas`).

### 3.4 Compilar e instalar (build.zig)

1. Escribe `apps/tuapp.zig` (exportando `alx_evento` y con su pánico).
2. Regístrala en `build.zig`:
   ```zig
   const apps_alx = [_]AppsAlx{
       .{ .fuente = "apps/calculadora.zig", .nombre = "CALC" },
       .{ .fuente = "apps/tuapp.zig",       .nombre = "TUAPP" },  // ← añade
   };
   ```
   (nombre ≤ 16, mayúsculas: es lo que muestran `alx: cargada` y el título
   por defecto de la ventana).
3. `zig build -Drelease=true`: ELF freestanding en 16 MiB (`apps/app.ld`)
   → `mkalx` valida y convierte → `mkalfs` lo instala en `/APPS/TUAPP.ALX`
   con el bit de ejecutable. Sale en la IMG y en la ISO.

### 3.5 Probar

```bash
zig build test                                  # tu lógica + formato + mkalx
python3 tools/probar_alx.py zig-out/antlexos.img build/palx   # de punta a punta
python3 tools/probar_escritorio.py ...          # clic+INTRO en el explorador
```

`probar_alx.py` verifica por serie: bit, carga, ventana, foco, cálculos
con teclado real, cierre con ESC, asociaciones y errores útiles. En el
sistema, `ejecutar` sin bit o sobre un no-`.ALX` explica qué falta.

### 3.6 Lista de comprobación para una app nueva

- [ ] Lógica pura con pruebas host (casos límite incluidos)
- [ ] `alx_evento` con ABI C + manejador de pánico
- [ ] `tam`/`titulo` solo en EV_INIT; dibujo acotado al área de cliente
- [ ] Búferes acotados y sin `@memcpy` con alias
- [ ] Registrada en `build.zig`; `zig fmt`, `zig build test`
- [ ] Pasos en `probar_alx.py` (o el arnés que toque) y fila en `docs/PRUEBAS.md`
- [ ] Si guarda datos: `api.escribir` + `sincronizar` antes de apagar

---

## 4. Apps internas: el modelo del juego Adivina

Las apps del sistema (compiladas en el kernel) se registran en la GUI con
los **8 puntos** de siempre (tipo, nombre, botón AL FINAL de la barra,
estado, posición, clic, teclado con ESC, dibujo + título) y su lógica vive
en `src/kernel/apps.zig` — pura y probada en host. El juego Adivina
(adivina el número 1..100; xorshift sembrado por el PIT al abrir) es el
ejemplo canónico documentado en la v1.1.0: sigue siendo válido paso a paso.
Úsalo para apps que deben existir aunque ALFS esté vacío; para todo lo
demás, `.ALX`.

## 5. Presente y futuro

- **Hecho (v1.2.0-dev)**: formato `.ALX`, bit de ejecutable, asociaciones,
  loader con API de eventos, Calculadora y Reloj.
- **Fase 8 (v1.3.0)**: escritorio estilo Windows 3.11 — iconos en el
  escritorio para las apps instaladas, minimizar a icono, Program Manager.
- **Fase 9 (v1.4.0)**: red (virtio-net, TCP, TLS 1.3 con cripto IETF sin
  regalías) y **tienda de apps** en un repositorio GitHub con índice y
  verificación SHA-256: `descargar CALC` + `instalar` y a correr.
- **Después**: aislamiento (ring 3 + syscalls), varias apps externas a la
  vez, pila USB. Ver `TODO.md` y `docs/PLAN_FASES_7-9.md`.
