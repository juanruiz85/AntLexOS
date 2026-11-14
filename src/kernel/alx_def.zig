//! AntLex OS — alx_def.zig: definiciones PURAS del formato ejecutable `.ALX`
//! y de la interfaz kernel↔aplicación. Es la fuente única de verdad que
//! comparten el kernel (`alx.zig`, `gui.zig`), las apps externas
//! (`apps/*.zig`) y la herramienta de construcción (`tools/mkalx.zig`).
//! No toca hardware: se prueba en el host con `zig build test`.
//!
//! Formato del archivo .ALX (64 B de cabecera + imagen):
//!
//!   offset 0   "ALX1" (magic)      offset 20  nombre[16] ("CALC", "RELOJ"…)
//!   offset 4   u16 version (=1)    offset 36  reservado[28] = 0
//!   offset 6   u16 flags (=0)      offset 64  imagen (código+datos,
//!   offset 8   u32 bss_len                     enlazada en ALX_BASE)
//!   offset 12  u32 entry_off (alx_evento)
//!   offset 16  u32 image_len
//!
//! La imagen es un ELF freestanding enlazado en ALX_BASE (16 MiB) reducido
//! a su contenido: se copia tal cual y se ejecuta en ring 0 (modelo
//! cooperativo del sistema; ver docs/manual_tecnico.md y la auditoría).

const std = @import("std");

// ---------------------------------------------------------------------------
// Constantes del formato
// ---------------------------------------------------------------------------

pub const MAGIC: u32 = 0x31584C41; // "ALX1" little-endian
pub const VERSION: u16 = 1;
pub const CABECERA: u32 = 64;
pub const TAM_NOMBRE: u32 = 16;

/// Dirección física donde se carga la imagen de la app externa.
/// El kernel vive en 1 MiB (acaba muy antes de 4 MiB) y el heap empieza en
/// 32 MiB; stage2 mapea los 4 GiB en identidad, así que 16 MiB es una
/// región libre y accesible. Una app externa a la vez (v1).
pub const ALX_BASE: u32 = 16 * 1024 * 1024;
/// Tamaño de la región reservada para la app (imagen + bss).
pub const ALX_REGION: u32 = 1024 * 1024;
/// Tamaño máximo de la imagen (sin contar bss).
pub const MAX_IMAGEN: u32 = 256 * 1024;
/// Extensión de los ejecutables.
pub const EXTENSION: []const u8 = "alx";

pub const Cabecera = extern struct {
    magic: u32,
    version: u16,
    flags: u16,
    bss_len: u32,
    entry_off: u32,
    image_len: u32,
    nombre: [TAM_NOMBRE]u8,
    _reservado: [28]u8,

    comptime {
        if (@sizeOf(Cabecera) != CABECERA) @compileError("Cabecera ALX debe medir 64 bytes");
        if (@offsetOf(Cabecera, "nombre") != 20) @compileError("nombre debe empezar en el byte 20");
        if (@offsetOf(Cabecera, "bss_len") != 8) @compileError("bss_len debe estar en el byte 8");
    }
};

pub const ErrorValidacion = error{
    MagicInvalido,
    VersionInvalida,
    Truncada,
    EntryFueraDeImagen,
    ImagenGrande,
    ImagenMasBssGrande,
};

/// Valida una cabecera ya leída contra el tamaño total del archivo.
pub fn validar(c: *const Cabecera, tam_archivo: u32) ErrorValidacion!void {
    if (c.magic != MAGIC) return ErrorValidacion.MagicInvalido;
    if (c.version != VERSION) return ErrorValidacion.VersionInvalida;
    if (tam_archivo < CABECERA) return ErrorValidacion.Truncada;
    if (c.image_len != tam_archivo - CABECERA) return ErrorValidacion.Truncada;
    if (c.image_len == 0 or c.image_len > MAX_IMAGEN) return ErrorValidacion.ImagenGrande;
    if (c.entry_off >= c.image_len) return ErrorValidacion.EntryFueraDeImagen;
    if (c.image_len + c.bss_len > ALX_REGION) return ErrorValidacion.ImagenMasBssGrande;
    if (c.bss_len > ALX_REGION) return ErrorValidacion.ImagenMasBssGrande;
}

/// Color en el formato del framebuffer: 0x00RRGGBB (igual que pantalla.rgb).
pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

/// Métricas de la fuente bitmap del sistema (para que las apps calculen
/// posiciones sin tocar los internos de la GUI).
pub const ANCHO_CARACTER: u32 = 8;
pub const ALTO_CARACTER: u32 = 16;

// ---------------------------------------------------------------------------
// Interfaz kernel ↔ app (ABI C, puntero a Api en RDI al llamar alx_evento)
// ---------------------------------------------------------------------------

/// Tipos de evento que la app puede recibir.
pub const EV_INIT: u8 = 0; // ventana a punto de mostrarse: título/tamaño
pub const EV_TECLA: u8 = 1; // tecla para la app (ESC la cierra el kernel)
pub const EV_DIBUJAR: u8 = 2; // pintar el área de cliente (x,y,an,al)
pub const EV_TICK: u8 = 3; // ≈1 Hz (relojes, animaciones lentas)
pub const EV_CERRAR: u8 = 4; // la ventana se cierra (no se puede evitar)

/// Evento entregado a `alx_evento` (siempre por puntero, ABI C).
pub const Evento = extern struct {
    tipo: u8,
    tecla: u8,
    _pad: [2]u8 = .{ 0, 0 },
    x: i32, // origen del área de cliente (para dibujar)
    y: i32,
    an: u32,
    al: u32,
};

/// Tabla de servicios del kernel. Las coordenadas de dibujo son relativas
/// al área de cliente de la ventana de la app (0,0 = esquina sup. izq.).
/// Los colores usan el mismo formato que pantalla.rgb: 0x00RRGGBB.
pub const Api = extern struct {
    texto: *const fn (x: i32, y: i32, s: [*:0]const u8, color: u32) callconv(.c) void,
    /// Texto acotado a `max` caracteres (para dibujar sin salirse).
    textoLim: *const fn (x: i32, y: i32, s: [*:0]const u8, color: u32, max: u32) callconv(.c) void,
    rect: *const fn (x: i32, y: i32, an: u32, al: u32, color: u32) callconv(.c) void,
    /// Relieve biselado 3D (claro arriba/izq, oscuro abajo/der; invertido
    /// si `hundido`) — el mismo estilo que usará el escritorio de la Fase 8.
    bisel: *const fn (x: i32, y: i32, an: u32, al: u32, hundido: bool) callconv(.c) void,
    /// Tamaño de la ventana: SOLO durante EV_INIT (120×80 .. 600×400).
    tam: *const fn (an: u32, al: u32) callconv(.c) void,
    /// Cambia el título de la ventana (≤23 bytes útiles).
    titulo: *const fn (s: [*:0]const u8) callconv(.c) void,
    /// Tics del PIT (≈100 Hz desde el arranque).
    tics: *const fn () callconv(.c) u32,
    /// Hora del RTC como (h*100+m)*100+s (p. ej. 21:45:07 → 214507).
    hora: *const fn () callconv(.c) u32,
    /// Imprime una línea en la consola del sistema (se refleja por serie).
    consola: *const fn (s: [*:0]const u8) callconv(.c) void,
    /// Lee un archivo de ALFS (ruta absoluta "/RUTA.TXT"); devuelve bytes
    /// leídos o −1 si no existe / no cabe.
    leer: *const fn (ruta: [*:0]const u8, buf: [*]u8, cap: u32) callconv(.c) i32,
    /// Escribe (crea o sustituye) un archivo de texto en ALFS; 0 ok, −1 error.
    escribir: *const fn (ruta: [*:0]const u8, buf: [*]const u8, len: u32) callconv(.c) i32,
};

// ---------------------------------------------------------------------------
// Asociaciones por extensión
// ---------------------------------------------------------------------------

pub const Accion = enum(u8) { editor = 0, ejecutar = 1, mostrar = 2 };

pub const MAX_ASOCIACIONES = 8;
pub const EXT_MAX: usize = 6; // "ALX", "TXT", "LOG"… sin el punto

/// Una asociación: extensión (mayúsculas/minúsculas da igual) → acción.
pub const Asociacion = struct {
    ext: [EXT_MAX]u8 = .{' '} ** EXT_MAX,
    ext_len: u8 = 0,
    accion: Accion = .mostrar,
};

/// Tabla de asociaciones con defaults; modificable con `asociar`.
pub const TablaAsoc = struct {
    entradas: [MAX_ASOCIACIONES]Asociacion = .{
        .{ .ext = .{ 'T', 'X', 'T', ' ', ' ', ' ' }, .ext_len = 3, .accion = .editor },
        .{ .ext = .{ 'A', 'L', 'X', ' ', ' ', ' ' }, .ext_len = 3, .accion = .ejecutar },
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
    },
    n: u8 = 2,

    /// Busca la acción asociada a la extensión de `nombre`.
    pub fn accionPara(self: *const TablaAsoc, nombre: []const u8) ?Accion {
        const ext = extensionDe(nombre) orelse return null;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const e = &self.entradas[i];
            if (e.ext_len == ext.len and std.ascii.eqlIgnoreCase(e.ext[0..e.ext_len], ext)) {
                return e.accion;
            }
        }
        return null;
    }

    /// Añade o sustituye la asociación de una extensión.
    pub fn asociar(self: *TablaAsoc, ext: []const u8, accion: Accion) bool {
        if (ext.len == 0 or ext.len > EXT_MAX) return false;
        // sustituir si ya existe
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const e = &self.entradas[i];
            if (e.ext_len == ext.len and std.ascii.eqlIgnoreCase(e.ext[0..e.ext_len], ext)) {
                e.accion = accion;
                return true;
            }
        }
        if (self.n >= MAX_ASOCIACIONES) return false;
        const e = &self.entradas[self.n];
        @memset(&e.ext, ' ');
        for (ext, 0..) |c, j| e.ext[j] = std.ascii.toUpper(c);
        e.ext_len = @intCast(ext.len);
        e.accion = accion;
        self.n += 1;
        return true;
    }
};

/// Extensión de un nombre de archivo (lo que sigue al último '.'), en
/// minúsculas internas no: se devuelve el slice tal cual (la comparación es
/// insensible a mayúsculas). `null` si no tiene extensión.
pub fn extensionDe(nombre: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOfScalar(u8, nombre, '.') orelse return null;
    if (i + 1 >= nombre.len) return null; // "." final: sin extensión
    return nombre[i + 1 ..];
}

/// ¿Termina el nombre en .ALX (sin distinguir mayúsculas)?
pub fn esAlx(nombre: []const u8) bool {
    const ext = extensionDe(nombre) orelse return false;
    return std.ascii.eqlIgnoreCase(ext, EXTENSION);
}

// ---------------------------------------------------------------------------
// Pruebas (host)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn cabeceraPrueba(image_len: u32) Cabecera {
    const c = Cabecera{
        .magic = MAGIC,
        .version = VERSION,
        .flags = 0,
        .bss_len = 64,
        .entry_off = 16,
        .image_len = image_len,
        .nombre = .{'C'} ** 16,
        ._reservado = .{0} ** 28,
    };
    return c;
}

test "alx_def: cabecera mide 64 bytes y valida" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(Cabecera));
    var c = cabeceraPrueba(1024);
    try validar(&c, CABECERA + 1024); // ok

    c.magic = 0xDEAD;
    try testing.expectError(ErrorValidacion.MagicInvalido, validar(&c, CABECERA + 1024));
    c = cabeceraPrueba(1024);
    c.version = 2;
    try testing.expectError(ErrorValidacion.VersionInvalida, validar(&c, CABECERA + 1024));
    c = cabeceraPrueba(1024);
    try testing.expectError(ErrorValidacion.Truncada, validar(&c, CABECERA + 512));
    c = cabeceraPrueba(1024);
    c.entry_off = 1024;
    try testing.expectError(ErrorValidacion.EntryFueraDeImagen, validar(&c, CABECERA + 1024));
    c = cabeceraPrueba(MAX_IMAGEN + 1);
    try testing.expectError(ErrorValidacion.ImagenGrande, validar(&c, CABECERA + MAX_IMAGEN + 1));
    c = cabeceraPrueba(1024);
    c.bss_len = ALX_REGION;
    try testing.expectError(ErrorValidacion.ImagenMasBssGrande, validar(&c, CABECERA + 1024));
}

test "alx_def: extensiones" {
    try testing.expectEqualStrings("ALX", extensionDe("CALC.ALX").?);
    try testing.expectEqualStrings("txt", extensionDe("nota.txt").?);
    try testing.expectEqualStrings("TXT", extensionDe("A.LEIDO.TXT").?);
    try testing.expect(extensionDe("SINEXT") == null);
    try testing.expect(extensionDe("punto.") == null);
    try testing.expect(esAlx("CALC.ALX"));
    try testing.expect(esAlx("reloj.alx"));
    try testing.expect(!esAlx("NOTA.TXT"));
    try testing.expect(!esAlx("ALX"));
}

test "alx_def: tabla de asociaciones" {
    var t = TablaAsoc{};
    try testing.expectEqual(Accion.editor, t.accionPara("NOTA.TXT").?);
    try testing.expectEqual(Accion.ejecutar, t.accionPara("CALC.ALX").?);
    try testing.expect(t.accionPara("FOTO.PNG") == null);
    try testing.expect(t.accionPara("SINEXT") == null);

    // sustituir una existente
    try testing.expect(t.asociar("txt", .mostrar));
    try testing.expectEqual(Accion.mostrar, t.accionPara("NOTA.TXT").?);
    // añadir nueva
    try testing.expect(t.asociar("log", .mostrar));
    try testing.expectEqual(Accion.mostrar, t.accionPara("arranque.LOG").?);
    // límites: 5 caracteres caben (EXT_MAX=6), 8 no
    try testing.expect(t.asociar("largo", .mostrar));
    try testing.expect(!t.asociar("demasiado", .mostrar)); // > EXT_MAX
    try testing.expectEqual(@as(u8, 4), t.n);
    try testing.expectEqual(Accion.mostrar, t.accionPara("ARCHIVO.LARGO").?);
}

test "alx_def: Api y Evento son extern (layout ABI C fijo)" {
    try testing.expectEqual(@as(usize, 20), @sizeOf(Evento));
    // la tabla es solo punteros: 11 funciones × 8 bytes
    try testing.expectEqual(@as(usize, 11 * 8), @sizeOf(Api));
}
