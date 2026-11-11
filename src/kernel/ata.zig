//! AntLex OS — driver ATA/IDE PIO (bus primario, disco maestro).
//! LBA28 con polling e interrupciones del disco desactivadas (nIEN): sin
//! colas, sin IRQ14/15 — suficiente para el volumen ALFS y hardware real
//! sencillo. Todas las esperas están acotadas (nunca bloquea el sistema).

const x86 = @import("x86.zig");

// registros del bus primario
const REG_DATOS: u16 = 0x1F0;
const REG_ERROR: u16 = 0x1F1;
const REG_CUENTA: u16 = 0x1F2;
const REG_LBA0: u16 = 0x1F3;
const REG_LBA1: u16 = 0x1F4;
const REG_LBA2: u16 = 0x1F5;
const REG_UNIDAD: u16 = 0x1F6;
const REG_ESTADO: u16 = 0x1F7; // lectura: estado; escritura: comando
const REG_CONTROL: u16 = 0x3F6;

const ST_ERR: u8 = 0x01;
const ST_DRQ: u8 = 0x08;
const ST_DF: u8 = 0x20;
const ST_DRDY: u8 = 0x40;
const ST_BSY: u8 = 0x80;

const CMD_LEER: u8 = 0x20; // READ SECTORS (LBA28)
const CMD_ESCRIBIR: u8 = 0x30; // WRITE SECTORS (LBA28)
const CMD_FLUSH: u8 = 0xE7; // FLUSH CACHE
const CMD_IDENTIFY: u8 = 0xEC;

/// Máximo de sectores por operación (acotado; el límite del protocolo es 256).
pub const MAX_POR_OP: u32 = 64;

pub const Error = error{ SinDisco, FallaAta, Timeout, FueraDeRango };

var disponible = false;
var soporta_lba28 = false;
var modelo_buf: [41]u8 = [_]u8{0} ** 41; // 40 caracteres + terminador

pub fn init() Error!void {
    // interrupciones del disco fuera (nIEN=1, bit1) — trabajamos por polling
    x86.outb(REG_CONTROL, 0x02);
    x86.ioWait();

    // seleccionar disco maestro (LBA mode bit)
    x86.outb(REG_UNIDAD, 0xE0);
    x86.ioWait();
    x86.ioWait();

    const st = x86.inb(REG_ESTADO);
    if (st == 0x00 or st == 0xFF) return Error.SinDisco; // bus vacío/flotante

    // IDENTIFY DEVICE
    x86.outb(REG_CUENTA, 0);
    x86.outb(REG_LBA0, 0);
    x86.outb(REG_LBA1, 0);
    x86.outb(REG_LBA2, 0);
    x86.outb(REG_ESTADO, CMD_IDENTIFY);

    const st2 = x86.inb(REG_ESTADO);
    if (st2 == 0) return Error.SinDisco;
    try esperarDatos(1_000_000);
    if (x86.inb(REG_ESTADO) & (ST_ERR | ST_DF) != 0) return Error.FallaAta;

    var palabras: [256]u16 align(4) = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) palabras[i] = x86.inw(REG_DATOS);

    // palabra 49, bit 9: soporte de LBA28
    soporta_lba28 = (palabras[49] & 0x200) != 0;
    // palabras 27..46: modelo del disco (cada palabra con bytes intercambiados)
    var n: usize = 0;
    i = 27;
    while (i <= 46) : (i += 1) {
        modelo_buf[n] = @truncate(palabras[i] >> 8);
        n += 1;
        modelo_buf[n] = @truncate(palabras[i] & 0xFF);
        n += 1;
    }
    modelo_buf[n] = 0;
    disponible = true;
}

pub fn estaDisponible() bool {
    return disponible;
}

/// Cadena con el modelo del disco (recortada de espacios).
pub fn modelo() []const u8 {
    var len: usize = 0;
    while (len < 40 and modelo_buf[len] != 0) len += 1;
    var inicio: usize = 0;
    while (inicio < len and modelo_buf[inicio] == ' ') inicio += 1;
    return modelo_buf[inicio..len];
}

/// Espera a que el disco esté listo para transferir (BSY=0 y DRQ=1).
fn esperarDatos(limite: u32) Error!void {
    var n: u32 = 0;
    while (n < limite) : (n += 1) {
        const st = x86.inb(REG_ESTADO);
        if (st & ST_BSY == 0) {
            if (st & (ST_ERR | ST_DF) != 0) return Error.FallaAta;
            if (st & ST_DRQ != 0) return;
        }
        x86.ioWait();
    }
    return Error.Timeout;
}

/// Espera a que el disco deje de estar ocupado (fin de comando).
fn esperarLibre(limite: u32) Error!void {
    var n: u32 = 0;
    while (n < limite) : (n += 1) {
        const st = x86.inb(REG_ESTADO);
        if (st & ST_BSY == 0 and st & ST_DRQ == 0) {
            if (st & (ST_ERR | ST_DF) != 0) return Error.FallaAta;
            return;
        }
        x86.ioWait();
    }
    return Error.Timeout;
}

fn preparar(lba: u32, cuenta: u8) void {
    x86.outb(REG_UNIDAD, 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F)));
    x86.outb(REG_CUENTA, cuenta);
    x86.outb(REG_LBA0, @truncate(lba & 0xFF));
    x86.outb(REG_LBA1, @truncate((lba >> 8) & 0xFF));
    x86.outb(REG_LBA2, @truncate((lba >> 16) & 0xFF));
}

/// Lee `cuenta` sectores (1..64) desde `lba` al búfer `destino` (u16).
/// PIO «READ SECTORS»: el disco pide DRQ por CADA sector, así que la
/// transferencia de 256 palabras se hace sector a sector.
pub fn leerSectores(lba: u32, cuenta: u32, destino: [*]u16) Error!void {
    if (!disponible) return Error.SinDisco;
    if (!soporta_lba28) return Error.FallaAta; // sin LBA28 el addressing sería CHS
    if (cuenta == 0 or cuenta > MAX_POR_OP) return Error.FueraDeRango;
    if (@as(u64, lba) + cuenta > 0x10000000) return Error.FueraDeRango; // límite LBA28
    try esperarLibre(2_000_000); // el disco debe estar listo antes de programar
    preparar(lba, @truncate(cuenta));
    x86.outb(REG_ESTADO, CMD_LEER);
    var i: u32 = 0;
    while (i < cuenta) : (i += 1) {
        try esperarDatos(2_000_000);
        insw(REG_DATOS, destino + @as(usize, i) * 256, 256);
    }
}

/// Escribe `cuenta` sectores (1..64) desde `fuente` a `lba`.
/// PIO «WRITE SECTORS»: DRQ por sector + espera final de disco libre.
pub fn escribirSectores(lba: u32, cuenta: u32, fuente: [*]const u16) Error!void {
    if (!disponible) return Error.SinDisco;
    if (!soporta_lba28) return Error.FallaAta;
    if (cuenta == 0 or cuenta > MAX_POR_OP) return Error.FueraDeRango;
    if (@as(u64, lba) + cuenta > 0x10000000) return Error.FueraDeRango;
    try esperarLibre(2_000_000); // el disco debe estar listo antes de programar
    preparar(lba, @truncate(cuenta));
    x86.outb(REG_ESTADO, CMD_ESCRIBIR);
    var i: u32 = 0;
    while (i < cuenta) : (i += 1) {
        try esperarDatos(2_000_000);
        outsw(REG_DATOS, fuente + @as(usize, i) * 256, 256);
    }
    try esperarLibre(2_000_000);
}

/// Vacía la caché interna del disco (persistencia real).
pub fn vaciarCache() Error!void {
    if (!disponible) return Error.SinDisco;
    x86.outb(REG_ESTADO, CMD_FLUSH);
    try esperarLibre(2_000_000);
}

/// Transferencia de palabras por E/S de puertos (rep insw/outsw).
/// Las entradas van en registros fijos y se declaran como clobber: LLVM
/// coloca los valores antes del bloque y no mantiene nada vivo en RDI/RCX
/// a través de él (verificado con prueba de sintaxis; el patrón "={D}"
/// de salida no es aceptado por el ensamblador inline de Zig 0.14).
inline fn insw(puerto: u16, destino: [*]u16, palabras: usize) void {
    asm volatile (
        \\ cld
        \\ rep insw
        :
        : [p] "{dx}" (puerto),
          [d] "{rdi}" (destino),
          [c] "{rcx}" (palabras),
        : "memory", "rdi", "rcx"
    );
}

inline fn outsw(puerto: u16, fuente: [*]const u16, palabras: usize) void {
    asm volatile (
        \\ cld
        \\ rep outsw
        :
        : [p] "{dx}" (puerto),
          [f] "{rsi}" (fuente), // el ORIGEN de outsw es RSI (a diferencia de insw, que usa RDI)
          [c] "{rcx}" (palabras),
        : "memory", "rsi", "rcx"
    );
}
