//! AntLex OS — pruebas unitarias que corren en el host (zig build test).
//! Cubren las partes puras del kernel: tablas de teclado, boot_info,
//! fuente bitmap, asignador de memoria y sistema de archivos ALFS.

const std = @import("std");
const teclado = @import("kernel/teclado.zig");
const bi = @import("kernel/boot_info.zig");
const fuente = @import("kernel/fuente.zig");
const datos = @import("kernel/fuente_datos.zig");
const mem = @import("kernel/mem.zig");
const reloj = @import("kernel/reloj.zig");
const alfs_formato = @import("kernel/alfs_formato.zig");
const alfs_volumen = @import("kernel/alfs_volumen.zig");
const nucleo = @import("kernel/antlex/nucleo.zig");
const pesos = @import("kernel/antlex/pesos.zig");
const corpus = @import("kernel/antlex/corpus.zig");
const raton = @import("kernel/raton.zig");
const apps = @import("kernel/apps.zig");

test "alfs: ejecuta las pruebas del formato y del volumen" {
    // referenciar los módulos obliga a compilar sus bloques test
    _ = alfs_formato;
    _ = alfs_volumen;
}

test "reloj: ejecuta las pruebas del RTC (Zeller y formatos)" {
    _ = reloj;
}

// ---------------------------------------------------------------------------
// IA AntLex (Fase 4)
// ---------------------------------------------------------------------------

test "antlex: ejecuta las pruebas del nucleo (normalización, tokens, exp)" {
    // referenciar el módulo obliga a compilar sus bloques test
    _ = nucleo;
}

fn clasificarEjemplo(texto: []const u8) nucleo.Resultado {
    var nbuf: [nucleo.MAX_NORMALIZADO]u8 = undefined;
    var toks: [nucleo.MAX_TOKENS][]const u8 = undefined;
    const norm = nucleo.normalizar(texto, &nbuf);
    const n = nucleo.tokenizar(norm, &toks);
    return nucleo.clasificar(&pesos.PESOS, toks[0..n]);
}

fn indiceIntencion(nombre: []const u8) usize {
    for (pesos.INTENCIONES, 0..) |v, i| {
        if (std.mem.eql(u8, v, nombre)) return i;
    }
    unreachable; // el corpus y los pesos deben coincidir
}

test "antlex: pesos embebidos clasifican el corpus completo" {
    // con la MISMA inferencia de punto fijo que corre en el kernel
    var fallos: usize = 0;
    for (corpus.EJEMPLOS) |ej| {
        const r = clasificarEjemplo(ej.texto);
        if (!r.aceptada or r.intencion != indiceIntencion(ej.intencion)) fallos += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), fallos);
}

test "antlex: canon 12/12 (10 intenciones + 2 rechazos)" {
    var aciertos: usize = 0;
    for (nucleo.CANON) |c| {
        const r = clasificarEjemplo(c.pregunta);
        const ok = if (c.esperada) |esp|
            (r.aceptada and std.mem.eql(u8, pesos.INTENCIONES[r.intencion], esp))
        else
            !r.aceptada;
        if (ok) aciertos += 1;
    }
    try std.testing.expectEqual(nucleo.CANON.len, aciertos);
}

test "antlex: adversariales rechazados (no habla de temas ajenos)" {
    for (corpus.ADVERSARIALES) |a| {
        const r = clasificarEjemplo(a);
        try std.testing.expectEqual(false, r.aceptada);
    }
}

test "antlex: coherencia de los pesos generados" {
    try std.testing.expectEqual(pesos.VOCAB.len * nucleo.OCULTAS, pesos.W1.len);
    try std.testing.expectEqual(nucleo.OCULTAS, pesos.B1.len);
    try std.testing.expectEqual(nucleo.OCULTAS * pesos.INTENCIONES.len, pesos.W2.len);
    try std.testing.expectEqual(pesos.INTENCIONES.len, pesos.B2.len);
    try std.testing.expect(pesos.INTENCIONES.len <= nucleo.MAX_INTENCIONES);
    // las dimensiones de la red son las que el kernel asume
    try std.testing.expectEqual(@as(usize, 16), nucleo.OCULTAS);
}

test "boot_info mide 80 bytes (76 campos + relleno)" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(bi.BootInfo));
}

test "teclado ES: ñ, ¡, ¿ y símbolos de números" {
    try std.testing.expectEqual(@as(u8, 0xF1), teclado.TABLA_ES[0x27]); // ñ
    try std.testing.expectEqual(@as(u8, 0xD1), teclado.TABLA_ES[0x27 + 128]); // Ñ
    try std.testing.expectEqual(@as(u8, 0xA1), teclado.TABLA_ES[0x0D]); // ¡
    try std.testing.expectEqual(@as(u8, 0xBF), teclado.TABLA_ES[0x0D + 128]); // ¿
    try std.testing.expectEqual(@as(u8, '!'), teclado.TABLA_ES[0x02 + 128]);
    try std.testing.expectEqual(@as(u8, '\''), teclado.TABLA_ES[0x0C]);
}

test "teclado US: corchetes y punto y coma" {
    try std.testing.expectEqual(@as(u8, '['), teclado.TABLA_US[0x1A]);
    try std.testing.expectEqual(@as(u8, ';'), teclado.TABLA_US[0x27]);
}

test "teclado: teclas muertas generan vocales acentuadas" {
    teclado.pruebaFijarMuerta(.agudo);
    try std.testing.expectEqual(@as(u8, 0xE1), teclado.aplicarMuerta('a')); // á
    teclado.pruebaFijarMuerta(.diere);
    try std.testing.expectEqual(@as(u8, 0xFC), teclado.aplicarMuerta('u')); // ü
    teclado.pruebaFijarMuerta(.grave);
    try std.testing.expectEqual(@as(u8, 'x'), teclado.aplicarMuerta('x')); // no vocal
}

test "fuente: índices ASCII y extras" {
    try std.testing.expectEqual(@as(u16, 33), fuente.indice('A').?); // 'A' - 32
    try std.testing.expect(fuente.indice(0xF1) != null); // ñ
    try std.testing.expect(fuente.indice(0xE1) != null); // á
    try std.testing.expect(fuente.indice(0x2500) != null); // ─
    try std.testing.expect(fuente.indice(0x2022) != null); // •
    try std.testing.expect(fuente.indice(0x263A) == null); //☺ sin glifo: null
    // el glifo de 'A' tiene píxeles encendidos
    var encendidos: u16 = 0;
    for (datos.GLIFOS[fuente.indice('A').?]) |fila| encendidos += @popCount(fila);
    try std.testing.expect(encendidos > 8);
}

test "regionHeap elige la mayor región usable" {
    var entradas = [_]bi.EntradaMem{
        .{ .base = 0, .long = 0x100000, .tipo = 1, .acpi = 1 }, // primer MiB
        .{ .base = 0x100000, .long = 0x2000000, .tipo = 1, .acpi = 1 }, // 32 MiB
        .{ .base = 0x2100000, .long = 0x8000000, .tipo = 1, .acpi = 1 }, // 128 MiB
        .{ .base = 0x1000, .long = 0x800, .tipo = 2, .acpi = 0 }, // reservada
    };
    const info = bi.BootInfo{
        .magic = 0x42584C41,
        .version = 1,
        .flags = 0,
        .reserved = 0,
        .fb_addr = 0xFD000000,
        .fb_w = 1024,
        .fb_h = 768,
        .fb_pitch = 4096,
        .fb_bpp = 32,
        .memmap_ptr = @intFromPtr(&entradas),
        .memmap_count = 4,
        .pad = 0,
        .alfs_ptr = 0,
        .alfs_size = 0,
        .sector_size = 512,
        .boot_drive = 0x80,
    };
    try std.testing.expectEqual(@as(u64, 0x8000000 + 0x2100000), bi.memoriaTotal(&info));
    const r = bi.regionHeap(&info, 32 * 1024 * 1024).?;
    // la mayor región usable desde 32 MiB: la de 128 MiB (empieza en 33 MiB)
    try std.testing.expectEqual(@as(u64, 0x2100000), r.base);
    try std.testing.expectEqual(@as(u64, 0x8000000), r.long);
}

test "mem: asignador secuencial alineado" {
    // sin init falla
    try std.testing.expectError(mem.Error.SinMemoria, mem.alloc(8, 8));
}

// ---------------------------------------------------------------------------
// Escritorio (Fase 5): ratón y aplicaciones
// ---------------------------------------------------------------------------

test "raton: ejecuta las pruebas del driver (paquetes y acotado)" {
    _ = raton;
}

test "apps: ejecuta las pruebas del editor y el explorador" {
    _ = apps;
}

test "apps: editor serializa exactamente lo cargado" {
    var e = apps.Editor{};
    const poema = "AntLex OS v0.5.0\ncon escritorio, ventanas\ny raton PS/2.";
    apps.editorCargar(&e, poema);
    var buf: [256]u8 = undefined;
    const n = apps.editorSerializar(&e, &buf);
    try std.testing.expectEqualStrings(poema, buf[0..n]);
    try std.testing.expect(!e.modificado);
}
