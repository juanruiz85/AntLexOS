## [v0.2.0] - 2026-11-11

### Fase 2 — Sistema de archivos ALFS, driver ATA y primeros comandos

- **ALFS (AntLex File System) v1**, formato propio: superbloque de 512 B
  con validación completa, mapa de bits de bloques, tabla de 256 entradas
  de 64 B (jerárquica, padre por índice) y archivos por **extensiones
  contiguas** (primer ajuste). Nombres hasta 44 B sin espacios ni '/',
  insensibles a mayúsculas, profundidad 16, 4 MiB por archivo.
- **Capa pura y compartida**: `alfs_formato.zig` (formato) y
  `alfs_volumen.zig` (operaciones sin E/S) las usan el kernel, la
  herramienta `mkalfs.zig` y las pruebas host — fuente única de verdad.
- **Driver ATA PIO LBA28** (`ata.zig`): polling con nIEN (sin IRQ14/15),
  IDENTIFY con modelo del disco, DRQ esperado por sector, timeouts
  acotados y FLUSH CACHE tras escribir.
- **Persistencia real**: el volumen se monta como espejo en RAM y
  `sincronizar` lo escribe entero al disco. Verificado por el arnés
  automatizado `probar_alfs.py`, que teclea comandos reales por QMP
  (teclado español), sincroniza, **reinicia la máquina virtual** y
  comprueba que el archivo sobrevive — en BIOS y en UEFI.
- **Intérprete de comandos** (`interprete.zig`): 16 comandos en español
  con alias en inglés (lista/ir/ruta/mostrar/escribir/anexar/nuevodir/
  borrar/copiar/espacio/sincronizar/ayuda/ver/eco/limpiar/teclado),
  prompt con ruta actual, Ctrl+C, y **salida espejada por COM1**
  (consola remota que habilita la automatización).
- **Protocolo boot_info v2**: `alfs_ptr` (offset en bytes) y `alfs_size`
  los rellenan ambos bootloaders; el kernel valida rango LBA28 y tamaño.
- **Volumen inicial desde `fsroot/`**: LEEME, ACERCA-DE, MANUAL-CONSOLA y
  /ejemplos dentro del propio sistema.
- **Autopruebas 11/11** (+ata_identify, +alfs_montado, +alfs_operaciones)
  y **pruebas host 17/17** (+formato, +volumen, +corrupción de disco).
- **Correcciones**: INTRO/retroceso/tabulador faltaban en las tablas de
  teclado (0x1C/0x0E/0x0F); el intérprete ya no descarta Latin-1 (ñ,
  acentos, ¿¡ tecleables).
- **Auditoría REV-FASE2** (agente revisor): 3 hallazgos críticos
  reproducidos con volumen corrupto (desbordamientos u32 y bitmap fuera
  de rango) + 15 más; todo corregido, con prueba de regresión host
  (ver `docs/revision_seguridad.md`).

## [v0.1.1] - 2026-11-11

### Fase 1b — Bootloader UEFI propio

- **BOOTX64.EFI (Zig, std.os.uefi)**: localiza el medio AntLex por BlockIo
  (marca "ANTLEX" en el MBR), lee la partición del kernel por bloques
  directamente a 1 MiB, obtiene el framebuffer por GOP (con detección del
  orden RGB/BGR), convierte el mapa de memoria EFI al formato E820 de
  AntLex (fusionando regiones adyacentes) y salta al kernel tras
  ExitBootServices con reintentos — sin usar la consola entre el mapa
  final y el salto (invalidaría la clave).
- **tools/mkfat.zig**: partición FAT16 (512 B/sector de clúster) con
  /EFI/BOOT/BOOTX64.EFI y /LEEME.txt, generada por código propio.
- **Kernel**: `cli()` inmediato al entrar (el firmware UEFI deja
  interrupciones activas) y recarga de CS con far-return en `gdt.init`
  (el selector heredado del firmware deja de ser válido); pantalla
  soporta el orden RGB deGOP con intercambio de canales.
- **CI**: se extrae Zig fuera del workspace (la auditoría daba falsos
  positivos sobre libstd) y se añade la prueba de arranque UEFI con OVMF
  en CI y en `release.yml`.

# Changelog — AntLex OS

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-1.1.0/);
las versiones siguen [SemVer](https://semver.org/lang/es/) y cada tag
`vX.Y.Z` publica un release con binarios (imagen de disco, código fuente y
sumas de verificación; la ISO y los bundles portables se añaden en fases
posteriores). El detalle de pruebas de cada versión está en
`docs/PRUEBAS.md`.

## [v0.1.0] - 2026-11-11

### Fase 1 — Bootloader propio y modo gráfico básico

- **stage1 (MBR, 512 B, NASM)**: comprueba extensiones int 13h (LBA), carga
  stage2 desde LBA 1 a 0x8000 y le pasa el control con la unidad de arranque.
- **stage2 (~1,3 KiB, NASM)**: lee la cabecera del kernel (`ALKR`, con
  tamaño acotado a 512 KiB), carga el kernel por bloques a 0x10000, elige
  modo VBE lineal 1024×768×32 (fallback 800×600 y 640×480), obtiene el mapa
  E820, activa A20, enmascara el PIC, construye tablas de páginas de
  identidad 4 GiB (páginas de 2 MiB) y salta al kernel en modo largo
  x86_64 con RDI = boot_info.
- **Kernel (Zig, freestanding)**: GDT/IDT propias con stubs generados en
  comptime y volcado de excepciones por serie; PIC remapeado; PIT a 100 Hz;
  teclado PS/2 con distribución española (ñ, acentos muertos, ¿¡) y
  conmutación a US; framebuffer con primitivas de dibujo; fuente bitmap
  8×16 generada desde GNU Unifont (133 glifos); consola gráfica con scroll;
  asignador de memoria; pantalla de bienvenida con logo; consola
  interactiva básica.
- **Autopruebas de arranque** (8/8): boot_info, framebuffer, mapa E820,
  CPUID, fuente bitmap, teclado ES, asignador y temporizador — volcadas por
  COM1 y validadas automáticamente por `tools/probar_boot.py` (serial +
  capturas QMP + análisis de píxeles).
- **Herramientas**: `mkimage.zig` (ELF → imagen de disco con particiones),
  `genfont.zig` (unifont.hex → fuente del kernel), `probar_boot.py` (arnés
  QEMU), `auditar.py` (escáner de secretos/TODO), `release.sh` (CLI de
  publicación), `empaquetar_release.sh`, `inspeccionar.py` (QMP).
- **CI**: `ci.yml` (compilar + `zig fmt` + pruebas host + arranque QEMU +
  auditoría) y `release.yml` (binarios del tag en GitHub Releases).
- **Documentación**: manuales de usuario y técnico (v0.1), registro de
  pruebas, registro de auditoría de seguridad (REV-FASE1) y resumen del
  proyecto para continuidad.

### Correcciones de seguridad aplicadas tras la auditoría REV-FASE1

- `boot_info.memmap()` acota el mapa a 64 entradas (sin lecturas salvajes
  ante un bootloader corrupto) y valida puntero/alineación.
- stage2 acota `kernel_size` a 512 KiB y exige ambos bits de atributos VBE.
- Atómicos reales en `pit.tics` y en el búfer del teclado (concurrencia
  IRQ↔hilo principal).
- Endurecimiento de `mem.alloc` (alineación potencia de 2, sin
  desbordamientos), `pantalla.init` (geometrías absurdas), `consola`
  (recortes a límites del framebuffer) y `mkimage` (validación de límites
  del ELF y del tamaño de stage2).
