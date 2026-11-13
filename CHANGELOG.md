## [v0.4.0] - 2026-11-13

### Fase 4 — IA embebida AntLex (misma identidad que el sistema)

- **AntLex, la IA del sistema, ya responde**: red neuronal diminuta
  (bolsa de palabras → 16 ocultas ReLU → softmax) **entrenada al
  compilar** y embarcada como pesos de punto fijo **Q4.11 sin FPU**
  (`src/kernel/antlex/pesos.zig`, generado por `tools/entrenar_antlex.zig`).
- **Corpus español propio**: 161 ejemplos en 24 intenciones, todas sobre el
  propio sistema (memoria, CPU, pantalla, disco, ALFS, espacio, fecha, hora,
  uptime, comandos, teclado, arranque, licencia, version, identidad, autor,
  archivos, sincronizar, apagar, reiniciar, saludo, despedida, gracias…).
- **Inferencia 100% entera en el kernel**: normalización (UTF-8 y Latin-1,
  minúsculas, sin acentos), palabras vacías, sinónimos (ram→memoria,
  cpu→procesador…), softmax con LUT exp2 comptime, umbral de confianza 75%
  y **cobertura de vocabulario >50%**: los temas ajenos se rechazan
  educadamente (los 8 adversariales del corpus, verificados).
- **Respuestas con datos en vivo**: memoria real, CPUID, framebuffer,
  disco ATA, bloques/entradas libres de ALFS, reloj RTC, uptime y modo de
  arranque (BIOS/UEFI/CD) — no hay respuestas prefabricadas.
- **Memoria aprendida persistente**: `antlex aprende <clave> = <respuesta>`
  guarda pares en `/memoria/antlex.txt` (ALFS); la clave coteja por forma
  canónica (sin mayúsculas, acentos ni palabras vacías), tiene prioridad
  sobre la red y sobrevive a reinicios con `sincronizar`/`apagar`.
  `antlex memoria` lista; `antlex olvida <clave>` borra.
- **Explicabilidad**: `antlex por que` cuenta la última respuesta — tokens
  reconocidos, cobertura, intención y confianza con umbral, segunda opción
  y aportes grad×entrada de cada palabra (o la clave aprendida que casó).
- **Rechazo educado** en dos variedades: sin palabras conocidas y cobertura
  insuficiente, con sugerencia de reformular o enseñar.
- **Autoprueba 13** (`antlex_canonica`): 12 preguntas canónicas (10 de
  sistema + 2 ajenas) → **13/13 autopruebas** en cada arranque.
- **Pruebas host: 32/32** (4 del núcleo + corpus 100% con la inferencia de
  punto fijo + canon 12/12 + adversariales 8/8 + coherencia de pesos).
- **Determinismo y trazabilidad**: el entrenador (SGD plano, LCG de semilla
  fija, **parada por margen** ≥85% con la red cuantizada) produce el mismo
  archivo byte a byte; `zig build entrenar-verificar` comprueba en CI que
  lo commiteado sigue siendo reproducible.
- **Arnés `tools/probar_antlex.py`**: conversación real de **24 pasos** por
  QMP con teclado español (intenciones en vivo, aprende/pregunta/persiste/
  lista/olvida, por qué en sus tres modos, rechazos, 13/13 y apagado ACPI).
- Auditoría **REV-FASE4** registrada (8 hallazgos + 3 informativos, todo
  corregido); 26 comandos en el intérprete (nuevo `antlex`, alias `ai`).

## [v0.3.0] - 2026-11-11

### Fase 3 — Intérprete de comandos completo

- **25 comandos** en español con alias en inglés: se añaden `sistema`
  (sysinfo), `fecha`, `hora`, `historia`, `pruebas`, `renombrar`, `buscar`,
  `apagar` y `reiniciar` a los 16 de la Fase 2.
- **Historial con flechas** ↑/↓ (16 entradas, numerado estilo bash, sin
  duplicados consecutivos, conserva la línea en edición al navegar).
- **Autocompletado con TAB**: comandos y rutas ALFS. Coincidencia única
  completa la palabra; múltiples opciones muestran la lista y amplían el
  prefijo común; los directorios completan con `/`. Comparación sin
  mayúsculas; los alias completan al nombre canónico.
- **Reloj de tiempo real** (`src/kernel/reloj.zig`): lectura del CMOS con
  espera del ciclo de actualización (UIP), conversión BCD/binaria, formatos
  12/24 h, siglo del registro 0x32 con respaldo al siglo 21, día de la
  semana por congruencia de Zeller (verificado con 1970-01-01 y 2000-01-01).
  `fecha` muestra "miércoles 11 de noviembre de 2026" + ISO; `hora`
  añade el tiempo de encendido.
- **`sistema`**: resumen tipo neofetch con logo ASCII de la hormiga, CPU por
  CPUID, memoria total/libre, framebuffer, disco + ALFS, teclado, uptime,
  fecha y licencia.
- **`pruebas`**: las 12 autopruebas bajo demanda con eco en la consola
  gráfica (antes solo por serie). Nueva autoprueba `reloj_rtc` → **12/12**.
- **`apagar`/`reiniciar`**: sincronizan ALFS si hay cambios pendientes y
  apagan por ACPI (QEMU cierra solo, verificado por el arnés) o reinician
  por pulso 8042 con triple fallo de respaldo.
- **`buscar <texto> [ruta]`**: búsqueda recursiva por nombre (sin
  mayúsculas) con límite de 100 resultados y profundidad 16; **`renombrar`**
  cambia el nombre de archivos de forma segura (crea el nuevo antes de
  borrar el original).
- **La IA del sistema se llama AntLex** (misma identidad que el sistema,
  embebida en él): renombrado en TODO, README, manuales y versión en lugar
  del provisional "LEX".
- **Arnés `tools/probar_interprete.py`**: sesión real de 22 comprobaciones
  por QMP (eco, ver, fecha ISO, hora, sistema, historial, flechas, TAB de
  comandos y de rutas, Ctrl+C, escribir/renombrar/buscar/mostrar/borrar,
  pruebas 12/12 y apagado ACPI con salida del proceso verificada). Se
  registra como paso `zig build probar-interprete`.
- Pruebas host: **23/23** (5 nuevas de Zeller y formatos del reloj + 1 de regresión del saneo CMOS).

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
