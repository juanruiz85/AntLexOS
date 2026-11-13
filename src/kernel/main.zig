//! AntLex OS — punto de entrada del kernel (x86_64).
//! Recibe en RDI el puntero a boot_info procedente de stage2 (BIOS) o del
//! bootloader EFI (UEFI).

const std = @import("std"); // solo tipos builtin y el manejador de pánico

const bi_mod = @import("boot_info.zig");
const serial = @import("serial.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");
const pit = @import("pit.zig");
const teclado = @import("teclado.zig");
const pantalla = @import("pantalla.zig");
const consola = @import("consola.zig");
const fuente = @import("fuente.zig");
const mem = @import("mem.zig");
const autoprueba = @import("autoprueba.zig");
const version = @import("version.zig");
const x86 = @import("x86.zig");
const ata = @import("ata.zig");
const alfs = @import("alfs.zig");
const interprete = @import("interprete.zig");
const antlex = @import("antlex.zig");

// pila propia del kernel: 64 KiB en .bss
var pila: [64 * 1024]u8 align(16) linksection(".bss") = undefined;

pub fn panic(mensaje: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    serial.puts("\n=== PANICO DEL KERNEL ===\n");
    serial.puts(mensaje);
    serial.puts("\nSistema detenido.\n");
    x86.cli();
    while (true) x86.hlt();
}

export fn kentry() linksection(".text.boot") callconv(.Naked) noreturn {
    asm volatile (
        \\ .code64
        \\ movq %[tope], %%rsp
        \\ xorq %%rbp, %%rbp
        \\ callq kmain
        \\ cli
        \\1: hlt
        \\ jmp 1b
        :
        : [tope] "r" (@as(usize, @intFromPtr(&pila)) + pila.len),
    );
}

export fn kmain(boot_ptr: usize) noreturn {
    // lo primero: sin interrupciones hasta tener IDT+PIC propios (en UEFI el
    // firmware puede dejar IF=1 y su temporizador activo)
    x86.cli();
    serial.init();

    const bi = bi_mod.desde(boot_ptr) orelse {
        serial.puts("ANTLEX: boot_info invalido (magic incorrecta)\n");
        x86.cli();
        while (true) x86.hlt();
    };

    serial.puts("\nAntLex OS v");
    serial.puts(version.VERSION);
    serial.puts(" (");
    serial.puts(if (bi.flags & bi_mod.MODO_UEFI != 0) "UEFI" else "BIOS");
    serial.puts(") arrancando...\n");

    // núcleo base (trazas de depuración del arranque por serie)
    serial.puts("init: gdt\n");
    gdt.init();
    serial.puts("init: idt\n");
    idt.init();
    serial.puts("init: pic\n");
    pic.init();
    serial.puts("init: pit\n");
    pit.init();
    serial.puts("init: teclado\n");
    teclado.init();
    serial.puts("init: pantalla\n");

    // pantalla gráfica desde el arranque
    pantalla.init(bi) catch |err| {
        serial.puts("ANTLEX: sin modo grafico util (");
        serial.puts(@errorName(err));
        serial.puts(")\n");
        x86.cli();
        while (true) x86.hlt();
    };
    consola.init();
    serial.puts("init: memoria\n");

    // memoria dinámica
    if (!mem.init(bi)) {
        serial.puts("ANTLEX: sin region de heap\n");
        x86.cli();
        while (true) x86.hlt();
    }
    serial.puts("init: interrupciones\n");

    // interrupciones activas
    x86.sti();
    serial.puts("init: splash\n");

    // pantalla de bienvenida
    splash();

    // ---------------- ATA + ALFS (Fase 2) ----------------
    serial.puts("init: ata\n");
    if (ata.init()) |_| {
        serial.puts("ata: disco ");
        serial.puts(ata.modelo());
        serial.puts("\n");
    } else |err_ata| {
        serial.puts("ata: no disponible (");
        serial.puts(@errorName(err_ata));
        serial.puts(") — ALFS quedara desmontado\n");
    }

    serial.puts("init: alfs\n");
    if (alfs.montar(bi)) |info| {
        serial.puts("ALFS MONTADO v");
        serial.putDec(info.libres);
        serial.puts(" bloques libres, ");
        serial.putDec(info.archivos);
        serial.puts(" archivos, ");
        serial.putDec(info.directorios);
        serial.puts(" directorios\n");
    } else |err_alfs| {
        serial.puts("ALFS NO MONTADO (");
        serial.puts(@errorName(err_alfs));
        serial.puts(")\n");
    }

    // batería de autopruebas (serial + resumen); el splash sigue en pantalla
    autoprueba.ejecutar(bi);

    // IA embebida (Fase 4): pesos ya en .rodata; carga la memoria aprendida
    serial.puts("init: antlex\n");
    antlex.fijarBootInfo(bi);
    antlex.init();

    // ventana de captura: 1 segundo con el splash visible (para pruebas y
    // para que un humano vea el logo)
    serial.puts("SPLASH VISIBLE\n");
    pit.esperaTics(100);

    // ---------------- intérprete de comandos (consola) ----------------
    serial.puts("init: interprete\n");
    consola.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = pantalla.rgb(0x0A, 0x0E, 0x16) });
    consola.limpiar();
    consola.puts("AntLex OS v");
    consola.puts(version.VERSION);
    consola.puts(" — consola grafica\n");
    consola.puts("Escribe 'ayuda' para ver los comandos.\n\n");

    interprete.init(bi);
    interprete.bucle();
}

/// Pantalla de bienvenida gráfica (logo + versión).
fn splash() void {
    const fondo = pantalla.rgb(0x0A, 0x0E, 0x16);
    pantalla.limpiar(fondo);

    // banda superior de acento
    pantalla.rect(0, 0, pantalla.anchoPix(), 6, pantalla.rgb(0x2C, 0x63, 0xB6));

    const blanco = pantalla.rgb(0xE8, 0xF0, 0xF8);
    const azul = pantalla.rgb(0x5B, 0x9B, 0xF0);

    consola.ponerCentrado(8, "ANTLEX", blanco, 3);
    consola.ponerCentrado(14, version.ESLOGAN, azul, 1);
    consola.ponerCentrado(17, "v" ++ version.VERSION ++ "  ·  " ++ version.ARQUITECTURA ++ "  ·  Zig", blanco, 1);

    // barra de progreso simple
    const an = pantalla.anchoPix();
    const x0 = an / 2 - 200;
    const y0 = 22 * fuente.ALTO;
    pantalla.rectBorde(x0, y0, 400, 18, fondo, azul);
    pit.esperaTics(20);
    pantalla.rect(x0 + 3, y0 + 3, 130, 12, azul);
    pit.esperaTics(20);
    pantalla.rect(x0 + 3, y0 + 3, 260, 12, azul);
    pit.esperaTics(20);
    pantalla.rect(x0 + 3, y0 + 3, 394, 12, azul);
    pit.esperaTics(15);
}
