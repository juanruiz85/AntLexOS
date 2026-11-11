# Registro de pruebas — AntLex OS

Toda prueba queda ligada a la **versión** en la que se ejecutó. Un mismo
identificador re-ejecutado en otra versión añade una fila nueva (así se ve
la evolución). Resultados: ✅ PASA · ❌ FALLA · ⚠️ PASA CON RESERVA.

## Metodología

- **Unitarias (host)**: `zig build test` — tablas de teclado, boot_info,
  fuente bitmap, asignador. Corren en el propio host de compilación.
- **Arranque (QEMU)**: `tools/probar_boot.py` lanza la imagen con
  `qemu-system-x86_64 -display none -serial file:... -qmp unix:...`:
  1. espera por serie la marca `ANTLEX BOOT OK v<versión>` (o `... CON ERRORES`),
  2. exige **0 autopruebas con `[FALLA]`** de las 8 del kernel,
  3. toma captura del splash vía QMP (valida >200 píxeles del color de acento del logo),
  4. toma captura de la consola (valida >200 píxeles de texto),
  5. guarda `serial.log`, `splash.png` y `captura.png`.
- **Auditoría**: `tools/auditar.py` (secretos, marcadores TODO en src/,
  sincronía de versión) + revisión de código por agente registrada en
  `docs/revision_seguridad.md`.
- **CI**: todo lo anterior se ejecuta en GitHub Actions en cada push y en
  cada tag antes de publicar el release.

## Registro

| ID | Fecha | Versión | Prueba | Resultado | Comentario |
|----|-------|---------|--------|-----------|------------|
| P-0001 | 2026-11-11 | 0.1.0-dev | Arranque BIOS QEMU (traza serie ABHKVMP) | ❌ | Triple fault: faltaba CR4.PAE — corregido |
| P-0002 | 2026-11-11 | 0.1.0-dev | Arranque BIOS QEMU | ❌ | Entradas de página de 4 bytes (necesitan 8) — corregido |
| P-0003 | 2026-11-11 | 0.1.0-dev | Arranque BIOS QEMU | ❌ | PDPT con stride de 4 bytes — corregido (stride 8) |
| P-0004 | 2026-11-11 | 0.1.0-dev | Arranque BIOS QEMU | ❌ | PIC sin enmascarar en la transición PM (int 13h dejaba IF=1) — corregido con cli+mask |
| P-0005 | 2026-11-11 | 0.1.0-dev | Arranque completo + banner kernel | ❌ | GDTR/IDTR del kernel con relleno de `extern struct` — corregido a `packed struct` |
| P-0006 | 2026-11-11 | 0.1.0-dev | Primeras interrupciones tras `sti` | ❌ | GDT del kernel sin el selector 0x18 heredado de stage2 — corregido |
| P-0007 | 2026-11-11 | 0.1.0-dev | Entrega de IRQ al manejador | ❌ | Puerta IDT apuntaba al selector 0x08 (código 32) en vez de 0x18 (64) — corregido |
| P-0008 | 2026-11-11 | 0.1.0-dev | Captura del splash | ⚠️ | Capturas duplicadas por carrera; ventana de 1 s con marcador `SPLASH VISIBLE` — corregido |
| P-0009 | 2026-11-11 | 0.1.0 | **Arranque BIOS QEMU completo** (`probar_boot.py`) | ✅ | Marca `ANTLEX BOOT OK v0.1.0`, splash con 2120 px de acento, consola con 4649 px de texto |
| P-0010 | 2026-11-11 | 0.1.0 | Autopruebas del kernel (serie) | ✅ | 8/8: boot_info, framebuffer, E820, CPUID, fuente, teclado ES, asignador, PIT |
| P-0011 | 2026-11-11 | 0.1.0 | Unitarias host (`zig build test`) | ✅ | 7 pruebas: tablas ES/US, teclas muertas, tamaño BootInfo, fuente, regionHeap, mem |
| P-0012 | 2026-11-11 | 0.1.0 | Auditoría `auditar.py` | ✅ | Sin secretos, sin marcadores TODO en src/, versión sincronizada |
| P-0013 | 2026-11-11 | 0.1.0 | Revisión de seguridad REV-FASE1 | ✅ | Veredicto APTO CON OBSERVACIONES; 8 hallazgos corregidos antes del tag (ver docs/revision_seguridad.md) |
| P-0014 | 2026-11-11 | 0.1.0 | Re-verificación tras correcciones de seguridad | ✅ | P-0009/P-0011 re-ejecutados: TODO PASA de nuevo |
| P-0015 | 2026-11-11 | 0.1.0 | Interacción teclado (eco de teclas) | ⚠️ | Verificada manualmente en QEMU con teclado ES (ñ, acentos, retroceso); no automatizada aún |

## Notas

- Las filas P-0001..P-0008 documentan el proceso de depuración del
  bootloader: se conservan a propósito como historial honesto del
  desarrollo (el proyecto valora el registro detallado).
- P-0015 quedará automatizada cuando exista inyección de teclas por QMP
  (Fase 3).
