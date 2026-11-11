# Registro de auditorías de seguridad y calidad — AntLex OS

Cada fase pasa una auditoría (agente de revisión) antes de su tag. Este
archivo registra el veredicto, los hallazgos y su resolución.

## REV-FASE1 — 2026-11-11 (pre-v0.1.0)

- **Alcance**: Fase 1 completa (stage1.asm, stage2.asm, kernel mínimo,
  mkimage, probar_boot, layout).
- **Veredicto**: **APTO CON OBSERVACIONES** → corregido todo lo relevante
  antes de publicar; re-verificado (P-0014).
- **Secretos**: NINGUNO en el repositorio (búsqueda de patrones de tokens,
  claves, credenciales).

### Hallazgos y resolución

| ID | Severidad | Hallazgo | Resolución |
|----|-----------|----------|------------|
| S1 | MEDIA | `boot_info.memmap()` sin acotar (`memmap_count` hostil → lecturas salvajes) | ✅ Acotado a 64 entradas + validación de puntero/alineación en `desde()` |
| S2 | MEDIA | stage2 no acotaba `kernel_size` (cabecera corrupta → desbordamiento) | ✅ `cmp 512*1024` → `err_kernel` |
| C1 | MEDIA | Test de atributos VBE aceptaba un solo bit (soportado **o** LFB) | ✅ `and ax,0x81 / cmp ax,0x81` (exige ambos) |
| S7 | BAJA | `pit.tics` y búfer de teclado sin atómicos (IRQ↔hilo principal) | ✅ `@atomicLoad/Store` con orden `.acquire/.release` |
| S3 | BAJA | `mem.alloc` sin validar alineación (0 → UB) ni desbordamientos | ✅ Validación potencia de 2 + aritmética segura |
| S4 | BAJA | `fb_w*4` desbordable en u32 | ✅ Producto en u64 + tope 16384 px |
| S5 | BAJA | `consola.copiarFila` escribía el framebuffer sin límites | ✅ Recortes a límites reales; `reubicar` también |
| S6 | BAJA | `desde()` sin validar alineación | ✅ Comprobada |
| S8 | BAJA | `mkimage` sin validar phoff/phnum/segmentos contra el tamaño del ELF | ✅ Validaciones añadidas |
| C2 | BAJA | stage2 ignoraba `entry_off` de la cabecera | ✅ Salta a `KBASE+entry_off` |
| C4 | BAJA | stage2 podía crecer hasta pisar los búferes VESA (0xA000) | ✅ mkimage limita stage2 a ~8 KiB |
| H1-H8 | INFO | Higiene: `gdq` muerto, comentario falso del padding, plantilla IDT 0x08, ktest sin ignorar, no-op en probar_boot, `stage2_max_bytes` engañoso, shift u8 en `pic.permitirEsclavo`, `zig fmt` pendiente | ✅ Todos corregidos |

### Puntos verificados correctos (resumen)

Protocolo boot_info byte a byte; marco de interrupciones vs stubs; búfer
circular del teclado; tablas ES/US; índices de la fuente; validaciones de
pantalla; scroll y tabulación de consola; línea de entrada de main; stage1
(MBR 512 B, DAP, extensiones int 13h); stage2 (offsets de cabecera,
paginación de identidad, GDT/selectores, chunks de carga, offsets VESA,
E820 con tope); mkimage (CRC32, particiones, firma); PIC; serial con
límite; tests host; GPL-3.0.

## REV-FASE2 — 2026-11-11 (pre-v0.2.0)

- **Alcance**: Fase 2 completa (ata.zig, alfs_formato.zig, alfs_volumen.zig,
  alfs.zig, interprete.zig, autoprueba.zig, teclado.zig, stage2.asm v2,
  efi/main.zig v2, mkalfs.zig, probar_alfs.py, build.zig).
- **Veredicto**: **NO APTO** en primera pasada (3 hallazgos CRÍTICOS
  reproducidos en ejecución con volúmenes corruptos) → **corregido todo lo
  crítico/alto/medio y los bajos baratos**; suite completa re-ejecutada en
  verde (P-0036). El agente revisor verificó empíricamente los fallos
  compilando el volumen en host con entradas corruptas antes de reportar.
- **Secretos**: NINGUNO (auditar.py en verde).

### Hallazgos y resolución

| ID | Severidad | Hallazgo | Resolución |
|----|-----------|----------|------------|
| H-1 | CRÍTICA | `leer()`: `nbloques * 512` en u32 desborda con entradas corruptas → pánico del kernel (reproducido) | ✅ Comparación en u64 |
| H-2 | CRÍTICA | `zonaDatos()`: `sb_datos_bloque + primer` suma en u32 antes de ensanchar → pánico (reproducido) | ✅ Suma y producto en u64 |
| H-3 | CRÍTICA | `liberar()` sin validar `primer+nbloques` → escritura fuera del bitmap en ReleaseFast / pánico en ReleaseSafe (reproducido) | ✅ Guard de rango + validación completa de entradas en `abrir()` (`entradasSanas`) |
| H-4 | MEDIA | `lba_base = @intCast(...)` sin validar rango contra límite LBA28 (boot_info semiconfiable) | ✅ Rango completo validado una vez en u64 en `montar()` |
| H-5 | MEDIA | Confusión de unidades: `alfs_ptr / sector_size` (2048 en CD) contra driver PIO de 512 B | ✅ Se exige `sector_size == 512`; soporte CD documentado para Fase 6 |
| H-6 | MEDIA | Intérprete descartaba TODO Latin-1 (0x80-0xFF): ñ/¿/¡/acentos no se podían teclear pese a estar documentados | ✅ Solo se descartan 0x80-0x9F (especiales + C1) |
| H-7 | BAJA | Autoprueba leía `pit.tics` sin átomo (convención del proyecto) | ✅ `pit.leerTics()` |
| H-8 | BAJA | Fallo de `crear` en autoprueba se saltaba el resumen (arnés colgado 90 s) | ✅ Bloque etiquetado `crear:` con `break :crear` |
| H-9 | BAJA | stage2 no rechazaba `kernel_size == 0`; EFI no validaba entry_off/bss | ✅ stage2: chequeo a cero; EFI: entry_off < kernel_size y .bss acotado a KERNEL_MAX |
| H-10 | BAJA | `soporta_lba28` sin consultar (disco CHS ejecutaría addressing erróneo) | ✅ Guard en leer/escribir |
| H-11 | BAJA | Función muerta en mkalfs | ✅ Eliminada |
| H-12 | INFO | Import sin uso en interprete | ✅ Eliminado |
| H-13 | INFO | `alfs_off + alfs_size` desbordable con args absurdos en mkalfs | ✅ Comprobación por resta |
| H-14 | INFO | stage2 duplica constantes de layout sin verificación cruzada | 📋 Aceptado: mkimage escribe la cabecera desde layout.zig; se documenta en manual §9 |
| H-15 | INFO | `dist_actual` (slice) leída por IRQ sin átomo | ✅ Sustituido por bool atómico |
| H-16 | INFO | Versión hardcodeada en banner EFI | ✅ Banner sin versión |
| H-17 | INFO | probar_alfs mutaba el artefacto de build | ✅ Trabaja sobre copia |
| H-18 | INFO | Escrituras ATA sin espera de disco listo antes de programar | ✅ `esperarLibre` previo en leer/escribir |

### Pruebas nuevas derivadas de la revisión

- `volumen: entradas corruptas se rechazan sin pánico` (host): nbloques
  gigante, primer fuera de rango, liberar corrupto, tipo inválido, ciclos
  padre↔hijo → errores limpios, sin pánicos ni cuelgues.
- Re-ejecución completa: host 17/17, BIOS 11/11 + capturas, UEFI 11/11,
  persistencia BIOS y UEFI PASA (P-0036).

El informe completo está en el historial de trabajo del proyecto; este
registro resume veredicto y trazabilidad.
