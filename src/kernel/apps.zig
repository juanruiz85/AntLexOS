//! AntLex OS — lógica de las aplicaciones del escritorio (Fase 5).
//! PURO: sin hardware, sin ALFS, sin framebuffer — solo buffers y cursores.
//! Lo usan la GUI (estado de las ventanas) y las pruebas host; el pegamento
//! con ALFS vive en gui.zig.

const std = @import("std");

pub const TIPO_DIR: u8 = 1;
pub const TIPO_ARCHIVO: u8 = 2;

// ===========================================================================
// editor de texto
// ===========================================================================

pub const EDITOR_MAX_LINEAS = 64;
pub const EDITOR_MAX_ANCHO = 96;
pub const EDITOR_MAX_NOMBRE = 45;

pub const Editor = struct {
    lineas: [EDITOR_MAX_LINEAS][EDITOR_MAX_ANCHO]u8 = undefined,
    lens: [EDITOR_MAX_LINEAS]u16 = [_]u16{0} ** EDITOR_MAX_LINEAS,
    n: u16 = 1,
    fila: u16 = 0,
    col: u16 = 0,
    nombre: [EDITOR_MAX_NOMBRE]u8 = undefined,
    nombre_len: u8 = 0,
    modificado: bool = false,
    // aviso de la última operación fallida (línea llena, etc.)
    aviso: ?[]const u8 = null,

    pub fn nombreStr(self: *const Editor) []const u8 {
        return self.nombre[0..self.nombre_len];
    }
};

/// Carga un contenido (con '\n') en el editor. Vacío → una línea vacía.
pub fn editorCargar(e: *Editor, contenido: []const u8) void {
    e.n = 0;
    e.fila = 0;
    e.col = 0;
    e.modificado = false;
    e.aviso = null;
    var inicio: usize = 0;
    while (e.n < EDITOR_MAX_LINEAS) {
        var fin = inicio;
        while (fin < contenido.len and contenido[fin] != '\n') fin += 1;
        const l = @min(fin - inicio, EDITOR_MAX_ANCHO);
        @memcpy(e.lineas[e.n][0..l], contenido[inicio .. inicio + l]);
        e.lens[e.n] = @intCast(l);
        e.n += 1;
        if (fin >= contenido.len) break;
        inicio = fin + 1;
    }
    if (e.n == 0) {
        e.n = 1;
        e.lens[0] = 0;
    }
}

/// Serializa las líneas a buf unidas por '\n'. Devuelve los bytes escritos.
pub fn editorSerializar(e: *const Editor, buf: []u8) usize {
    var n: usize = 0;
    var f: u32 = 0;
    while (f < e.n) : (f += 1) {
        const l = e.lens[f];
        if (n + l + 1 > buf.len) break;
        @memcpy(buf[n .. n + l], e.lineas[f][0..l]);
        n += l;
        if (f + 1 < e.n) {
            buf[n] = '\n';
            n += 1;
        }
    }
    return n;
}

fn insertarLinea(e: *Editor, tras: u16) bool {
    if (e.n >= EDITOR_MAX_LINEAS) {
        e.aviso = "documento lleno";
        return false;
    }
    var f = e.n;
    while (f > tras + 1) : (f -= 1) {
        e.lineas[f] = e.lineas[f - 1];
        e.lens[f] = e.lens[f - 1];
    }
    e.n += 1;
    e.lens[tras + 1] = 0;
    return true;
}

/// Procesa una tecla del editor (mismos códigos que el intérprete).
/// Devuelve true si consumió la tecla.
pub fn editorTecla(e: *Editor, c: u8) bool {
    e.aviso = null;
    switch (c) {
        '\n' => {
            // partir la línea en el cursor
            if (!insertarLinea(e, e.fila)) return true;
            const cola = e.lens[e.fila] - e.col;
            @memcpy(e.lineas[e.fila + 1][0..cola], e.lineas[e.fila][e.col..e.lens[e.fila]]);
            e.lens[e.fila + 1] = cola;
            e.lens[e.fila] = e.col;
            e.fila += 1;
            e.col = 0;
            e.modificado = true;
        },
        8 => { // retroceso
            if (e.col > 0) {
                std.mem.copyBackwards(u8, e.lineas[e.fila][e.col - 1 .. e.lens[e.fila]], e.lineas[e.fila][e.col..e.lens[e.fila]]);
                e.col -= 1;
                e.lens[e.fila] -= 1;
                e.modificado = true;
            } else if (e.fila > 0) {
                // unir con la anterior si cabe
                const previa = e.lens[e.fila - 1];
                const actual = e.lens[e.fila];
                if (previa + actual > EDITOR_MAX_ANCHO) {
                    e.aviso = "no cabe al unir";
                    return true;
                }
                @memcpy(e.lineas[e.fila - 1][previa .. previa + actual], e.lineas[e.fila][0..actual]);
                e.lens[e.fila - 1] = previa + actual;
                var f = e.fila;
                while (f + 1 < e.n) : (f += 1) {
                    e.lineas[f] = e.lineas[f + 1];
                    e.lens[f] = e.lens[f + 1];
                }
                e.n -= 1;
                e.fila -= 1;
                e.col = previa;
                e.modificado = true;
            }
        },
        0x80 => { // flecha izquierda
            if (e.col > 0) e.col -= 1 else if (e.fila > 0) {
                e.fila -= 1;
                e.col = e.lens[e.fila];
            }
        },
        0x81 => { // flecha derecha
            if (e.col < e.lens[e.fila]) e.col += 1 else if (e.fila + 1 < e.n) {
                e.fila += 1;
                e.col = 0;
            }
        },
        0x82 => { // flecha arriba
            if (e.fila > 0) {
                e.fila -= 1;
                e.col = @min(e.col, e.lens[e.fila]);
            }
        },
        0x83 => { // flecha abajo
            if (e.fila + 1 < e.n) {
                e.fila += 1;
                e.col = @min(e.col, e.lens[e.fila]);
            }
        },
        0x85 => e.col = 0, // inicio
        0x86 => e.col = e.lens[e.fila], // fin
        0x84 => { // suprimir
            if (e.col < e.lens[e.fila]) {
                std.mem.copyForwards(u8, e.lineas[e.fila][e.col .. e.lens[e.fila] - 1], e.lineas[e.fila][e.col + 1 .. e.lens[e.fila]]);
                e.lens[e.fila] -= 1;
                e.modificado = true;
            } else if (e.fila + 1 < e.n) {
                // unir la siguiente con esta
                const actual = e.lens[e.fila];
                const sig = e.lens[e.fila + 1];
                if (actual + sig > EDITOR_MAX_ANCHO) {
                    e.aviso = "no cabe al unir";
                    return true;
                }
                @memcpy(e.lineas[e.fila][actual .. actual + sig], e.lineas[e.fila + 1][0..sig]);
                e.lens[e.fila] = actual + sig;
                var f = e.fila + 1;
                while (f + 1 < e.n) : (f += 1) {
                    e.lineas[f] = e.lineas[f + 1];
                    e.lens[f] = e.lens[f + 1];
                }
                e.n -= 1;
                e.modificado = true;
            }
        },
        else => {
            // ASCII imprimible y Latin-1 (mismo filtro que el intérprete)
            if (c >= 32 and c != 127 and (c < 0x80 or c >= 0xA0)) {
                if (e.lens[e.fila] >= EDITOR_MAX_ANCHO) {
                    e.aviso = "linea llena";
                    return true;
                }
                const l = e.lens[e.fila];
                std.mem.copyBackwards(u8, e.lineas[e.fila][e.col + 1 .. l + 1], e.lineas[e.fila][e.col..l]);
                e.lineas[e.fila][e.col] = c;
                e.lens[e.fila] = l + 1;
                e.col += 1;
                e.modificado = true;
            }
        },
    }
    return true;
}

// ===========================================================================
// explorador de archivos
// ===========================================================================

pub const EXPLORADOR_MAX_FILAS = 48;
pub const EXPLORADOR_MAX_NOMBRE = 45;

pub const FilaExpl = struct {
    nombre: [EXPLORADOR_MAX_NOMBRE]u8 = undefined,
    nombre_len: u8 = 0,
    tipo: u8 = TIPO_ARCHIVO,
    idx: u16 = 0,

    pub fn nombreStr(self: *const FilaExpl) []const u8 {
        return self.nombre[0..self.nombre_len];
    }
};

pub const Explorador = struct {
    entradas: [EXPLORADOR_MAX_FILAS]FilaExpl = undefined,
    n: u16 = 0,
    seleccion: i16 = -1,
    scroll: u16 = 0,

    pub fn seleccionada(self: *const Explorador) ?*const FilaExpl {
        if (self.seleccion < 0 or self.seleccion >= self.n) return null;
        return &self.entradas[@intCast(self.seleccion)];
    }
};

/// Añade una entrada (lo llama el pegamento de ALFS en gui.zig).
pub fn explAnadir(e: *Explorador, idx: u16, tipo: u8, nombre: []const u8) void {
    if (e.n >= EXPLORADOR_MAX_FILAS) return;
    const l = @min(nombre.len, EXPLORADOR_MAX_NOMBRE);
    @memcpy(e.entradas[e.n].nombre[0..l], nombre[0..l]);
    e.entradas[e.n].nombre_len = @intCast(l);
    e.entradas[e.n].tipo = tipo;
    e.entradas[e.n].idx = idx;
    e.n += 1;
}

/// Mueve la selección `delta` posiciones (acotada; -1 hasta deseleccionar).
pub fn explMover(e: *Explorador, delta: i16) void {
    const destino = e.seleccion + delta;
    e.seleccion = std.math.clamp(destino, -1, @as(i16, @intCast(e.n)) - 1);
}

// ===========================================================================
// pruebas en host
// ===========================================================================

const testing = std.testing;

test "editor: cargar y serializar en redondo" {
    var e = Editor{};
    editorCargar(&e, "hola\nmundo cruel\nadios");
    try testing.expectEqual(@as(u16, 3), e.n);
    var buf: [256]u8 = undefined;
    const n = editorSerializar(&e, &buf);
    try testing.expectEqualStrings("hola\nmundo cruel\nadios", buf[0..n]);
}

test "editor: escribir, partir líneas y borrar" {
    var e = Editor{};
    editorCargar(&e, "");
    try testing.expectEqual(@as(u16, 1), e.n);
    for ("hola mundo") |c| _ = editorTecla(&e, c);
    try testing.expectEqualStrings("hola mundo", e.lineas[0][0..e.lens[0]]);
    try testing.expect(e.modificado);
    // partir en la columna 5
    for (0..5) |_| _ = editorTecla(&e, 0x80); // ←
    _ = editorTecla(&e, '\n');
    try testing.expectEqual(@as(u16, 2), e.n);
    // el corte en la columna 5 deja el espacio en la primera línea
    try testing.expectEqualStrings("hola ", e.lineas[0][0..e.lens[0]]);
    try testing.expectEqualStrings("mundo", e.lineas[1][0..e.lens[1]]);
    // volver a unir con retroceso al inicio de la segunda
    _ = editorTecla(&e, 8);
    try testing.expectEqual(@as(u16, 1), e.n);
    try testing.expectEqualStrings("hola mundo", e.lineas[0][0..e.lens[0]]);
    // suprimir: FIN y borrar la última letra desde col 9
    _ = editorTecla(&e, 0x86); // FIN → col 10
    _ = editorTecla(&e, 0x80); // ← → col 9
    _ = editorTecla(&e, 0x84); // SUPR borra la 'o' final
    try testing.expectEqualStrings("hola mund", e.lineas[0][0..e.lens[0]]);
}

test "editor: límites respetados" {
    var e = Editor{};
    editorCargar(&e, "");
    var i: u32 = 0;
    while (i < EDITOR_MAX_ANCHO + 10) : (i += 1) _ = editorTecla(&e, 'x');
    try testing.expectEqual(@as(u16, EDITOR_MAX_ANCHO), e.lens[0]);
    try testing.expectEqualStrings("linea llena", e.aviso.?);
}

test "explorador: añadir, mover y seleccionar" {
    var e = Explorador{};
    explAnadir(&e, 3, TIPO_DIR, "documentos");
    explAnadir(&e, 7, TIPO_ARCHIVO, "LEEME.TXT");
    explAnadir(&e, 9, TIPO_ARCHIVO, "DATOS.TXT");
    try testing.expectEqual(@as(u16, 3), e.n);
    explMover(&e, 1);
    try testing.expectEqualStrings("documentos", e.seleccionada().?.nombreStr());
    explMover(&e, 1);
    explMover(&e, 1);
    try testing.expectEqualStrings("DATOS.TXT", e.seleccionada().?.nombreStr());
    explMover(&e, 99); // acotado al final
    try testing.expectEqualStrings("DATOS.TXT", e.seleccionada().?.nombreStr());
    explMover(&e, -99); // hasta deseleccionar
    try testing.expect(e.seleccionada() == null);
}
