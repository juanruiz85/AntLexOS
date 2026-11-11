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
