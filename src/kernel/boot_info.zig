//! AntLex OS — estructura boot_info compartida por los bootloaders (BIOS/UEFI)
//! y el kernel. La rellenan stage2 (BIOS) y el bootloader EFI (UEFI).
//!
//! Versiones del protocolo:
//!   v1 — arranque básico (alfs_ptr sin uso).
//!   v2 — añade la posición del volumen ALFS: `alfs_ptr` = offset EN BYTES
//!        del volumen ALFS dentro del medio de arranque (0 = sin volumen) y
//!        `alfs_size` = tamaño del volumen en bytes. El kernel calcula el
//!        LBA como alfs_ptr / sector_size.

const boot_magic: u32 = 0x42584C41; // "ALXB"

/// Versión actual del protocolo (deben escribir la misma los tres: stage2,
/// bootloader EFI y kernel).
pub const VERSION_ACTUAL: u32 = 2;

pub const MODO_UEFI: u32 = 0x1; // bit 0 de flags
pub const MODO_CD: u32 = 0x2; // bit 1 de flags

/// Entrada de mapa de memoria en formato E820.
pub const EntradaMem = extern struct {
    base: u64,
    long: u64,
    tipo: u32, // 1 = usable, resto = reservada
    acpi: u32,
};

pub const BootInfo = extern struct {
    magic: u32,
    version: u32,
    flags: u32,
    reserved: u32,
    fb_addr: u64,
    fb_w: u32,
    fb_h: u32,
    fb_pitch: u32,
    fb_bpp: u32,
    memmap_ptr: u64,
    memmap_count: u32,
    pad: u32,
    alfs_ptr: u64, // v2: offset en bytes del volumen ALFS en el medio (0 = no hay)
    alfs_size: u32, // v2: tamaño del volumen ALFS en bytes
    sector_size: u32, // 512 (HDD) o 2048 (CD)
    boot_drive: u32, // 0x80.. (BIOS) o 0xFFFFFFFF (UEFI)
};

comptime {
    // 76 bytes de campos + 4 de relleno de alineación (los loaders escriben
    // solo los campos; el relleno nunca se lee, así que su contenido es
    // irrelevante)
    if (@sizeOf(BootInfo) != 80) @compileError("BootInfo debe medir 80 bytes (76 + relleno)");
}

/// Región de memoria usable.
pub const Region = struct { base: u64, long: u64 };

/// Máximo de entradas del mapa E820 que acepta el protocolo (layout.zig).
const MEMMAP_MAX: u32 = 64;

/// Valida la magia y devuelve el puntero a boot_info.
pub fn desde(direccion: usize) ?*BootInfo {
    if (direccion == 0 or direccion % @alignOf(BootInfo) != 0) return null;
    const bi: *volatile BootInfo = @ptrFromInt(direccion);
    if (bi.magic != boot_magic) return null;
    return @constCast(@volatileCast(bi));
}

/// Devuelve el mapa de memoria E820 (acotado a MEMMAP_MAX por seguridad:
/// un bootloader corrupto no puede provocar lecturas salvajes).
pub fn memmap(bi: *const BootInfo) []const EntradaMem {
    if (bi.memmap_ptr == 0) return &.{};
    const n: usize = @min(bi.memmap_count, MEMMAP_MAX);
    if (n == 0) return &.{};
    const p: [*]const EntradaMem = @ptrFromInt(bi.memmap_ptr);
    return p[0..n];
}

/// Memoria total usable (bytes).
pub fn memoriaTotal(bi: *const BootInfo) u64 {
    var total: u64 = 0;
    for (memmap(bi)) |e| {
        if (e.tipo == 1) total += e.long;
    }
    return total;
}

/// Inicio de la mayor región usable por encima de un mínimo (para el heap).
pub fn regionHeap(bi: *const BootInfo, minimo: u64) ?Region {
    var mejor: ?Region = null;
    for (memmap(bi)) |e| {
        if (e.tipo != 1) continue;
        if (e.long < 1024 * 1024) continue; // ignorar regiones diminutas
        if (e.base < minimo) {
            const recorte = minimo - e.base;
            if (e.long <= recorte) continue;
            const base = minimo;
            const long = e.long - recorte;
            if (mejor == null or long > mejor.?.long) mejor = .{ .base = base, .long = long };
        } else {
            if (mejor == null or e.long > mejor.?.long) mejor = .{ .base = e.base, .long = e.long };
        }
    }
    return mejor;
}
