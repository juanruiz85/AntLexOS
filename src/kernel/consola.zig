//! AntLex OS — consola de texto gráfica sobre el framebuffer.
//! Gestiona cursor, scroll y colores; es la base del panel TERMINAL.

const pantalla = @import("pantalla.zig");
const fuente = @import("fuente.zig");

pub const Estilo = struct {
    tinta: u32,
    fondo: u32,
};

pub const COLOR_TEXTO: u32 = pantalla.rgb(0xD8, 0xE4, 0xEE);
pub const COLOR_ALERTA: u32 = pantalla.rgb(0xF2, 0xB8, 0x66);
pub const COLOR_OK: u32 = pantalla.rgb(0x7F, 0xDB, 0x8A);
pub const COLOR_ERROR: u32 = pantalla.rgb(0xFF, 0x6E, 0x6E);
pub const COLOR_TITULO: u32 = pantalla.rgb(0x9C, 0xD1, 0xFF);
pub const COLOR_CURSOR: u32 = pantalla.rgb(0x9C, 0xD1, 0xFF);

// Origen y tamaño del área de la consola (puede ser una ventana o pantalla entera)
var cx: u32 = 0; // columna (en glifos)
var cy: u32 = 0; // fila
var ancho_cols: u32 = 0;
var alto_filas: u32 = 0;
var origen_x: u32 = 0;
var origen_y: u32 = 0;
var estilo: Estilo = .{ .tinta = COLOR_TEXTO, .fondo = pantalla.rgb(0x0A, 0x0E, 0x16) };
var cursor_visible = true;

pub fn init() void {
    const an = pantalla.anchoPix();
    const al = pantalla.altoPix();
    origen_x = 0;
    origen_y = 0;
    ancho_cols = an / fuente.ANCHO;
    alto_filas = al / fuente.ALTO;
    cx = 0;
    cy = 0;
    limpiar();
}

/// Reubica el área de la consola (por ejemplo, dentro de una ventana).
/// Recorta el área pedida a los límites de la pantalla.
pub fn reubicar(x: u32, y: u32, an_pix: u32, al_pix: u32) void {
    origen_x = x;
    origen_y = y;
    const an_disp = if (x < pantalla.anchoPix()) pantalla.anchoPix() - x else 0;
    const al_disp = if (y < pantalla.altoPix()) pantalla.altoPix() - y else 0;
    ancho_cols = @min(an_pix, an_disp) / fuente.ANCHO;
    alto_filas = @min(al_pix, al_disp) / fuente.ALTO;
    if (alto_filas == 0) alto_filas = 1; // evitar underflow en scroll()
    if (ancho_cols == 0) ancho_cols = 1;
    cx = 0;
    cy = 0;
}

pub fn limpiar() void {
    pantalla.rect(origen_x, origen_y, ancho_cols * fuente.ANCHO, alto_filas * fuente.ALTO, estilo.fondo);
    cx = 0;
    cy = 0;
}

pub fn fijarEstilo(e: Estilo) void {
    estilo = e;
}

pub fn estiloActual() Estilo {
    return estilo;
}

pub fn columnas() u32 {
    return ancho_cols;
}

pub fn filas() u32 {
    return alto_filas;
}

pub fn posicion() struct { x: u32, y: u32 } {
    return .{ .x = cx, .y = cy };
}

fn scroll() void {
    // mover cada fila una hacia arriba (copiar hacia direcciones más bajas)
    const fila_px = fuente.ALTO;
    const ancho_px = ancho_cols * fuente.ANCHO;
    var f: u32 = 0;
    while (f < alto_filas - 1) : (f += 1) {
        copiarFila(f + 1, f);
    }
    // borrar la última fila
    pantalla.rect(origen_x, origen_y + (alto_filas - 1) * fila_px, ancho_px, fila_px, estilo.fondo);
}

fn copiarFila(desde: u32, hacia: u32) void {
    const paso = pantalla.pasoBytes() / 4;
    const fb: [*]volatile u32 = @ptrFromInt(pantalla.direccion());
    // recortar el ancho a los límites reales del framebuffer
    const ancho_total = pantalla.anchoPix();
    var ancho_px = ancho_cols * fuente.ANCHO;
    if (origen_x + ancho_px > ancho_total) ancho_px = ancho_total -| origen_x;
    const y_ori = origen_y + desde * fuente.ALTO;
    const y_dst = origen_y + hacia * fuente.ALTO;
    if (y_ori >= pantalla.altoPix() or y_dst >= pantalla.altoPix() or ancho_px == 0) return;
    const filas_px = @min(fuente.ALTO, pantalla.altoPix() -| @max(y_ori, y_dst));
    var fila: u32 = 0;
    while (fila < filas_px) : (fila += 1) {
        const src = fb + @as(usize, y_ori + fila) * paso + origen_x;
        const dst = fb + @as(usize, y_dst + fila) * paso + origen_x;
        var i: u32 = 0;
        while (i < ancho_px) : (i += 1) dst[i] = src[i];
    }
}

fn borrarCursor() void {
    if (!cursor_visible) return;
    const px = origen_x + cx * fuente.ANCHO;
    const py = origen_y + cy * fuente.ALTO;
    pantalla.rect(px, py, fuente.ANCHO, fuente.ALTO, estilo.fondo);
}

fn pintarCursor() void {
    if (!cursor_visible) return;
    const px = origen_x + cx * fuente.ANCHO;
    const py = origen_y + cy * fuente.ALTO;
    // subrayado de 2px en la parte baja
    pantalla.rect(px, py + fuente.ALTO - 2, fuente.ANCHO, 2, COLOR_CURSOR);
}

pub fn putc(c: u8) void {
    borrarCursor();
    switch (c) {
        '\n' => {
            cx = 0;
            cy += 1;
        },
        '\r' => cx = 0,
        8 => { // retroceso
            if (cx > 0) cx -= 1;
            const px = origen_x + cx * fuente.ANCHO;
            const py = origen_y + cy * fuente.ALTO;
            pantalla.rect(px, py, fuente.ANCHO, fuente.ALTO, estilo.fondo);
        },
        '\t' => {
            const salto = 8 - (cx % 8);
            var i: u32 = 0;
            while (i < salto) : (i += 1) putc(' ');
            return;
        },
        else => {
            const px = origen_x + cx * fuente.ANCHO;
            const py = origen_y + cy * fuente.ALTO;
            fuente.dibujar(px, py, c, estilo.tinta, estilo.fondo, 1);
            cx += 1;
            if (cx >= ancho_cols) {
                cx = 0;
                cy += 1;
            }
        },
    }
    if (cy >= alto_filas) {
        scroll();
        cy = alto_filas - 1;
    }
    pintarCursor();
}

pub fn puts(cadena: []const u8) void {
    for (cadena) |c| putc(c);
}

pub fn putDec(valor: u64) void {
    var buf: [24]u8 = undefined;
    var i: usize = buf.len;
    var v = valor;
    if (v == 0) {
        putc('0');
        return;
    }
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + @as(u8, @intCast(v % 10)));
        v /= 10;
    }
    puts(buf[i..]);
}

pub fn putHex(valor: u64) void {
    const digitos = "0123456789ABCDEF";
    puts("0x");
    var i: u7 = 64;
    while (i > 0) {
        i -= 4;
        putc(digitos[(valor >> @as(u6, @intCast(i))) & 0xF]);
    }
}

/// Centrar texto en la fila indicada (escala del glifo opcional).
pub fn ponerCentrado(fila: u32, texto: []const u8, color: u32, escala: u32) void {
    const an = texto.len * fuente.ANCHO * escala;
    const x = origen_x + (ancho_cols * fuente.ANCHO - @min(an, ancho_cols * fuente.ANCHO)) / 2;
    const y = origen_y + fila * fuente.ALTO;
    for (texto, 0..) |c, i| {
        fuente.dibujar(x + @as(u32, @intCast(i)) * fuente.ANCHO * escala, y, c, color, null, escala);
    }
}
