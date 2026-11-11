//! AntLex OS — ALFS v1: definición del formato en disco (capa pura, sin
//! hardware). Es la fuente única de verdad del formato y la usan el kernel,
//! la herramienta `tools/mkalfs.zig` y las pruebas unitarias del host.
//!
//! Formato del volumen (por defecto 16 MiB = 32768 bloques de 512 B):
//!
//!   bloque 0            superbloque (512 B)
//!   bloque 1..8         mapa de bits de bloques (32768 bits = 4096 B)
//!   bloque 9..40        tabla de 256 entradas de 64 B (16 KiB)
//!   bloque 41..         área de datos (archivos por extensiones contiguas)
//!
//! Entrada de tabla (64 B):
//!   u8 tipo (0 libre, 1 archivo, 2 directorio) · u8 flags · u16 nombre_len
//!   [44]u8 nombre · u16 padre (0xFFFF = raíz) · u16 reservado
//!   u32 tam · u32 primer_bloque · u32 nbloques

const std = @import("std");

pub const MAGIC: u32 = 0x31534C41; // "ALF1" little-endian
pub const VERSION_FORMATO: u16 = 1;
pub const BLOQUE_LOG2: u16 = 9;
pub const TAM_BLOQUE: u32 = 512;

pub const MAX_ENTRADAS: u32 = 256;
pub const TAM_NOMBRE: u32 = 44;
pub const PADRE_RAIZ: u16 = 0xFFFF;
pub const RAIZ: u16 = 0;

pub const TIPO_LIBRE: u8 = 0;
pub const TIPO_ARCHIVO: u8 = 1;
pub const TIPO_DIRECTORIO: u8 = 2;

/// Tamaño máximo de archivo soportado por el formato (cap de seguridad).
pub const TAM_MAX_ARCHIVO: u32 = 4 * 1024 * 1024;
/// Profundidad máxima de rutas (componentes) al resolver.
pub const MAX_PROFUNDIDAD: u32 = 16;

pub const Entrada = extern struct {
    tipo: u8,
    flags: u8,
    nombre_len: u16,
    nombre: [TAM_NOMBRE]u8,
    padre: u16,
    reservado: u16,
    tam: u32,
    primer_bloque: u32,
    nbloques: u32,

    comptime {
        if (@sizeOf(Entrada) != 64) @compileError("Entrada ALFS debe medir 64 bytes");
        if (@offsetOf(Entrada, "nombre") != 4) @compileError("nombre debe empezar en el byte 4");
        if (@offsetOf(Entrada, "tam") != 52) @compileError("tam debe estar en el byte 52");
    }
};

pub const Superbloque = extern struct {
    magic: u32,
    version: u16,
    bloque_log2: u16,
    n_bloques: u32,
    bitmap_bloque: u32,
    tabla_bloque: u32,
    tabla_entradas: u32,
    datos_bloque: u32,
    bloques_libres: u32,
    crc: u32, // v1: 0 (reservado)
    etiqueta: [16]u8,
    _relleno: [TAM_BLOQUE - 52]u8,

    comptime {
        if (@sizeOf(Superbloque) != TAM_BLOQUE) @compileError("Superbloque ALFS debe medir 512 bytes");
        if (@offsetOf(Superbloque, "etiqueta") != 36) @compileError("etiqueta debe estar en el byte 36");
        if (@offsetOf(Superbloque, "bloques_libres") != 28) @compileError("bloques_libres debe estar en el byte 28");
        if (@offsetOf(Superbloque, "crc") != 32) @compileError("crc debe estar en el byte 32");
    }
};

/// Bloque donde empieza el mapa de bits para un volumen de n bloques.
pub fn bloqueTabla(n_bloques: u32) u32 {
    const bytes_bitmap = (n_bloques + 7) / 8;
    return 1 + porBloques(bytes_bitmap);
}

/// Bloque donde empieza el área de datos.
pub fn bloqueDatos(n_bloques: u32) u32 {
    return bloqueTabla(n_bloques) + porBloques(MAX_ENTRADAS * 64);
}

fn porBloques(bytes: u32) u32 {
    return (bytes + TAM_BLOQUE - 1) / TAM_BLOQUE;
}

// ---------------------------------------------------------------------------
// Mapa de bits de bloques
// ---------------------------------------------------------------------------

pub inline fn bitOcupado(bitmap: []const u8, bloque: u32) bool {
    const i = bloque / 8;
    const b: u3 = @intCast(bloque % 8);
    return (bitmap[i] >> b) & 1 == 1;
}

pub inline fn ponerBit(bitmap: []u8, bloque: u32) void {
    const i = bloque / 8;
    const b: u3 = @intCast(bloque % 8);
    bitmap[i] |= @as(u8, 1) << b;
}

pub inline fn quitarBit(bitmap: []u8, bloque: u32) void {
    const i = bloque / 8;
    const b: u3 = @intCast(bloque % 8);
    bitmap[i] &= ~(@as(u8, 1) << b);
}

/// Cuenta los bits libres del mapa (longitud en bytes).
pub fn contarLibres(bitmap: []const u8, n_bloques: u32) u32 {
    var libres: u32 = 0;
    var b: u32 = 0;
    while (b < n_bloques) : (b += 1) {
        if (!bitOcupado(bitmap, b)) libres += 1;
    }
    return libres;
}

// ---------------------------------------------------------------------------
// Nombres y comparación
// ---------------------------------------------------------------------------

/// Comparación de nombres insensible a mayúsculas ASCII (ñ y demás Latin-1
/// se comparan byte a byte, que es lo esperado en un teclado español).
pub fn eqlNombre(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (aMinus(x) != aMinus(y)) return false;
    }
    return true;
}

inline fn aMinus(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Valida un nombre de archivo/directorio: 1..44 bytes, sin '/', sin NUL,
/// sin espacios (el intérprete separa argumentos por espacios) y sin
/// caracteres de control.
pub fn nombreValido(nombre: []const u8) bool {
    if (nombre.len == 0 or nombre.len > TAM_NOMBRE) return false;
    for (nombre) |c| {
        if (c == '/' or c == 0 or c == ' ') return false;
        if (c < 32) return false;
        if (c == 127) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Pruebas del formato (host)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "formato: tamaños de estructura" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(Entrada));
    try testing.expectEqual(@as(usize, 512), @sizeOf(Superbloque));
}

test "formato: layout del volumen de 32768 bloques" {
    const n: u32 = 32768;
    try testing.expectEqual(@as(u32, 9), bloqueTabla(n));
    try testing.expectEqual(@as(u32, 41), bloqueDatos(n));
}

test "formato: mapa de bits" {
    var bitmap: [4096]u8 = undefined;
    @memset(&bitmap, 0);
    try testing.expect(!bitOcupado(&bitmap, 0));
    ponerBit(&bitmap, 0);
    ponerBit(&bitmap, 32767);
    try testing.expect(bitOcupado(&bitmap, 0));
    try testing.expect(bitOcupado(&bitmap, 32767));
    try testing.expect(!bitOcupado(&bitmap, 1));
    quitarBit(&bitmap, 0);
    try testing.expect(!bitOcupado(&bitmap, 0));
    try testing.expectEqual(@as(u32, 32767), contarLibres(&bitmap, 32768));
}

test "formato: nombres" {
    try testing.expect(eqlNombre("LEEME.TXT", "leeme.txt"));
    try testing.expect(!eqlNombre("NOTA1.TXT", "NOTA2.TXT"));
    try testing.expect(nombreValido("prueba.txt"));
    try testing.expect(nombreValido("ñandú.txt"));
    try testing.expect(!nombreValido(""));
    try testing.expect(!nombreValido("con espacio"));
    try testing.expect(!nombreValido("con/barra"));
    var largo: [45]u8 = undefined;
    @memset(&largo, 'a');
    try testing.expect(!nombreValido(&largo));
}
