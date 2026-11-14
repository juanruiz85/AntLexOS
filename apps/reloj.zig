//! AntLex OS — apps/reloj.zig: app externa `.ALX` (Fase 7) que muestra la
//! hora del RTC del sistema (vía `api.hora()`) y el tiempo de encendido.
//! Demuestra EV_TICK (redibujo por segundo) y el título dinámico.

const std = @import("std");
const alx = @import("alx_def");

const C_FONDO = alx.rgb(0x10, 0x16, 0x20);
const C_TINTA = alx.rgb(0x9A, 0xAA, 0xBC);
const C_ACENTO = alx.rgb(0x5B, 0x9B, 0xF0);

var api_actual: ?*const alx.Api = null;

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    if (api_actual) |a| _ = a.consola("reloj: PANICA\n");
    while (true) {}
}

fn z(buf: []u8, s: []const u8) [*:0]const u8 {
    const l = @min(s.len, buf.len - 1);
    @memcpy(buf[0..l], s[0..l]);
    buf[l] = 0;
    return @ptrCast(buf.ptr);
}

/// Como `z`, pero para slices ya formateados dentro de `buf` (sin copia
/// que alias con @memcpy).
fn zEn(buf: []u8, s: []const u8) [*:0]const u8 {
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

export fn alx_evento(api: *const alx.Api, ev: *const alx.Evento) callconv(.c) void {
    api_actual = api;
    switch (ev.tipo) {
        alx.EV_INIT => {
            api.titulo("Reloj");
            api.tam(230, 120);
        },
        alx.EV_TECLA => {}, // el reloj no usa teclas
        alx.EV_DIBUJAR => { // (el GUI redibuja tras cada EV_TICK)
            const h = api.hora();
            const hh = h / 10000;
            const mm = (h / 100) % 100;
            const ss = h % 100;
            const encendido = api.tics() / 100; // segundos desde el arranque

            api.rect(0, 0, ev.an, ev.al, C_FONDO);
            api.bisel(6, 6, @intCast(@as(i32, @intCast(ev.an)) - 12), 44, true);
            var buf: [32]u8 = undefined;
            const hora_txt = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }) catch "??:??:??";
            api.texto(18, 14, zEn(&buf, hora_txt), C_ACENTO);

            var buf2: [48]u8 = undefined;
            const up_txt = std.fmt.bufPrint(&buf2, "encendido: {d:0>2}:{d:0>2}", .{
                encendido / 60,
                encendido % 60,
            }) catch "";
            api.texto(14, 58, zEn(&buf2, up_txt), C_TINTA);
            api.texto(6, @intCast(@as(i32, @intCast(ev.al)) - 18), "la hora vive del reloj del sistema", C_TINTA);
        },
        alx.EV_CERRAR => {},
        else => {},
    }
}
