//! AntLex OS — asignador de memoria del kernel (bump allocator).
//! Fase 1: asignación secuencial sin liberación (documentado en el manual
//! técnico); la Fase 7 lo sustituirá por un asignador por clases de tamaño.

const boot_info = @import("boot_info.zig");

var base: usize = 0;
var larga: usize = 0;
var usada: usize = 0;

pub fn init(bi: *const boot_info.BootInfo) bool {
    // heap a partir de 32 MiB para no pisar kernel, pilas ni buffers bajos
    const region = boot_info.regionHeap(bi, 32 * 1024 * 1024) orelse return false;
    base = region.base;
    larga = region.long;
    usada = 0;
    return true;
}

pub const Error = error{ SinMemoria, AlineacionInvalida };

/// Asigna `n` bytes con alineación `alineacion` (potencia de 2, mínimo 1).
pub fn alloc(n: usize, alineacion: usize) Error!usize {
    if (base == 0) return Error.SinMemoria;
    if (alineacion == 0 or (alineacion & (alineacion - 1)) != 0) {
        return Error.AlineacionInvalida;
    }
    if (n > larga) return Error.SinMemoria;
    const actual = base + usada;
    const ajustado = (actual + alineacion - 1) & ~(alineacion - 1);
    const desperdicio = ajustado - actual;
    if (desperdicio + n > larga - usada) return Error.SinMemoria;
    usada += desperdicio + n;
    return ajustado;
}

/// Asigna `n` bytes y los pone a cero.
pub fn allocCero(n: usize, alineacion: usize) Error!usize {
    const p = try alloc(n, alineacion);
    const destino: [*]u8 = @ptrFromInt(p);
    @memset(destino[0..n], 0);
    return p;
}

pub fn estadisticas() struct { total: usize, usada: usize, libre: usize } {
    return .{ .total = larga, .usada = usada, .libre = larga - usada };
}
