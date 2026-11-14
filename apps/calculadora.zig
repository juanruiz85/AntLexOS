//! AntLex OS — apps/calculadora.zig: primera aplicación externa `.ALX`
//! (Fase 7). Se compila como ELF freestanding enlazado en 16 MiB y se
//! convierte a CALC.ALX con tools/mkalx.zig; el kernel la carga con
//! `ejecutar` o desde el explorador (doble clic).
//!
//! La lógica del cálculo es PURA (struct Calc + calcTecla) y se prueba en
//! el host desde src/tests.zig; la capa ALX (eventos + dibujo) es fina.

const std = @import("std");
const alx = @import("alx_def");

// ---------------------------------------------------------------------------
// Lógica pura de la calculadora (enteros de 64 bits, cadena a la izquierda)
// ---------------------------------------------------------------------------

pub const MAX_DIGITOS = 12;

pub const Calc = struct {
    entrada: i64 = 0, // número en curso
    entrada_len: u8 = 0, // dígitos tecleados (0 = sin entrada)
    acumulador: i64 = 0, // primer operando / último resultado
    operador: u8 = 0, // '+', '-', '*', '/' o 0
    mostrando_resultado: bool = false,
    es_error: bool = false, // E (desbordamiento o división por cero)
    // última evaluación completa ("12 + 34 = 46"), para la consola y trazas
    ultimo: [64]u8 = .{0} ** 64,
    ultimo_len: u8 = 0,
};

pub const CalcEvento = enum { nada, digito, operador, evaluada, err, limpia };

pub fn ultimoStr(c: *const Calc) []const u8 {
    return c.ultimo[0..c.ultimo_len];
}

/// Guarda "a op b = r" (o "= E") tras evaluar.
fn recordarEval(c: *Calc, a: i64, op: u8, b: i64) void {
    const txt = if (c.es_error)
        std.fmt.bufPrint(&c.ultimo, "{d} {c} {d} = E", .{ a, op, b }) catch return
    else if (op != 0)
        std.fmt.bufPrint(&c.ultimo, "{d} {c} {d} = {d}", .{ a, op, b, c.acumulador }) catch return
    else
        std.fmt.bufPrint(&c.ultimo, "{d} = {d}", .{ b, c.acumulador }) catch return;
    c.ultimo_len = @intCast(txt.len);
}

fn aplicar(c: *Calc) void {
    const b = c.entrada;
    const r = switch (c.operador) {
        '+' => std.math.add(i64, c.acumulador, b),
        '-' => std.math.sub(i64, c.acumulador, b),
        '*' => std.math.mul(i64, c.acumulador, b),
        '/' => if (b == 0) error.DivisionPorCero else std.math.divTrunc(i64, c.acumulador, b),
        else => c.acumulador,
    } catch {
        c.es_error = true;
        return;
    };
    c.acumulador = r;
}

/// Procesa una tecla. Tras `evaluada`, `ultimo_texto` describe la operación.
pub fn calcTecla(c: *Calc, k: u8) CalcEvento {
    if (c.es_error) {
        if (k == 'c' or k == 'C') {
            c.* = .{};
            return .limpia;
        }
        return .nada;
    }
    switch (k) {
        '0'...'9' => {
            if (c.mostrando_resultado) c.* = .{}; // nueva operación tras =
            if (c.entrada_len < MAX_DIGITOS and c.entrada <= 100_000_000_000) {
                c.entrada = c.entrada * 10 + (k - '0');
                c.entrada_len += 1;
            }
            return .digito;
        },
        '+', '-', '*', '/' => {
            if (c.entrada_len > 0) {
                if (c.operador != 0) {
                    aplicar(c); // encadena: 2 + 3 * → 5 *
                    if (c.es_error) return .err;
                } else {
                    c.acumulador = c.entrada;
                }
                c.entrada = 0;
                c.entrada_len = 0;
            }
            // sin entrada: seguir con el acumulador (resultado previo o 0)
            c.mostrando_resultado = false;
            c.operador = k;
            return .operador;
        },
        '=', '\n' => {
            if (c.operador != 0 and c.entrada_len > 0) {
                const a0 = c.acumulador;
                const b0 = c.entrada;
                const op0 = c.operador;
                aplicar(c);
                c.operador = 0;
                c.entrada = 0;
                c.entrada_len = 0;
                c.mostrando_resultado = true;
                recordarEval(c, a0, op0, b0);
                return if (c.es_error) .err else .evaluada;
            }
            if (c.operador == 0 and c.entrada_len > 0) {
                c.acumulador = c.entrada; // "42 =" → 42
                const b0 = c.entrada;
                c.entrada = 0;
                c.entrada_len = 0;
                c.mostrando_resultado = true;
                recordarEval(c, 0, 0, b0);
                return .evaluada;
            }
            return .nada;
        },
        'c', 'C' => {
            c.* = .{};
            return .limpia;
        },
        8 => { // retroceso: borra el último dígito
            if (c.entrada_len > 0) {
                c.entrada = @divTrunc(c.entrada, 10);
                c.entrada_len -= 1;
            }
            return .digito;
        },
        else => return .nada,
    }
}

/// Lo que muestra la línea principal (entrada en curso / resultado / E).
pub fn calcDisplay(c: *const Calc, buf: []u8) []const u8 {
    if (c.es_error) return "E";
    const v = if (c.mostrando_resultado or c.entrada_len == 0) c.acumulador else c.entrada;
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "E";
}

/// Expresión pendiente ("12 + " o "12 + 34 = 46" tras evaluar).
pub fn calcExpresion(c: *const Calc, buf: []u8) []const u8 {
    if (c.operador != 0) {
        return std.fmt.bufPrint(buf, "{d} {c} ", .{ c.acumulador, c.operador }) catch "";
    }
    if (c.mostrando_resultado) {
        return std.fmt.bufPrint(buf, "= {d}", .{c.acumulador}) catch "";
    }
    return "";
}

// ---------------------------------------------------------------------------
// Pruebas en host (también las ejecuta src/tests.zig vía módulo calc_app)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn escribir(c: *Calc, s: []const u8) void {
    for (s) |k| _ = calcTecla(c, k);
}

test "calculadora: suma, multiplicación y cadena a la izquierda" {
    var c = Calc{};
    escribir(&c, "12+34=");
    try testing.expectEqual(@as(i64, 46), c.acumulador);
    try testing.expect(c.mostrando_resultado);
    try testing.expectEqualStrings("12 + 34 = 46", ultimoStr(&c));

    // encadenar con el resultado: + 1 =
    escribir(&c, "+1=");
    try testing.expectEqual(@as(i64, 47), c.acumulador);

    // cadena clásica: 2 + 3 * 4 = 20 (se evalúa al teclear el operador)
    var d = Calc{};
    escribir(&d, "2+3*4=");
    try testing.expectEqual(@as(i64, 20), d.acumulador);
}

test "calculadora: división entera, por cero y recuperación con C" {
    var c = Calc{};
    escribir(&c, "7/2=");
    try testing.expectEqual(@as(i64, 3), c.acumulador);

    escribir(&c, "5/0=");
    try testing.expect(c.es_error);
    try testing.expectEqualStrings("5 / 0 = E", ultimoStr(&c));
    try testing.expectEqualStrings("E", calcDisplay(&c, undefined));
    // cualquier tecla se ignora en error salvo C
    try testing.expectEqual(CalcEvento.nada, calcTecla(&c, '5'));
    try testing.expectEqual(CalcEvento.limpia, calcTecla(&c, 'c'));
    try testing.expectEqual(@as(i64, 0), c.acumulador);

    var m = Calc{};
    escribir(&m, "0-8=");
    try testing.expectEqual(@as(i64, -8), m.acumulador);
}

test "calculadora: retroceso, límites y = sin operador" {
    var c = Calc{};
    escribir(&c, "12");
    _ = calcTecla(&c, 8); // borrar → 1
    try testing.expectEqual(@as(i64, 1), c.entrada);
    try testing.expectEqual(@as(u8, 1), c.entrada_len);

    var d = Calc{};
    escribir(&d, "42=");
    try testing.expectEqual(@as(i64, 42), d.acumulador);
    try testing.expect(d.mostrando_resultado);

    // más de 12 dígitos: se ignoran los extra
    var e = Calc{};
    escribir(&e, "999999999999999"); // 15 dígitos
    try testing.expectEqual(@as(u8, MAX_DIGITOS), e.entrada_len);
    try testing.expectEqual(@as(i64, 999999999999), e.entrada);
}

// ---------------------------------------------------------------------------
// Capa ALX: eventos y dibujo (corre dentro del kernel, ring 0)
// ---------------------------------------------------------------------------

const C_FONDO = alx.rgb(0x10, 0x16, 0x20);
const C_TINTA = alx.rgb(0x9A, 0xAA, 0xBC);
const C_VERDE = alx.rgb(0x7F, 0xDB, 0x8A);
const C_ACENTO = alx.rgb(0x5B, 0x9B, 0xF0);

var calc = Calc{};
var api_actual: ?*const alx.Api = null;

pub fn panic(mensaje: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    // sin aislamiento (ring 0): una pánica detiene el sistema; documentado
    // en la auditoría REV-v1.2.0. Al menos dejamos rastro por la consola.
    if (api_actual) |a| {
        var buf: [96]u8 = .{0} ** 96;
        const pre = "calculadora: PANICA: ";
        const l = @min(mensaje.len, buf.len - pre.len - 2);
        @memcpy(buf[0..pre.len], pre);
        @memcpy(buf[pre.len..][0..l], mensaje[0..l]);
        buf[pre.len + l] = '\n';
        a.consola(@ptrCast(&buf));
    }
    while (true) {}
}

/// Convierte un slice a [*:0] sobre un búfer propio (la API usa cadenas C).
fn z(buf: []u8, s: []const u8) [*:0]const u8 {
    const l = @min(s.len, buf.len - 1);
    @memcpy(buf[0..l], s[0..l]);
    buf[l] = 0;
    return @ptrCast(buf.ptr);
}

/// Igual, pero para un slice que YA vive dentro de `buf` (evita el
/// alias de @memcpy: los formateadores devuelven slices del búfer).
fn zEn(buf: []u8, s: []const u8) [*:0]const u8 {
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

export fn alx_evento(api: *const alx.Api, ev: *const alx.Evento) callconv(.c) void {
    api_actual = api;
    switch (ev.tipo) {
        alx.EV_INIT => {
            api.titulo("Calculadora");
            api.tam(280, 190);
        },
        alx.EV_TECLA => {
            const r = calcTecla(&calc, ev.tecla);
            if (r == .evaluada or r == .err) {
                var linea: [128]u8 = .{0} ** 128;
                const escrito = std.fmt.bufPrint(&linea, "calculadora: {s}\n", .{ultimoStr(&calc)}) catch return;
                linea[escrito.len] = 0;
                api.consola(@ptrCast(&linea));
            }
        },
        alx.EV_DIBUJAR => {
            api.rect(0, 0, ev.an, ev.al, C_FONDO);
            api.bisel(6, 6, @intCast(@as(i32, @intCast(ev.an)) - 12), 48, true);
            var buf: [32]u8 = undefined;
            api.texto(14, 12, zEn(&buf, calcDisplay(&calc, &buf)), if (calc.es_error) alx.rgb(0xFF, 0x6E, 0x6E) else C_VERDE);
            var buf2: [48]u8 = undefined;
            api.texto(14, 34, zEn(&buf2, calcExpresion(&calc, &buf2)), C_TINTA);
            var buf3: [64]u8 = undefined;
            api.texto(6, @intCast(@as(i32, @intCast(ev.al)) - 18), z(&buf3, "0-9  + - * /   INTRO evalua   C limpia"), C_TINTA);
        },
        alx.EV_TICK => {}, // no hay nada periódico que hacer
        alx.EV_CERRAR => {},
        else => {},
    }
}
