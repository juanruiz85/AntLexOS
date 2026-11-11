//! AntLex OS — render de la fuente bitmap 8x16 (generada desde GNU Unifont).

const pantalla = @import("pantalla.zig");
const datos = @import("fuente_datos.zig");

pub const ANCHO: u32 = 8;
pub const ALTO: u32 = 16;

/// Índice del glifo para un código de carácter, o null si no existe.
pub fn indice(cp: u21) ?u16 {
    if (cp >= 32 and cp <= 126) return @intCast(cp - 32); // ASCII contiguo
    for (datos.EXTRAS) |e| {
        if (e.cp == cp) return e.idx;
    }
    return null;
}

/// Dibuja un carácter en (x, y) con factor de escala (1 = 8x16).
/// Si `fondo` es null, no pinta el fondo (transparencia).
pub fn dibujar(x: u32, y: u32, cp: u21, color: u32, fondo: ?u32, escala: u32) void {
    const idx = indice(cp) orelse {
        dibujarDesconocido(x, y, color, fondo, escala);
        return;
    };
    const glifo = &datos.GLIFOS[idx];
    var fila: u32 = 0;
    while (fila < ALTO) : (fila += 1) {
        const bits = glifo[fila];
        var col: u32 = 0;
        while (col < ANCHO) : (col += 1) {
            const encendido = (bits >> @intCast(7 - col)) & 1 == 1;
            const c: u32 = if (encendido) color else (fondo orelse continue);
            if (escala == 1) {
                pantalla.pixel(x + col, y + fila, c);
            } else {
                pantalla.rect(x + col * escala, y + fila * escala, escala, escala, c);
            }
        }
    }
}

fn dibujarDesconocido(x: u32, y: u32, color: u32, fondo: ?u32, escala: u32) void {
    // caja con ? para caracteres sin glifo
    if (fondo) |f| pantalla.rect(x, y, ANCHO * escala, ALTO * escala, f);
    const gx = x + 2 * escala;
    const gy = y + 2 * escala;
    var fila: u32 = 0;
    const patron = [12]u8{
        0x3C, 0x42, 0x42, 0x42, 0x42, 0x44,
        0x40, 0x40, 0x40, 0x40, 0x00, 0x40,
    };
    while (fila < 12) : (fila += 1) {
        const bits = patron[fila];
        var col: u32 = 0;
        while (col < 8) : (col += 1) {
            if ((bits >> @intCast(7 - col)) & 1 == 1) {
                pantalla.rect(gx + col * escala, gy + fila * escala, escala, escala, color);
            }
        }
    }
}

/// Ancho/alto en píxeles de una cadena (para centrar texto).
pub fn anchoTexto(n: u32, escala: u32) u32 {
    return n * ANCHO * escala;
}
