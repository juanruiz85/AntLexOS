# RESUMEN DEL PROYECTO — AntLex OS

**Propósito de este documento**: que cualquier persona — u otra IA — pueda
retomar el proyecto donde está, sin re-derivar decisiones ya tomadas. Se
actualiza al final de cada fase.

## Qué es

Sistema operativo experimental **desde cero** en **Zig 0.14.1** para
**x86_64**, con IA embebida (**AntLex**, misma identidad que el sistema),
GUI desde el arranque y sistema de archivos propio (ALFS). Nada de
GRUB/Limine/Linux: bootloader propio en NASM (BIOS) y Zig (UEFI). Repo
público GPL-3.0: `juanruiz85/AntLexOS`. Commits bajo el usuario
`juanruiz85`.

Decisiones tomadas con el propietario (2026-11-11):
nombre **AntLex OS**; IA **AntLex** (renombrada desde "LEX" a petición del
propietario: la identidad de la IA es la del propio sistema, embebida en
él); FS **ALFS**; arranque **BIOS+UEFI**; teclado **ES conmutable**; GUI
**escritorio dividido terminal|AntLex + extras (explorador, editor)**;
comandos **en español con alias en inglés**; licencia **GPL-3.0**;
**un tag+release por fase** (v0.1.0 → v1.0.0).

## Estado actual (v0.5.0, Fase 5 terminada)

✅ Fase 1 (v0.1.0): bootloader BIOS completo + kernel con consola gráfica.
✅ Fase 1b (v0.1.1): bootloader UEFI propio (BOOTX64.EFI + FAT16 con mkfat).
✅ Fase 2 (v0.2.0): sistema de archivos **ALFS** con persistencia real
   (driver ATA PIO, sincronizar escribe el volumen y sobrevive a
   reinicios — verificado por arnés en BIOS y UEFI) e intérprete base.
✅ Fase 3 (v0.3.0): **intérprete completo** — 25 comandos ES+alias EN,
   historial con flechas, autocompletado TAB (comandos y rutas), reloj RTC
   (`fecha`/`hora`/Zeller con pruebas), `sistema` (sysinfo), `buscar`
   recursivo, `renombrar`, `pruebas` bajo demanda, `apagar`/`reiniciar`
   reales (ACPI verificado: QEMU cierra solo). Arnés de 22 pasos.
✅ Fase 4 (v0.4.0): **IA embebida AntLex** — red neuronal (bolsa → 16
   ocultas → 24 intenciones) entrenada al compilar por
   `tools/entrenar_antlex.zig` (determinista, parada por margen ≥85%) y
   embebida en Q4.11 **sin FPU**; inferencia entera en `antlex/nucleo.zig`
   (UTF-8/Latin-1, vacías, sinónimos, softmax con LUT); respuestas con
   datos en vivo; **memoria aprendida persistente** en /memoria/antlex.txt
   (aprende/olvida/memoria, cotejo por forma canónica); **explicabilidad**
   (`antlex por que`: tokens, cobertura, confianza, aportes grad×entrada);
   rechazo educado de temas ajenos (confianza 75% + cobertura >50%);
   comando `antlex` (alias `ai`) → **26 comandos**; autoprueba 13
   (12 canónicas); pruebas host **32/32**; arnés `probar_antlex.py`
   **24/24**; `entrenar-verificar` en CI (reproducibilidad).

✅ Fase 5 (v0.5.0): **escritorio con ventanas** — ratón PS/2 real (IRQ12,
   paquetes con signo, sección crítica en init, sin teclas perdidas al
   teclear con el ratón en movimiento); escritorio dividido **TERMINAL |
   chat de AntLex** con foco por clic; barra de tareas con menú INICIO,
   reloj y memoria; ventanas arrastrables **Explorador** (navega ALFS,
   abre .txt) y **Editor** (F2 guarda en ALFS) + Acerca de; consolas con
   rejilla de respaldo (los paneles se repintan al destaparlos); intérprete
   re-factorizado a `tecla()` para que la GUI enrute el teclado; límite de
   kernel 768 KiB; autoprueba 14; pruebas host **42/42**; arnés
   `probar_escritorio.py` **28/28** (ratón por HMP: `input-send-event` no
   llega al PS/2 en QEMU 11).

Siguiente: **Fase 6 (v1.0.0) empaquetado y distribución** (ver `TODO.md`).

Lecciones Fase 5 para quien continúe:
1. El controlador PS/2 es COMPARTIDO: teclado y ratón usan el mismo búfer
   de salida. Sin sección crítica en el init del ratón, la IRQ1 se come
   los bytes de respuesta; y si IRQ1 vuelve sin leer porque hay un byte
   AUX delante, el byte de teclado que viene detrás ya no genera otro
   canto (PIC por flanco) — `raton.irq` lo remata.
2. `input-send-event` de QMP NO llega al PS/2 en QEMU 11; el ratón se
   controla por HMP (`mouse_move`/`mouse_button`). Y los qcodes van en
   minúscula: las mayúsculas se rechazan en silencio (mayúscula =
   shift+letra; borrar = `backspace`, no `bspc`).
3. Las estructuras grandes con inicializadores no nulos caen en .data y
   engordan el binario: inicializadores a cero (todo a .bss) y asignar en
   init(). La huella total (binario+.bss) es lo que limita el cargador.

Lecciones Fase 4 para quien continúe:
1. El kernel NO tiene FPU: toda la IA es punto fijo. Q4.11 (±15.99, paso
   1/2048) para pesos y Q16.16 para activaciones; acumular en i64 y
   clampear a ±2^30 antes de i32.
2. Softmax entera: exp(-d) = 2^(-d·log₂e) con LUT comptime de 2^(-i/256).
   OJO al signo: la LUT lleva el exponente NEGATIVO (unPositive LUT daba
   exp(-1)≈0.68 y softmax casi uniforme — bug real, ver REV-FASE4 S4).
3. `zig build probar*` recompila en DEBUG (sin -Drelease) y el kernel
   debug NO cabe en el límite de 512 KiB del cargador UEFI: los arneses
   van contra la imagen release (invoca los .py directamente o con
   -Drelease=true). En BIOS el debug arranca; en UEFI no.
4. Los literales de cadena de Zig son UTF-8 pero el teclado PS/2 produce
   Latin-1: la normalización acepta AMBOS (decodificador UTF-8 con
   fallback a byte crudo).
5. El cotejo de "memoria aprendida" usa la forma canónica (normalizada +
   SIN palabras vacías): normalizar a secas NO quita el/la/de/que y las
   claves nunca casaban (REV-FASE4 S1).
6. Momentum 0.9 en SGD con bolsa de palabras dispersa no convergía (26%
   clavado): el paso efectivo ~10×. SGD plano + parada por margen, mejor.
7. Cuantizar destruye redes sobreentrenadas (pesos >rango se clampaban):
   parar cuando TODO el corpus clasifica con margen en la red YA
   cuantizada — no cuando el argmax acierta.
8. El formato `{d:>6}` de Zig 0.14 emite '+' en positivos: los literales
   "+713," no compilan. Formato manual en el generador de pesos.zig; y el
   archivo generado pasa por `zig fmt` (build step), así que la
   verificación compara ENTEROS, no bytes.
9. En el mapa ES: '=' es shift+0 y '/' es shift+7 (QMP send-key con
   combos ["shift","0"]) — el qcode "slash" produce '-' en ES.

Lecciones Fase 3 para quien continúe:
1. `switch` de Zig no admite solapamiento entre un caso puntual y un
   rango: las flechas (0x80-0x83) y el rango C1 0x80-0x9F no pueden
   coexistir; enumera los códigos especiales explícitamente.
2. El filtro de imprimibles debe aceptar Latin-1 ≥ 0xA0 (ñ, acentos, ¿¡)
   pero descartar C1 (0x80-0x9F): `(c < 0x80 or c >= 0xA0)`.
3. Las funciones de comando son `fn ([]const u8) void`: para `apagar`
   (que no vuelve) declara void con bucle `hlt` final — un fn `noreturn`
   no coercionaba bien en la tabla.
4. Un slice de un búfer local solo vive durante la llamada: `salida(bufPrint(&buf,…))`
   es válido, devolverlo no.
5. QMP `send-key` acepta combos (`["ctrl","c"]`) — ideal para probar
   cancelaciones.

Lecciones Fase 2 para quien continúe (además de las de Fase 1):
1. PIO «READ/WRITE SECTORS» pide DRQ por CADA sector: nunca hagas `rep
   insw/outsw` de más de 256 palabras seguidas.
2. **`rep outsw` lee de RSI, `rep insw` escribe en RDI** (semejanza con
   movs). Confundirlos escribe ceros sin error alguno — verificado a costa
   de un volumen borrado.
3. El asm inline de Zig 0.14 no acepta `"={D}"` como salida con la misma
   entrada: usa entradas de registro fijo + clobbers (patrón en ata.zig,
   probado con script aparte antes de integrarlo).
4. El scancode del INTRO (0x1C) debe estar EN LA TABLA del teclado: el eco
   de caracteres funcionaba pero ninguna línea llegaba al intérprete. Los
   arneses de teclado por QMP (`send-key`, qcode `ret`) destapan esto en
   segundos.
5. El cliente QMP debe leer por LÍNEAS y descartar eventos: las respuestas
   se acumulan con los eventos RESET.
6. Los búferes que reciben estructuras del disco (superbloque) deben estar
   alineados: `readFileAlloc` no lo garantiza (usar page_allocator o
   allocCero con alineación).
7. Toda aritmética sobre campos de disco va en u64: un `nbloques*512` en
   u32 es un pánico servido (H-1..H-3 de REV-FASE2, reproducidos).

Lecciones UEFI para quien continúe:
1. OVMF_4M viene PARTIDO (CODE 3.5M + VARS 0.5M): se monta como DOS
   pflash, no con -bios.
2. Ninguna llamada a boot services (¡ni printf por ConOut!) entre el
   getMemoryMap final y exitBootServices: invalidan la clave.
3. El reintento de EBS debe pedir el mapa con la CAPACIDAD del búfer
   (tam viejo + margen), no con el tamaño del mapa anterior.
4. OVMF entra a la app con IF=1: el kernel hace cli() de inmediato.
5. El CS heredado de OVMF muere al sustituir la GDT: far-return a 0x18
   en gdt.init ANTES de cualquier iretq.

## Mapa del código

```
layout.zig            ← OFFSETS DEL DISCO: fuente única de verdad (¡leer primero!)
src/boot/efi/main.zig bootloader UEFI (std.os.uefi, BlockIo+GOP+EBS con reintentos)
tools/mkfat.zig       partición FAT16 de arranque EFI (código propio)
linker.ld             kernel en 0x100000, .text.boot primero
src/boot/stage1.asm   MBR 512 B (marca "ANTLEX" en offset 3)
src/boot/stage2.asm   cargador completo; -D CD=1 = variante ISO (El Torito)
src/kernel/main.zig   kentry/kmain: orden de inicialización y consola
src/kernel/boot_info.zig  protocolo v2 de 76 bytes (BIOS y UEFI lo rellenan)
src/kernel/idt.zig    stubs comptime + Marco; selector 0x18; eoi()
src/kernel/teclado.zig  tablas ES/US 256 entradas, teclas muertas, INTRO/TAB, atómicos
src/kernel/{pantalla,fuente,consola}.zig  framebuffer 32bpp + fuente 8×16 unifont
src/kernel/ata.zig      driver ATA PIO LBA28 (DRQ por sector, timeouts)
src/kernel/alfs_formato.zig  formato ALFS en disco (superbloque/entradas/bitmap)
src/kernel/alfs_volumen.zig  operaciones de Volumen (capa pura, sin E/S)
src/kernel/alfs.zig     montaje por ATA + sincronizar (espejo RAM)
src/kernel/interprete.zig  25 comandos ES+alias, historial, TAB, salida serie
src/kernel/reloj.zig    RTC del CMOS (BCD, 12/24 h, Zeller, formatos)
src/kernel/{gdt,pic,pit,mem,serial,x86,version,autoprueba}.zig
tools/mkimage.zig     ELF→img (cabecera ALKR con crc32, particiones)
tools/mkalfs.zig      volumen ALFS inicial desde fsroot/ (mismo módulo Volumen)
tools/genfont.zig     unifont.hex → fuente_datos.zig (subconjunto commiteado)
tools/probar_boot.py  QEMU headless: serial + QMP screendump + validación píxeles
tools/probar_alfs.py  persistencia: teclado QMP → sync → REINICIO → verificar
tools/probar_interprete.py  sesión real del intérprete (22 pasos, apagado ACPI)
tools/auditar.py      secretos/TODO/versión (CI lo exige)
tools/release.sh      CLI: ./tools/release.sh 0.2.0 "resumen" → tag → CI publica
tools/inspeccionar.py volcado de memoria física vía QMP (depuración)
fsroot/               contenido inicial del volumen ALFS (manuales dentro)
```

## Cómo trabajar aquí

```bash
# entorno del sandbox (si aplica): source /home/z/my-project/scripts/entorno.sh
zig build -Drelease=true      # imagen en zig-out/antlexos.img
zig build test                # unitarias host (23)
zig build probar              # arranque verificado en QEMU (BIOS)
zig build probar-uefi         # arranque verificado con OVMF
zig build probar-alfs         # persistencia real: escribe, REINICIA y verifica
zig build probar-interprete   # sesión real: historial, TAB, reloj, apagado ACPI
python3 tools/auditar.py
./tools/release.sh X.Y.Z "resumen de fase"   # publica (solo árbol limpio)
```

Reglas de oro aprendidas (errores reales de esta fase, no repitas):

1. **Pseudodescriptores (GDTR/IDTR)**: struct con u16+u64 → `packed struct`
   de 10 bytes y `asm ("lgdtq (%[d])" :: [d] "r" (&d))` — nunca "m".
2. **Tablas de páginas en modo largo**: entradas de **8 bytes** (stride 8,
   parte alta a cero) — un stride de 4 produce page-fault con código de
   error 0x8 (bits reservados).
3. **Selectores**: stage2 y kernel comparten layout (0x08=código32,
   0x10=datos, **0x18=código64**). CS heredado=0x18; las puertas IDT usan
   0x18. Cambiar uno sin el otro = #GP err=0x18 o entrada en modo compat.
4. **BIOS deja IF=1** tras int 13h: `cli` + enmascarar PIC antes de la
   transición PM.
5. **CR4.PAE antes de PG** (obvio pero se olvidó una vez).
6. El cargador de CD usa LBA de 2048 B: los offsets del layout son bytes
   múltiplos de 2048 a propósito (kernel@9 MiB, ALFS@13 MiB).
7. `movq %[tope], %%rsp` con "r" en el kentry naked funciona; no uses "i".
8. Las salidas de pasos NASM viven en .zig-cache: para desensamblar lo
   que REALMENTE arrancó, extrae del .img (`dd skip=1`) o usa
   tools/inspeccionar.py.
9. Cuidado con `add rax, [mem]` en NASM 64: infiere qword — leer campos
   u32 con `mov r8d, [mem]`.

## Protocolos que debes respetar al continuar

- **boot_info** (76 B en 0x5000): ver `src/kernel/boot_info.zig` y el
  manual técnico §3. **v2**: cualquier campo nuevo ⇒ versión +1 y
  compatibilidad en los DOS bootloaders (alfs_ptr/alfs_size ya están en v2).
- **Cabecera de kernel** ("ALKR"): ver manual técnico §2.1.
- **Trazas serie**: `init: <paso>` en el arranque; `SPLASH VISIBLE` /
  `CONSOLA LISTA` los usa `probar_boot.py` (no los borres sin actualizar
  el arnés); `[ OK ]/[FALLA] <nombre>` para autopruebas; `ANTLEX BOOT OK
  v<version>` marca el éxito; `ALFS MONTADO ...`/`ALFS SINCRONIZADO` los usa
  `probar_alfs.py`. **El intérprete refleja toda su salida por COM1**
  (consola remota): no lo rompas, la automatización de teclado depende de
  eso.
- **Versionado**: `VERSION` + `src/kernel/version.zig` sincronizados
  (auditar.py lo exige); CHANGELOG con sección por tag; PRUEBAS.md con una
  fila por ejecución (versionada); revisión de seguridad por fase.

## Trampas del entorno sandbox (para la IA que siga)

- El toolchain portátil vive en `/home/z/my-project/toolchain/` (zig,
  nasm, qemu-root con OVMF). `source /home/z/my-project/scripts/entorno.sh`
  exporta PATH y QEMU_FW (rutas -L del firmware).
- Los procesos en segundo plano NO sobreviven entre mensajes: ejecuta
  tareas largas en primer plano con timeout.
- El token de GitHub está en `/home/z/my-project/.token` (chmod 600,
  FUERA del repo). Nunca imprimirlo ni commitearlo. Para empujar:
  `git -c credential.helper='!f(){ echo username=juanruiz85; echo
  password=$(cat /home/z/my-project/.token); }; f' push origin main --tags`.

## Próximos hitos (resumen; detalle en TODO.md)

1. **Fase 1b**: `src/boot/efi/main.zig` con std.os.uefi + `tools/mkfat.zig`
   (FAT16) + prueba OVMF en CI.
2. **Fase 2**: `ata.zig` (PIO LBA28) + `alfs.zig` (bitmap+extensiones, 256
   entradas, jerárquico) + `tools/mkalfs.zig` desde `fsroot/`.
3. **Fase 3**: `interprete.zig` (~25 comandos ES+alias, historial, TAB).
4. **Fase 4**: `tools/entrenar_lex.zig` → pesos embebidos; `src/kernel/lex/`.
5. **Fase 5**: ✅ terminada (v0.5.0).
6. **Fase 6**: `tools/mkiso.zig` (ISO9660+El Torito dual) + portables con
   QEMU + release v1.0.0 completo.
