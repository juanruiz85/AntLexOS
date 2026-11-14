//! AntLex OS — tools/mkalfs.zig (herramienta de compilación, corre en host).
//! Genera el volumen ALFS inicial a partir del árbol `fsroot/` y lo inserta
//! en la imagen de disco (partición 3, offset alfs_off).
//!
//! Uso:
//!   mkalfs.zig <img_entrada> <dir_fsroot> <img_salida> <alfs_off> <alfs_size>
//!
//! El volumen se construye con las mismas operaciones `Volumen` que usa el
//! kernel (fuente única de verdad del formato: src/kernel/alfs_*.zig).

const std = @import("std");
const vol = @import("alfs_volumen");
const fmt = vol.formato; // re-exportación del módulo único alfs_volumen

/// Entrada de directorio del host para ordenar de forma determinista.
const EntradaHost = struct { nombre: []const u8, tipo: std.fs.Dir.Entry.Kind };

fn menosQue(_: void, a: EntradaHost, b: EntradaHost) bool {
    return std.mem.lessThan(u8, a.nombre, b.nombre);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 6) {
        std.debug.print(
            "uso: mkalfs.zig <img_entrada> <dir_fsroot> <img_salida> <alfs_off> <alfs_size> [--app <archivo> <nombre>]...\n",
            .{},
        );
        return error.Uso;
    }
    // apps externas .ALX (Fase 7): pares --app <archivo> <nombre>
    const AppArg = struct { ruta: []const u8, nombre: []const u8 };
    var apps_alx = std.ArrayList(AppArg).init(arena);
    var ai: usize = 6;
    while (ai < args.len) : (ai += 3) {
        if (ai + 2 >= args.len or !std.mem.eql(u8, args[ai], "--app")) {
            std.debug.print("mkalfs: uso: --app <archivo> <nombre>\n", .{});
            return error.Uso;
        }
        try apps_alx.append(.{ .ruta = args[ai + 1], .nombre = args[ai + 2] });
    }
    const ruta_in = args[1];
    const ruta_fsroot = args[2];
    const ruta_out = args[3];
    const alfs_off = try std.fmt.parseInt(u64, args[4], 10);
    const alfs_size = try std.fmt.parseInt(u64, args[5], 10);

    // imagen de entrada (del paso mkimage), leída a un búfer alineado a
    // página: las estructuras de ALFS exigen alineación de 4/8 bytes y el
    // offset de la partición debe conservarla
    const archivo = try std.fs.cwd().openFile(ruta_in, .{});
    defer archivo.close();
    const tam_img = (try archivo.stat()).size;
    const img = try std.heap.page_allocator.alloc(u8, tam_img);
    defer std.heap.page_allocator.free(img);
    const leidos = try archivo.readAll(img);
    if (leidos != tam_img) return error.LecturaCorta;
    if (alfs_off > img.len or alfs_size > img.len - alfs_off) return error.ImgCorta;

    // formatear el volumen dentro de la partición 3
    const region = img[@intCast(alfs_off)..][0..@intCast(alfs_size)];
    var v = try vol.Volumen.formatear(region, "ANTLEX");

    // recorrer fsroot/ de forma determinista (orden alfabético por nivel)
    var raiz_fs = try std.fs.cwd().openDir(ruta_fsroot, .{ .iterate = true });
    defer raiz_fs.close();
    var total_archivos: u32 = 0;
    var total_dirs: u32 = 0;
    var total_bytes: u64 = 0;
    try agregarArbol(&v, arena, &raiz_fs, fmt.RAIZ, &total_archivos, &total_dirs, &total_bytes);

    // apps externas .ALX: siempre en /APPS y con el bit de ejecutable
    if (apps_alx.items.len > 0) {
        const dir_apps = v.buscarHijo(fmt.RAIZ, "APPS") orelse
            v.crear(fmt.RAIZ, "APPS", fmt.TIPO_DIRECTORIO, "") catch |err| return err;
        for (apps_alx.items) |a| {
            const datos = try std.fs.cwd().readFileAlloc(arena, a.ruta, fmt.TAM_MAX_ARCHIVO);
            const idx = v.crear(dir_apps, a.nombre, fmt.TIPO_ARCHIVO, datos) catch |err| {
                std.debug.print("mkalfs: error creando app '{s}': {s}\n", .{ a.nombre, @errorName(err) });
                return err;
            };
            if (v.entrada(idx)) |e| e.flags |= fmt.FLAG_EJECUTABLE;
            total_archivos += 1;
            total_bytes += datos.len;
            std.debug.print("mkalfs: app instalada /APPS/{s} ({d} bytes, ejecutable)\n", .{ a.nombre, datos.len });
        }
        total_dirs += 1; // /APPS
    }

    // verificación final: el volumen debe reabrirse limpio
    _ = try vol.Volumen.abrir(region);

    // escribir la imagen final
    try std.fs.cwd().writeFile(.{ .sub_path = ruta_out, .data = img });

    std.debug.print(
        "volumen ALFS listo en offset {d}: {d} archivo(s), {d} directorio(s), {d} bytes, {d} bloques libres\n",
        .{ alfs_off, total_archivos, total_dirs, total_bytes, v.libres() },
    );
}

/// Añade el contenido de `dir` (host) como hijos de `padre` (ALFS).
fn agregarArbol(
    v: *vol.Volumen,
    arena: std.mem.Allocator,
    dir: *std.fs.Dir,
    padre: u16,
    total_archivos: *u32,
    total_dirs: *u32,
    total_bytes: *u64,
) !void {
    // recolectar entradas para ordenarlas (builds reproducibles)
    var entradas = std.ArrayList(EntradaHost).init(arena);
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file and e.kind != .directory) continue;
        try entradas.append(.{ .nombre = try arena.dupe(u8, e.name), .tipo = e.kind });
    }
    std.sort.pdq(EntradaHost, entradas.items, {}, menosQue);

    for (entradas.items) |e| {
        if (!fmt.nombreValido(e.nombre)) {
            std.debug.print("mkalfs: nombre invalido en fsroot: '{s}' (sin espacios ni '/', max 44)\n", .{e.nombre});
            return error.NombreInvalido;
        }
        switch (e.tipo) {
            .directory => {
                const idx = v.crear(padre, e.nombre, fmt.TIPO_DIRECTORIO, "") catch |err| {
                    std.debug.print("mkalfs: error creando dir '{s}': {s}\n", .{ e.nombre, @errorName(err) });
                    return err;
                };
                total_dirs.* += 1;
                var sub = try dir.openDir(e.nombre, .{ .iterate = true });
                defer sub.close();
                try agregarArbol(v, arena, &sub, idx, total_archivos, total_dirs, total_bytes);
            },
            .file => {
                const datos = try dir.readFileAlloc(arena, e.nombre, fmt.TAM_MAX_ARCHIVO);
                const idx = v.crear(padre, e.nombre, fmt.TIPO_ARCHIVO, datos) catch |err| {
                    std.debug.print("mkalfs: error creando archivo '{s}': {s}\n", .{ e.nombre, @errorName(err) });
                    return err;
                };
                // Fase 7: los .ALX de fsroot se instalan (bit de ejecutable)
                if (std.mem.endsWith(u8, e.nombre, ".alx") or std.mem.endsWith(u8, e.nombre, ".ALX")) {
                    if (v.entrada(idx)) |en| en.flags |= fmt.FLAG_EJECUTABLE;
                }
                total_archivos.* += 1;
                total_bytes.* += datos.len;
            },
            else => unreachable,
        }
    }
}
