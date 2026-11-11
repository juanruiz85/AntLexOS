//! AntLex OS — reloj de tiempo real (RTC del CMOS).
//! Lectura por sondeo con espera del ciclo de actualización (UIP),
//! conversión BCD/binaria, formatos 12/24 h y siglo del registro 0x32.
//! Sin IRQ8: se lee bajo demanda (comandos fecha, hora y sistema).

const std = @import("std");
const x86 = @import("x86.zig");

pub const FechaHora = struct {
    anio: u16,
    mes: u8, // 1..12
    dia: u8, // 1..31
    hora: u8, // 0..23
    min: u8, // 0..59
    seg: u8, // 0..59

    /// Día de la semana (0=domingo … 6=sábado) por congruencia de Zeller.
    /// Comprobado con 1970-01-01 (jueves) y 2000-01-01 (sábado).
    pub fn diaSemana(self: FechaHora) u8 {
        const q: i32 = self.dia;
        var m: i32 = self.mes;
        var anio: i32 = self.anio;
        if (m < 3) {
            m += 12;
            anio -= 1;
        }
        const k = @mod(anio, 100);
        const j = @divTrunc(anio, 100);
        const h = @mod(q + @divTrunc(13 * (m + 1), 5) + k + @divTrunc(k, 4) + @divTrunc(j, 4) + 5 * j, 7);
        // Zeller: h=0 es sábado, 1 domingo … 6 viernes → 0=domingo
        return @intCast(@mod(h + 6, 7));
    }
};

pub const MESES = [_][]const u8{
    "enero", "febrero", "marzo",      "abril",   "mayo",      "junio",
    "julio", "agosto",  "septiembre", "octubre", "noviembre", "diciembre",
};

pub const DIAS = [_][]const u8{
    "domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado",
};

fn leerReg(n: u8) u8 {
    x86.outb(0x70, n | 0x80); // NMI desactivada durante la selección
    return x86.inb(0x71);
}

fn deBcd(v: u8, binario: bool) u8 {
    if (binario) return v;
    return (v & 0x0F) + ((v >> 4) * 10);
}

/// Espera (acotada) a que el RTC no esté en mitad de una actualización.
fn esperarEstable() void {
    var intentos: u32 = 0;
    while (leerReg(0x0A) & 0x80 != 0 and intentos < 100_000) intentos += 1;
}

/// Lee fecha y hora del CMOS. Si el registro de siglo no existe o devuelve
/// basura, se asume el siglo 21 (válido para 2000-2099).
pub fn leer() FechaHora {
    esperarEstable();
    const reg_b = leerReg(0x0B);
    const binario = reg_b & 0x04 != 0;
    const h24 = reg_b & 0x02 != 0;

    const seg = deBcd(leerReg(0x00), binario);
    const min = deBcd(leerReg(0x02), binario);
    const hora_crudo = leerReg(0x04);
    const dia = deBcd(leerReg(0x07), binario);
    const mes = deBcd(leerReg(0x08), binario);
    const anio2 = deBcd(leerReg(0x09), binario);
    const siglo = deBcd(leerReg(0x32), binario);

    var hora = deBcd(hora_crudo & 0x7F, binario);
    if (!h24) {
        if (hora_crudo & 0x80 != 0) { // PM
            if (hora != 12) hora = @intCast(@as(u16, hora) + 12);
        } else if (hora == 12) {
            hora = 0; // 12 AM
        }
    }

    var anio: u16 = @as(u16, siglo) * 100 + anio2;
    if (anio < 2000 or anio > 2099) anio = 2000 + @as(u16, anio2);
    // saneo defensivo: un CMOS con batería agotada puede devolver 0 o basura
    // en mes/día/hora; sin esto, MESES[mes-1] underflowearía (pánico).
    const mes_ok: u8 = if (mes < 1) 1 else if (mes > 12) 12 else mes;
    const dia_ok: u8 = if (dia < 1) 1 else if (dia > 31) 31 else dia;
    return .{
        .anio = anio,
        .mes = mes_ok,
        .dia = dia_ok,
        .hora = if (hora > 23) 23 else hora,
        .min = if (min > 59) 59 else min,
        .seg = if (seg > 59) 59 else seg,
    };
}

/// "AAAA-MM-DD HH:MM:SS"
pub fn iso(f: FechaHora, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        f.anio, f.mes, f.dia, f.hora, f.min, f.seg,
    }) catch buf[0..0];
}

/// "jueves 11 de noviembre de 2026"
pub fn textoLargo(f: FechaHora, buf: []u8) []const u8 {
    const dia = DIAS[@min(f.diaSemana(), 6)];
    const mes = MESES[@min(@max(f.mes, 1), 12) - 1];
    return std.fmt.bufPrint(buf, "{s} {d} de {s} de {d}", .{ dia, f.dia, mes, f.anio }) catch buf[0..0];
}

/// "HH:MM:SS"
pub fn textoHora(f: FechaHora, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ f.hora, f.min, f.seg }) catch buf[0..0];
}

/// Tiempo encendido: "45s", "12m 03s" o "3h 24m 11s".
pub fn textoUptime(seg: u64, buf: []u8) []const u8 {
    if (seg < 60) {
        return std.fmt.bufPrint(buf, "{d}s", .{seg}) catch buf[0..0];
    } else if (seg < 3600) {
        return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ seg / 60, seg % 60 }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}h {d:0>2}m {d:0>2}s", .{ seg / 3600, (seg % 3600) / 60, seg % 60 }) catch buf[0..0];
}

/// ¿Es una fecha razonable? (la usa la autoprueba del arranque)
pub fn valida(f: FechaHora) bool {
    return f.anio >= 2020 and f.anio <= 2099 and
        f.mes >= 1 and f.mes <= 12 and
        f.dia >= 1 and f.dia <= 31 and
        f.hora < 24 and f.min < 60 and f.seg < 60;
}

// ---------------------------------------------------------------------------
// pruebas (corren en host con `zig build test`)
// ---------------------------------------------------------------------------

const expectEqual = @import("std").testing.expectEqual;

test "reloj: Zeller — 1970-01-01 fue jueves" {
    const f = FechaHora{ .anio = 1970, .mes = 1, .dia = 1, .hora = 0, .min = 0, .seg = 0 };
    try expectEqual(@as(u8, 4), f.diaSemana()); // 0=dom … 4=jueves
}

test "reloj: Zeller — 2000-01-01 fue sábado" {
    const f = FechaHora{ .anio = 2000, .mes = 1, .dia = 1, .hora = 0, .min = 0, .seg = 0 };
    try expectEqual(@as(u8, 6), f.diaSemana());
}

test "reloj: Zeller — 2026-11-11 es miércoles" {
    const f = FechaHora{ .anio = 2026, .mes = 11, .dia = 11, .hora = 12, .min = 0, .seg = 0 };
    try expectEqual(@as(u8, 3), f.diaSemana()); // 0=dom … 3=miércoles
}

test "reloj: formatos iso/largo/hora/uptime" {
    const f = FechaHora{ .anio = 2026, .mes = 11, .dia = 11, .hora = 9, .min = 5, .seg = 3 };
    var buf: [64]u8 = undefined;
    try @import("std").testing.expectEqualStrings("2026-11-11 09:05:03", iso(f, &buf));
    try @import("std").testing.expectEqualStrings("miércoles 11 de noviembre de 2026", textoLargo(f, &buf));
    try @import("std").testing.expectEqualStrings("09:05:03", textoHora(f, &buf));
    try @import("std").testing.expectEqualStrings("45s", textoUptime(45, &buf));
    try @import("std").testing.expectEqualStrings("2m 05s", textoUptime(125, &buf));
    try @import("std").testing.expectEqualStrings("3h 02m 05s", textoUptime(3 * 3600 + 125, &buf));
    try @import("std").testing.expect(valida(f));
}

test "reloj: saneo de mes 0 no hace pánico (regresión H-1 REV-FASE3)" {
    // un CMOS con batería agotada puede dar mes 0: el índice seguro con
    // @max lo recorta y textoLargo no debe underflowear
    const mala = FechaHora{ .anio = 2026, .mes = 0, .dia = 0, .hora = 0, .min = 0, .seg = 0 };
    var buf: [64]u8 = undefined;
    _ = textoLargo(mala, &buf); // sin pánico = pasada
    _ = iso(mala, &buf);
}
