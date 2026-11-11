//! AntLex OS — driver UART 16550 (COM1) para depuración y pruebas.
//! Todos los selftests del sistema vuelcan su resultado por aquí.

const x86 = @import("x86.zig");

pub const PUERTO: u16 = 0x3F8; // COM1

var listo = false;

pub fn init() void {
    // 115200 baudios, 8N1, FIFO activada
    x86.outb(PUERTO + 1, 0x00); // sin interrupciones
    x86.outb(PUERTO + 3, 0x80); // DLAB on
    x86.outb(PUERTO + 0, 0x01); // divisor = 1
    x86.outb(PUERTO + 1, 0x00);
    x86.outb(PUERTO + 3, 0x03); // 8 bits, sin paridad, 1 stop
    x86.outb(PUERTO + 2, 0xC7); // FIFO activada, limpia, 14 bytes
    x86.outb(PUERTO + 4, 0x03); // DTR + RTS
    listo = true;
}

pub fn put(car: u8) void {
    if (!listo) return;
    // esperar a que el transmisor esté vacío (LSR bit 5)
    var limite: u32 = 0;
    while (x86.inb(PUERTO + 5) & 0x20 == 0) {
        limite += 1;
        if (limite > 1_000_000) return; // no bloquearse para siempre
    }
    x86.outb(PUERTO, car);
}

pub fn puts(cadena: []const u8) void {
    for (cadena) |c| {
        if (c == '\n') put('\r');
        put(c);
    }
}

/// Alias de put() para homogeneidad con consola.putc.
pub fn putc(c: u8) void {
    put(c);
}

pub fn putHex(valor: u64) void {
    const digitos = "0123456789ABCDEF";
    var i: u7 = 64;
    puts("0x");
    while (i > 0) {
        i -= 4;
        put(digitos[(valor >> @as(u6, @intCast(i))) & 0xF]);
    }
}

pub fn putDec(valor: u64) void {
    var buf: [24]u8 = undefined;
    var i: usize = buf.len;
    var v = valor;
    if (v == 0) {
        put('0');
        return;
    }
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    puts(buf[i..]);
}
