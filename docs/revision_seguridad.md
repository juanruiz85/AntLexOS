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

El informe completo está en el historial de trabajo del proyecto; este
registro resume veredicto y trazabilidad.
