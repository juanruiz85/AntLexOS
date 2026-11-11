//! AntLex OS — IDT, excepciones e interrupciones.
//! Los stubs se generan en comptime: empujan un marco uniforme
//! (código de error ficticio para las excepciones que no lo traen).

const x86 = @import("x86.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const teclado = @import("teclado.zig");

pub const Marco = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,
    vec: u64,
    err: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const Entrada = extern struct {
    bajo: u16, // bits 0..15 del manejador
    sel: u16, // selector de código
    cero: u8,
    tipo: u8, // 0x8E = interrupt gate, DPL 0
    medio: u16, // bits 16..31
    alto: u32, // bits 32..63
    cero2: u32,
};

const Idtr = packed struct {
    limite: u16,
    base: u64,
};

const NOMES_EXC = [32][]const u8{
    "división por cero", "depuración",         "NMI",                "breakpoint",
    "overflow",           "BOUND",               "opcode inválido",   "dispositivo no disp.",
    "doble fallo",        "coprocesador",        "TSS inválida",      "segmento no presente",
    "fallo de pila",      "protección general", "fallo de página",   "reservada",
    "x87",                "alineación",         "comprobación máq", "SIMD",
    "virt.",              "control de protecc.", "reservada",          "reservada",
    "reservada",          "reservada",           "reservada",          "reservada",
    "reservada",          "seguridad",           "reservada",          "reservada",
};

fn conError(comptime vec: u32) bool {
    return switch (vec) {
        8, 10, 11, 12, 13, 14, 17, 21 => true,
        else => false,
    };
}

fn Stub(comptime vec: u32, comptime trae_err: bool) type {
    const cuerpo = "cli\n" ++
        (if (trae_err) "" else "pushq $0\n") ++
        "pushq %[vec]\n" ++
        "pushq %rax\npushq %rcx\npushq %rdx\npushq %rbx\npushq %rsi\npushq %rdi\n" ++
        "pushq %rbp\npushq %r8\npushq %r9\npushq %r10\npushq %r11\npushq %r12\n" ++
        "pushq %r13\npushq %r14\npushq %r15\n" ++
        "movq %rsp, %rdi\n" ++
        "cld\n" ++
        "callq isrComun\n" ++
        "popq %r15\npopq %r14\npopq %r13\npopq %r12\npopq %r11\npopq %r10\n" ++
        "popq %r9\npopq %r8\npopq %rbp\npopq %rdi\npopq %rsi\npopq %rbx\n" ++
        "popq %rdx\npopq %rcx\npopq %rax\n" ++
        "addq $16, %rsp\n" ++
        "iretq\n";
    return struct {
        fn isr() callconv(.Naked) noreturn {
            asm volatile (cuerpo
                :
                : [vec] "n" (@as(u32, vec)),
            );
        }
    };
}

fn stubFn(comptime vec: u32) *const fn () callconv(.Naked) noreturn {
    return &Stub(vec, conError(vec)).isr;
}

var tabla: [256]Entrada = [_]Entrada{.{ .bajo = 0, .sel = 0x18, .cero = 0, .tipo = 0x8E, .medio = 0, .alto = 0, .cero2 = 0 }} ** 256;
var idtr = Idtr{ .limite = @sizeOf(@TypeOf(tabla)) - 1, .base = 0 };

fn registrar(vec: u8, manejador: *const fn () callconv(.Naked) noreturn) void {
    const dir = @intFromPtr(manejador);
    tabla[vec] = .{
        .bajo = @truncate(dir),
        .sel = 0x18, // código 64 bits (misma disposición que stage2/gdt.zig)
        .cero = 0,
        .tipo = 0x8E,
        .medio = @truncate(dir >> 16),
        .alto = @truncate(dir >> 32),
        .cero2 = 0,
    };
}

pub fn init() void {
    inline for (0..256) |n| {
        registrar(@intCast(n), stubFn(@intCast(n)));
    }
    idtr.base = @intFromPtr(&tabla);
    asm volatile ("lidtq (%[d])"
        :
        : [d] "r" (&idtr),
        : "memory"
    );
}

fn eoi(vec: u64) void {
    if (vec >= 40) x86.outb(0xA0, 0x20); // esclavo
    if (vec >= 32) x86.outb(0x20, 0x20); // maestro
}

export fn isrComun(marco: *const Marco) callconv(.C) void {
    const vec = marco.vec;
    if (vec <= 31) {
        // Excepción fatal: volcar y detenerse
        serial.puts("\n=== EXCEPCION FATAL ===\n");
        serial.puts("vector: ");
        serial.putDec(vec);
        serial.puts(" (");
        if (vec < 32) serial.puts(NOMES_EXC[@intCast(vec)]);
        serial.puts(") err: ");
        serial.putDec(marco.err);
        serial.puts("\nRIP: ");
        serial.putHex(marco.rip);
        serial.puts(" RSP: ");
        serial.putHex(marco.rsp);
        serial.puts("\nRAX: ");
        serial.putHex(marco.rax);
        serial.puts(" RBX: ");
        serial.putHex(marco.rbx);
        serial.puts(" RCX: ");
        serial.putHex(marco.rcx);
        serial.puts(" RDX: ");
        serial.putHex(marco.rdx);
        serial.puts("\nRSI: ");
        serial.putHex(marco.rsi);
        serial.puts(" RDI: ");
        serial.putHex(marco.rdi);
        serial.puts(" RBP: ");
        serial.putHex(marco.rbp);
        serial.puts("\nCR2 aproximada no disponible; sistema detenido.\n");
        x86.cli();
        while (true) x86.hlt();
    }
    switch (vec) {
        32 => pit.tick(), // IRQ0: temporizador
        33 => teclado.irq(), // IRQ1: teclado
        else => {}, // sin manejo específico
    }
    eoi(vec);
}
