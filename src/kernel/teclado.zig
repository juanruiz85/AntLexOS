//! AntLex OS — driver de teclado PS/2 (scancode set 1) con distribuciones
//! ES (español, por defecto) y US, teclas muertas (´ ` ¨), flechas y Ctrl+C.

const std = @import("std");
const x86 = @import("x86.zig");

// Códigos internos para teclas especiales (fuera de ASCII/Latin-1)
pub const FLECHA_IZQ: u8 = 0x80;
pub const FLECHA_DER: u8 = 0x81;
pub const FLECHA_ARRIBA: u8 = 0x82;
pub const FLECHA_ABAJO: u8 = 0x83;
pub const SUPRIMIR: u8 = 0x84;
pub const INICIO: u8 = 0x85;
pub const FIN: u8 = 0x86;
pub const CTRL_C: u8 = 0x03; // interrupción de línea

// teclas muertas internas
const M_AGUDO: u8 = 0x90;
const M_GRAVE: u8 = 0x91;
const M_DIERE: u8 = 0x92;

pub const Muerta = enum { ninguna, agudo, grave, diere };

// distribución activa como indicador atómico (la escribe el hilo principal
// y la lee la IRQ1: sin lecturas rasgadas)
var dist_es: bool = true;
var muerta: Muerta = .ninguna;
var mayus: bool = false;
var shift: bool = false;
var ctrl: bool = false;
var alt: bool = false;
var extendido: bool = false;

const TAM_BUF = 64;
var buffer: [TAM_BUF]u8 = undefined;
// volatile: los modifica la IRQ1 y los lee el hilo principal
var leido: usize = 0; // volatile
var escrito: usize = 0; // volatile
var desbordamientos: u32 = 0;

/// Tabla de 256 entradas: índices 0..127 = sin shift, 128..255 = con shift.
const Tabla = [256]u8;

fn mayusculas(t: *Tabla, base: usize, s: []const u8) void {
    for (s, 0..) |c, i| {
        if (c >= 'a' and c <= 'z') {
            t[base + i + 128] = c - 32;
        }
    }
}

fn tablaES() Tabla {
    var t = [_]u8{0} ** 256;
    // fila de números: 1 2 3 4 5 6 7 8 9 0 ' ¡  /  !"·$%&/()¿?
    const nums = [_]u8{ '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '\'', 0xA1 };
    const nums_s = [_]u8{ '!', '"', 0xB7, '$', '%', '&', '/', '(', ')', '=', '?', 0xBF };
    for (0..12) |i| {
        t[0x02 + i] = nums[i];
        t[0x02 + i + 128] = nums_s[i];
    }
    const q = "qwertyuiop";
    for (q, 0..) |c, i| t[0x10 + i] = c;
    const a = "asdfghjkl";
    for (a, 0..) |c, i| t[0x1E + i] = c;
    const z = "zxcvbnm";
    for (z, 0..) |c, i| t[0x2C + i] = c;
    mayusculas(&t, 0x10, q);
    mayusculas(&t, 0x1E, a);
    mayusculas(&t, 0x2C, z);
    t[0x1C] = '\n'; // INTRO
    t[0x1C + 128] = '\n';
    t[0x0E] = 8; // retroceso
    t[0x0E + 128] = 8;
    t[0x0F] = '\t'; // tabulador
    t[0x0F + 128] = '\t';
    // teclas específicas ES
    t[0x1A] = M_GRAVE; // ` muerto
    t[0x1A + 128] = '^';
    t[0x1B] = '+';
    t[0x1B + 128] = '*';
    t[0x27] = 0xF1; // ñ
    t[0x27 + 128] = 0xD1; // Ñ
    t[0x28] = M_AGUDO; // ´ muerto
    t[0x28 + 128] = M_DIERE; // ¨ muerto
    t[0x29] = 0xBA; // º
    t[0x29 + 128] = 0xAA; // ª
    t[0x2B] = 0xE7; // ç
    t[0x2B + 128] = 0xC7; // Ç
    t[0x33] = ',';
    t[0x33 + 128] = ';';
    t[0x34] = '.';
    t[0x34 + 128] = ':';
    t[0x35] = '-';
    t[0x35 + 128] = '_';
    t[0x39] = ' ';
    return t;
}

fn tablaUS() Tabla {
    var t = [_]u8{0} ** 256;
    const nums = [_]u8{ '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=' };
    const nums_s = [_]u8{ '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+' };
    for (0..12) |i| {
        t[0x02 + i] = nums[i];
        t[0x02 + i + 128] = nums_s[i];
    }
    const q = "qwertyuiop";
    for (q, 0..) |c, i| t[0x10 + i] = c;
    t[0x1A] = '[';
    t[0x1A + 128] = '{';
    t[0x1B] = ']';
    t[0x1B + 128] = '}';
    const a = "asdfghjkl";
    for (a, 0..) |c, i| t[0x1E + i] = c;
    t[0x27] = ';';
    t[0x27 + 128] = ':';
    t[0x28] = '\'';
    t[0x28 + 128] = '"';
    t[0x29] = '`';
    t[0x29 + 128] = '~';
    t[0x2B] = '\\';
    t[0x2B + 128] = '|';
    const z = "zxcvbnm";
    for (z, 0..) |c, i| t[0x2C + i] = c;
    mayusculas(&t, 0x10, q);
    mayusculas(&t, 0x1E, a);
    mayusculas(&t, 0x2C, z);
    t[0x1C] = '\n'; // INTRO
    t[0x1C + 128] = '\n';
    t[0x0E] = 8; // retroceso
    t[0x0E + 128] = 8;
    t[0x0F] = '\t'; // tabulador
    t[0x0F + 128] = '\t';
    t[0x33] = ',';
    t[0x33 + 128] = '<';
    t[0x34] = '.';
    t[0x34 + 128] = '>';
    t[0x35] = '/';
    t[0x35 + 128] = '?';
    t[0x39] = ' ';
    return t;
}

pub const TABLA_ES = tablaES();
pub const TABLA_US = tablaUS();

pub fn init() void {
    // vaciar el búfer de salida del controlador PS/2
    while (x86.inb(0x64) & 0x01 != 0) {
        _ = x86.inb(0x60);
    }
}

/// Cambia la distribución ("es" o "us"). Devuelve false si es desconocida.
pub fn fijarDistribucion(nombre: []const u8) bool {
    if (std.mem.eql(u8, nombre, "es")) {
        @atomicStore(bool, &dist_es, true, .release);
        return true;
    } else if (std.mem.eql(u8, nombre, "us")) {
        @atomicStore(bool, &dist_es, false, .release);
        return true;
    }
    return false;
}

pub fn distribucion() []const u8 {
    return if (@atomicLoad(bool, &dist_es, .acquire)) "es" else "us";
}

pub fn totalDesbordamientos() u32 {
    return desbordamientos;
}

fn empujar(c: u8) void {
    const esc = @atomicLoad(usize, &escrito, .acquire);
    const lei = @atomicLoad(usize, &leido, .acquire);
    const sig = (esc + 1) % TAM_BUF;
    if (sig == lei) {
        desbordamientos += 1;
        return;
    }
    buffer[esc] = c;
    @atomicStore(usize, &escrito, sig, .release);
}

/// Saca un carácter del búfer (o null si está vacío).
pub fn poll() ?u8 {
    const lei = @atomicLoad(usize, &leido, .acquire);
    const esc = @atomicLoad(usize, &escrito, .acquire);
    if (lei == esc) return null;
    const c = buffer[lei];
    @atomicStore(usize, &leido, (lei + 1) % TAM_BUF, .release);
    return c;
}

pub fn aplicarMuerta(c: u8) u8 {
    if (muerta == .ninguna) return c;
    const m = muerta;
    muerta = .ninguna;
    const vocales = [_]u8{ 'a', 'e', 'i', 'o', 'u' };
    const con_agudo = [_]u8{ 0xE1, 0xE9, 0xED, 0xF3, 0xFA }; // á é í ó ú
    const con_grave = [_]u8{ 0xE0, 0xE8, 0xEC, 0xF2, 0xF9 }; // à è ì ò ù
    const con_diere = [_]u8{ 0xE4, 0xEB, 0xEF, 0xF6, 0xFC }; // ä ë ï ö ü
    const con_acento = switch (m) {
        .agudo => con_agudo,
        .grave => con_grave,
        .diere => con_diere,
        .ninguna => unreachable,
    };
    for (vocales, 0..) |v, i| {
        if (c == v) return con_acento[i];
    }
    // no era vocal: se pierde el acento y pasa el carácter
    return c;
}

/// Solo para pruebas unitarias: fuerza el estado de tecla muerta.
pub fn pruebaFijarMuerta(m: Muerta) void {
    muerta = m;
}

/// Manejador de IRQ1.
pub fn irq() void {
    if (x86.inb(0x64) & 0x01 == 0) return;
    const sc = x86.inb(0x60);

    if (sc == 0xE0) {
        extendido = true;
        return;
    }
    if (extendido) {
        extendido = false;
        switch (sc) {
            0x48 => empujar(FLECHA_ARRIBA),
            0x50 => empujar(FLECHA_ABAJO),
            0x4B => empujar(FLECHA_IZQ),
            0x4D => empujar(FLECHA_DER),
            0x53 => empujar(SUPRIMIR),
            0x47 => empujar(INICIO),
            0x4F => empujar(FIN),
            0x1C => empujar('\n'), // INTRO del teclado numérico
            else => {},
        }
        return;
    }

    const soltar = sc & 0x80 != 0;
    const code = sc & 0x7F;
    switch (code) {
        0x2A, 0x36 => {
            shift = !soltar;
            return;
        },
        0x1D => {
            ctrl = !soltar;
            return;
        },
        0x38 => {
            alt = !soltar;
            return;
        },
        0x3A => {
            if (!soltar) mayus = !mayus;
            return;
        },
        else => {},
    }
    if (soltar or code >= 128) return;

    const tabla: *const Tabla = if (!@atomicLoad(bool, &dist_es, .acquire)) &TABLA_US else &TABLA_ES;
    var c = tabla[code];

    // mayúsculas de bloqueo solo afectan a letras
    const es_letra = (c >= 'a' and c <= 'z') or c == 0xF1;
    const usar_shift = if (es_letra) (shift != mayus) else shift;
    if (usar_shift) {
        const cs = tabla[code + 128];
        if (cs != 0) c = cs;
    }
    if (c == 0) return;

    if (c >= 0x90 and c <= 0x92) {
        muerta = switch (c) {
            M_AGUDO => .agudo,
            M_GRAVE => .grave,
            else => .diere,
        };
        return;
    }
    if (ctrl and (c == 'c' or c == 'C')) {
        empujar(CTRL_C);
        return;
    }
    empujar(aplicarMuerta(c));
}
