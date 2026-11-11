//! AntLex OS — tools/genfont.zig (herramienta de compilación, corre en host)
//! Genera src/kernel/fuente_datos.zig a partir de un archivo unifont.hex.
//!
//! Uso:  zig run tools/genfont.zig -- assets/unifont.hex [--subconjunto assets/unifont_subconjunto.hex]
//!
//! La fuente base es GNU Unifont (GPL-2+ con excepción de embebido de fuentes,
//! u OFL según la versión), lo que permite usar sus glifos en AntLex OS.
//! El subconjunto generado se commitea para que las compilaciones sean
//! reproducibles sin descargar unifont completo.

const std = @import("std");

/// Codepoints extra además de ASCII 32..126 (¡ ¿ ª º ° · acentos ñ ç Ñ Ç
/// acentuadas mayúsculas, caja para paneles y flechas de texto).
const EXTRAS = [_]u21{
    0xA1, 0xBF, // ¡ ¿
    0xAA, 0xBA, 0xB0, 0xB7, // ª º ° ·
    0xE1, 0xE9, 0xED, 0xF3, 0xFA, 0xFC, 0xF1, 0xE7, // á é í ó ú ü ñ ç
    0xC1, 0xC9, 0xCD, 0xD3, 0xDA, 0xDC, 0xD1, 0xC7, // Á É Í Ó Ú Ü Ñ Ç
    0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, // ─ │ ┌ ┐ └ ┘
    0x251C, 0x2524, 0x252C, 0x2534, 0x253C, // ├ ┤ ┬ ┴ ┼
    0x2588, 0x2592, // █ ▒
    0x25BA, 0x25C4, // ► ◄
    0x2022, // •
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 2) {
        std.debug.print("uso: genfont.zig <unifont.hex> [--subconjunto salida.hex]\n", .{});
        return error.Uso;
    }
    const ruta_hex = args[1];
    var ruta_sub: ?[]const u8 = null;
    if (args.len >= 4 and std.mem.eql(u8, args[2], "--subconjunto")) {
        ruta_sub = args[3];
    }

    const contenido = try std.fs.cwd().readFileAlloc(arena, ruta_hex, 64 * 1024 * 1024);

    // construir el mapa de codepoints deseados
    var glifos = std.ArrayList([16]u8).init(arena);
    var extras = std.ArrayList(struct { cp: u21, idx: u16 }).init(arena);
    var n_ascii: usize = 0;

    var buscados = std.AutoHashMap(u21, void).init(arena);

    // ASCII 32..126 primero (contiguos, índice = cp - 32)
    var faltan = std.ArrayList(u21).init(arena);

    for (EXTRAS) |cp| try buscados.put(cp, {});

    var lineas = std.mem.tokenizeScalar(u8, contenido, '\n');
    while (lineas.next()) |linea| {
        if (linea.len < 6) continue;
        const dos_puntos = std.mem.indexOfScalar(u8, linea, ':') orelse continue;
        const cp = std.fmt.parseInt(u21, linea[0..dos_puntos], 16) catch continue;
        const es_ascii = cp >= 32 and cp <= 126;
        const es_extra = buscados.contains(cp);
        if (!es_ascii and !es_extra) continue;
        if (es_ascii and (n_ascii >= 95 or cp != 32 + n_ascii)) continue; // esperar ordenado

        const hexdata = std.mem.trim(u8, linea[dos_puntos + 1 ..], " \r\t");
        var glifo: [16]u8 = undefined;
        if (hexdata.len == 32) {
            // semiancho: 16 filas x 1 byte (8 px)
            for (0..16) |fila| {
                glifo[fila] = std.fmt.parseInt(u8, hexdata[fila * 2 .. fila * 2 + 2], 16) catch 0;
            }
        } else if (hexdata.len == 64) {
            // ancho completo: nos quedamos con la mitad izquierda (8 px)
            for (0..16) |fila| {
                glifo[fila] = std.fmt.parseInt(u8, hexdata[fila * 4 .. fila * 4 + 2], 16) catch 0;
            }
        } else {
            continue;
        }

        if (es_ascii) {
            try glifos.append(glifo);
            n_ascii += 1;
        } else {
            try extras.append(.{ .cp = cp, .idx = @intCast(glifos.items.len) });
            try glifos.append(glifo);
            _ = buscados.remove(cp);
        }
    }

    // verificar faltantes
    var it = buscados.keyIterator();
    while (it.next()) |cp| try faltan.append(cp.*);
    if (n_ascii != 95) {
        std.debug.print("ERROR: ASCII incompleto ({d}/95)\n", .{n_ascii});
        return error.ASCIIFaltante;
    }
    if (faltan.items.len > 0) {
        std.debug.print("ERROR: codepoints extra sin glifo en unifont: ", .{});
        for (faltan.items) |cp| std.debug.print("U+{X:0>4} ", .{cp});
        std.debug.print("\n", .{});
        return error.GlifoFaltante;
    }

    // ordenar extras por cp para búsqueda determinista
    const Extra = @TypeOf(extras.items[0]);
    std.mem.sort(Extra, extras.items, {}, struct {
        fn menor(_: void, a: Extra, b: Extra) bool {
            return a.cp < b.cp;
        }
    }.menor);

    // -------- escribir fuente_datos.zig --------
    var salida = std.ArrayList(u8).init(arena);
    const w = salida.writer();
    try w.print("// GENERADO por tools/genfont.zig desde GNU Unifont — NO EDITAR A MANO\n", .{});
    try w.print("// Codepoints: ASCII 32..126 + {d} extras (latinos + caja)\n\n", .{extras.items.len});
    try w.print("pub const GLIFOS = [{}]([16]u8){{\n", .{glifos.items.len});
    for (glifos.items) |g| {
        try w.writeAll("    .{ ");
        for (g) |b| try w.print("0x{X:0>2}, ", .{b});
        try w.writeAll("},\n");
    }
    try w.writeAll("};\n\n");
    try w.print("pub const Extra = struct {{ cp: u21, idx: u16 }};\n", .{});
    try w.print("pub const EXTRAS = [_]Extra{{\n", .{});
    for (extras.items) |e| {
        try w.print("    .{{ .cp = 0x{X}, .idx = {} }},\n", .{ e.cp, e.idx });
    }
    try w.writeAll("};\n");

    try std.fs.cwd().writeFile(.{ .sub_path = "src/kernel/fuente_datos.zig", .data = salida.items });
    std.debug.print("fuente_datos.zig: {d} glifos ({d} ASCII + {d} extras)\n", .{ glifos.items.len, 95, extras.items.len });

    // -------- subconjunto .hex --------
    if (ruta_sub) |rs| {
        var sub = std.ArrayList(u8).init(arena);
        const sw = sub.writer();
        for (glifos.items, 0..) |g, i| {
            var cp: u21 = 32 + @as(u21, @intCast(i));
            for (extras.items) |e| {
                if (e.idx == i) cp = e.cp;
            }
            try sw.print("{X:0>4}:", .{cp});
            for (g) |b| try sw.print("{X:0>2}", .{b});
            try sw.writeByte('\n');
        }
        try std.fs.cwd().writeFile(.{ .sub_path = rs, .data = sub.items });
        std.debug.print("subconjunto: {s}\n", .{rs});
    }
}
