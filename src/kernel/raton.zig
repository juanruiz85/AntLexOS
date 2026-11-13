//! AntLex OS — driver de ratón PS/2 (Fase 5).
//! Interrupción IRQ12 (esclavo 4), protocolo estándar de 3 bytes con
//! sincronización por el bit 3 del primer byte, coordenadas acumuladas
//! acotadas a pantalla y eventos (mover/pulsar/soltar) en un búfer anillo
//! como el del teclado.
//!
//! La decodificación de paquetes es PURA (`decodificar`, `acotar`) y se
//! prueba en host; el hardware (puertos 0x60/0x64) queda en init()/irq().

const std = @import("std");
const x86 = @import("x86.zig");
const pantalla = @import("pantalla.zig");
const pic = @import("pic.zig");
const teclado = @import("teclado.zig");

pub const Boton = enum(u2) { izq = 0, der = 1, medio = 2 };

pub const TipoEvento = enum { mover, pulsar, soltar };

pub const Evento = struct {
    tipo: TipoEvento,
    boton: Boton = .izq,
    x: u32 = 0,
    y: u32 = 0,
};

/// Decodificación de un paquete PS/2 de 3 bytes.
pub const Movimiento = struct {
    dx: i16, // positivo hacia la derecha
    dy: i16, // positivo hacia ARRIBA (así lo define el protocolo)
    botones: u3,
    desborde: bool, // bit 6/7: el contador se desbordó, paquete inválido
};

// -------------------------------------------------------------------------
// estado del dispositivo
// -------------------------------------------------------------------------

var x: i32 = 0;
var y: i32 = 0;
var botones: u3 = 0;
var paquete: [3]u8 = .{ 0, 0, 0 };
var n_paquete: usize = 0;
var disponible = false;
/// Último paso fallido (diagnóstico por el puerto serie).
pub var fallo_paso: []const u8 = "";

const TAM_BUF = 64;
var buffer: [TAM_BUF]Evento = undefined;
var leido: usize = 0; // volatile: escribe la IRQ, lee el hilo principal
var escrito: usize = 0; // volatile
var desbordamientos: u32 = 0;

// -------------------------------------------------------------------------
// inicialización (secuencia PS/2 estándar con timeouts acotados)
// -------------------------------------------------------------------------

const MAX_ESPERA: u32 = 100_000;

/// Espera a que el controlador pueda aceptar un byte (bit 1 de 0x64 a 0).
fn esperarEntradaLibre() bool {
    var n: u32 = 0;
    while (n < MAX_ESPERA) : (n += 1) {
        if (x86.inb(0x64) & 0x02 == 0) return true;
    }
    return false;
}

/// Espera un byte de salida del controlador (bit 0 de 0x64 a 1).
fn esperarSalida() ?u8 {
    var n: u32 = 0;
    while (n < MAX_ESPERA) : (n += 1) {
        if (x86.inb(0x64) & 0x01 != 0) return x86.inb(0x60);
    }
    return null;
}

/// Espera un byte AUX (bit 5): los ACK del ratón. Los bytes de teclado
/// que aparezcan por el camino se descartan (no son nuestra respuesta).
fn esperarSalidaAux() ?u8 {
    var n: u32 = 0;
    while (n < MAX_ESPERA) : (n += 1) {
        const st = x86.inb(0x64);
        if (st & 0x01 != 0) {
            const b = x86.inb(0x60);
            if (st & 0x20 != 0) return b;
        }
    }
    return null;
}

/// Drena el búfer de salida del controlador (descarta lo pendiente).
fn vaciarSalida() void {
    var n: u32 = 0;
    while (n < 32) : (n += 1) {
        if (x86.inb(0x64) & 0x01 == 0) return;
        _ = x86.inb(0x60);
    }
}

/// Envía un comando al dispositivo auxiliar (0xD4 + byte, espera ACK).
fn enviarComando(cmd: u8) bool {
    if (!esperarEntradaLibre()) return false;
    x86.outb(0x64, 0xD4);
    if (!esperarEntradaLibre()) return false;
    x86.outb(0x60, cmd);
    const ack = esperarSalidaAux() orelse return false;
    return ack == 0xFA;
}

/// Inicializa el ratón. Devuelve false si el controlador no responde
/// (el sistema sigue siendo usable solo con teclado).
pub fn init() bool {
    disponible = false;
    fallo_paso = "";
    x = @intCast(pantalla.anchoPix() / 2);
    y = @intCast(pantalla.altoPix() / 2);
    botones = 0;
    n_paquete = 0;

    // Sección crítica: sin IRQ1 que robe los bytes de respuesta (se llama
    // con interrupciones activas desde la GUI). Al salir se reactivan.
    const if_previo = if (x86.leerFlags() & 0x200 != 0) true else false;
    x86.cli();
    defer if (if_previo) x86.sti();
    vaciarSalida();

    // 1) activar el puerto auxiliar (segundo PS/2)
    if (!esperarEntradaLibre()) {
        fallo_paso = "ctlr ocupado (A8)";
        return false;
    }
    x86.outb(0x64, 0xA8);

    // 2) leer el byte de configuración y activar sus dos IRQ. Si el
    // controlador no contesta, se usa el valor por defecto 0x47 (IRQs de
    // ambos puertos activadas): suficiente para QEMU y hardware común.
    var cfg: u8 = 0x47;
    if (esperarEntradaLibre()) {
        x86.outb(0x64, 0x20);
        if (esperarSalida()) |cfg_leida| cfg = cfg_leida;
    }
    if (!esperarEntradaLibre()) {
        fallo_paso = "ctlr ocupado (60)";
        return false;
    }
    x86.outb(0x64, 0x60);
    if (!esperarEntradaLibre()) {
        fallo_paso = "ctlr ocupado (cfg write)";
        return false;
    }
    x86.outb(0x60, cfg | 0b0000_0011); // IRQ1 + IRQ12

    // 3) valores por defecto e informes de datos
    if (!enviarComando(0xF6)) { // defaults
        fallo_paso = "F6 sin ACK";
        return false;
    }
    if (!enviarComando(0xF4)) { // data reporting on
        fallo_paso = "F4 sin ACK";
        return false;
    }

    disponible = true;
    pic.permitirEsclavo(4); // IRQ12 = pin 4 del esclavo
    return true;
}

pub fn estaDisponible() bool {
    return disponible;
}

pub fn totalDesbordamientos() u32 {
    return desbordamientos;
}

/// Posición actual del cursor (píxeles).
pub fn posicion() struct { x: u32, y: u32 } {
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

// -------------------------------------------------------------------------
// IRQ12: lectura y decodificación de paquetes
// -------------------------------------------------------------------------

/// Manejador de IRQ12. Solo consume bytes AUX (bit 5 del estado).
pub fn irq() void {
    while (x86.inb(0x64) & 0x21 == 0x21) {
        procesarByte(x86.inb(0x60));
    }
    // Si al drenar el ratón quedó un byte de TECLADO pendiente, hay que
    // procesarlo aquí: su IRQ1 ya se disparó (PIC por flanco: no habrá
    // otro canto hasta la siguiente pulsación) y teclado.irq() lo habría
    // dejado atrás al encontrar el bit AUX. Sin esto, teclear mientras
    // se mueve el ratón pierde la primera tecla de la ráfaga.
    if (x86.inb(0x64) & 0x01 != 0) {
        teclado.irq();
    }
}

fn procesarByte(b: u8) void {
    // sincronización: el byte 0 siempre tiene el bit 3 a 1
    if (n_paquete == 0 and (b & 0x08) == 0) return;
    paquete[n_paquete] = b;
    n_paquete += 1;
    if (n_paquete < 3) return;
    n_paquete = 0;

    const mov = decodificar(paquete);
    if (mov.desborde) return; // paquete inválido: se descarta entero

    x = acotar(x + mov.dx, 0, @as(i32, @intCast(pantalla.anchoPix())) - 1);
    y = acotar(y - mov.dy, 0, @as(i32, @intCast(pantalla.altoPix())) - 1);
    const px: u32 = @intCast(x);
    const py: u32 = @intCast(y);

    // eventos de flanco por botón + el movimiento
    const bot: u3 = @intCast(mov.botones);
    if (bot & 1 != botones & 1) empujar(.{ .tipo = if (bot & 1 != 0) .pulsar else .soltar, .boton = .izq, .x = px, .y = py });
    if (bot & 2 != botones & 2) empujar(.{ .tipo = if (bot & 2 != 0) .pulsar else .soltar, .boton = .der, .x = px, .y = py });
    if (bot & 4 != botones & 4) empujar(.{ .tipo = if (bot & 4 != 0) .pulsar else .soltar, .boton = .medio, .x = px, .y = py });
    botones = bot;
    empujar(.{ .tipo = .mover, .x = px, .y = py });
}

/// Decodifica un paquete PS/2 de 3 bytes (PURO, probado en host).
pub fn decodificar(p: [3]u8) Movimiento {
    const dx: i16 = if (p[0] & 0x10 != 0) @as(i16, p[1]) - 256 else @as(i16, p[1]);
    const dy: i16 = if (p[0] & 0x20 != 0) @as(i16, p[2]) - 256 else @as(i16, p[2]);
    return .{
        .dx = dx,
        .dy = dy,
        .botones = @intCast(p[0] & 0x07),
        .desborde = p[0] & 0xC0 != 0,
    };
}

/// Acota v al rango [min, max] (PURO, probado en host).
pub fn acotar(v: i32, min: i32, max: i32) i32 {
    return std.math.clamp(v, min, max);
}

fn empujar(ev: Evento) void {
    const sig = (escrito + 1) % TAM_BUF;
    if (sig == leido) {
        desbordamientos += 1;
        return; // se pierde el evento, nunca se corrompe el búfer
    }
    buffer[escrito] = ev;
    escrito = sig;
}

/// Siguiente evento pendiente (o null).
pub fn poll() ?Evento {
    if (leido == escrito) return null;
    const ev = buffer[leido];
    leido = (leido + 1) % TAM_BUF;
    return ev;
}

// -------------------------------------------------------------------------
// pruebas en host
// -------------------------------------------------------------------------

const testing = std.testing;

test "decodificar: movimientos positivos y negativos" {
    // dx=+10, dy=+5, botón izquierdo
    var m = decodificar(.{ 0x09, 10, 5 });
    try testing.expectEqual(@as(i16, 10), m.dx);
    try testing.expectEqual(@as(i16, 5), m.dy);
    try testing.expectEqual(@as(u3, 1), m.botones);
    try testing.expect(!m.desborde);

    // dx=-30 (0xE2=226-256, signo X), dy=-3 (0xFD=253-256, signo Y)
    m = decodificar(.{ 0x38, 0xE2, 0xFD });
    try testing.expectEqual(@as(i16, -30), m.dx);
    try testing.expectEqual(@as(i16, -3), m.dy);
    try testing.expectEqual(@as(u3, 0), m.botones);

    // tres botones pulsados
    m = decodificar(.{ 0x0F, 0, 0 });
    try testing.expectEqual(@as(u3, 7), m.botones);
}

test "decodificar: desbordes señalados" {
    try testing.expect(decodificar(.{ 0x48, 1, 1 }).desborde); // bit 6
    try testing.expect(decodificar(.{ 0x88, 1, 1 }).desborde); // bit 7
    try testing.expect(!decodificar(.{ 0x08, 1, 1 }).desborde);
}

test "acotar mantiene el cursor en pantalla" {
    try testing.expectEqual(@as(i32, 0), acotar(-25, 0, 1023));
    try testing.expectEqual(@as(i32, 1023), acotar(4096, 0, 1023));
    try testing.expectEqual(@as(i32, 512), acotar(512, 0, 1023));
}
