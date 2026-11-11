//! AntLex OS — GDT propia del kernel (modo largo, anillo 0).

const Gdt = packed struct {
    limite: u16,
    base: u64,
};

// Misma disposición que stage2 para que el CS heredado (0x18, código 64)
// siga siendo válido en los iretq de las interrupciones:
//   0x00 nulo | 0x08 código 32 | 0x10 datos | 0x18 código 64
var tabla = [4]u64{
    0x0000000000000000,
    0x00CF9A000000FFFF, // 0x08: código 32 (herencia de stage2)
    0x00CF92000000FFFF, // 0x10: datos
    0x00AF9A000000FFFF, // 0x18: código 64 (CS activo)
};

var descriptor = Gdt{ .limite = @sizeOf(@TypeOf(tabla)) - 1, .base = 0 };

pub fn init() void {
    descriptor.base = @intFromPtr(&tabla);
    // OJO: pasar la dirección con "r" y desreferenciar en la instrucción;
    // con "m" el compilador puede meter un puntero intermedio y lgdt leería
    // el puntero (no el pseudodescriptor de 10 bytes).
    asm volatile ("lgdtq (%[d])"
        :
        : [d] "r" (&descriptor),
        : "memory"
    );
    // recargar también CS: el selector heredado (BIOS: 0x18 ya correcto;
    // UEFI: selector propio del firmware) debe pasar a apuntar a NUESTRO
    // descriptor de código 64 antes de cualquier iretq
    asm volatile (
        \\ pushq $0x18
        \\ leaq 1f(%rip), %rax
        \\ pushq %rax
        \\ lretq
        \\ 1:
        ::: "ax", "memory");
    // recargar segmentos de datos
    asm volatile (
        \\ movw $0x10, %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%ss
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ xorl %%eax, %%eax
        ::: "ax", "memory");
}
