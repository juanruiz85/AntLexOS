//! AntLex OS — ALFS: montaje del volumen en el kernel.
//! Carga el volumen completo a memoria (espejo RAM) por ATA, ofrece las
//! operaciones de `alfs_volumen.Volumen` al resto del kernel y lo escribe
//! de vuelta al disco con `sincronizar()`.

const std = @import("std");
const boot_info = @import("boot_info.zig");
const ata = @import("ata.zig");
const mem = @import("mem.zig");
const serial = @import("serial.zig");
const vol = @import("alfs_volumen.zig");
const fmt = @import("alfs_formato.zig");

pub const Volumen = vol.Volumen;
pub const Error = vol.Error;

pub const Info = struct {
    archivos: u32,
    directorios: u32,
    libres: u32,
    etiqueta: [16]u8,
};

var volumen: ?Volumen = null;
var lba_base: u32 = 0;
var sectores: u32 = 0;
var sucio = false; // hay cambios sin sincronizar

pub fn montado() bool {
    return volumen != null;
}

/// Volumen activo (null si no hay ALFS montado).
pub fn actual() ?*Volumen {
    if (volumen) |*v| return v;
    return null;
}

pub fn hayCambiosSinSincronizar() bool {
    return sucio;
}

/// Monta el volumen ALFS desde el medio de arranque descrito por boot_info
/// (protocolo v2: alfs_ptr = offset en bytes, alfs_size = tamaño en bytes).
pub fn montar(bi: *const boot_info.BootInfo) Error!Info {
    if (bi.version < 2 or bi.alfs_ptr == 0 or bi.alfs_size == 0) {
        return Error.VolumenInvalido;
    }
    // el driver ATA PIO direcciona sectores de 512 B: el medio debe ser de
    // 512 B/sector (HDD/USB); el arranque desde CD (2048) llega en la Fase 6
    // con soporte específico
    if (bi.sector_size != 512) return Error.VolumenInvalido;
    if (bi.alfs_ptr % 512 != 0) return Error.VolumenInvalido;
    if (bi.alfs_size % 512 != 0 or bi.alfs_size < 2 * 1024 * 1024 or bi.alfs_size > 64 * 1024 * 1024) {
        return Error.VolumenInvalido;
    }
    // rango LBA28 completo validado una vez en u64: boot_info es semiconfiable
    const lba0: u64 = bi.alfs_ptr / 512;
    const n_sect: u64 = bi.alfs_size / 512;
    if (lba0 + n_sect > 0x10000000) return Error.VolumenInvalido;

    lba_base = @intCast(lba0);
    sectores = @intCast(n_sect);

    // espejo RAM del volumen completo
    const buf = mem.allocCero(bi.alfs_size, 4096) catch return Error.VolumenInvalido;
    const destino: [*]u16 = @ptrFromInt(buf);

    var leidos: u32 = 0;
    while (leidos < sectores) {
        const n = @min(ata.MAX_POR_OP, sectores - leidos);
        ata.leerSectores(lba_base + leidos, n, destino + @as(usize, leidos) * 256) catch
            return Error.VolumenInvalido;
        leidos += n;
    }

    volumen = try Volumen.abrir(@as([*]u8, @ptrFromInt(buf))[0..bi.alfs_size]);
    sucio = false;

    // recuento para la información de arranque
    var info = Info{ .archivos = 0, .directorios = 0, .libres = 0, .etiqueta = undefined };
    const v = &(volumen.?);
    info.libres = v.libres();
    info.etiqueta = v.superbloque().etiqueta;
    var i: u32 = 0;
    while (i < fmt.MAX_ENTRADAS) : (i += 1) {
        const e = v.entrada(@intCast(i)) orelse continue;
        switch (e.tipo) {
            1 => info.archivos += 1,
            2 => info.directorios += 1,
            else => {},
        }
    }
    return info;
}

fn alfsLbaAbs(bi: *const boot_info.BootInfo) u64 {
    return bi.alfs_ptr / 512; // el driver ATA trabaja en sectores de 512 B
}

/// Escribe el espejo RAM completo al disco y vacía la caché del disco.
/// Devuelve los bytes escritos.
pub fn sincronizar() !u32 {
    const v = &(volumen orelse return Error.VolumenInvalido);
    const fuente: [*]const u16 = @ptrFromInt(@intFromPtr(v.datos.ptr));
    var escritos: u32 = 0;
    while (escritos < sectores) {
        const n = @min(ata.MAX_POR_OP, sectores - escritos);
        try ata.escribirSectores(lba_base + escritos, n, fuente + @as(usize, escritos) * 256);
        escritos += n;
    }
    try ata.vaciarCache();
    sucio = false;
    return escritos * 512;
}

/// Marca el volumen como modificado (lo llama el intérprete tras cada
/// operación de escritura).
pub fn marcar() void {
    sucio = true;
}
