//! AntLex OS — tools/mkfat.zig: construye la partición FAT16 de arranque
//! UEFI con /EFI/BOOT/BOOTX64.EFI y /LEEME.txt. Herramienta de host (std).
//!
//! Uso:
//!   mkfat.zig <salida.img> <sectores_totales> <BOOTX64.EFI> <LEEME.txt>
//!
//! Formato FAT16 clásico (el MBR de AntLex apunta aquí desde la P1):
//!   sector 0        boot sector/BPB (sin código de arranque propio)
//!   sector 1..N     FAT1
//!   N..2N           FAT2 (copia)
//!   después         directorio raíz (512 entradas) y clústeres de 2 KiB
//! Solo sirve para que el firmware UEFI encuentre BOOTX64.EFI.

const std = @import("std");

const SECTOR = 512;
const CLUSTER_SECTORES = 1; // clúster de 512 B (necesario para >4085 clusters en 8 MiB)
const ROOT_ENTRIES = 512;

const ATR_VOLUMEN: u8 = 0x08;
const ATR_DIR: u8 = 0x10;
const ATR_ARCHIVO: u8 = 0x20;

const FECHA_2026_01_01: u16 = (26 << 9) | (1 << 5) | 1;

const Entrada = struct {
    nombre: [11]u8, // 8.3 rellenado con espacios
    attr: u8,
    cluster: u16,
    tamano: u32,
};

fn nombre83(cadena: []const u8) [11]u8 {
    var n = [_]u8{' '} ** 11;
    var en_ext: bool = false;
    var j: usize = 0;
    for (cadena) |ch| {
        const c = std.ascii.toUpper(ch);
        if (c == '.') {
            en_ext = true;
            j = 8;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '$' and c != '~') continue;
        if (!en_ext and j < 8) {
            n[j] = c;
            j += 1;
        } else if (en_ext and j < 11) {
            n[j] = c;
            j += 1;
        }
    }
    return n;
}

const Escritor = struct {
    img: []u8,
    fat: []u16,
    datos_lba: u32,
    proximo: u32,
    raiz_lba: u32,

    const Error = error{SinClusters};

    /// Escribe un archivo y devuelve su primer clúster (0 si vacío).
    fn archivo(self: *Escritor, contenido: []const u8) Error!u16 {
        var previo: ?u32 = null;
        var primero: u16 = 0;
        var off: usize = 0;
        while (off < contenido.len) {
            if (self.proximo > 0xFFEF) return Error.SinClusters;
            const c: u32 = self.proximo;
            self.proximo += 1;
            const destino = @as(usize, self.datos_lba + (c - 2) * CLUSTER_SECTORES) * SECTOR;
            const trozo = @min(contenido.len - off, CLUSTER_SECTORES * SECTOR);
            @memcpy(self.img[destino .. destino + trozo], contenido[off .. off + trozo]);
            if (previo) |p| self.fat[p] = @intCast(c) else primero = @intCast(c);
            previo = c;
            off += trozo;
        }
        if (previo == null) return 0;
        self.fat[previo.?] = 0xFFFF;
        return primero;
    }

    /// Reserva un clúster para un directorio vacío y lo devuelve.
    fn directorio(self: *Escritor) Error!u16 {
        if (self.proximo > 0xFFEF) return Error.SinClusters;
        const c: u32 = self.proximo;
        self.proximo += 1;
        self.fat[c] = 0xFFFF;
        return @intCast(c);
    }

    /// Inicializa un directorio (entradas "." y "..") en su primer clúster.
    fn subdirectorio(self: *Escritor, cluster: u16, cluster_padre: u16, nombre: [11]u8) void {
        if (cluster == 0) return;
        const destino = @as(usize, self.datos_lba + (@as(usize, cluster) - 2) * CLUSTER_SECTORES) * SECTOR;
        ponerEntrada(self.img[destino..][0..32], .{ .nombre = nombre, .attr = ATR_DIR, .cluster = cluster, .tamano = 0 });
        ponerEntrada(self.img[destino + 32 ..][0..32], .{ .nombre = nombre, .attr = ATR_DIR, .cluster = cluster_padre, .tamano = 0 });
    }

    /// Añade una entrada a un directorio (busca hueco libre).
    fn anadir(self: *Escritor, cluster_dir: u16, en_raiz: bool, e: Entrada) void {
        var base: usize = undefined;
        var capacidad: usize = undefined;
        if (en_raiz) {
            base = self.raiz_lba * SECTOR;
            capacidad = ROOT_ENTRIES;
        } else if (cluster_dir == 0) {
            return;
        } else {
            base = @as(usize, self.datos_lba + (@as(usize, cluster_dir) - 2) * CLUSTER_SECTORES) * SECTOR;
            capacidad = CLUSTER_SECTORES * SECTOR / 32;
        }
        var i: usize = 0;
        while (i < capacidad) : (i += 1) {
            const pos = base + i * 32;
            if (self.img[pos] == 0 or self.img[pos] == 0xE5) {
                ponerEntrada(self.img[pos..][0..32], e);
                return;
            }
        }
    }
};

fn ponerEntrada(destino: []u8, e: Entrada) void {
    @memset(destino[0..32], 0);
    @memcpy(destino[0..11], &e.nombre);
    destino[11] = e.attr;
    escribirU16(destino[22..], FECHA_2026_01_01); // último acceso
    escribirU16(destino[26..], e.cluster);
    escribirU32(destino[28..], e.tamano);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 5) {
        std.debug.print("uso: mkfat.zig <salida.img> <sectores> <BOOTX64.EFI> <LEEME.txt>\n", .{});
        return error.Uso;
    }
    const ruta_out = args[1];
    const total_sectores = try std.fmt.parseInt(u32, args[2], 10);
    const efi = try std.fs.cwd().readFileAlloc(arena, args[3], 8 * 1024 * 1024);
    const leeme = try std.fs.cwd().readFileAlloc(arena, args[4], 1024 * 1024);
    if (efi.len == 0) return error.EfiVacio;

    // --- dimensionar la FAT (iterativo, como manda el formato) ---
    const sectores_raiz = ROOT_ENTRIES * 32 / SECTOR; // 32
    var fat_sectores: u32 = 1;
    var clusters: u32 = 0;
    while (fat_sectores < total_sectores) : (fat_sectores += 1) {
        const datos = total_sectores -| (1 + 2 * fat_sectores + sectores_raiz);
        clusters = datos / CLUSTER_SECTORES;
        if (fat_sectores * SECTOR / 2 >= clusters + 2) break;
    }
    if (clusters < 4085 or clusters > 65524) {
        std.debug.print("ERROR: geometría no válida para FAT16 ({d} clusters)\n", .{clusters});
        return error.GeometriaInvalida;
    }
    const fat1_lba: u32 = 1;
    const fat2_lba: u32 = fat1_lba + fat_sectores;
    const raiz_lba: u32 = fat2_lba + fat_sectores;
    const datos_lba: u32 = raiz_lba + sectores_raiz;

    const img = try arena.alloc(u8, total_sectores * SECTOR);
    @memset(img, 0);

    // --- boot sector / BPB ---
    img[0] = 0xEB;
    img[1] = 0x3C;
    img[2] = 0x90;
    @memcpy(img[3..11], "ANTLEX  ");
    escribirU16(img[11..], SECTOR);
    img[13] = CLUSTER_SECTORES;
    escribirU16(img[14..], 1); // sectores reservados
    img[16] = 2; // dos FAT
    escribirU16(img[17..], ROOT_ENTRIES);
    escribirU16(img[19..], @intCast(total_sectores));
    img[21] = 0xF8; // disco fijo
    escribirU16(img[22..], @intCast(fat_sectores));
    escribirU16(img[24..], 63);
    escribirU16(img[26..], 255);
    img[36] = 0x80;
    img[38] = 0x29;
    escribirU32(img[39..], 0x414C4653); // "SFLA"
    @memcpy(img[43..54], "ANTLEX     ");
    @memcpy(img[54..62], "FAT16   ");
    img[510] = 0x55;
    img[511] = 0xAA;

    // --- contenido ---
    const fat = try arena.alloc(u16, fat_sectores * SECTOR / 2);
    @memset(fat, 0);
    fat[0] = 0xFFF8;
    fat[1] = 0xFFFF;

    var esc = Escritor{ .img = img, .fat = fat, .datos_lba = datos_lba, .raiz_lba = raiz_lba, .proximo = 2 };

    const c_efi = esc.archivo(efi) catch return error.SinClusters;
    const c_leeme = esc.archivo(leeme) catch return error.SinClusters;
    const c_dir_efi = esc.directorio() catch return error.SinClusters; // clúster para EFI/
    const c_dir_boot = esc.directorio() catch return error.SinClusters; // clúster para EFI/BOOT/

    esc.subdirectorio(c_dir_efi, 0, nombre83("EFI"));
    esc.subdirectorio(c_dir_boot, c_dir_efi, nombre83("BOOT"));

    esc.anadir(0, true, .{ .nombre = nombre83("ANTLEX"), .attr = ATR_VOLUMEN, .cluster = 0, .tamano = 0 });
    esc.anadir(0, true, .{ .nombre = nombre83("LEEME.TXT"), .attr = ATR_ARCHIVO, .cluster = c_leeme, .tamano = @intCast(leeme.len) });
    esc.anadir(0, true, .{ .nombre = nombre83("EFI"), .attr = ATR_DIR, .cluster = c_dir_efi, .tamano = 0 });
    esc.anadir(c_dir_efi, false, .{ .nombre = nombre83("BOOT"), .attr = ATR_DIR, .cluster = c_dir_boot, .tamano = 0 });
    esc.anadir(c_dir_boot, false, .{ .nombre = nombre83("BOOTX64.EFI"), .attr = ATR_ARCHIVO, .cluster = c_efi, .tamano = @intCast(efi.len) });

    // --- volcar las dos FAT ---
    const fat_bytes = std.mem.sliceAsBytes(fat);
    @memcpy(img[@as(usize, fat1_lba) * SECTOR ..][0..fat_bytes.len], fat_bytes);
    @memcpy(img[@as(usize, fat2_lba) * SECTOR ..][0..fat_bytes.len], fat_bytes);

    try std.fs.cwd().writeFile(.{ .sub_path = ruta_out, .data = img });
    std.debug.print(
        "FAT16 listo: {d} sectores, FAT {d} sect, {d} clusters, EFI {d} B (cluster {d}), LEEME {d} B\n",
        .{ total_sectores, fat_sectores, clusters, efi.len, c_efi, leeme.len },
    );
}

fn escribirU16(dst: []u8, v: u16) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
}

fn escribirU32(dst: []u8, v: u32) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
    dst[2] = @truncate(v >> 16);
    dst[3] = @truncate(v >> 24);
}
