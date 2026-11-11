//! AntLex OS — PIC 8259 remapeado a los vectores 32..47.

const x86 = @import("x86.zig");

pub fn init() void {
    // cascada, ICW4 necesaria
    x86.outb(0x20, 0x11);
    x86.ioWait();
    x86.outb(0xA0, 0x11);
    x86.ioWait();
    // offsets: maestro 32, esclavo 40
    x86.outb(0x21, 32);
    x86.ioWait();
    x86.outb(0xA1, 40);
    x86.ioWait();
    // cascada por IRQ2
    x86.outb(0x21, 0x04);
    x86.ioWait();
    x86.outb(0xA1, 0x02);
    x86.ioWait();
    // modo 8086
    x86.outb(0x21, 0x01);
    x86.ioWait();
    x86.outb(0xA1, 0x01);
    x86.ioWait();
    // máscara: permitir IRQ0 (temporizador), IRQ1 (teclado) e IRQ2 (cascada)
    x86.outb(0x21, 0b11111000);
    x86.outb(0xA1, 0xFF); // esclavo cerrado de momento (se abre con el ratón)
}

/// Abre una IRQ del PIC esclavo (0..7; p. ej. 4 para el ratón en IRQ12).
pub fn permitirEsclavo(irq: u8) void {
    if (irq > 7) return;
    const m = x86.inb(0xA1);
    const mascara: u8 = @truncate(@as(u16, 1) << @intCast(irq));
    x86.outb(0xA1, m & ~mascara);
}

pub fn eoi() void {
    x86.outb(0x20, 0x20);
}
