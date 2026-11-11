//! AntLex OS — framebuffer VBE/UEFI: primitivas de dibujo 32 bpp.

const boot_info = @import("boot_info.zig");

/// Color 0x00RRGGBB. El framebuffer de QEMU/BIOS (VBE) es BGR en memoria,
/// que coincide con este valor little-endian; si el firmware UEFI entrega
/// GOP con orden RGB se activa el intercambio en init().
pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

inline fn ajustar(color: u32) u32 {
    if (!intercambio_rgb) return color;
    // intercambiar canales R y B (GOP con orden RGB)
    return (color & 0xFF00FF00) | ((color & 0x000000FF) << 16) | ((color & 0x00FF0000) >> 16);
}

pub const ANCHO_MIN = 640;
pub const ALTO_MIN = 480;

var fb: [*]volatile u32 = undefined;
var ancho: u32 = 0;
var alto: u32 = 0;
var paso: u32 = 0; // bytes por línea
var bpp: u32 = 0;
var intercambio_rgb: bool = false; // GOP con orden RGB en vez de BGR (UEFI)

pub const PantallaError = error{ SinFramebuffer, ModoInvalido };

pub fn init(bi: *const boot_info.BootInfo) PantallaError!void {
    if (bi.fb_addr == 0) return PantallaError.SinFramebuffer;
    if (bi.fb_bpp != 32) return PantallaError.ModoInvalido;
    if (bi.fb_w < ANCHO_MIN or bi.fb_h < ALTO_MIN) return PantallaError.ModoInvalido;
    if (bi.fb_w > 16384 or bi.fb_h > 16384) return PantallaError.ModoInvalido;
    // producto en 64 bits para no desbordar con geometrías absurdas
    if (@as(u64, bi.fb_pitch) < @as(u64, bi.fb_w) * 4) return PantallaError.ModoInvalido;
    fb = @ptrFromInt(bi.fb_addr);
    ancho = bi.fb_w;
    alto = bi.fb_h;
    paso = bi.fb_pitch;
    bpp = bi.fb_bpp;
    intercambio_rgb = (bi.reserved & 1) != 0; // bit0: GOP en orden RGB
}

pub fn anchoPix() u32 {
    return ancho;
}

pub fn altoPix() u32 {
    return alto;
}

pub fn pasoBytes() u32 {
    return paso;
}

pub fn direccion() usize {
    return @intFromPtr(fb);
}

pub inline fn pixel(x: u32, y: u32, color: u32) void {
    if (x >= ancho or y >= alto) return;
    fb[@as(usize, y) * (paso / 4) + x] = ajustar(color);
}

pub fn rect(x0: u32, y0: u32, an: u32, al: u32, color: u32) void {
    if (an == 0 or al == 0) return;
    const x_fin = @min(x0 + an, ancho);
    const y_fin = @min(y0 + al, alto);
    if (x0 >= ancho or y0 >= alto) return;
    var y = y0;
    while (y < y_fin) : (y += 1) {
        const fila: [*]volatile u32 = fb + @as(usize, y) * (paso / 4);
        var x = x0;
        while (x < x_fin) : (x += 1) fila[x] = ajustar(color);
    }
}

pub fn limpiar(color: u32) void {
    rect(0, 0, ancho, alto, color);
}

/// Rectángulo con borde (para ventanas y paneles).
pub fn rectBorde(x0: u32, y0: u32, an: u32, al: u32, relleno: u32, borde: u32) void {
    rect(x0, y0, an, al, relleno);
    rect(x0, y0, an, 1, borde); // arriba
    rect(x0, y0 + al - 1, an, 1, borde); // abajo
    rect(x0, y0, 1, al, borde); // izquierda
    rect(x0 + an - 1, y0, 1, al, borde); // derecha
}

/// Línea horizontal gruesa.
pub fn hline(x0: u32, x1: u32, y: u32, color: u32) void {
    const a = @min(x0, x1);
    const b = @max(x0, x1);
    rect(a, y, b - a + 1, 1, color);
}

/// Línea vertical.
pub fn vline(x: u32, y0: u32, y1: u32, color: u32) void {
    const a = @min(y0, y1);
    const b = @max(y0, y1);
    rect(x, a, 1, b - a + 1, color);
}
