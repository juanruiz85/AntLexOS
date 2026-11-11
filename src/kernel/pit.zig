//! AntLex OS — PIT 8253/8254: tics del sistema a 100 Hz.

const x86 = @import("x86.zig");

pub const FRECUENCIA: u32 = 100; // tics por segundo
const DIVISOR: u32 = 1193182 / FRECUENCIA; // 11931

pub var tics: u64 = 0; // volatile: la escribe la IRQ0 y la lee el hilo principal

pub fn init() void {
    x86.outb(0x43, 0x36); // canal 0, modo 3 (onda cuadrada), lobyte/hibyte
    x86.outb(0x40, @truncate(DIVISOR));
    x86.outb(0x40, @truncate(DIVISOR >> 8));
}

pub fn tick() void {
    @atomicStore(u64, &tics, @atomicLoad(u64, &tics, .acquire) + 1, .release);
}

/// Tics actuales (lectura segura desde el hilo principal).
pub fn leerTics() u64 {
    return @atomicLoad(u64, &tics, .acquire);
}

/// Segundos desde el arranque (aproximado).
pub fn uptimeSeg() u64 {
    return leerTics() / FRECUENCIA;
}

/// Milisegundos desde el arranque (aproximado).
pub fn uptimeMs() u64 {
    return leerTics() * (1000 / FRECUENCIA);
}

/// Espera activa de n tics (uso: animaciones de arranque).
pub fn esperaTics(n: u64) void {
    const objetivo = leerTics() + n;
    while (leerTics() < objetivo) {
        x86.hlt();
    }
}
