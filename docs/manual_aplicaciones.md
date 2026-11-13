# Manual de aplicaciones — AntLex OS

Cómo crear aplicaciones y juegos para AntLex OS, con el juego **Adivina**
(como ejemplo real del repositorio) paso a paso.

> Versión del documento: v1.1.0-dev · El ejemplo vive en
> `src/kernel/apps.zig` (lógica), `src/kernel/gui.zig` (ventana) y
> `tools/probar_escritorio.py` (prueba). Captura: `docs/img/juego-adivina.png`.

---

## 1. Cómo funciona realmente una «app» en AntLex OS

### 1.1 No hay ejecutables independientes (todavía)

En AntLex OS v1.x **no existe un formato de ejecutable de usuario**: no hay
`.exe`, ni `.elf`, ni `.app` que se pueda copiar y lanzar. Una aplicación
es un **módulo Zig que se compila DENTRO del kernel** y se registra en la
GUI. Cuando enciendes el sistema, la app ya está dentro.

La unidad de código de una app es un archivo `.zig` (por ejemplo
`src/kernel/tuapp.zig` o una sección de `src/kernel/apps.zig`). «Instalar»
tu app = recompilar la imagen del sistema con ella dentro.

**¿Por qué esta decisión?** El kernel aún no tiene las tres piezas que
exige un formato de ejecutables real:

| Pieza | Qué haría falta | Estado |
|---|---|---|
| Carga dinámica | Un loader que lea un archivo y lo mapee en memoria (ELF o formato propio) | No existe |
| Aislamiento | Anillo 3 + syscalls: que una app no pueda tumbar el sistema | Sin ring 3 (todo corre en ring 0) |
| Punto de entrada estándar | ABI de llamada al kernel (abrir ventana, dibujar…) | Las apps llaman a `gui`/`pantalla` directamente |

Es el camino clásico de los sistemas operativos educativos: primero el
sistema monolítico funciona completo; el formato de ejecutables vendrá
después (ver §5).

### 1.2 ¿Y por qué el Explorador no muestra los archivos del sistema?

Es **intencional**, y la razón es de arquitectura: **el sistema no corre
desde archivos**. El disco se divide en regiones fijas:

```
offset 0        MBR + stage1 (512 B)          ┐
LBA 1..32       stage2 (16 KiB)               │ cadena de arranque + kernel:
9 MiB           kernel binario (4 MiB)        │ se leen por LBA fijo,
mkfat           FAT16 del arranque UEFI       │ no son «archivos»
13 MiB          volumen ALFS (16 MiB)         ┘ ← LO ÚNICO que monta el kernel
29 MiB          fin del disco (29 MiB)
```

El explorador (y los comandos `lista`, `mostrar`…) solo montan el volumen
**ALFS** de 13 MiB: la partición de datos del usuario. El kernel no sabe
ni leer ni escribir las demás regiones como archivos — para él son
sectores crudos. Dos consecuencias buenas:

1. **No puedes borrar el sistema por accidente**: no hay comando ni clic
   que alcance la zona del kernel.
2. **Todo lo que ves en ALFS son tus datos**: nada de archivos ocultos
   del sistema que «ensucien» el explorador.

Así que no, no corre «desde una única pieza en el arranque»: corre desde
una **cadena** (stage1 → stage2 → kernel) que se copia a memoria tal cual;
y el kernel lleva todas las aplicaciones compiladas dentro.

### 1.3 ¿Qué es entonces un «archivo» en ALFS?

ALFS (AntLex File System) tiene dos tipos de entrada: directorio y
archivo de texto. **No hay bit de ejecutable, ni permisos, ni
asociaciones por extensión** — una extensión como `.TXT` es solo parte
del nombre. Por eso «pegar mi app en el explorador» no puede funcionar
hoy: pegarías datos, y no hay nada que los ejecute.

---

## 2. Cómo meter DATOS en el sistema (sin USB ni red)

AntLex OS v1.x **no tiene pila USB** (haría falta driver XHCI + protocolo
mass-storage/BOT + lector FAT/exFAT) **ni pila de red** (driver NIC +
TCP/IP). No se puede «descargar de internet» dentro del sistema. Los
tres canales reales para llevar datos a ALFS:

### 2.1 Al construir la imagen (recomendado)

Todo lo que pongas en `fsroot/` del repositorio acaba dentro del volumen
ALFS de la imagen, gracias a `mkalfs`:

```
fsroot/
  LEEME.txt          → /LEEME.TXT
  ejemplos/datos.txt → /EJEMPLOS/DATOS.TXT
  juegos/notas.txt   → /JUEGOS/NOTAS.TXT
```

```bash
cp mis-notas.txt AntLexOS/fsroot/       # tu archivo, en español y sin ñ
cd AntLexOS && zig build -Drelease=true # regenera antlexos.img
# arranca la imagen y ahí está: /MIS-NOTAS.TXT
```

Es el flujo normal de desarrollo de sistemas operativos: cambias el
contenido, regeneras, arrancas (30 segundos con el portable).

### 2.2 En vivo, desde el TERMINAL

```
antlex:/?> escribir partidas.txt Gane al adivina en 5 intentos
antlex:/?> anexar partidas.txt y tambien en 3
antlex:/?> mostrar partidas.txt
antlex:/?> sincronizar        ← obligatorio antes de apagar: escribe al disco
```

### 2.3 En vivo, desde la GUI

Botón **Editor** → escribe → **F2** guarda en ALFS (pedirá nombre la
primera vez).

> La persistencia es real: `sincronizar` (o apagar, que sincroniza) deja
> los datos en el disco y siguen ahí tras reiniciar. El arnés
> `tools/probar_alfs.py` lo verifica escribiendo, reiniciando y
> comprobando.

---

## 3. Tutorial: tu primera aplicación, paso a paso

Vamos a construir **Adivina**: el sistema piensa un número del 1 al 100,
tú escribes cifras y te dice «mayor» o «menor». El código completo está
en el repositorio; aquí se explica cada decisión.

### 3.1 Regla de oro del proyecto

**La lógica de la app va PURA** (sin hardware, sin framebuffer, sin
ALFS): solo structs y funciones. Así se puede probar en el host con
`zig build test` en milisegundos, sin arrancar QEMU. El pegamento con
hardware (teclado, dibujo, serie) vive en `gui.zig` y se mantiene mínimo.

### 3.2 Paso 1 — estado y lógica pura (`src/kernel/apps.zig`)

El estado de la app es un struct plano (sin punteros, sin allocación) y
sus eventos devuelven un enum que la GUI traduce en trazas:

```zig
pub const AdivinaEvento = enum { nada, intento, acierto, nueva };

pub const Adivina = struct {
    semilla: u32 = 0x1234_5678,   // xorshift: avanza en cada ronda
    secreto: u16 = 0,             // 1..100
    intentos: u16 = 0,
    acertado: bool = false,
    intento: [3]u8 = undefined,   // cifras en curso
    intento_len: u8 = 0,
    msg: [48]u8 = undefined,      // «El numero es MAYOR»…
    msg_len: u8 = 0,
};

pub fn adivinaNueva(a: *Adivina, semilla: u32) void { … }
pub fn adivinaTecla(a: *Adivina, c: u8) AdivinaEvento { … }
```

`adivinaTecla` procesa una tecla y devuelve qué pasó: los dígitos
acumulan, INTRO evalúa (`mayor`/`menor`/¡correcto!), la tecla 8 borra y,
tras acertar, INTRO arranca una ronda nueva con la semilla avanzada.
Fíjate en los límites explícitos (máximo 3 dígitos, mensaje acotado a
48 bytes): es la regla de seguridad del proyecto — todo búfer acotado.

**El azar sin hardware**: `adivinaNueva` recibe la semilla por parámetro.
Las pruebas pasan una semilla fija (determinismo total) y la GUI pasa
`pit.leerTics()` (los tics del temporizador al abrir la ventana).

### 3.3 Paso 2 — registrar la ventana (`src/kernel/gui.zig`)

Ocho puntos de registro, todos con assert en los scripts del repo:

1. **Tipo**: añade tu app al enum `TipoApp` (cupo actual: 4 valores `u2`).
   ```zig
   pub const TipoApp = enum(u2) { explorador = 0, editor = 1, acerca = 2, adivina = 3 };
   ```
   ¿Más de 4 apps? Cambia `u2` por `u3` y agranda `ventanas`.
2. **Nombre**: `const NOMBRE_APP = [4][]const u8{ …, "Adivina" };` (lo
   usan las trazas y el título).
3. **Botón de la barra**: añádelo AL FINAL de `BOTONES` (no desplaces
   los existentes: el arnés replica sus coordenadas):
   ```zig
   .{ .x = 436, .an = 70, .texto = "Adivina" },
   ```
4. **Estado en la ventana**: campo nuevo en `Ventana`
   (`adv: apps.Adivina = .{}`) y `var ventanas: [4]Ventana`.
5. **Posición inicial**: en `init()`,
   `ventanas[@intFromEnum(TipoApp.adivina)] = .{ .x = 330, .y = 170, .an = 340, .al = 230 };`
6. **Clic en el botón**: en el `switch (i)` de la barra,
   `6 => abrirVentana(.adivina),`. Dentro de `abrirVentana`, inicia la
   ronda tras el foco (el orden de las trazas lo espera el arnés):
   ```zig
   if (t == .adivina) {
       apps.adivinaNueva(&v.adv, @truncate(pit.leerTics()));
       serial.puts("gui: adivina nueva\n");
   }
   ```
7. **Teclado**: caso nuevo en `procesarTecla`. ESC cierra; el resto va a
   tu lógica y el evento se traduce en trazas de serie:
   ```zig
   .adivina => {
       if (c == teclado.ESC) { cerrarVentana(.adivina); return; }
       const ev = apps.adivinaTecla(&ventanas[@intFromEnum(TipoApp.adivina)].adv, c);
       switch (ev) {
           .intento => serial.puts("gui: adivina intento\n"),
           .acierto => serial.puts("gui: adivina acierto\n"),
           .nueva   => serial.puts("gui: adivina nueva\n"),
           .nada    => {},
       }
       dibujarTodo();
   },
   ```
8. **Dibujo**: caso nuevo en `dibujarVentana` + tu función
   `dibujarAdivina(v, x, y)` usando `texto`, `textoLim` y `pantalla.rect`
   (copia el patrón del editor). Y un caso en `tituloVentana`.

Los cierres por el botón [X], el arrastre, el orden Z y el foco los
hereda tu ventana gratis del gestor de ventanas.

### 3.4 Paso 3 — pruebas host deterministas (`src/kernel/apps.zig`, bloque `test`)

```zig
test "adivina: ronda completa determinista" {
    var a = Adivina{};
    adivinaNueva(&a, 42);                 // semilla fija → secreto conocido
    // … teclea '5','0', INTRO; acierta con el secreto; INTRO reinicia …
    try testing.expectEqual(AdivinaEvento.acierto, ev);
    try testing.expectEqual(@as(u16, 3), a.intentos);
}
```

Con `zig build test` verificas la lógica del juego entera (incluido el
reinicio de ronda) sin arrancar la máquina. Añade casos límite: teclas
ignoradas, números fuera de 1..100, tres dígitos y no más.

### 3.5 Paso 4 — pasos del arnés (`tools/probar_escritorio.py`)

Añade el botón a `BOTONES` del arnés y pasos que usan el ratón y el
teclado REALES por QMP/HMP:

```python
"adivina": (471, ALTO - 14),   # centro del botón x=436 an=70

r.clic(*BOTONES["adivina"])
paso("ventana Adivina", "gui: ventana abierta Adivina", ref, serial_path)
paso("foco Adivina", "gui: foco ventana Adivina", ref, serial_path)
paso("ronda nueva de Adivina", "gui: adivina nueva", ref, serial_path)
teclear_con_igual(qmp, "50"); qmp.tecla("ret"); time.sleep(0.6)
paso("intento de Adivina registrado", "gui: adivina intento", ref, serial_path)
qmp.tecla("esc")
paso("Adivina cerrada con ESC", "gui: ventana cerrada Adivina", ref, serial_path)
```

Así tu app queda protegida contra regresiones para siempre (CI la ejecuta
en cada push).

### 3.6 Paso 5 — construir y verificar

```bash
zig fmt .                                  # el CI lo exige
zig build -Drelease=true                   # kernel + bootloader + IMG + ISO
zig build test                             # tus pruebas host
python3 tools/probar_escritorio.py zig-out/antlexos.img build/prueba --tiempo 300
python3 tools/auditar.py                   # secretos, marcadores, versión
```

Estado verificado del ejemplo: **44/44 pruebas host** y **33/33 pasos del
arnés de escritorio** (los 5 pasos del juego incluidos).

---

## 4. Lista de comprobación para una app nueva

- [ ] Lógica pura en `apps.zig` (o `tuapp.zig`) con límites explícitos
- [ ] Prueba host determinista (semillas fijas, casos límite)
- [ ] Los 8 registros de `gui.zig` (tipo, nombre, botón AL FINAL,
      estado, posición, clic, teclado con ESC, dibujo + título)
- [ ] Trazas de serie para cada acción visible (`gui: miapp …`)
- [ ] Pasos del arnés con ratón/teclado reales
- [ ] `zig fmt`, `zig build test`, arnés completo, `auditar.py`
- [ ] Fila en `docs/PRUEBAS.md` y entrada en `CHANGELOG.md`
- [ ] Si tu app necesita datos: mételos por `fsroot/` (§2.1)

## 5. Más allá: un formato de ejecutables propio (ideas)

Cuando el proyecto crezca, el salto natural es un formato **.ALX** con
loader en el kernel: cabecera mágica + versión + punto de entrada +
secciones reubicables, leído desde ALFS por un `cargador.zig`, con la app
llamando al kernel por una tabla de funciones exportadas (dibujar,
teclado, ALFS). El mismo diseño del bootloader UEFI (que ya carga ELF
_PE_ por BlockIO) sirve de guía: es el mismo problema a otro nivel. Ver
«Ideas futuras» en `TODO.md`.
