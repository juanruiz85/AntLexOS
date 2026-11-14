# TODO — AntLex OS

Hoja de ruta y lista de tareas. Cada fase termina con un tag `vX.Y.Z`, su
entrada en `CHANGELOG.md`, sus pruebas registradas en `docs/PRUEBAS.md` y su
auditoría en `docs/revision_seguridad.md`.

## Fase 1b (v0.1.1) — Bootloader UEFI propio
- [x] `src/boot/efi/main.zig`: aplicación UEFI en Zig (std.os.uefi)
- [x] Leer kernel por BlockIO en el offset fijo (9 MiB); ALFS se añadirá en la Fase 2
- [x] GOP para el framebuffer (32 bpp, con detección RGB/BGR)
- [x] Mapa de memoria → boot_info (modo UEFI, regiones fusionadas) y salto al kernel
- [x] `tools/mkfat.zig`: partición FAT16 con `/EFI/BOOT/BOOTX64.EFI`
- [x] Prueba de arranque UEFI en QEMU con OVMF (local y CI)

## Fase 2 (v0.2.0) — Sistema de archivos ALFS
- [x] `src/kernel/ata.zig`: driver ATA PIO (LBA28, polling, DRQ por sector)
- [x] `src/kernel/alfs*.zig`: montaje, creación/lectura/escritura/borrado,
      directorios jerárquicos, extensión de archivos (capa de volumen pura
      compartida con mkalfs y pruebas host)
- [x] `tools/mkalfs.zig`: genera el volumen inicial desde `fsroot/`
- [x] Comandos: lista/ir/ruta/mostrar/escribir/anexar/nuevodir/borrar/
      copiar/espacio/sincronizar (+ ayuda/ver/eco/limpiar/teclado)
- [x] Persistencia real: cambios visibles tras reiniciar QEMU
      (`tools/probar_alfs.py` en BIOS y UEFI)
- [x] Autopruebas de ALFS en el arranque (11/11) + pruebas host del formato
      y del volumen (9 pruebas nuevas)
- [x] Protocolo boot_info v2 (alfs_ptr/alfs_size) en BIOS y UEFI

## Fase 3 (v0.3.0) — Intérprete de comandos
- [x] `src/kernel/interprete.zig` con **25 comandos** en español + alias
- [x] Historial con flechas (16 entradas, numerado, sin duplicados consecutivos)
- [x] Autocompletado con TAB: comandos y rutas ALFS (prefijo común + opciones)
- [x] `sistema` (sysinfo con logo, CPUID, memoria, uptime, framebuffer)
- [x] Reloj RTC (`src/kernel/reloj.zig`): `fecha` y `hora` reales (UTC)
- [x] `pruebas` (autopruebas bajo demanda, eco en consola), `apagar`/`reiniciar`
      (ACPI/8042 con triple fallo de respaldo)
- [x] `renombrar` y `buscar` (recursivo, 100 resultados, profundidad 16)
- [x] Arnés `tools/probar_interprete.py`: sesión real de 22 pasos por QMP
      (incluye apagado limpio por ACPI verificado)

## Fase 4 (v0.4.0) — IA embebida AntLex ✅
- [x] `tools/entrenar_antlex.zig`: red diminuta (bolsa de palabras → capa
      oculta → intenciones) entrenada en build-time, pesos embebidos
      (SGD plano determinista, parada por margen, cuantización Q4.11)
- [x] Corpus en español con intenciones solo del sistema
      (161 ejemplos, 24 intenciones + 8 adversariales)
- [x] `src/kernel/antlex/`: normalización (UTF-8/Latin-1, acentos), sinónimos,
      clasificación con umbral de confianza 75% + cobertura >50%, respuestas
      con datos en vivo (memoria, CPU, disco, ALFS, reloj, uptime…)
- [x] `antlex <pregunta>` + `antlex por que` (explicabilidad) + `antlex aprende`
      (pares guardados en ALFS, cotejo por forma canónica) + `antlex olvida`
      + `antlex memoria` — y rechazo educado de temas ajenos (2 variedades)
- [x] Autoprueba de AntLex: 12 preguntas canónicas → intención esperada
      (autoprueba 13, 13/13 en cada arranque)
- [x] Arnés `probar_antlex.py` (24 pasos por QMP) + pruebas host 32/32 +
      `zig build entrenar-verificar` (reproducibilidad de los pesos)

## Fase 5 (v0.5.0) — Escritorio con ventanas ✅
- [x] Ratón PS/2 (IRQ12) con cursor (XOR, auto-inverso) y eventos por búfer
- [x] Escritorio dividido: TERMINAL | chat de AntLex (paneles base)
- [x] Barra de tareas: menú INICIO, botones de paneles/ventanas, reloj y memoria
- [x] Ventanas flotantes arrastrables: Explorador de archivos, Editor de
      texto, Acerca de (foco, orden Z, cierre [X] y ESC)
- [x] Explorador: navegar ALFS, abrir .txt en el editor (clic+INTRO y doble clic)
- [x] Editor: editar líneas, guardar en ALFS (F2, con marca de modificado)

## Fase 6 (v1.0.0) — Empaquetado y distribución ✅
- [x] `tools/mkiso.zig`: ISO9660 + El Torito (BIOS y UEFI) sin xorriso
- [x] `stage1_cd.asm` (con guardia de 512 B) + stage2 CD ya existente
- [x] `tools/empaquetar_portable.sh` + `resolver_dlls.py`: ZIP portable
      Linux con QEMU estático y ZIP Windows (qemu w64 de Stefan Weil con
      SHA-512 verificado, clausura exacta de DLLs) — sin instalar nada
- [x] Release v1.0.0: IMG + ISO + portables + fuente + SHA256SUMS
- [x] Verificación end-to-end: ISO arranca en BIOS y UEFI (arnés dedicado);
      portable Linux arrancado de verdad en ambos modos

## Ideas futuras (v1.x+)
- [ ] Asignador de memoria por clases de tamaño (sustituir bump allocator)
- [ ] ATA DMA / AHCI; discos más grandes
- [ ] Sonido PC speaker; pitido de arranque
- [x] Juego incluido: **Adivina** (v1.1.0, ejemplo del manual de aplicaciones)
- [x] **Fase 7 (v1.2.0)**: ejecutables `.ALX` — bit de ejecutable en ALFS, asociaciones por extensión, loader + API, `ejecutar`/`instalar`/`abrir`/`asociar`, apps Calculadora y Reloj — **publicada** (tag v1.2.0)
- [x] **Fase 8 (v1.3.0)**: escritorio estilo Windows 3.11 — Program Manager con grupos, iconos, minimizar a icono, relieve 3D, cascada/mosaico, Alt+Tab/F4 — **publicada** (tag v1.3.0); diseño y registro en [PLAN_FASES_7-9.md](docs/PLAN_FASES_7-9.md)
- [ ] **Fase 9 (v1.4.0)**: red virtio-net + TCP + TLS 1.3 + `descargar` y tienda de apps en GitHub — diseño en [PLAN_FASES_7-9.md](docs/PLAN_FASES_7-9.md)
- [ ] Pila USB (XHCI + mass-storage + lector FAT) para memoria USB
- [ ] Red (virtio-net) — muy a largo plazo
- [ ] Múltiples terminales simultáneas
