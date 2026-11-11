# Manual técnico — AntLex OS v0.2.0

Documento de referencia interna para desarrollar y depurar el sistema.
Público: quien quiera entender cómo funciona por dentro o continuar el
proyecto (véase también `docs/RESUMEN_PROYECTO.md`).

## 1. Panorama

```
            ┌─ BIOS ─────────────────────────────────────────────┐
            │ 0x7C00: stage1 (MBR, 512 B)                        │
            │   └─ int13h LBA → carga stage2 en 0x8000           │
            │        stage2:                                     │
            │          · cabecera kernel (LBA 18432)             │
            │          · kernel → 0x10000 (bloques de 32 sect.)  │
            │          · VBE 1024×768×32 LFB                     │
            │          · E820 → 0x6000 (máx 64 entradas)         │
            │          · A20 + PIC enmascarado + cli             │
            │          · GDT propia → PM → páginas identidad     │
            │            (2 MiB, 4 GiB) → modo largo             │
            │          · kernel → 0x100000, bss→0, boot_info→0x5000
            └────────────────────────────────────────────────────┘
                              │ RDI = 0x5000
                              ▼
            ┌─ Kernel (Zig, 0x100000) ──────────────────────────┐
            │ kentry (.text.boot): pila propia 64 KiB (.bss)    │
            │ kmain: serial → gdt → idt → pic → pit → teclado   │
            │        → pantalla(VBE) → consola → mem → sti      │
            │        → splash → autopruebas → consola interactiva│
            └───────────────────────────────────────────────────┘
```

## 2. Layout del medio (fuente única: `layout.zig`)

| Offset | Tamaño | Contenido |
|--------|--------|-----------|
| 0 | 512 B | MBR propio (`stage1.bin`); bytes 446-509 tabla de particiones |
| 512 | ≤ ~8 KiB | stage2 (límite real: hasta 0xA000 para no pisar sus búferes VESA) |
| 1 MiB | 8 MiB | P1 FAT16 (`0x06`, activa): `/EFI/BOOT/BOOTX64.EFI` (Fase 1b) |
| 9 MiB | 4 MiB | P2 (`0xDA`): cabecera del kernel + binario crudo |
| 13 MiB | 16 MiB | P3 (`0xDA`): volumen ALFS (Fase 2) |
| 29 MiB | — | Fin de la imagen |

Todos los offsets son múltiplos de 2048: el mismo layout funciona en
medios de 512 B (HDD/USB) y de 2048 B (El Torito CD). La variante CD de
stage2 se ensambla con `-D CD=1` (offsets LBA divididos por 2048).

### 2.1 Cabecera del kernel (offset 0 de P2)

```
+0   u32  magic "ALKR" (0x524B4C41)
+4   u16  hdr_version = 1
+6   u16  flags
+8   u32  entry_off   (desde 0x100000; el linker script garantiza 0)
+12  u32  bss_off
+16  u32  bss_size
+20  u32  kernel_size (bytes; stage2 lo acota a 512 KiB)
+24  u32  crc32 del binario crudo
+28  ...  relleno a sector
```

## 3. Protocolo `boot_info` (0x5000, 76 bytes de campos)

**v2 (desde 0.2.0)**: `alfs_ptr` pasa a ser el offset EN BYTES del volumen
ALFS dentro del medio de arranque (0 = sin volumen) y `alfs_size` su tamaño
en bytes. El kernel calcula el LBA como `alfs_ptr / sector_size`. stage2
(BIOS) y el bootloader UEFI escriben ambos la versión 2; los tres binarios
(kernel incluido) deben ir sincronizados.

`extern struct` en `src/kernel/boot_info.zig` (@sizeOf = 80 con relleno
final; el relleno nunca se lee). Magia `ALXB`. Campos: modo (BIOS/UEFI/CD),
framebuffer (dirección, ancho, alto, paso, bpp), mapa E820 (puntero +
recuento, **acotado a 64 al leerlo**), ALFS precargado (UEFI; 0 en BIOS),
tamaño de sector del medio y unidad de arranque. Los dos bootloaders
(BIOS/UEFI) rellenan exactamente los mismos 76 bytes.

## 4. stage2 — decisiones y constantes

- **Carga del kernel**: bloques de 32 sectores a partir de 0x10000, con
  destino siempre en offset 0 de un segmento alineado (nunca cruza 64 KiB).
  Límite 512 KiB (comprobado contra la cabecera).
- **VBE**: busca en orden 1024×768, 800×600, 640×480 — todas ×32 bpp,
  modelo directo, exigiendo los bits 0 (soportado) **y** 7 (LFB) del campo
  atributos. `PhysBasePtr`, `BytesPerScanLine` y resoluciones se guardan en
  `boot_info`.
- **E820**: entradas de 24 B en 0x6000, tope 64, contador en BP (ECX lo
  usa la propia BIOS en cada llamada).
- **Transición PM→LM**: GDT de 4 descriptores (nulo, código 32, datos,
  código 64). El salto a PM usa el selector de **32 bits** (la fase de
  tablas se ejecuta como código 32) y el salto final a modo largo usa el
  **0x18 (L=1)**. Tablas: PML4@0x90000, PDPT@0x91000, PD0-3@0x92000..0x95FFF,
  entradas de **8 bytes** (parte alta a cero explícita), páginas de 2 MiB
  identidad. CR4 = PAE+OSFXSR+OSXMMEXCPT antes de PG.
- **IRQ antes del kernel**: `cli` + máscaras 0xFF en ambos PIC (las rutinas
  int 13h del BIOS dejan IF=1; el kernel reprograma el PIC en su init).
- **Traza de arranque**: letras por COM1 (`ABHKVMP3TrE0LCJ`) — cada letra
  es un hito; documentado para depuración.

## 4b. Bootloader UEFI (src/boot/efi/main.zig)

Aplicación EFI en Zig (`std.os.uefi`) que comparte `boot_info.zig` con el
kernel (módulo común del build) y recibe los offsets de `layout.zig` por
opciones de compilación:

1. **Localización del medio**: `locateHandleBuffer(BlockIo)` + lectura del
   bloque 0; se identifica el disco por la marca "ANTLEX" del MBR (offset 3).
   No se usa SimpleFileSystem: así servirá también para el CD (2048 B).
2. **Kernel**: lectura por bloques de la P2 directamente a 1 MiB
   (`AllocateAddress`), `copyForwards` para quitar la cabecera y borrado
   del `.bss` según la cabecera `ALKR`.
3. **GOP**: si el modo actual no es de 32 bpp/componente se busca otro
   (setMode). El orden RGB/BGR se comunica al kernel por el bit 0 de
   `boot_info.reserved` (la pantalla intercambia canales si procede).
4. **Mapa de memoria**: conversión de descriptores EFI al formato E820,
   fusionando regiones contiguas del mismo tipo (OVMF da >100
   descriptores; el protocolo admite 64). Todas las asignaciones (pool y
   páginas) se hacen ANTES del mapa definitivo.
5. **ExitBootServices** con reintentos: relectura silenciosa del mapa
   (capacidad real del búfer, con margen) y llamada; ninguna operación de
   consola entre el mapa final y el salto (invalidaría la clave).
6. **Salto**: `jmp` al entry con RDI = boot_info. El kernel mantiene las
   tablas de página de UEFI (identidad) hasta que gestione las suyas.

La partición FAT16 (P1) la construye `tools/mkfat.zig` (512 B/sector de
clúster para superar el umbral FAT12 de 4085 clústeres en 8 MiB) con
`/EFI/BOOT/BOOTX64.EFI` y `/LEEME.txt`. El mismo `antlexos.img` arranca
por ambos firmwares.

### 4c. Ajustes del kernel para UEFI

- `cli()` es la primera instrucción de `kmain` (OVMF deja IF=1).
- `gdt.init()` recarga CS con un far-return al selector 0x18: el CS
  heredado del firmware apuntaba a la GDT de OVMF, ya sustituida.

## 5. Kernel

- **Sin std en tiempo de ejecución**: `std` solo se importa para tipos
  builtin y el manejador de pánico. Todo lo demás (formato numérico,
  cadenas, listas) es código propio.
- **Entrada**: `kentry` en `linksection(".text.boot")` (naked) — pila
  propia de 64 KiB en `.bss`, `red_zone = false` en el build.
- **GDT del kernel**: 4 entradas idénticas en layout a la de stage2
  (el CS heredado 0x18 debe seguir siendo válido en cada `iretq`).
- **IDT**: 256 puertas tipo 0x8E con selector 0x18. Los stubs se generan
  en comptime (`Stub(vec, trae_err)`): marco uniforme con código de error
  ficticio para las excepciones que no lo traen. `Marco` (`extern struct`)
  refleja el orden exacto de pushes (r15…rax, vec, err, rip, cs, rflags,
  rsp, ss). Las excepciones vuelcan registros por serie y paran; IRQ0→PIT,
  IRQ1→teclado, EOI a los PIC.
- **Teclado**: scancode set 1, tablas ES/US de 256 entradas (mitad alta =
  shift), mayúsculas de bloqueo solo para letras, teclas muertas (´ ` ¨)
  con estado, flechas como códigos 0x80-0x86, Ctrl+C=0x03. Búfer circular
  de 64 con atómicos (productor IRQ1, consumidor hilo principal).
- **Pantalla**: framebuffer 32 bpp (`0x00RRGGBB` en little-endian = RGB en
  memoria para QEMU). Primitivas `pixel/rect/rectBorde` con recorte.
- **Fuente**: 8×16, 133 glifos (ASCII + latinos + caja) generados desde
  GNU Unifont por `tools/genfont.zig` (subconjunto commiteado en
  `assets/unifont_subconjunto.hex` para reproducibilidad).
- **Consola**: rejilla de caracteres sobre el framebuffer con scroll
  (copiado fila a fila hacia direcciones más bajas), cursor de subrayado,
  estilos de color. `reubicar()` permitirá meterla en una ventana (Fase 5).
- **mem.zig**: bump allocator (región usable desde 32 MiB); la Fase 7 lo
  sustituirá por clases de tamaño. `alloc` valida alineación potencia de 2
  y no desborda.
- **Autopruebas** (`autoprueba.zig`): 11 comprobaciones volcadas por COM1
  con prefijo `[ OK ]/[FALLA]` y resumen; `tools/probar_boot.py` las
  exige en CI. Desde v0.2.0 incluyen `ata_identify`, `alfs_montado` y
  `alfs_operaciones` (ciclo crear/leer/rutas/borrar en RAM, sin tocar disco).

### 5.1 Driver ATA (`src/kernel/ata.zig`)

- Bus primario, disco maestro, **PIO LBA28 con polling** (nIEN activado:
  sin IRQ14/15; el PIC mantiene al esclavo cerrado).
- `IDENTIFY DEVICE` valida el disco y extrae la cadena de modelo (palabras
  27..46 con bytes intercambiados); word 49 bit 9 = soporte LBA28.
- **Lecturas/escrituras por bloques de hasta 64 sectores, con DRQ esperado
  ANTES DE CADA SECTOR** (así exige PIO «READ/WRITE SECTORS»); la
  transferencia de 256 palabras es `rep insw`/`rep outsw`.
- Todas las esperas acotadas (timeout de ~2 M iteraciones + ioWait):
  un disco colgado nunca cuelga el sistema; devuelve `Timeout`/`FallaAta`.
- `FLUSH CACHE` (0xE7) tras cada escritura: persistencia real.
- Lección importante: **`rep insw` escribe en ES:RDI pero `rep outsw` lee de
  DS:RSI**. Usar RDI como origen de outsw escribe basura (en QEMU, ceros)
  sin ningún error. Encontrado comparando el desensamblado; documentado
  para no repetirlo.

### 5.2 Sistema de archivos ALFS (`src/kernel/alfs*.zig`)

**Capas** (fuente única de verdad del formato):

| Archivo | Contenido | Usado por |
|---------|-----------|-----------|
| `alfs_formato.zig` | Constantes, `Superbloque` (512 B), `Entrada` (64 B), mapa de bits, validación de nombres | kernel, mkalfs, pruebas |
| `alfs_volumen.zig` | `Volumen`: todas las operaciones sobre un búfer (capa pura, sin E/S) | kernel, mkalfs, pruebas host |
| `alfs.zig` | Montaje por ATA (espejo RAM), `sincronizar()`, estado global | kernel |
| `tools/mkalfs.zig` | Genera el volumen inicial desde `fsroot/` e inserta la partición 3 | build |

El volumen completo (16 MiB) se carga a un espejo en RAM al arrancar; todas
las operaciones trabajan sobre el espejo y `sincronizar` reescribe el
volumen entero al disco (32768 sectores en bloques de 64 + FLUSH). Es
simple y robusto; la escritura diferencial es mejora futura.

**Formato en disco** (por defecto 32768 bloques de 512 B):

```
bloque 0    superbloque: magic "ALF1" (0x31534C41), versión, log2=9,
            n_bloques, bitmap_bloque=1, tabla_bloque, tabla_entradas=256,
            datos_bloque, bloques_libres, crc (reservado), etiqueta[16]
bloques 1..8   mapa de bits de bloques (32768 bits)
bloques 9..40  tabla de 256 entradas de 64 B
bloques 41..   área de datos (archivos como extensiones CONTIGUAS)
```

**Entrada de tabla (64 B)**: tipo (0 libre/1 archivo/2 directorio), flags,
nombre_len, nombre[44], padre (u16, 0xFFFF=raíz), tam (u32),
primer_bloque (u32), nbloques (u32).

**Decisiones y límites** (documentadas a propósito):

- Archivos por **extensiones contiguas** con primer ajuste: sin
  fragmentación interna ni punteros; si no hay corrida libre suficiente
  → `Fragmentado` (borrar archivos libera huecos). Máx. 4 MiB por archivo.
- Nombres insensibles a mayúsculas ASCII (la ñ y demás Latin-1 comparan
  byte a byte), sin espacios ni '/', máx. 44 B. Profundidad máx. 16.
- Tabla de 256 entradas (un directorio no vacío no se borra).
- `Volumen.abrir()` revalida TODO el superbloque y recounts el mapa de
  bits: un volumen corrupto se rechaza sin lecturas salvajes.
- Escritura de archivo: se reserva la extensión nueva ANTES de liberar la
  vieja (permite crecer in situ); los datos se copian al bloque nuevo.

### 5.3 Intérprete de comandos (`src/kernel/interprete.zig`)

- Tabla `COMANDOS` con nombre ES + alias EN + ayuda + uso; 16 comandos en
  v0.2.0 (ver manual de usuario).
- **Toda la salida se refleja por COM1** (consola remota): base de la
  automatización de pruebas (`probar_alfs.py` teclea con QMP `send-key` y
  valida por serie; el mapa ES se tiene en cuenta: solo se inyectan
  caracteres seguros en ambas distribuciones).
- Editor de línea: imprimibles, retroceso, Ctrl+C. Historial y TAB llegan
  en la Fase 3.
- Las rutas aceptan absolutas y relativas, `.` y `..`; el prompt muestra
  la ruta actual (`antlex:/ejemplos> `).

## 6. Sistema de compilación

`zig build` (recomendado `-Drelease=true` → ReleaseSafe):

| Paso | Descripción |
|------|-------------|
| `kernel` | `src/kernel/main.zig` → ELF con `linker.ld` (base 0x100000, `.text.boot` primero) |
| `stage1`/`stage2` | NASM (`-f bin`, `-D STAGE2_SECTORES=32`; variante `-D CD=1`) |
| `mkimage` | `zig run tools/mkimage.zig`: parsea el ELF (PT_LOAD), binario plano + cabecera (entry/bss/crc32) + particiones → imagen base |
| `mkalfs` | ejecutable host con el MISMO módulo `alfs_volumen`: genera la partición 3 desde `fsroot/` → `zig-out/antlexos.img` |
| `test` | pruebas unitarias en host (`src/tests.zig` + pruebas de formato/volumen ALFS) |
| `probar` | `tools/probar_boot.py` (QEMU + serial + QMP + validación de píxeles) |
| `probar-uefi` | igual con OVMF (pflash dual) |
| `probar-alfs` | `tools/probar_alfs.py`: escribe un archivo por teclado QMP, sincroniza, REINICIA la VM y verifica la persistencia |
| `fuente` | regenera `fuente_datos.zig` desde `assets/unifont.hex` |

Zig **0.14.1** fijado (`.zon` + CI descarga esa versión exacta).

## 7. Pruebas y CI

- `ci.yml`: `zig fmt --check` → build → `test` → `probar` → `auditar.py` →
  artefactos.
- `release.yml`: en tags `v*` ejecuta lo mismo y publica en GitHub
  Releases (imagen, fuente, SHA256SUMS; ISO y portables cuando existan).
- Resultados registrados por versión en `docs/PRUEBAS.md`.

## 8. Depuración

- **Serial COM1**: banner, hitos `init:`, autopruebas y volcados de
  excepciones. `-serial stdio` en QEMU.
- **Traza del stage2**: `ABHKVMP3TrE0LCJ` (ver §4).
- **QEMU**: `-d int -D fichero` para excepciones;
  `tools/inspeccionar.py` para volcar memoria física vía QMP
  (`xp /8gx <dir>`).
- **Caso real documentado**: page-fault con código de error 0x8 (bits
  reservados) tras activar PG → entradas de página escritas con stride
  incorrecto. El volcado de las tablas por QMP lo destapó al instante.
- **Casos reales v0.2.0**: (a) PIO multi-sector sin DRQ por sector leía
  solo el primer sector válido; (b) `rep outsw` con origen en RDI
  (debe ser RSI) escribió 16 MiB de ceros; (c) el scancode del INTRO
  (0x1C) faltaba en las tablas y ninguna línea llegaba al intérprete.
  Los tres los destapó el arnés de persistencia automatizado.

## 9. Riesgos conocidos y decisiones abiertas

- `stage2` limitado a ~8 KiB (búferes VESA en 0xA000): vigilar al crecer.
- El kernel hereda las tablas de página de stage2 (identidad 4 GiB, 2 MiB);
  un heap > 4 GiB requeriría mapeo propio.
- A20 solo por puerta rápida (QEMU y hardware moderno la tienen activa).
- La ISO/El Torito (Fase 6) usará la variante `-D CD=1` ya precompilada.
- ALFS: `sincronizar` reescribe el volumen COMPLETO (16 MiB): simple pero
  lento; la escritura diferencial (bitmap sucio por bloques) es mejora
  futura. Los archivos muy fragmentados pueden pedir reorden (no hay
  compactador aún).
- El espejo RAM del volumen (16 MiB) sale del bump allocator: las sesiones
  con mucha escritura consumen heap hasta `sincronizar` (no lo libera;
  es aceptable con 512 MiB de RAM de prueba).
