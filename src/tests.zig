//! AntLex OS — pruebas unitarias que corren en el host (zig build test).
//! Cubren las partes puras del kernel: tablas de teclado, boot_info,
//! fuente bitmap y asignador de memoria.

const std = @import("std");
const teclado = @import("kernel/teclado.zig");
const bi = @import("kernel/boot_info.zig");
const fuente = @import("kernel/fuente.zig");
const datos = @import("kernel/fuente_datos.zig");
const mem = @import("kernel/mem.zig");

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
