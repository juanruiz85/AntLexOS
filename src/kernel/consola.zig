//! AntLex OS — consola de texto gráfica sobre el framebuffer.
//! Gestiona cursor, scroll y colores; es la base del panel TERMINAL.
//!
//! Fase 5: la consola es una ESTRUCTURA con rejilla de celdas de respaldo
//! (carácter + estilo) para poder REDIBUJARLA entera cuando una ventana
//! flotante pasa por encima y se aparta. La instancia por defecto se
//! exporta con funciones a nivel de módulo (compatibilidad con el resto
//! del kernel); la GUI crea una segunda instancia para el chat de AntLex.

const std = @import("std");
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

pub const FONDO_DEF: u32 = pantalla.rgb(0x0A, 0x0E, 0x16);

/// Techo de geometrías soportadas (1280x800 → 160×50 glifos).
pub const MAX_COLS = 160;
pub const MAX_FILAS = 50;
/// Paleta de estilos por celda (índice de 8 bits, sobran).
pub const MAX_ESTILOS = 256;

const Celda = packed struct(u16) {
    car: u8,
    estilo: u8,
};

pub const Consola = struct {
    ox: u32 = 0,
    oy: u32 = 0,
    cols: u32 = 0,
    filas: u32 = 0,
    cx: u32 = 0,
    cy: u32 = 0,
    fondo: u32 = FONDO_DEF,
    cursor_visible: bool = true,
    estilos: [MAX_ESTILOS]Estilo = undefined,
    n_estilos: u8 = 0,
    actual: u8 = 0,
    // la rejilla se rellena en limpiar() (solo el área visible importa;
    // fuera de cols/filas nunca se lee ni se pinta)
    celdas: [MAX_FILAS][MAX_COLS]Celda = undefined,

    /// Registra un estilo en la paleta (o devuelve el existente).
    fn indiceEstilo(self: *Consola, e: Estilo) u8 {
        var i: u8 = 0;
        while (i < self.n_estilos) : (i += 1) {
            if (self.estilos[i].tinta == e.tinta and self.estilos[i].fondo == e.fondo) return i;
        }
        if (self.n_estilos == MAX_ESTILOS - 1) return 0; // paleta llena: estilo 0
        self.estilos[self.n_estilos] = e;
        self.n_estilos += 1;
        return self.n_estilos - 1;
    }

    /// Fija la región de la consola en píxeles (recortada a pantalla).
    pub fn region(self: *Consola, x: u32, y: u32, an_pix: u32, al_pix: u32) void {
        self.ox = x;
        self.oy = y;
        const an_disp = if (x < pantalla.anchoPix()) pantalla.anchoPix() - x else 0;
        const al_disp = if (y < pantalla.altoPix()) pantalla.altoPix() - y else 0;
        self.cols = @min(@min(an_pix, an_disp) / fuente.ANCHO, MAX_COLS);
        self.filas = @min(@min(al_pix, al_disp) / fuente.ALTO, MAX_FILAS);
        if (self.filas == 0) self.filas = 1; // evitar underflow en scroll()
        if (self.cols == 0) self.cols = 1;
        self.cx = 0;
        self.cy = 0;
    }

    /// Consola a pantalla completa (fase de arranque, antes de la GUI).
    pub fn regionPantalla(self: *Consola) void {
        self.region(0, 0, pantalla.anchoPix(), pantalla.altoPix());
    }

    pub fn limpiar(self: *Consola) void {
        self.llenar(' ');
        self.redibujar();
        self.cx = 0;
        self.cy = 0;
    }

    fn llenar(self: *Consola, car: u8) void {
        for (0..self.filas) |f| {
            for (0..self.cols) |c| {
                self.celdas[f][c] = .{ .car = car, .estilo = self.actual };
            }
        }
    }

    pub fn fijarEstilo(self: *Consola, e: Estilo) void {
        self.actual = self.indiceEstilo(e);
    }

    pub fn estiloActual(self: *Consola) Estilo {
        return self.estilos[self.actual];
    }

    pub fn columnas(self: *const Consola) u32 {
        return self.cols;
    }

    pub fn cuentaFilas(self: *const Consola) u32 {
        return self.filas;
    }

    pub fn posicion(self: *const Consola) struct { x: u32, y: u32 } {
        return .{ .x = self.cx, .y = self.cy };
    }

    fn scroll(self: *Consola) void {
        // rejilla: mover filas hacia arriba
        var f: u32 = 0;
        while (f < self.filas - 1) : (f += 1) {
            @memcpy(self.celdas[f][0..self.cols], self.celdas[f + 1][0..self.cols]);
        }
        for (0..self.cols) |c| self.celdas[self.filas - 1][c] = .{ .car = ' ', .estilo = self.actual };
        // framebuffer: copiar píxel a píxel (direcciones más bajas)
        var y: u32 = 1;
        while (y < self.filas) : (y += 1) {
            self.copiarFila(y, y - 1);
        }
        pantalla.rect(self.ox, self.oy + (self.filas - 1) * fuente.ALTO, self.cols * fuente.ANCHO, fuente.ALTO, self.estilos[self.celdas[self.filas - 1][0].estilo].fondo);
    }

    fn copiarFila(self: *Consola, desde: u32, hacia: u32) void {
        const paso = pantalla.pasoBytes() / 4;
        const fb: [*]volatile u32 = @ptrFromInt(pantalla.direccion());
        const ancho_total = pantalla.anchoPix();
        var ancho_px = self.cols * fuente.ANCHO;
        if (self.ox + ancho_px > ancho_total) ancho_px = ancho_total -| self.ox;
        const y_ori = self.oy + desde * fuente.ALTO;
        const y_dst = self.oy + hacia * fuente.ALTO;
        if (y_ori >= pantalla.altoPix() or y_dst >= pantalla.altoPix() or ancho_px == 0) return;
        const filas_px = @min(fuente.ALTO, pantalla.altoPix() -| @max(y_ori, y_dst));
        var fila: u32 = 0;
        while (fila < filas_px) : (fila += 1) {
            const src = fb + @as(usize, y_ori + fila) * paso + self.ox;
            const dst = fb + @as(usize, y_dst + fila) * paso + self.ox;
            var i: u32 = 0;
            while (i < ancho_px) : (i += 1) dst[i] = src[i];
        }
    }

    fn borrarCursor(self: *Consola) void {
        if (!self.cursor_visible) return;
        const px = self.ox + self.cx * fuente.ANCHO;
        const py = self.oy + self.cy * fuente.ALTO;
        pantalla.rect(px, py, fuente.ANCHO, fuente.ALTO, self.estilos[self.actual].fondo);
    }

    fn pintarCursor(self: *Consola) void {
        if (!self.cursor_visible) return;
        const px = self.ox + self.cx * fuente.ANCHO;
        const py = self.oy + self.cy * fuente.ALTO;
        pantalla.rect(px, py + fuente.ALTO - 2, fuente.ANCHO, 2, COLOR_CURSOR);
    }

    pub fn putc(self: *Consola, c: u8) void {
        self.borrarCursor();
        switch (c) {
            '\n' => {
                self.cx = 0;
                self.cy += 1;
            },
            '\r' => self.cx = 0,
            8 => { // retroceso
                if (self.cx > 0) self.cx -= 1;
                self.celdas[self.cy][self.cx] = .{ .car = ' ', .estilo = self.actual };
                const px = self.ox + self.cx * fuente.ANCHO;
                const py = self.oy + self.cy * fuente.ALTO;
                pantalla.rect(px, py, fuente.ANCHO, fuente.ALTO, self.estilos[self.actual].fondo);
            },
            '\t' => {
                const salto = 8 - (self.cx % 8);
                var i: u32 = 0;
                while (i < salto) : (i += 1) self.putc(' ');
                return;
            },
            else => {
                self.celdas[self.cy][self.cx] = .{ .car = c, .estilo = self.actual };
                const px = self.ox + self.cx * fuente.ANCHO;
                const py = self.oy + self.cy * fuente.ALTO;
                fuente.dibujar(px, py, c, self.estilos[self.actual].tinta, self.estilos[self.actual].fondo, 1);
                self.cx += 1;
                if (self.cx >= self.cols) {
                    self.cx = 0;
                    self.cy += 1;
                }
            },
        }
        if (self.cy >= self.filas) {
            self.scroll();
            self.cy = self.filas - 1;
        }
        self.pintarCursor();
    }

    pub fn puts(self: *Consola, cadena: []const u8) void {
        for (cadena) |c| self.putc(c);
    }

    /// Redibuja TODA la región desde la rejilla (tras tapar/destapar).
    pub fn redibujar(self: *Consola) void {
        pantalla.rect(self.ox, self.oy, self.cols * fuente.ANCHO, self.filas * fuente.ALTO, self.estilos[0].fondo);
        var f: u32 = 0;
        while (f < self.filas) : (f += 1) {
            var c: u32 = 0;
            while (c < self.cols) : (c += 1) {
                const celda = self.celdas[f][c];
                if (celda.car == ' ') continue; // el fondo ya está puesto
                const e = self.estilos[celda.estilo];
                fuente.dibujar(self.ox + c * fuente.ANCHO, self.oy + f * fuente.ALTO, celda.car, e.tinta, e.fondo, 1);
            }
        }
        self.pintarCursor();
    }

    /// Texto de una fila de la rejilla (para pruebas e inspección).
    pub fn filaTexto(self: *const Consola, f: u32, buf: []u8) []const u8 {
        if (f >= self.filas) return buf[0..0];
        const n = @min(self.cols, buf.len);
        for (0..n) |c| buf[c] = self.celdas[f][c].car;
        return buf[0..n];
    }
};

// ---------------------------------------------------------------------------
// instancia por defecto (pantalla completa hasta que la GUI la recoloca)
// ---------------------------------------------------------------------------

var defecto = Consola{};

pub fn init() void {
    defecto = .{};
    defecto.regionPantalla();
    defecto.fijarEstilo(.{ .tinta = COLOR_TEXTO, .fondo = FONDO_DEF });
    defecto.limpiar();
}

/// Acceso a la instancia por defecto (la usa la GUI para redibujar el
/// panel TERMINAL). `defecto` es module-level: dirección fija aunque init()
/// la reasigne por valor.
pub fn instancia() *Consola {
    return &defecto;
}

pub fn limpiar() void {
    defecto.limpiar();
}

pub fn reubicar(x: u32, y: u32, an_pix: u32, al_pix: u32) void {
    defecto.region(x, y, an_pix, al_pix);
}

pub fn fijarEstilo(e: Estilo) void {
    defecto.fijarEstilo(e);
}

pub fn estiloActual() Estilo {
    return defecto.estiloActual();
}

pub fn columnas() u32 {
    return defecto.columnas();
}

pub fn filas() u32 {
    return defecto.cuentaFilas();
}

pub fn posicion() struct { x: u32, y: u32 } {
    return defecto.posicion();
}

pub fn putc(c: u8) void {
    defecto.putc(c);
}

pub fn puts(cadena: []const u8) void {
    defecto.puts(cadena);
}

pub fn redibujar() void {
    defecto.redibujar();
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
    const x = defecto.ox + (defecto.cols * fuente.ANCHO - @min(an, defecto.cols * fuente.ANCHO)) / 2;
    const y = defecto.oy + fila * fuente.ALTO;
    for (texto, 0..) |c, i| {
        fuente.dibujar(x + @as(u32, @intCast(i)) * fuente.ANCHO * escala, y, c, color, null, escala);
    }
}
