//! AntLex OS — alx.zig: loader de ejecutables `.ALX` (Fase 7).
//!
//! Copia la imagen del archivo a la región física fija `ALX_BASE` (16 MiB,
//! mapeada en identidad por stage2) y expone el punto de entrada
//! `alx_evento` para que la GUI lo llame con la tabla `Api`.
//!
//! Modelo de seguridad (registrado en la auditoría REV-v1.2.0): la app corre
//! en ring 0 como todo el sistema — sin aislamiento todavía; por eso hace
//! falta el bit de ejecutable (lo pone `instalar` o el build) y la cabecera
//! se valida a fondo (magic, versión, tamaños acotados, entry dentro de la
//! imagen) antes de copiar nada. Una app a la vez (región única).

const std = @import("std");
const alfs = @import("alfs.zig");
const fmt = @import("alfs_formato.zig");
const serial = @import("serial.zig");
const mem = @import("mem.zig");
const def = @import("alx_def.zig");

pub const FLAG_EJECUTABLE = fmt.FLAG_EJECUTABLE;

/// Tabla de asociaciones por extensión (la edita el comando `asociar`).
pub var asociaciones = def.TablaAsoc{};

/// Punto de entrada de una app externa (ABI C: RDI=*Api, RSI=*Evento).
pub const PuntoEntrada = *const fn (*const def.Api, *const def.Evento) callconv(.c) void;

pub const Error = error{
    SinAlfs,
    TamGrande,
    CabeceraInvalida,
    SinMemoria,
    LecturaAlfs,
};

pub const Estado = struct {
    cargada: bool = false,
    idx: u16 = 0, // entrada ALFS del .ALX en ejecución
    nombre: [def.TAM_NOMBRE]u8 = .{0} ** def.TAM_NOMBRE,
    nombre_len: u8 = 0,
    entry: usize = 0,
};

var estado = Estado{};

pub fn cargada() bool {
    return estado.cargada;
}

pub fn nombreStr() []const u8 {
    return estado.nombre[0..estado.nombre_len];
}

pub fn entrada() ?PuntoEntrada {
    if (!estado.cargada) return null;
    return @ptrFromInt(estado.entry);
}

/// Carga y valida el `.ALX` de la entrada ALFS `idx`. Deja la imagen en
/// ALX_BASE (región puesta a cero antes) y devuelve el punto de entrada.
pub fn cargar(idx: u16) Error!PuntoEntrada {
    if (!alfs.montado()) return Error.SinAlfs;
    const vol = alfs.actual() orelse return Error.SinAlfs;
    const tam = vol.tamDe(idx) catch return Error.LecturaAlfs;
    if (tam > def.CABECERA + def.MAX_IMAGEN) return Error.TamGrande;

    // leer el archivo completo a un búfer del heap del kernel
    const p = mem.alloc(tam, 16) catch return Error.SinMemoria;
    const buf: []u8 = @as([*]u8, @ptrFromInt(p))[0..tam];
    const n = vol.leer(idx, buf) catch return Error.LecturaAlfs;
    if (n != tam) return Error.LecturaAlfs;

    // validar la cabecera ANTES de tocar la región de la app
    const cab: *const def.Cabecera = @ptrCast(@alignCast(buf.ptr));
    def.validar(cab, @intCast(n)) catch return Error.CabeceraInvalida;

    // copiar la imagen (la región se pone a cero: el bss queda limpio)
    const region: [*]u8 = @ptrFromInt(def.ALX_BASE);
    @memset(region[0..def.ALX_REGION], 0);
    const imagen = buf[def.CABECERA..][0..cab.image_len];
    @memcpy(region[0..cab.image_len], imagen);

    // registrar estado
    estado = .{
        .cargada = true,
        .idx = idx,
        .nombre_len = @intCast(std.mem.indexOfScalar(u8, &cab.nombre, 0) orelse cab.nombre.len),
        .entry = def.ALX_BASE + cab.entry_off,
    };
    @memcpy(estado.nombre[0..estado.nombre_len], cab.nombre[0..estado.nombre_len]);

    serial.puts("alx: cargada ");
    serial.puts(nombreStr());
    serial.puts(" (");
    var bufn: [16]u8 = undefined;
    const tn = std.fmt.bufPrint(&bufn, "{d}", .{cab.image_len}) catch "?";
    serial.puts(tn);
    serial.puts(" bytes)\n");
    return @ptrFromInt(estado.entry);
}

/// Descarga la app actual (la ventana debe cerrarse antes).
pub fn descargar() void {
    if (!estado.cargada) return;
    serial.puts("alx: descargada ");
    serial.puts(nombreStr());
    serial.puts("\n");
    estado = .{};
}

/// ¿Tiene la entrada ALFS el bit de ejecutable?
pub fn esEjecutable(idx: u16) bool {
    if (!alfs.montado()) return false;
    const vol = alfs.actual() orelse return false;
    const e = vol.entrada(idx) orelse return false;
    return e.tipo == fmt.TIPO_ARCHIVO and (e.flags & FLAG_EJECUTABLE) != 0;
}

/// Pone (o quita) el bit de ejecutable de una entrada.
pub fn ponerBitEjecutable(idx: u16, valor: bool) bool {
    if (!alfs.montado()) return false;
    const vol = alfs.actual() orelse return false;
    const e = vol.entrada(idx) orelse return false;
    if (e.tipo != fmt.TIPO_ARCHIVO) return false;
    if (valor) {
        e.flags |= FLAG_EJECUTABLE;
    } else {
        e.flags &= ~FLAG_EJECUTABLE;
    }
    alfs.marcar(); // hay cambios que sincronizar
    return true;
}
