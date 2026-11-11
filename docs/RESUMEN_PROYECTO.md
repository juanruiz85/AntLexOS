# RESUMEN DEL PROYECTO — AntLex OS

**Propósito de este documento**: que cualquier persona — u otra IA — pueda
retomar el proyecto donde está, sin re-derivar decisiones ya tomadas. Se
actualiza al final de cada fase.

## Qué es

Sistema operativo experimental **desde cero** en **Zig 0.14.1** para
**x86_64**, con IA embebida (LEX), GUI desde el arranque y sistema de
archivos propio (ALFS). Nada de GRUB/Limine/Linux: bootloader propio en
NASM (BIOS; UEFI en camino). Repo público GPL-3.0:
`juanruiz85/AntLexOS`. Commits bajo el usuario `juanruiz85`.

Decisiones tomadas con el propietario (2026-11-11):
nombre **AntLex OS**; IA **LEX**; FS **ALFS**; arranque **BIOS+UEFI**;
teclado **ES conmutable**; GUI **escritorio dividido terminal|LEX + extras
(explorador, editor)**; comandos **en español con alias en inglés**;
licencia **GPL-3.0**; **un tag+release por fase** (v0.1.0 → v1.0.0).

## Estado actual (v0.1.0, Fase 1 terminada)

✅ Bootloader BIOS completo (MBR → stage2 → modo largo) con VBE
1024×768×32 desde el arranque. ✅ Kernel Zig: GDT/IDT/PIC/PIT/teclado
ES-Us/framebuffer/consola/splash/autopruebas 8/8. ✅ Build reproducible
(zig + nasm; mkimage/genfont/probar_boot/auditar/release). ✅ CI + release
automático por tag. ✅ Auditoría REV-FASE1 corregida al completo.
✅ Documentación completa de la fase. ✅ **Fase 1b (v0.1.1): bootloader
UEFI propio** (BOOTX64.EFI + FAT16 con mkfat) arrancando en OVMF con el
mismo kernel e imagen.

Siguiente: **Fase 2 (v0.2.0) ALFS + ATA** (ver `TODO.md`).

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
src/kernel/boot_info.zig  protocolo de 76 bytes (BIOS y UEFI lo rellenan)
src/kernel/idt.zig    stubs comptime + Marco; selector 0x18; eoi()
src/kernel/teclado.zig  tablas ES/US 256 entradas, teclas muertas, atómicos
src/kernel/{pantalla,fuente,consola}.zig  framebuffer 32bpp + fuente 8×16 unifont
src/kernel/{gdt,pic,pit,mem,serial,x86,version,autoprueba}.zig
tools/mkimage.zig     ELF→img (cabecera ALKR con crc32, particiones)
tools/genfont.zig     unifont.hex → fuente_datos.zig (subconjunto commiteado)
tools/probar_boot.py  QEMU headless: serial + QMP screendump + validación píxeles
tools/auditar.py      secretos/TODO/versión (CI lo exige)
tools/release.sh      CLI: ./tools/release.sh 0.2.0 "resumen" → tag → CI publica
tools/inspeccionar.py volcado de memoria física vía QMP (depuración)
fsroot/               contenido inicial del futuro volumen ALFS
```

## Cómo trabajar aquí

```bash
# entorno del sandbox (si aplica): source /home/z/my-project/scripts/entorno.sh
zig build -Drelease=true      # imagen en zig-out/antlexos.img
zig build test                # unitarias host
zig build probar              # arranque verificado en QEMU
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
  manual técnico §3. Cualquier campo nuevo ⇒ versión del protocolo +1 y
  compatibilidad en los DOS bootloaders.
- **Cabecera de kernel** ("ALKR"): ver manual técnico §2.1.
- **Trazas serie**: `init: <paso>` en el arranque; `SPLASH VISIBLE` /
  `CONSOLA LISTA` los usa `probar_boot.py` (no los borres sin actualizar
  el arnés); `[ OK ]/[FALLA] <nombre>` para autopruebas; `ANTLEX BOOT OK
  v<version>` marca el éxito.
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
3. **Fase 3**: `interprete.zig` (~24 comandos ES+alias, historial, TAB).
4. **Fase 4**: `tools/entrenar_lex.zig` → pesos embebidos; `src/kernel/lex/`.
5. **Fase 5**: ratón + escritorio dividido + ventanas (explorador, editor).
6. **Fase 6**: `tools/mkiso.zig` (ISO9660+El Torito dual) + portables con
   QEMU + release v1.0.0 completo.
