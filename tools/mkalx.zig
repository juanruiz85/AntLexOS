//! AntLex OS — tools/mkalx.zig: convierte un ELF freestanding x86_64
//! (enlazado en 16 MiB, ver apps/app.ld) en un ejecutable `.ALX` de la
//! Fase 7: cabecera propia de 64 bytes + imagen plana.
//!
//! Uso: mkalx <elf_entrada> <nombre_app> <alx_salida>
//!
//! El punto de entrada sale de e_entry del ELF (build.zig lo fija al
//! símbolo `alx_evento`), así que no hace falta tocar el symtab.

const std = @import("std");
const alx_def = @import("alx_def");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 4) {
        std.debug.print("uso: mkalx <elf_entrada> <nombre_app> <alx_salida>\n", .{});
        return error.Uso;
    }
    const elf_bytes = try std.fs.cwd().readFileAlloc(arena, args[1], 16 * 1024 * 1024);
    const nombre = args[2];

    var out = try arena.alloc(u8, alx_def.CABECERA + alx_def.MAX_IMAGEN);
    const escritos = try desdeElf(elf_bytes, nombre, out);
    try std.fs.cwd().writeFile(.{ .sub_path = args[3], .data = out[0..escritos] });
    std.debug.print("mkalx: {s} → {s} ({d} bytes, imagen {d})\n", .{
        args[1], args[3], escritos, escritos - alx_def.CABECERA,
    });
}

pub const Error = error{
    NoEsElf64,
    NoEsEjecutable,
    BaseIncorrecta,
    SinSegmentos,
    EntryFueraDeImagen,
    ImagenGrande,
    SalidaCorta,
};

/// Convierte `bytes` (ELF) en un .ALX escrito en `out` (devuelve su longitud).
/// El nombre se copia a la cabecera (máx. 16, se trunca).
pub fn desdeElf(bytes: []const u8, nombre: []const u8, out: []u8) Error!usize {
    if (bytes.len < 64) return Error.NoEsElf64;
    // std.elf exige puntero alineado: copiamos la cabecera a búfer propio
    var ehdr_buf: [64]u8 align(8) = undefined;
    @memcpy(&ehdr_buf, bytes[0..64]);
    const hdr = std.elf.Header.parse(&ehdr_buf) catch return Error.NoEsElf64;
    if (hdr.machine != .X86_64) return Error.NoEsElf64;
    if (hdr.type != .EXEC) return Error.NoEsEjecutable;

    // recorrer los segmentos PT_LOAD: imagen = su contenido colgado de BASE
    const fbs = std.io.fixedBufferStream(bytes);
    var it = hdr.program_header_iterator(fbs);
    var imagen_fin: u32 = 0; // fin de bytes con contenido (vaddr-BASE)
    var mem_fin: u32 = 0; // fin de memoria (incluye bss)
    var primero = true;
    var imagen = out[alx_def.CABECERA..];
    while (true) {
        const ph = it.next() catch return Error.NoEsElf64;
        const p = ph orelse break;
        if (p.p_type != std.elf.PT_LOAD) continue;
        if (primero) {
            // el primer segmento debe empezar exactamente en ALX_BASE
            if (p.p_vaddr != alx_def.ALX_BASE) return Error.BaseIncorrecta;
            primero = false;
        }
        if (p.p_vaddr < alx_def.ALX_BASE) return Error.BaseIncorrecta;
        const ini: u32 = @intCast(p.p_vaddr - alx_def.ALX_BASE);
        const fin: u32 = ini + @as(u32, @intCast(p.p_filesz));
        const fin_mem: u32 = ini + @as(u32, @intCast(p.p_memsz));
        if (fin > imagen.len) return Error.ImagenGrande;
        if (fin > imagen_fin) imagen_fin = fin;
        if (fin_mem > mem_fin) mem_fin = fin_mem;
        if (p.p_offset + p.p_filesz > bytes.len) return Error.NoEsElf64;
        @memcpy(imagen[ini..fin], bytes[@intCast(p.p_offset)..][0..@intCast(p.p_filesz)]);
    }
    if (primero) return Error.SinSegmentos;

    // punto de entrada: e_entry (build.zig lo fija a alx_evento)
    const entry: u32 = @intCast(hdr.entry -| alx_def.ALX_BASE);
    if (hdr.entry < alx_def.ALX_BASE or entry >= imagen_fin) return Error.EntryFueraDeImagen;

    // bss: lo que ocupa en memoria más allá del contenido del archivo
    const bss_len: u32 = mem_fin -| imagen_fin;

    // cabecera
    var cab = alx_def.Cabecera{
        .magic = alx_def.MAGIC,
        .version = alx_def.VERSION,
        .flags = 0,
        .bss_len = bss_len,
        .entry_off = entry,
        .image_len = imagen_fin,
        .nombre = .{0} ** alx_def.TAM_NOMBRE,
        ._reservado = .{0} ** 28,
    };
    const l = @min(nombre.len, alx_def.TAM_NOMBRE);
    for (nombre[0..l], 0..) |c, i| cab.nombre[i] = std.ascii.toUpper(c);
    const total = alx_def.CABECERA + imagen_fin;
    if (out.len < total) return Error.SalidaCorta;
    @memset(out[0..alx_def.CABECERA], 0);
    const cab_bytes: []const u8 = std.mem.asBytes(&cab);
    @memcpy(out[0..alx_def.CABECERA], cab_bytes);
    return total;
}

// ---------------------------------------------------------------------------
// Pruebas (host): un ELF64 sintético mínimo con un PT_LOAD y e_entry
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Construye un ELF64 x86_64 EXEC mínimo: 1 PT_LOAD en 16 MiB con
/// `codigo` (y `bss` extra de memoria), e_entry = BASE + entry_off.
fn elfSintetico(codigo: []const u8, bss: u32, entry_off: u32, buf: []align(8) u8) []const u8 {
    const Ehdr = extern struct {
        ident: [16]u8,
        e_type: u16,
        e_machine: u16,
        e_version: u32,
        e_entry: u64,
        e_phoff: u64,
        e_shoff: u64,
        e_flags: u32,
        e_ehsize: u16,
        e_phentsize: u16,
        e_phnum: u16,
        e_shentsize: u16,
        e_shnum: u16,
        e_shstrndx: u16,
    };
    const Phdr = extern struct {
        p_type: u32,
        p_flags: u32,
        p_offset: u64,
        p_vaddr: u64,
        p_paddr: u64,
        p_filesz: u64,
        p_memsz: u64,
        p_align: u64,
    };
    comptime {
        if (@sizeOf(Ehdr) != 64 or @sizeOf(Phdr) != 56) @compileError("layout ELF64");
    }
    @memset(buf, 0);
    const off_ph: u32 = 64;
    const off_img: u32 = 64 + 56;

    const eh: *Ehdr = @ptrCast(buf);
    eh.ident = .{ 0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    eh.e_type = 2; // EXEC
    eh.e_machine = 0x3E; // x86_64
    eh.e_version = 1;
    eh.e_entry = alx_def.ALX_BASE + entry_off;
    eh.e_phoff = off_ph;
    eh.e_shoff = 0;
    eh.e_ehsize = 64;
    eh.e_phentsize = 56;
    eh.e_phnum = 1;

    const ph: *Phdr = @ptrCast(@alignCast(buf[off_ph..].ptr));
    ph.p_type = 1; // PT_LOAD
    ph.p_flags = 5; // R+X
    ph.p_offset = off_img;
    ph.p_vaddr = alx_def.ALX_BASE;
    ph.p_paddr = alx_def.ALX_BASE;
    ph.p_filesz = codigo.len;
    ph.p_memsz = codigo.len + bss;
    ph.p_align = 0x1000;

    @memcpy(buf[off_img..][0..codigo.len], codigo);
    return buf[0 .. off_img + codigo.len];
}

test "mkalx: convierte un ELF sintético en .ALX válido" {
    var buf_elf: [512]u8 align(8) = undefined;
    var out: [alx_def.CABECERA + 4096]u8 align(8) = undefined;

    const codigo = "\x55\x48\x89\xe5\x90\x90\xc3" ++ "DATOS123";
    const elf = elfSintetico(codigo, 64, 8, &buf_elf); // entry en el byte 8
    const n = try desdeElf(elf, "calc", &out);
    try testing.expectEqual(alx_def.CABECERA + codigo.len, n);

    const cab: *const alx_def.Cabecera = @ptrCast(&out);
    try alx_def.validar(cab, @intCast(n));
    try testing.expectEqual(@as(u32, codigo.len), cab.image_len);
    try testing.expectEqual(@as(u32, 8), cab.entry_off);
    try testing.expectEqual(@as(u32, 64), cab.bss_len);
    try testing.expectEqualStrings("CALC", cab.nombre[0..4]);
    // la imagen va tras la cabecera, tal cual el contenido del segmento
    try testing.expectEqualSlices(u8, codigo, out[alx_def.CABECERA..][0..codigo.len]);
}

test "mkalx: rechaza ELFs inválidos" {
    var buf_elf: [512]u8 align(8) = undefined;
    var out: [alx_def.CABECERA + 4096]u8 align(8) = undefined;

    // entry fuera de la imagen
    const elf = elfSintetico("abc", 0, 99, &buf_elf);
    try testing.expectError(Error.EntryFueraDeImagen, desdeElf(elf, "x", &out));
    // basura (no es ELF)
    try testing.expectError(Error.NoEsElf64, desdeElf("no es un elf", "x", &out));
}
