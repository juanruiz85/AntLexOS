# Registro de pruebas — AntLex OS

Toda prueba queda ligada a la **versión** en la que se ejecutó. Un mismo
identificador re-ejecutado en otra versión añade una fila nueva (así se ve
la evolución). Resultados: ✅ PASA · ❌ FALLA · ⚠️ PASA CON RESERVA.

## Metodología

- **Unitarias (host)**: `zig build test` — tablas de teclado, boot_info,
  fuente bitmap, asignador, formato ALFS y operaciones de Volumen (16
  pruebas). Corren en el propio host de compilación.
- **Arranque (QEMU)**: `tools/probar_boot.py` lanza la imagen con
  `qemu-system-x86_64 -display none -serial file:... -qmp unix:...`:
  1. espera por serie la marca `ANTLEX BOOT OK v<versión>` (o `... CON ERRORES`),
  2. exige **0 autopruebas con `[FALLA]`** de las 11 del kernel,
  3. toma captura del splash vía QMP (valida >200 píxeles del color de acento del logo),
  4. toma captura de la consola (valida >200 píxeles de texto),
  5. guarda `serial.log`, `splash.png` y `captura.png`.
- **Persistencia (QEMU + teclado)**: `tools/probar_alfs.py` (desde v0.2.0)
  teclea comandos reales por QMP `send-key` (mapa ES tenido en cuenta),
  sincroniza, REINICIA la máquina (`system_reset`), vuelve a arrancar y
  verifica que el archivo creado sigue en el volumen; luego limpia.
  Existe la variante `--uefi` (arranque por OVMF).
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

| P-0016 | 2026-11-11 | 0.1.1-dev | Arranque UEFI (OVMF pflash dual) | ❌ | OVMF_CODE_4M no va con -bios (partes 3.5M+0.5M): montaje pflash dual — corregido |
| P-0017 | 2026-11-11 | 0.1.1-dev | Bootloader EFI en OVMF | ❌ | exitBootServices=INVALID_PARAMETER: allocatePages tras getMemoryMap invalidaba la clave — reordenado |
| P-0018 | 2026-11-11 | 0.1.11-dev | Reintento de EBS | ❌ | Reintento usaba tamaño de mapa viejo (BUFFER_TOO_SMALL eterno) — corregido con capacidad real |
| P-0019 | 2026-11-11 | 0.1.1-dev | Kernel por UEFI hasta consola | ❌ | OVMF dejaba IF=1 y CS heredado inválido tras lgdt — cli() inicial + recarga de CS — corregido |
| P-0020 | 2026-11-11 | 0.1.1 | **Arranque UEFI completo** (`probar_boot.py --uefi`, OVMF 4M) | ✅ | Bootloader EFI + kernel 8/8 autopruebas + BOOT OK por UEFI; GOP 1280x800 BGR |
| P-0021 | 2026-11-11 | 0.1.1 | Regresión BIOS tras cambios UEFI | ✅ | v0.1.1 sigue arrancando por BIOS (mismo kernel, dos rutas) |
| P-0022 | 2026-11-11 | 0.1.0 | CI GitHub (v0.1.0) | ⚠️ | Build+tests+arranque BIOS PASARON en runner; auditoría falló por falsos positivos del toolchain zig dentro del workspace — corregido en v0.1.1 (extracción a $RUNNER_TEMP) |
| P-0023 | 2026-11-11 | 0.1.0 | Release v0.1.0 en GitHub | ✅ | Workflow publicó img + src.tar.gz + SHA256SUMS + NOTAS.md automáticamente |

| P-0024 | 2026-11-11 | 0.2.0-dev | Unitarias host con ALFS (`zig build test`) | ❌ | Campo de struct tras declaraciones + superbloque mal dimensionado + doble '/' en rutaAbsoluta — corregidos (3 ciclos) |
| P-0025 | 2026-11-11 | 0.2.0-dev | Unitarias host con ALFS | ✅ | 16/16: tablas, boot_info, fuente, teclas muertas, regionHeap, formato ALFS (4) y Volumen (5) |
| P-0026 | 2026-11-11 | 0.2.0-dev | Montaje ALFS en arranque BIOS | ❌ | VolumenInvalido: PIO multi-sector leía solo el 1.er sector (DRQ es POR sector en READ/WRITE SECTORS) — corregido esperando DRQ antes de cada sector |
| P-0027 | 2026-11-11 | 0.2.0-dev | Autoprueba alfs_operaciones | ❌ | Conteo del texto de prueba (14 ≠ 15 bytes) — corregido |
| P-0028 | 2026-11-11 | 0.2.0-dev | Arranque BIOS 11/11 autopruebas | ✅ | Incluye boot_info v2, ata_identify, alfs_montado, alfs_operaciones |
| P-0029 | 2026-11-11 | 0.2.0-dev | Persistencia ALFS (teclado QMP) | ❌ | El INTRO no llegaba: scancode 0x1C sin mapear en las tablas ES/US (bug real heredado de v0.1.x, invisible a prueba manual de eco simple) — corregido + retroceso/tabulador/INTRO numérico |
| P-0030 | 2026-11-11 | 0.2.0-dev | Persistencia ALFS (teclado QMP) | ❌ | Cliente QMP se colgaba con eventos acumulados — reescrito con búfer por líneas y descarte de eventos |
| P-0031 | 2026-11-11 | 0.2.0-dev | Persistencia ALFS (teclado QMP) | ❌ | Sync dejaba el volumen a CEROS: `rep outsw` leía de RSI pero el asm lo ponía en RDI (insw SÍ usa RDI como destino) — hallado desensamblando el kernel; corregido |
| P-0032 | 2026-11-11 | 0.2.0 | **Persistencia ALFS completa en BIOS** (`probar-alfs`) | ✅ | escribir prueba.txt → sincronizar → REINICIO de la VM → mostrar verifica el contenido → limpieza. Archivo sobrevive al reinicio real |
| P-0033 | 2026-11-11 | 0.2.0 | **Persistencia ALFS completa en UEFI** | ✅ | Mismo ciclo arrancando por OVMF: el kernel monta/escribe ALFS por ATA igual en ambos modos |
| P-0034 | 2026-11-11 | 0.2.0 | Regresión arranque BIOS + UEFI | ✅ | 11/11 autopruebas en ambos modos; splash y consola validados por píxeles |
| P-0035 | 2026-11-11 | 0.2.0 | Auditoría `auditar.py` + revisión de seguridad REV-FASE2 | ❌→✅ | Agente revisor: veredicto NO APTO con 3 hallazgos críticos reproducidos (pánico del kernel con volumen corrupto); corregidos H-1..H-18 (ver docs/revision_seguridad.md) |
| P-0036 | 2026-11-11 | 0.2.0 | **Suite completa tras correcciones REV-FASE2** | ✅ | Host 17/17 (incluye prueba nueva de entradas corruptas), BIOS 11/11 + capturas, UEFI 11/11, persistencia BIOS y UEFI PASA |

| P-0037 | 2026-11-11 | 0.3.0-dev | Compilación con Fase 3 (reloj + intérprete extendido) | ❌ | Error de tipos en reloj.zig (literal 2000 en u8) — corregido con @as(u16,…) |
| P-0038 | 2026-11-11 | 0.3.0-dev | Unitarias host (`zig build test`) | ✅ | 22/22: 17 previas + 5 de reloj (Zeller ×3, formatos) |
| P-0039 | 2026-11-11 | 0.3.0-dev | Arranque BIOS con autoprueba nueva `reloj_rtc` | ✅ | 12/12 (antes 11/11); fecha RTC correcta 2026-11-11 |
| P-0040 | 2026-11-11 | 0.3.0 | **Arnés del intérprete** (`probar_interprete.py`) | ✅ | 21/21 pasos: eco, ver+reloj, fecha ISO, hora, sistema, historia numerada, flecha ↑, TAB comando/ruta/múltiple, Ctrl+C, escribir/renombrar/buscar/mostrar/borrar, pruebas 12/12 y APAGADO real por ACPI (QEMU cierra solo, código 0) |
| P-0041 | 2026-11-11 | 0.3.0 | Regresión arranque UEFI (OVMF) | ✅ | 12/12 autopruebas por UEFI, GOP 1280x800 |
| P-0042 | 2026-11-11 | 0.3.0 | Regresión persistencia ALFS (BIOS y UEFI) | ✅ | Ciclo escribir→sincronizar→REINICIO→verificar en ambos modos de arranque |

| P-0043 | 2026-11-11 | 0.3.0 | Auditoría `auditar.py` + revisión de seguridad REV-FASE3 | ❌→✅ | Agente revisor: APTO CON OBSERVACIONES — 1 hallazgo crítico (pánico por mes CMOS 0, reproducido) + 3 medios (columna de tamaño de `lista` nunca impresa —bug de v0.2.0—, falso positivo del paso flecha-arriba del arnés, autocompletado por alias con basura) + 6 menores; TODO corregido antes del tag (ver docs/revision_seguridad.md) |
| P-0044 | 2026-11-11 | 0.3.0 | **Suite completa tras correcciones REV-FASE3** | ✅ | Host 23/23 (nueva prueba de regresión del saneo CMOS), BIOS 12/12 + capturas, UEFI 12/12, persistencia ALFS en BIOS y UEFI, arnés del intérprete 22 pasos (nueva comprobación de la columna de tamaño), apagado ACPI verificado |

## Notas

- Las filas P-0001..P-0008 documentan el proceso de depuración del
  bootloader: se conservan a propósito como historial honesto del
  desarrollo (el proyecto valora el registro detallado).
- P-0015 quedó automatizada en la Fase 3: el arnés `probar_interprete.py`
  ejerce el teclado real por QMP (incluido Ctrl+C y TAB) en cada ejecución.
