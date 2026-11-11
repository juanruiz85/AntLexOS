//! AntLex OS — tools/mkimage.zig (herramienta de compilación, corre en host)
//! Construye antlexos.img a partir del kernel ELF, stage1 (MBR) y stage2.
//!
//! Uso:
//!   mkimage.zig <kernel.elf> <stage1.bin> <stage2.bin> <salida.img>
//!               <kernel_off> <fat_off> <alfs_off> <disk_size>
//!               <kernel_max> <kernel_load_addr>
//!
//! Layout del disco (offsets en bytes, ver layout.zig):
//!   0          MBR (stage1) + tabla de particiones
//!   512        stage2
//!   fat_off    partición 1: FAT16 (EFI)          — se rellena en la Fase 1b
//!   kernel_off partición 2: cabecera + kernel
//!   alfs_off   partición 3: volumen ALFS         — se rellena en la Fase 2

const std = @import("std");

const Ehdr = extern struct {
    ident: [16]u8,
    tipo: u16,
    maquina: u16,
    version: u32,
    entrada: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const Phdr = extern struct {
    tipo: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    alineacion: u64,
};

const PT_LOAD = 1;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 11) {
        std.debug.print("uso: mkimage.zig <kernel.elf> <stage1.bin> <stage2.bin> <salida.img> <kernel_off> <fat_off> <alfs_off> <disk_size> <kernel_max> <kernel_load_addr>\n", .{});
        return error.Uso;
    }

    const ruta_elf = args[1];
    const ruta_s1 = args[2];
    const ruta_s2 = args[3];
    const ruta_out = args[4];
    const kernel_off = try std.fmt.parseInt(u64, args[5], 10);
    const fat_off = try std.fmt.parseInt(u64, args[6], 10);
    const alfs_off = try std.fmt.parseInt(u64, args[7], 10);
    const disk_size = try std.fmt.parseInt(u64, args[8], 10);
    const kernel_max = try std.fmt.parseInt(u64, args[9], 10);
    const load_addr = try std.fmt.parseInt(u64, args[10], 10);

    // ---------------- leer el ELF del kernel ----------------
    const elf = try std.fs.cwd().readFileAlloc(arena, ruta_elf, 32 * 1024 * 1024);
    if (elf.len < @sizeOf(Ehdr)) return error.ElfCorto;
    const ehdr: *const Ehdr = @alignCast(@ptrCast(elf.ptr));
    if (!std.mem.eql(u8, ehdr.ident[0..4], "\x7fELF")) return error.ElfInvalido;
    if (ehdr.ident[4] != 2) return error.ElfNo64; // ELF64
    if (ehdr.ident[5] != 1) return error.ElfNoLE; // little-endian
    if (ehdr.maquina != 0x3E) return error.ElfNoX8664;
    if (ehdr.phnum == 0 or ehdr.phentsize != @sizeOf(Phdr)) return error.ElfSinPhdr;
    // validación de límites: la tabla de segmentos debe caber en el archivo
    if (ehdr.phoff > elf.len or
        @as(u64, ehdr.phnum) * @sizeOf(Phdr) > elf.len - ehdr.phoff) return error.ElfPhFuera;
    const ph_tabla = elf[ehdr.phoff..];

    // binario plano: [load_addr, fin de todos los PT_LOAD)
    var fin_archivo: u64 = load_addr; // fin de datos presentes en archivo
    var fin_memoria: u64 = load_addr; // fin incluyendo .bss
    var bss_off: u64 = 0;
    var bss_size: u64 = 0;
    var i: usize = 0;
    while (i < ehdr.phnum) : (i += 1) {
        const ph: *const Phdr = @alignCast(@ptrCast(ph_tabla.ptr + i * @sizeOf(Phdr)));
        if (ph.tipo != PT_LOAD) continue;
        if (ph.offset > elf.len or ph.filesz > elf.len - ph.offset) return error.ElfSegmentoFuera;
        if (ph.vaddr < load_addr) return error.VaddrBajo;
        if (ph.vaddr + ph.memsz > fin_memoria) fin_memoria = ph.vaddr + ph.memsz;
        if (ph.vaddr + ph.filesz > fin_archivo) fin_archivo = ph.vaddr + ph.filesz;
        if (ph.memsz > ph.filesz) {
            bss_off = ph.vaddr - load_addr + ph.filesz;
            bss_size = ph.memsz - ph.filesz;
        }
    }
    const tam_binario: u64 = fin_archivo - load_addr;
    if (tam_binario == 0) return error.KernelVacio;
    if (tam_binario > kernel_max) {
        std.debug.print("ERROR: kernel de {d} bytes supera el límite del cargador ({d})\n", .{ tam_binario, kernel_max });
        return error.KernelGrande;
    }
    // El linker script garantiza que .text.boot (kentry) es lo primero:
    // entry_off = 0. e_entry solo se usa como verificación informativa.
    var entry_off: u64 = 0;
    if (ehdr.entrada >= load_addr and ehdr.entrada - load_addr <= 0x10000) {
        entry_off = ehdr.entrada - load_addr;
    } else {
        std.debug.print("aviso: e_entry={d} fuera de rango; usando entry_off=0 (.text.boot primero)\n", .{ehdr.entrada});
    }

    // ---------------- montar la imagen ----------------
    const disco = try arena.alloc(u8, @intCast(disk_size));
    @memset(disco, 0);

    const s1 = try std.fs.cwd().readFileAlloc(arena, ruta_s1, 1024 * 1024);
    const s2 = try std.fs.cwd().readFileAlloc(arena, ruta_s2, 1024 * 1024);
    if (s1.len != 512) return error.MBRNo512;
    if (s1[510] != 0x55 or s1[511] != 0xAA) return error.MBRSinFirma;
    // stage2 debe dejar libre la zona 0xA000..0xB0FF que usa stage2 para los
    // búferes VESA (VESA_INFO=0xA000, MODE_INFO=0xB000)
    if (s2.len > 0x2000 - 0x100) return error.Stage2Grande;
    if (s2.len > 32 * 512) return error.Stage2Grande; // y lo que carga stage1 (32 sectores)

    @memcpy(disco[0..512], s1);
    @memcpy(disco[512 .. 512 + s2.len], s2);

    // tabla de particiones (offset 446): P1 FAT16 (arrancable), P2 kernel, P3 ALFS
    const sect = disk_size / 512;
    escribirParticion(disco, 0, true, 0x06, fat_off / 512, (kernel_off - fat_off) / 512);
    escribirParticion(disco, 1, false, 0xDA, kernel_off / 512, (alfs_off - kernel_off) / 512);
    escribirParticion(disco, 2, false, 0xDA, alfs_off / 512, sect - alfs_off / 512);
    disco[510] = 0x55;
    disco[511] = 0xAA;

    // cabecera + kernel en la partición 2
    const kbase: usize = @intCast(kernel_off);
    disco[kbase + 0] = 'A';
    disco[kbase + 1] = 'L';
    disco[kbase + 2] = 'K';
    disco[kbase + 3] = 'R';
    disco[kbase + 4] = 1; // hdr_version
    disco[kbase + 6] = 0; // flags
    escribirU32(disco[kbase + 8 ..], @intCast(entry_off)); // entry_off
    escribirU32(disco[kbase + 12 ..], @intCast(bss_off));
    escribirU32(disco[kbase + 16 ..], @intCast(bss_size));
    escribirU32(disco[kbase + 20 ..], @intCast(tam_binario));

    // copiar los PT_LOAD al binario plano
    i = 0;
    while (i < ehdr.phnum) : (i += 1) {
        const ph: *const Phdr = @alignCast(@ptrCast(ph_tabla.ptr + i * @sizeOf(Phdr)));
        if (ph.tipo != PT_LOAD) continue;
        const dst: usize = @intCast(kbase + 512 + (ph.vaddr - load_addr));
        const src: usize = @intCast(ph.offset);
        @memcpy(disco[dst .. dst + @as(usize, @intCast(ph.filesz))], elf[src .. src + @as(usize, @intCast(ph.filesz))]);
    }
    const crc = std.hash.Crc32.hash(disco[kbase + 512 .. kbase + 512 + @as(usize, @intCast(tam_binario))]);
    escribirU32(disco[kbase + 24 ..], crc);

    try std.fs.cwd().writeFile(.{ .sub_path = ruta_out, .data = disco });

    std.debug.print(
        "antlexos.img listo ({d} MiB)\n" ++
            "  kernel: {d} bytes (entrada +{d}, bss {d}@+{d}, crc32 {X:0>8})\n" ++
            "  stage2: {d} bytes | particiones: P1 FAT16@{d} P2 kernel@{d} P3 ALFS@{d}\n",
        .{ disk_size / (1024 * 1024), tam_binario, ehdr.entrada - load_addr, bss_size, bss_off, crc, s2.len, fat_off, kernel_off, alfs_off },
    );
}

fn escribirParticion(disco: []u8, indice: usize, activa: bool, tipo: u8, lba: u64, sectores: u64) void {
    const p = disco[446 + indice * 16 ..][0..16];
    p[0] = if (activa) 0x80 else 0x00;
    p[1] = 0xFE;
    p[2] = 0xFF;
    p[3] = 0xFF; // CHS inutilizado (LBA puro)
    p[4] = tipo;
    p[5] = 0xFE;
    p[6] = 0xFF;
    p[7] = 0xFF;
    escribirU32(p[8..12], @intCast(lba));
    escribirU32(p[12..16], @intCast(sectores));
}

fn escribirU32(dst: []u8, valor: u32) void {
    dst[0] = @truncate(valor);
    dst[1] = @truncate(valor >> 8);
    dst[2] = @truncate(valor >> 16);
    dst[3] = @truncate(valor >> 24);
}
