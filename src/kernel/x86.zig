//! AntLex OS — utilidades x86_64 de bajo nivel (E/S de puertos, CPU).

pub inline fn hlt() void {
    asm volatile ("hlt");
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn outb(puerto: u16, valor: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (valor),
          [p] "{dx}" (puerto),
    );
}

pub inline fn inb(puerto: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (puerto),
    );
}

pub inline fn outw(puerto: u16, valor: u16) void {
    asm volatile ("outw %[v], %[p]"
        :
        : [v] "{ax}" (valor),
          [p] "{dx}" (puerto),
    );
}

pub inline fn inw(puerto: u16) u16 {
    return asm volatile ("inw %[p], %[r]"
        : [r] "={ax}" (-> u16),
        : [p] "{dx}" (puerto),
    );
}

pub inline fn outd(puerto: u16, valor: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (valor),
          [p] "{dx}" (puerto),
    );
}

pub inline fn ind(puerto: u16) u32 {
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "{dx}" (puerto),
    );
}

/// Pequeña espera (~1 µs) útil para dispositivos ISA lentos.
pub inline fn ioWait() void {
    outb(0x80, 0);
}

/// Lee el identificador de marca del procesador (CPUID hojas 0x80000002..04).
pub fn cpuidMarca(marca: *[48]u8) void {
    inline for (0..3) |i| {
        const hoja: u32 = 0x80000002 + @as(u32, @intCast(i));
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
            : [hoja] "{eax}" (hoja),
        );
        const base = i * 16;
        const parte: [16]u8 = @bitCast([_]u32{ eax, ebx, ecx, edx });
        @memcpy(marca[base..][0..16], &parte);
    }
}
