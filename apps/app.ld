/* AntLex OS — script de enlazado de las apps externas .ALX (x86_64).
 * La imagen se enlaza en ALX_BASE (16 MiB, ver src/kernel/alx_def.zig):
 * el kernel copia el resultado tal cual a esa dirección física y llama
 * a `alx_evento` (e_entry, que fija build.zig). */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

SECTIONS
{
    . = 0x1000000;

    .text : ALIGN(16)
    {
        *(.text .text.*)
    }

    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(16)
    {
        *(.data .data.*)
    }

    . = ALIGN(16);
    .bss (NOLOAD) : ALIGN(16)
    {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    }

    /DISCARD/ :
    {
        *(.eh_frame)
        *(.comment)
        *(.note*)
    }
}
