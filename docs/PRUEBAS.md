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

| P-0045 | 2026-11-11 | 0.3.0 | CI GitHub (push main + tag v0.3.0) | ✅ | Workflow CI en verde: build + fmt + 23/23 host + arranque BIOS + auditoría; Release workflow en verde |
| P-0046 | 2026-11-11 | 0.3.0 | **Release v0.3.0 en GitHub** | ✅ | Publicado automáticamente: antlexos-v0.3.0-x86_64.img (29 MB) + src.tar.gz + NOTAS.md + SHA256SUMS — https://github.com/juanruiz85/AntLexOS/releases/tag/v0.3.0 |

| P-0047 | 2026-11-13 | 0.4.0-dev | **Entrenador AntLex** (`tools/entrenar_antlex.zig`) | ✅ | 161 ejemplos/24 intenciones; exactitud flotante 100% (40 épocas, parada por margen ≥85%); exactitud cuantizada 100% con la inferencia entera del kernel; pesos ~±3 en Q4.11 sin reescalado |
| P-0048 | 2026-11-13 | 0.4.0-dev | Canon y adversariales (entrenador + host) | ✅ | Canon 12/12 (10 intenciones con confianza 99-100%, 2 ajenas rechazadas); 8/8 adversariales rechazados (umbral 75% + cobertura >50%: "como hacer una tarta de queso" 94% de confianza pero 1/3 de cobertura → rechazo) |
| P-0049 | 2026-11-13 | 0.4.0-dev | Pruebas host de la IA | ✅ | 32/32: 4 del núcleo (normalización UTF-8/Latin-1, tokens/sinónimos, exp(-1)≈0.368±1%), corpus 100%, canon 12/12, adversariales 8/8, coherencia de dimensiones de pesos.zig |
| P-0050 | 2026-11-13 | 0.4.0-dev | Autoprueba 13 `antlex_canonica` (BIOS) | ✅ | 13/13 autopruebas en el arranque; "init: antlex" carga la memoria aprendida |
| P-0051 | 2026-11-13 | 0.4.0-dev | Arranque UEFI con IA embebida | ✅ | 13/13 autopruebas por UEFI (OVMF), GOP 1280x800; el kernel crece ~24 KB (pesos) y sigue bajo el límite de 512 KiB del cargador |
| P-0052 | 2026-11-13 | 0.4.0-dev | **Arnés de conversación AntLex** (`probar_antlex.py`) | ✅ | 24/24 pasos: presentación, saludo/identidad/memoria/hora/versión/ALFS/espacio en vivo, por qué (red con confianza y aportes), aprende → pregunta con clave canónica → por qué (aprendida) → sincronizar → archivo /memoria/antlex.txt verificado → lista → 2 rechazos → olvida → memoria vacía → 13/13 → apagado ACPI (QEMU cierra solo) |
| P-0053 | 2026-11-13 | 0.4.0-dev | Determinismo del entrenador | ✅ | Dos ejecuciones del mismo binario → pesos.zig byte a byte idéntico; `entrenar-verificar` compara los 2735 enteros (insensible a zig fmt) |
| P-0054 | 2026-11-13 | 0.4.0-dev | Regresiones tras REV-FASE4 | ✅ | Host 32/32, BIOS 13/13 + capturas, UEFI 13/13, persistencia ALFS, arnés del intérprete 22 pasos (marcador 13/13), zig fmt --check limpio, auditar.py sin hallazgos |

| P-0055 | 2026-11-13 | 0.4.0 | CI GitHub (push main + tag v0.4.0) | ✅ | CI en verde: fmt + build + 32/32 host + entrenar-verificar (pesos reproducibles) + arranque BIOS + UEFI + persistencia ALFS + **arnés AntLex 24/24** + auditoría; Release workflow en verde |
| P-0056 | 2026-11-13 | 0.4.0 | **Release v0.4.0 en GitHub** | ✅ | Publicado automáticamente: antlexos-v0.4.0-x86_64.img (29 MiB) + src.tar.gz + NOTAS.md + SHA256SUMS — https://github.com/juanruiz85/AntLexOS/releases/tag/v0.4.0 |


| P-0057 | 2026-11-13 | 0.5.0-dev | **Arranque del escritorio** (BIOS) | ✅ | Ratón PS/2 activo (IRQ12), autopruebas 14/14, ESCRITORIO LISTO, 26534 px iluminados |
| P-0058 | 2026-11-13 | 0.5.0-dev | Driver de ratón: decodificación y acotado | ✅ | Autoprueba 14 (raton_paquetes) + 3 pruebas host: signos, botones, desbordes, clamp |
| P-0059 | 2026-11-13 | 0.5.0-dev | Editor/explorador (lógica pura, host) | ✅ | 5 pruebas host: cargar/serializar en redondo, partir y unir líneas, SUPR, límites de línea, selección del explorador (42/42 en total) |
| P-0060 | 2026-11-13 | 0.5.0-dev | **Arnés del escritorio** (`probar_escritorio.py`) | ❌ | input-send-event de QMP no llega al PS/2 en QEMU 11 — sustituido por mouse_move/mouse_button vía HMP |
| P-0061 | 2026-11-13 | 0.5.0-dev | Arnés del escritorio (2ª pasada) | ❌ | Marcadores buscados fuera de orden (ref avanzaba por «menu cerrado» antes que por la apertura) y clic de [X] con coordenadas previas al arrastre — corregidos ambos |
| P-0062 | 2026-11-13 | 0.5.0-dev | Arnés del escritorio (3ª pasada) | ❌ | Mayúsculas: QMP rechaza qcodes en mayúscula («Escribo»→«scribo»); el arnés las teclea ahora con shift+letra |
| P-0063 | 2026-11-13 | 0.5.0-dev | Arnés del escritorio (4ª pasada) | ❌ | S3: nombre de directorio vacío al entrar (use-after-reset en explAbrir) — copia local antes de relistar; PASA 27/27 |
| P-0064 | 2026-11-13 | 0.5.0-dev | **Arnés del escritorio completo** | ✅ | 28/28: menú, ventana Explorador, navegación con clic+INTRO, editor abre DATOS.TXT, edición+F2, verificación por `mostrar` desde el TERMINAL, chat de AntLex, arrastre, cierre por [X] y ESC, captura, apagado ACPI desde el menú |
| P-0065 | 2026-11-13 | 0.5.0-dev | UEFI con escritorio | ❌ | Huella kernel 597 KB > límite 512 KiB del cargador EFI — consolas/ventanas a .bss, paleta 256→16, límite 768 KiB (stage2+EFI); huella 575 KB |
| P-0066 | 2026-11-13 | 0.5.0-dev | Regresiones tras cambios de tamaño | ✅ | Host 42/42, BIOS boot+intérprete+ALFS+AntLex, UEFI boot (splash 2138 px), escritorio 28/28 |
| P-0067 | 2026-11-13 | 0.5.0-dev | Revisión de seguridad REV-FASE5 | ✅ | APTO CON OBSERVACIONES; S1 (tecla atascada tras bytes de ratón), S2 (borde del menú), S3, S4 corregidos; regresión S1 en el arnés (paso 2b) |
| P-0068 | 2026-11-13 | 0.5.0-dev | Limpieza del terminal en el paso 2b del arnés | ❌ | «bspc» no es un qcode de QEMU (rechazado en silencio): la línea quedó «aaaaaamostrar» — el qcode correcto es «backspace»; PASA de nuevo 28/28 |

| P-0069 | 2026-11-13 | 1.0.0-dev | ISO: arranque BIOS (SeaBIOS + El Torito) | ❌ | strcmp de SeaBIOS exige NUL tras «EL TORITO SPECIFICATION» (rellenaba con espacios → código 5) |
| P-0070 | 2026-11-13 | 1.0.0-dev | ISO: catálogo El Torito | ❌ | Clave 55AA y checksum intercambiados (la clave va en 30-31, no 28-29 → código 0xa) |
| P-0071 | 2026-11-13 | 1.0.0-dev | ISO: kernel en RAM | ❌ | stage2_cd leía desde LBA 4609 (+2048) pero el binario iba pegado a la cabecera de 512 B: mkiso ahora alinea el binario al sector de CD |
| P-0072 | 2026-11-13 | 1.0.0-dev | ISO: arranque UEFI (OVMF) | ❌ | EDK2 moderno no trae driver ISO9660: añadida sección El Torito 0xEF que expone la FAT16 embebida como partición |
| P-0073 | 2026-11-13 | 1.0.0-dev | **Arranque ISO en BIOS** (`probar_iso.py`) | ✅ | 6/6: ESCRITORIO LISTO, cadena AB…J, ratón PS/2, 11/14 autopruebas (sin ATA), captura 26538 px |
| P-0074 | 2026-11-13 | 1.0.0-dev | **Arranque ISO en UEFI** (OVMF) | ✅ | 7/7: [ANTLEX EFI] medio 2048 B, GOP 1280x800, ESCRITORIO LISTO, captura 32036 px |
| P-0075 | 2026-11-13 | 1.0.0-dev | Portable Linux (arranque real) | ✅ | ZIP descomprimido: lanzar.sh → ANTLEX BOOT OK + ESCRITORIO LISTO; lanzar-uefi.sh → [ANTLEX EFI] + ESCRITORIO LISTO |
| P-0076 | 2026-11-13 | 1.0.0-dev | Portable Windows (estructura) | ✅ | 146 archivos: exe + 104 DLLs (clausura por objdump), firmware, bats con CRLF; no ejecutable en entorno Linux |
| P-0077 | 2026-11-13 | 1.0.0-dev | Corrección del CI de v0.5.0 | ⚠️ | El arnés del escritorio NO se ejecutó en el CI de v0.5.0 (un replace silencioso dejó ci.yml sin el paso); corregido con assert y re-verificado |
| P-0078 | 2026-11-13 | 1.0.0-dev | Auditoría REV-FASE6 | ✅ | APTO CON OBSERVACIONES: S1 (guardia stage1_cd) y S2 (format=raw) corregidos; H1-H3 informativos |

| P-0079 | 2026-11-13 | 1.1.0-dev | Lógica del juego Adivina en host | ✅ | 2 pruebas deterministas (ronda completa con semilla fija, límites y teclas ignoradas): 44/44 en total |
| P-0080 | 2026-11-13 | 1.1.0-dev | Juego Adivina en el escritorio (arnés) | ✅ | 33/33: abrir por clic, foco, ronda nueva, intento por teclado real, cierre con ESC |
| P-0081 | 2026-11-13 | 1.1.0-dev | Auditoría REV-v1.1.0-dev + documentación | ✅ | auditar.py PASA; manual de aplicaciones coherente con el código (verificado cada extracto) |

| P-0082 | 2026-11-14 | 1.1.0 | Documentación de la Fase 4 publicada | ✅ | docs/informe-fase-4-v0.4.0.md: el informe de la IA embebida pasa del registro local al repositorio |

| P-0083 | 2026-11-14 | 1.1.0 | Batería completa de liberación v1.1.0 | ✅ | Re-ejecutada sobre la build final 1.1.0: host 44/44 · boot BIOS/UEFI · escritorio 33/33 · ISO BIOS 6/6 y UEFI 7/7 · ALFS · AntLex IA 24/24 · auditar.py · fmt (detalles en REV-v1.1.0) |

| P-0084 | 2026-11-14 | 1.2.0 | Formato .ALX y herramientas en host | ✅ | 54/54: cabecera/validación/asociaciones (alx_def), conversor mkalx con ELF sintético, lógica de la calculadora (suma, cadena, división por cero, límites) |
| P-0085 | 2026-11-14 | 1.2.0 | Ejecutables .ALX de punta a punta (arnés nuevo) | ✅ | probar_alx.py 20/20: bit EJECUTABLE, carga, ventana, foco, 4 cálculos con teclado ES real, 9/0=E, descarga con ESC, asociaciones, abrir Reloj con captura (1075 px), errores útiles, re-ejecución |
| P-0086 | 2026-11-14 | 1.2.0 | .ALX desde el explorador (escritorio) | ✅ | probar_escritorio.py 41/41: 8 pasos nuevos — subir a raíz, entrar /APPS, abrir CALC.ALX con clic+INTRO, calcular 12+34=46, cerrar y descargar |

| P-0087 | 2026-11-14 | 1.2.0 | Release v1.2.0: batería completa re-ejecutada + arnés .ALX en CI | ✅ | 54/54 host · probar_alx 20/20 · escritorio 41/41 · boot BIOS/UEFI · ISO 6/6 y 7/7 · ALFS · AntLex 24/24 · auditar · fmt — probar_alx añadido a ci.yml y release.yml |

| P-0088 | 2026-11-14 | 1.3.0-dev | Kernel de la Fase 8 (commit a172477) en CI | ❌ | `zig fmt --check` falló en `gui.zig` e `iconos.zig` (código nuevo sin formatear) y el resto del trabajo se saltó; corregido en 5ea445d |
| P-0089 | 2026-11-14 | 1.3.0-dev | Arnés del escritorio clásico (1ª pasada) | ❌ | 35 ok / 21 fallos: el ancla de orden nacía en «ESCRITORIO LISTO» pero los marcadores tempranos (splash, ventanas iniciales) salen ANTES; clics sobre puntos cubiertos por otras ventanas (el enrutado va foco-primero y luego índice descendente); menús cliqueados en posiciones previas a cascada/mosaico |
| P-0090 | 2026-11-14 | 1.3.0-dev | Arnés del escritorio clásico (2ª pasada) | ❌ | 68/1: el paso «foco Programas tras cascada» era innecesario — clicar la barra de menú ya enfoca la ventana y `enfocarVentana` solo traza si el foco CAMBIA; eliminado el clic previo |
| P-0091 | 2026-11-14 | 1.3.0-dev | **Arnés del escritorio clásico completo (Fase 8)** | ✅ | 68/68: arranque, splash, grupos e iconos, explorador (raíz→ejemplos→APPS), editor+F2 y verificación por `mostrar`, chat de AntLex, Adivina, grupo Accesorios cerrado con ✕, CALC.ALX con 12+34=46, minimizar/restaurar por icono, maximizar (doble clic) y ▲, arrastre, Alt+Tab→Terminal, Alt+F4, cascada, mosaico, cierre de apps con teclado, fondo teal por píxeles y apagado ACPI desde Archivo |
| P-0092 | 2026-11-14 | 1.3.0-dev | Flake del CI del tag v1.2.0: «sincronizar» | ✅ | Causa raíz: el push del tag disparó CI y Release a la vez y dos QEMU con TCG compitieron por la CPU del runner; la escritura ATA de `sincronizar` superó los 25 s del arnés (el archivo sí se escribió: el paso siguiente pasó). Corregido: margen de 60 s en probar_antlex.py y ci.yml sin trigger de tags |
| P-0093 | 2026-11-14 | 1.3.0 | **Release v1.3.0: batería completa re-ejecutada** | ✅ | Sobre la build final 1.3.0: host 54/54 · entrenar-verificar · boot BIOS/UEFI · ALFS · AntLex IA 24/24 · .ALX 20/20 · escritorio 68/68 · ISO BIOS 6/6 y UEFI 7/7 · auditar.py · fmt (detalles en REV-v1.3.0-dev) |

## Notas

- Las filas P-0001..P-0008 documentan el proceso de depuración del
  bootloader: se conservan a propósito como historial honesto del
  desarrollo (el proyecto valora el registro detallado).
- P-0015 quedó automatizada en la Fase 3: el arnés `probar_interprete.py`
  ejerce el teclado real por QMP (incluido Ctrl+C y TAB) en cada ejecución.
- El arnés del escritorio controla el ratón por HMP (`mouse_move`,
  `mouse_button`) porque `input-send-event` de QMP no llega al dispositivo
  PS/2 en QEMU 11 (verificado con sonda; P-0060). Las coordenadas de
  botones/menú/ventanas del arnés replican las constantes de gui.zig.
- Desde la Fase 8 (P-0089) el arnés del escritorio garantiza el FOCO
  antes de cada clic (el kernel enruta primero a la ventana enfocada y
  luego por índice de enum descendente), busca los marcadores serie en
  orden desde el splash, y cliquea los menús del Program Manager en su
  posición ACTUAL (cascada y mosaico lo mueven). El cierre final de
  ventanas usa Alt+Tab+Alt+F4: el teclado es inmune a las posiciones.
