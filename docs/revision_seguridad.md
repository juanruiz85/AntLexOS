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

## REV-FASE3 — 2026-11-11 (pre-v0.3.0)

- **Alcance**: Fase 3 completa (reloj.zig nuevo, interprete.zig extendido
  con historial/TAB/9 comandos, autoprueba.zig con eco de consola, tests.zig,
  build.zig paso probar-interprete, tools/probar_interprete.py, docs).
- **Veredicto**: **APTO CON OBSERVACIONES** → condición cumplida: H-1
  (crítica) y el resto de hallazgos corregidos ANTES del tag v0.3.0;
  suite completa re-ejecutada en verde (P-0044). El agente verificó
  empíricamente (Zig 0.14.1, programas aislados) los hallazgos de
  formateo/índice antes de reportarlos.
- **Secretos**: NINGUNO en el repositorio (auditar.py PASA).

### Hallazgos y resolución

| ID | Severidad | Hallazgo | Resolución |
|----|-----------|----------|------------|
| H-1 | CRÍTICA | `reloj.zig`: `MESES[@min(f.mes,12)-1]` underflowea con mes 0 de un CMOS con batería agotada → pánico del kernel con `fecha` (reproducido) | ✅ Saneo en `leer()` (mes/día/hora a rangos válidos) + índice con `@min(@max(f.mes,1),12)` + prueba host de regresión (23.ª) |
| H-2 | MEDIA | `lista`: búfer de 16 B insuficiente para "{d:>8} B {d:>3} blk" (≥19 B) → la columna de tamaño NO se imprimía NUNCA (bug heredado de v0.2.0, ningún arnés la cubría) | ✅ Búfer a 24 B + paso nuevo del arnés "lista muestra columna de tamano" |
| H-3 | MEDIA | `probar_interprete.py`: `paso()` dejaba la referencia en el INICIO de la marca anterior → el paso de flecha-arriba re-encontraba la ocurrencia vieja (falso positivo garantizado) | ✅ Referencia pasa a `pos + len(marca)` (y en la marca inicial de consola) |
| H-4 | MEDIA | Autocompletado por alias: completaba con el nombre canónico pese a teclear el alias → "date"+TAB producía "datcha" | ✅ La rama de alias completa con el propio alias |
| H-5 | BAJA | `buscarRec`: `bufPrint(...) catch continue` saltaba también la comprobación de coincidencia y el subdirectorio; truncamientos sin aviso | ✅ Coincidencia comprobada antes de construir la ruta; salida "…/nombre" si la ruta no cabe; aviso "(límite de N resultados alcanzado)" |
| H-6 | BAJA | Cada lectura del RTC deja la NMI enmascarada (bit 7 de 0x70) sin restaurar | ✅ Documentado en manual técnico §5.4 (kernel no usa NMI) |
| H-7 | BAJA | `cargarLinea` redibujaba con retrocesos simples: en serie dejaba texto fantasma (0x08 no borra) y en consola podía dejar restos con líneas envueltas | ✅ Retroceso+espacio+retroceso en consola y serie (líneas envueltas: limitación conocida hasta la GUI de Fase 5) |
| H-8 | BAJA | manual_tecnico.md decía "SLP_TYP=5" pero el código escribe SLP_EN (S5 de QEMU) | ✅ Manual corregido |
| H-9 | BAJA | `renombrar`: si borrar() fallaba tras crear(), quedaban dos archivos sin informar | ✅ Mensaje explícito "…PERO no se pudo borrar el original" |
| H-10 | INFO | Consumo del bump allocator por `pruebas`/`copiar`/`renombrar` (memoria filtrada hasta Fase 7) | ℹ️ Ya documentado como limitación; vigilar en máquinas de 32-64 MiB |

### Puntos verificados correctos (resumen)

Zeller sin desbordamientos (i32, @intCast acotado); deBcd (máx 165);
esperarEstable acotado; invariante del historial (16 entradas, dedup,
guards de flechas); autocompletado con guardas y slices síncronos;
buscarRec sin aliasing entre niveles y PROFUNDIDAD_MAX=16 = límite real de
ALFS; lidtq sobre 10 bytes = patrón canónico (sin alineación requerida);
cmdPruebas con contadores que se resetean; cifras de docs verificadas
contra el código (25 comandos, 12 autopruebas, 22→23 host, 21→22 pasos del
arnés tras el paso nuevo); sin usos incorrectos de Zig 0.14.

## REV-FASE4 — 2026-11-13 (pre-v0.4.0)

- **Alcance**: Fase 4 completa — IA embebida AntLex: `src/kernel/antlex/`
  (nucleo.zig, corpus.zig, pesos.zig generado), `src/kernel/antlex.zig`,
  `tools/entrenar_antlex.zig`, `tools/probar_antlex.py`, integración en
  intérprete/autopruebas/main, build steps `entrenar`/`entrenar-verificar`/
  `probar-antlex`.
- **Veredicto**: **APTO CON OBSERVACIONES** → todo lo relevante corregido
  durante la fase y re-verificado por el arnés (24/24) y las 32 pruebas host.
- **Secretos**: NINGUNO (auditar.py pasa; los pesos embebidos son solo
  números Q4.11 del corpus público).

### Hallazgos y resolución

| ID | Severidad | Hallazgo | Resolución |
|----|-----------|----------|------------|
| S1 | ALTA (funcional) | El cotejo de la memoria aprendida comparaba la pregunta normalizada COMPLETA (con palabras vacías) contra la clave: "cual es tu color favorito" nunca casaba con "color favorito" | ✅ Clave de cotejo = forma canónica (normalizada + sin vacías + tokens unidos por espacio) en guardarPar/pregunta/olvida; verificado por el arnés (pasos 12-13) |
| S2 | MEDIA | Prefijo "AntLex: " duplicado en los intents con datos en vivo (memoria, pantalla, espacio): "AntLex: AntLex: 479 MiB…" | ✅ Eliminado el prefijo interno (lo imprime pregunta()); verificado en serial |
| S3 | MEDIA | Cuantización Q8.8 original clampaba pesos ≥0.496 tras el sobreentrenamiento (exactitud cuantizada 9%) y el reescalado t·k aplastaba la resolución (5%) | ✅ Formato Q4.11 (±15.99, paso 1/2048) + parada temprana por MARGEN (todo el corpus ≥85% con la red cuantizada): 100% cuantizada, canon 12/12 con ≥94%, pesos ~±3 sin reescalar |
| S4 | MEDIA | LUT de exp2 con signo positivo: exp(-1) devolvía ≈0.68 (real 0.368) → softmax casi uniforme | ✅ LUT = 2^(-i/256) decreciente + prueba unitaria de extremos y exp(-1) (±1%) |
| S5 | BAJA | normalizar asumía Latin-1; los literales Zig son UTF-8 ("Qué" → basura "a qua") | ✅ Decodificador UTF-8 (2-3 bytes) con fallback a byte crudo Latin-1 (lo que teclea el intérprete); pruebas con acentos, ¿¡ y ñ→n |
| S6 | BAJA | `olvidar` imprimía la clave DESPUÉS de desplazar el array (mostraba el par siguiente o datos viejos) | ✅ Copia de la clave a un búfer local antes del shift |
| S7 | BAJA | adversariales con una palabra de vocabulario ("como hacer una tarta de queso" → comandos 94%) | ✅ Doble regla de aceptación: confianza ≥75% Y cobertura de vocabulario >50% (51%); los 8 adversariales del corpus se rechazan y el canon 12/12 pasa |
| S8 | BAJA | Comparación byte a byte de pesos.zig rota al pasar `zig fmt` (alinea columnas) | ✅ `--verificar` compara la SECUENCIA DE ENTEROS (insensible al formato); build step `entrenar` deja el archivo formateado |
| H1 | INFO | Los pares aprendidos tienen PRIORIDAD sobre la red: un /memoria/antlex.txt precargado puede cambiar respuestas (p. ej. la identidad) | Comportamiento INTENCIONADO (espacio del usuario); documentado aquí y en el manual técnico |
| H2 | INFO | `canonica()` trunca a 48 bytes: en teoría podría falsear un match | Imposible en la práctica: las claves miden ≤47 y la forma truncada mide exactamente 48 (verificado) |
| H3 | INFO | Comentarios obsoletos "Q8.8" en el entrenador | ✅ Actualizados a Q4.11 |

### Puntos verificados correctos (resumen)

Aritmética entera del kernel sin FPU acotada (z1 ≤ 33.5M en i32 con 32
tokens; z2 y aportes en i64 con clamp ±2^30; expMenosQ16 con ent<17 y
@intCast sobre no-negativos); buffers de normalización/tokens/pares con
guardas de longitud en cada escritura; memcpy de claves/valores solo tras
validar 47/127 bytes; parseo de /memoria/antlex.txt acotado (64 KiB,
64 pares, líneas sin '=' ignoradas); persistirPares compone en heap con
tope por línea y crea el directorio si falta; sin cadenas de formato
controladas por el usuario; sin bucles sin acotar; autoprueba 13
(antlex_canonica 12/12) en cada arranque; determinismo del entrenador
(LCG semilla fija, mismo binario → mismo archivo byte a byte; verificación
semántica en CI); PESOS con asserts de dimensiones (un pesos.zig
inconsistente pánica en el arranque, no en producción); tablas ES del
arnés ('=' = shift+0, '/' = shift+7) verificadas contra teclado.zig.


## REV-FASE5 — 2026-11-13 (pre-v0.5.0)

- **Alcance**: Fase 5 completa — `src/kernel/raton.zig`, `src/kernel/gui.zig`,
  `src/kernel/apps.zig`, refactor de `src/kernel/consola.zig` (Consola con
  rejilla), AUX/F2/ESC en `teclado.zig`, `tecla()` extraída en
  `interprete.zig`, salida de `antlex.zig` al chat, `layout.zig`
  (kernel_max 768 KiB) + `stage2.asm`, `tools/probar_escritorio.py` y CI.
- **Veredicto**: **APTO CON OBSERVACIONES** → hallazgos S1/S2 corregidos y
  cubiertos por regresión automática; arnés del escritorio 28/28 y las
  cinco suites de regresión en verde.
- **Secretos**: NINGUNO (auditar.py pasa; el arnés usa QMP/HMP locales).

### Hallazgos y resolución

| ID | Severidad | Hallazgo | Resolución |
|----|-----------|----------|------------|
| S1 | MEDIA | Byte de teclado atascado: si IRQ1 se dispara con un byte de ratón pendiente, vuelve sin leer; el byte de teclado detrás suyo no genera otro canto (PIC por flanco) y se pierde hasta la siguiente pulsación — teclear moviendo el ratón perdía teclas | ✅ `raton.irq`, tras drenar los bytes AUX, comprueba si queda un byte de teclado pendiente y llama a `teclado.irq()`; regresión automática en el arnés (paso 2b: teclear con el ratón en movimiento) |
| S2 | BAJA | Los 4 px del borde superior del menú INICIO ejecutaban el ítem 0 (divTrunc de desplazamientos negativos hacia 0) | ✅ Solo se ejecuta con `dy >= 0`; separador e índices fuera de rango no hacen nada |
| S3 | BAJA (funcional) | `explAbrir` leía el nombre de la entrada DESPUÉS de relistar el directorio: el puntero apuntaba al array recién reiniciado y el directorio abierto se trazaba con nombre vacío | ✅ Copia de nombre/índice a búfer local antes de relistar; verificado por el arnés («explorador entra ejemplos») |
| S4 | BAJA (higiene) | Consolas y ventanas con inicializadores no nulos iban a .data (62 KB extra de binario) y la huella total del kernel superaba el límite del cargador en UEFI (597 KB > 512 KiB) | ✅ Inicializadores a cero (todo a .bss), paleta de estilos 256→16 y límite subido a 768 KiB (P2 es de 4 MiB, heap en 32 MiB; stage2 con el mismo tope); binario 375 KB, huella 575 KB |
| H1 | INFO | El editor reserva 8-10 KB de heap por abrir/guardar sin liberar (bump allocator del kernel) | Comportamiento heredado del resto del kernel (mostrar/alfs hacen lo propio); a 32 MiB de heap no es alcanzable en una sesión normal |
| H2 | INFO | El cursor en XOR puede corromper unos píxeles si la consola escribe justo debajo mientras se mueve (sin compositor) | Efecto cosmético de v1, documentado; el cursor se redibuja en el siguiente evento |
| H3 | INFO | `input-send-event` de QMP no llega al PS/2 en QEMU 11 | El arnés usa `mouse_move`/`mouse_button` por HMP (verificado con sonda); documentado en PRUEBAS.md |

### Puntos verificados correctos (resumen)

Sincronización de paquetes PS/2 por bit 3 con descarte de desbordes;
coordenadas acotadas en IRQ y en la GUI (arrastre clamp que deja la barra
de título visible); búfer anillo de eventos con contador de desbordes y sin
corrupción; sección crítica cli/sti en init con restauración de IF y
timeouts acotados en cada espera de puerto; lecturas de rejilla/entradas
acotadas por cols/filas y n; copias de nombre por longitud mínima;
chat_linea/editor/acercas con guardas de longitud en toda escritura;
`procesarTecla` revalida que la ventana enfocada siga abierta; doble clic
por ventana de 40 tics con resta saturante; bucle del escritorio sin
asignaciones; sin cadenas de formato controladas por el usuario; las
coordenadas de la GUI que replica el arnés están en constantes compartidas
documentadas en ambos lados.


## REV-FASE6 — 2026-11-13 (pre-v1.0.0)

- **Alcance**: `src/boot/stage1_cd.asm`, `tools/mkiso.zig`,
  `tools/probar_iso.py`, `tools/empaquetar_portable.sh`,
  `tools/resolver_dlls.py`, `build.zig` (paso mkiso), CI y release con
  los nuevos artefactos.
- **Veredicto**: **APTO CON OBSERVACIONES** → S1/S2 corregidos con
  verificación; arranques ISO BIOS (6/6) y UEFI (7/7) y portable Linux
  (BIOS y UEFI) ejecutados de verdad.
- **Secretos**: NINGUNO (auditar.py pasa; el SHA-512 del instalador
  qemu-w64 se verifica antes de extraerlo).

### Hallazgos y resolución

| ID | Severidad | Hallazgo | Resolución |
|----|-----------|----------|------------|
| S1 | BAJA | stage1_cd podía crecer más de 512 B sin darse cuenta: stage2_cd aterriza en 0x7E00 y lo pisaría en tiempo de arranque | ✅ Guardia de ensamblado (%if + %error en nasm): no compila si el código pasa de 512 B |
| S2 | BAJA | Lanzadores de los portables con -hda sin formato: QEMU detecta raw, avisa y restringe escrituras del bloque 0 | ✅ -drive format=raw en los 4 lanzadores; portable Linux re-verificado |
| S3 | BAJA (funcional, hallado en depuración) | Desalineación del kernel en la ISO: stage2_cd lee desde el LBA 4609 (+2048 B) pero el binario iba tras la cabecera de 512 B → el kernel se copiaba desplazado y triple-faulteaba en el primer UBSan | ✅ mkiso alinea el binario al sector de CD (cabecera en el LBA 4608, binario en el 4609); el bootloader UEFI lee +tamanio_sector y funciona igual en ambos medios |
| H1 | INFO | Las DLLs del portable Windows se anclan a la versión 20260811 del instalador de Stefan Weil | Intencional y reproducible: versión fijada + SHA-512 verificado en cada empaquetado |
| H2 | INFO | En CD puro las autopruebas bajan a 11/14 (sin disco ATA fallan ata_identify, alfs_montado y alfs_operaciones) | Comportamiento correcto documentado; el arnés de la ISO lo espera explícitamente |
| H3 | INFO | El portable Windows no se puede EJECUTAR en un entorno Linux de CI | Verificación estructural completa (clausura por objdump + 104 DLLs + bats CRLF); la ejecución real queda para una máquina Windows |

### Puntos verificados correctos (resumen)

Tamaños acotados en mkiso (stage1/stage2 ≤ 1 sector, datos antes del
kernel, FAT dentro de 9 MiB) con fallo ruidoso en tiempo de construcción;
suma de verificación del catálogo con aritmética saturante (la aceptan
SeaBIOS y EDK2); fechas fijas → ISO reproducible byte a byte; la marca
ANTLEX del sector 0 identifica el medio para el bootloader UEFI sin
confiar en el sistema de archivos; el extractor de portables excluye el
directorio $PLUGINSDIR del NSIS; las descargas con --retry y caché
idempotente; sin secretos; lanzadores con rutas relativas al propio
script (funcionan desde cualquier directorio).


## REV-v1.1.0-dev — 2026-11-13 (manual de aplicaciones + juego Adivina)

- **Alcance**: `src/kernel/apps.zig` (juego), `src/kernel/gui.zig`
  (registro de la ventana), `tools/probar_escritorio.py` (pasos nuevos),
  `docs/manual_aplicaciones.md` (nuevo), README y manuales.
- **Metodología**: `tools/auditar.py` completo (PASA: sin secretos, sin
  marcadores, VERSION y version.zig sincronizadas en 1.1.0-dev) +
  revisión manual del código y de cada afirmación técnica del manual
  contra el fuente + re-ejecución de toda la batería afectada.

### Verificación ejecutada

| Prueba | Resultado |
|---|---|
| `zig build test` (host) | 44/44 (42 previas + 2 del juego, deterministas) |
| `probar_escritorio.py` (BIOS, 33 pasos) | 33/33 — clic/teclado reales por QMP+HMP |
| `zig fmt --check` | limpio |
| `auditar.py` | PASA |

### Hallazgos y resolución

| ID | Severidad | Hallazgo | Resolución |
|----|-----------|----------|------------|
| S1 | BAJA | Orden de trazas: «gui: adivina nueva» se emitía ANTES de «gui: foco ventana Adivina», y el arnés busca los marcadores en orden → paso en falso negativo | ✅ La ronda nueva se inicia tras `enfocarVentana` (orden lógico y trazas en secuencia); arnés 33/33 |
| S2 | BAJA (evitado) | Riesgo de regresión al añadir un botón a la barra: el arnés replica las coordenadas de los botones existentes | ✅ Botón añadido AL FINAL (x=436, no desplaza ninguno); los pasos previos pasan intactos |
| H1 | INFO | El azar del juego usa xorshift de 32 bits con semilla del PIT: no es criptográfico | Adecuado para un juego; documentado en el manual («El azar sin hardware») |
| H2 | INFO | `TipoApp` es `u2`: cupo de 4 ventanas alcanzado | Documentado en el manual §3.3 (cambiar a `u3` y agrandar `ventanas` cuando haga falta) |
| H3 | INFO | El manual afirma que no hay pila USB ni red: verificado contra el código (solo ATA/PS/2/serie) y coherente con TODO.md (ideas futuras) | — |

### Puntos verificados correctos (resumen)

Búferes del juego acotados (3 dígitos, mensaje de 48 B con `@min`, sin
punteros ni allocación); parseo numérico sin desbordamiento (máx. 999 en
u16); xorshift nunca recibe semilla 0 (`| 1`); las entradas fuera de
1..100 no cuentan como intento y se contestan con mensaje acotado; sin
nuevas superficies de entrada desde hardware (el teclado pasa por el
despacho central de la GUI); el manual no promete funciones inexistentes
(USB, red y ejecutables .ALX figuran como ideas futuras, no como
presentes).
