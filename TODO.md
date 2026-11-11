# TODO — AntLex OS

Hoja de ruta y lista de tareas. Cada fase termina con un tag `vX.Y.Z`, su
entrada en `CHANGELOG.md`, sus pruebas registradas en `docs/PRUEBAS.md` y su
auditoría en `docs/revision_seguridad.md`.

## Fase 1b (v0.1.1) — Bootloader UEFI propio
- [ ] `src/boot/efi/main.zig`: aplicación UEFI en Zig (std.os.uefi)
- [ ] Leer kernel y ALFS por BlockIO en los offsets fijos (9 MiB / 13 MiB)
- [ ] GOP para el framebuffer (32 bpp)
- [ ] Mapa de memoria → boot_info (modo UEFI) y salto al kernel
- [ ] `tools/mkfat.zig`: partición FAT16 con `/EFI/BOOT/BOOTX64.EFI`
- [ ] Prueba de arranque UEFI en QEMU con OVMF (job de CI)

## Fase 2 (v0.2.0) — Sistema de archivos ALFS
- [ ] `src/kernel/ata.zig`: driver ATA PIO (LBA28, polling)
- [ ] `src/kernel/alfs.zig`: montaje, creación/lectura/escritura/borrado,
      directorios jerárquicos, extensión de archivos
- [ ] `tools/mkalfs.zig`: genera el volumen inicial desde `fsroot/`
- [ ] Comandos: lista/ir/ruta/mostrar/escribir/anexar/nuevodir/borrar/
      copiar/espacio/sincronizar
- [ ] Persistencia real: cambios visibles tras reiniciar QEMU
- [ ] Autopruebas de ALFS en el arranque + pruebas host del formato

## Fase 3 (v0.3.0) — Intérprete de comandos
- [ ] `src/kernel/interprete.zig` con ~24 comandos en español + alias
- [ ] Historial con flechas, autocompletado con TAB
- [ ] `sistema` (sysinfo con CPUID, memoria, uptime, framebuffer)
- [ ] Reloj RTC (fecha/hora reales en consola y barra de tareas)
- [ ] `pruebas` (autopruebas bajo demanda), `apagar`/`reiniciar`

## Fase 4 (v0.4.0) — IA embebida LEX
- [ ] `tools/entrenar_lex.zig`: red diminuta (bolsa de palabras → capa
      oculta → intenciones) entrenada en build-time, pesos embebidos
- [ ] Corpus en español con intenciones solo del sistema (~150 ejemplos)
- [ ] `src/kernel/lex/`: normalización (acentos), sinónimos, clasificación
      con umbral de confianza, plantillas con datos en vivo (memoria, CPU…)
- [ ] `lex <pregunta>` + `lex por que` (explicabilidad) + `lex aprende`
      (pares guardados en ALFS) — y rechazo educado de temas ajenos
- [ ] Autoprueba de LEX: preguntas cannicas → intención esperada

## Fase 5 (v0.5.0) — Escritorio con ventanas
- [ ] Ratón PS/2 (IRQ12) con cursor
- [ ] Escritorio dividido: TERMINAL | chat de LEX (paneles base)
- [ ] Barra de tareas: menú, ventanas abiertas, reloj, memoria
- [ ] Ventanas flotantes arrastrables: Explorador de archivos, Editor de
      texto, Acerca de
- [ ] Explorador: navegar ALFS, abrir .txt en el editor
- [ ] Editor: editar líneas, guardar en ALFS

## Fase 6 (v1.0.0) — Empaquetado y distribución
- [ ] `tools/mkiso.zig`: ISO9660 + El Torito (BIOS y UEFI) sin xorriso
- [ ] `stage1_cd.asm` + variante CD de stage2 (sectores de 2048)
- [ ] `tools/empaquetar_portable.sh`: ZIP portable Linux con QEMU incluido
      y ZIP Windows (qemu w64) — descargar y probar sin instalar nada
- [ ] Release v1.0.0: IMG + ISO + portables + fuente + SHA256SUMS
- [ ] Verificación end-to-end de los artefactos publicados

## Ideas futuras (v1.x+)
- [ ] Asignador de memoria por clases de tamaño (sustituir bump allocator)
- [ ] ATA DMA / AHCI; discos más grandes
- [ ] Sonido PC speaker; pitido de arranque
- [ ] Juego incluido (¿snake en el escritorio?)
- [ ] Red (virtio-net) — muy a largo plazo
- [ ] Múltiples terminales simultáneas
