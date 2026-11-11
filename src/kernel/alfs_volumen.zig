//! AntLex OS — ALFS: operaciones de volumen sobre un búfer en memoria
//! (capa pura, sin hardware). La usan el kernel (montaje desde ATA), la
//! herramienta mkalfs (creación del volumen inicial) y las pruebas host.
//!
//! Todas las operaciones validan índices, tamaños y consistencia: unos datos
//! corruptos en disco nunca provocan lecturas/escrituras fuera del búfer.

const std = @import("std");
const fmt = @import("alfs_formato.zig");

pub const Error = error{
    VolumenInvalido,
    TablaLlena,
    SinEspacio,
    Fragmentado,
    YaExiste,
    NoExiste,
    NoEsDirectorio,
    NoEsArchivo,
    DirectorioNoVacio,
    NombreInvalido,
    RutaInvalida,
    ArchivoGrande,
    Desbordamiento,
};

pub const Volumen = struct {
    datos: []u8,
    n_bloques: u32,
    // copias de los campos del superbloque (evita releerlo en cada acceso)
    sb_bitmap_bloque: u32 = 0,
    sb_tabla_bloque: u32 = 0,
    sb_datos_bloque: u32 = 0,

    // ---------------- acceso a estructuras (con validación) ----------------

    pub fn superbloque(v: *const Volumen) *Superbloque {
        return @alignCast(@ptrCast(v.datos.ptr));
    }

    pub fn entrada(v: *const Volumen, indice: u16) ?*Entrada {
        if (indice >= fmt.MAX_ENTRADAS) return null;
        const base = @as(usize, v.sb_tabla_bloque) * fmt.TAM_BLOQUE + @as(usize, indice) * 64;
        if (base + 64 > v.datos.len) return null;
        return @alignCast(@ptrCast(v.datos.ptr + base));
    }

    pub fn bitmap(v: *const Volumen) []u8 {
        const inicio = @as(usize, v.sb_bitmap_bloque) * fmt.TAM_BLOQUE;
        const bytes = (v.n_bloques + 7) / 8;
        return v.datos[inicio..][0..bytes];
    }

    fn zonaDatos(v: *const Volumen, primer: u32, nbloques: u32) ?[]u8 {
        if (nbloques == 0) return v.datos[0..0];
        // suma y producto en u64: una entrada corrupta no debe desbordar u32
        const inicio = (@as(u64, v.sb_datos_bloque) + primer) * fmt.TAM_BLOQUE;
        const long = @as(u64, nbloques) * fmt.TAM_BLOQUE;
        if (inicio + long > v.datos.len) return null;
        const i: usize = @intCast(inicio);
        const l: usize = @intCast(long);
        return v.datos[i .. i + l];
    }

    // ---------------- creación y validación ----------------

    /// Formatea `buf` como volumen ALFS vacío (solo la raíz).
    pub fn formatear(buf: []u8, etiqueta: []const u8) Error!Volumen {
        if (buf.len < 2 * 1024 * 1024) return Error.VolumenInvalido;
        if (buf.len % fmt.TAM_BLOQUE != 0) return Error.VolumenInvalido;
        const n: u32 = @intCast(buf.len / fmt.TAM_BLOQUE);
        @memset(buf, 0);

        var v = Volumen{ .datos = buf, .n_bloques = n };
        const sb = v.superbloque();
        sb.magic = fmt.MAGIC;
        sb.version = fmt.VERSION_FORMATO;
        sb.bloque_log2 = fmt.BLOQUE_LOG2;
        sb.n_bloques = n;
        sb.bitmap_bloque = 1;
        sb.tabla_bloque = fmt.bloqueTabla(n);
        sb.tabla_entradas = fmt.MAX_ENTRADAS;
        sb.datos_bloque = fmt.bloqueDatos(n);
        sb.crc = 0;
        const etq = etiqueta[0..@min(etiqueta.len, sb.etiqueta.len)];
        @memcpy(sb.etiqueta[0..etq.len], etq);

        v.sb_bitmap_bloque = sb.bitmap_bloque;
        v.sb_tabla_bloque = sb.tabla_bloque;
        v.sb_datos_bloque = sb.datos_bloque;

        // marcar bloques del sistema como ocupados
        var b: u32 = 0;
        while (b < sb.datos_bloque) : (b += 1) fmt.ponerBit(v.bitmap(), b);

        // entrada raíz
        const raiz = v.entrada(fmt.RAIZ) orelse return Error.VolumenInvalido;
        raiz.tipo = fmt.TIPO_DIRECTORIO;
        raiz.flags = 0;
        raiz.nombre_len = 1;
        raiz.nombre[0] = '/';
        raiz.padre = fmt.PADRE_RAIZ;
        raiz.tam = 0;
        raiz.primer_bloque = 0;
        raiz.nbloques = 0;

        sb.bloques_libres = fmt.contarLibres(v.bitmap(), n);
        return v;
    }

    /// Abre un volumen ya formateado en `buf` validando el superbloque.
    pub fn abrir(buf: []u8) Error!Volumen {
        if (buf.len < 2 * 1024 * 1024) return Error.VolumenInvalido;
        if (buf.len % fmt.TAM_BLOQUE != 0) return Error.VolumenInvalido;
        const n: u32 = @intCast(buf.len / fmt.TAM_BLOQUE);
        var v = Volumen{ .datos = buf, .n_bloques = n };
        const sb = v.superbloque();
        if (sb.magic != fmt.MAGIC) return Error.VolumenInvalido;
        if (sb.version != fmt.VERSION_FORMATO) return Error.VolumenInvalido;
        if (sb.bloque_log2 != fmt.BLOQUE_LOG2) return Error.VolumenInvalido;
        if (sb.n_bloques != n) return Error.VolumenInvalido;
        if (sb.bitmap_bloque != 1) return Error.VolumenInvalido;
        if (sb.tabla_bloque != fmt.bloqueTabla(n)) return Error.VolumenInvalido;
        if (sb.tabla_entradas != fmt.MAX_ENTRADAS) return Error.VolumenInvalido;
        if (sb.datos_bloque != fmt.bloqueDatos(n)) return Error.VolumenInvalido;
        if (@as(u64, sb.datos_bloque) * fmt.TAM_BLOQUE >= buf.len) return Error.VolumenInvalido;
        v.sb_bitmap_bloque = sb.bitmap_bloque;
        v.sb_tabla_bloque = sb.tabla_bloque;
        v.sb_datos_bloque = sb.datos_bloque;
        // el recuento de libres debe cuadrar con el mapa real
        if (fmt.contarLibres(v.bitmap(), n) != sb.bloques_libres) return Error.VolumenInvalido;
        // la raíz debe ser un directorio y la tabla estar sana
        const raiz = v.entrada(fmt.RAIZ) orelse return Error.VolumenInvalido;
        if (raiz.tipo != fmt.TIPO_DIRECTORIO) return Error.VolumenInvalido;
        if (!v.entradasSanas()) return Error.VolumenInvalido;
        return v;
    }

    // ---------------- consultas ----------------

    pub fn libres(v: *const Volumen) u32 {
        return v.superbloque().bloques_libres;
    }

    pub fn entradasLibres(v: *const Volumen) u32 {
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < fmt.MAX_ENTRADAS) : (i += 1) {
            const e = v.entrada(@intCast(i)).?;
            if (e.tipo == fmt.TIPO_LIBRE) n += 1;
        }
        return n;
    }

    pub fn nombreDe(v: *const Volumen, indice: u16) []const u8 {
        const e = v.entrada(indice) orelse return "";
        const len = @min(@as(u32, e.nombre_len), fmt.TAM_NOMBRE);
        return e.nombre[0..len];
    }

    pub fn tipoDe(v: *const Volumen, indice: u16) u8 {
        const e = v.entrada(indice) orelse return fmt.TIPO_LIBRE;
        return e.tipo;
    }

    /// Busca un hijo directo por nombre (insensible a mayúsculas).
    pub fn buscarHijo(v: *const Volumen, padre: u16, nombre: []const u8) ?u16 {
        if (v.tipoDe(padre) != fmt.TIPO_DIRECTORIO) return null;
        var i: u32 = 0;
        while (i < fmt.MAX_ENTRADAS) : (i += 1) {
            const idx: u16 = @intCast(i);
            const e = v.entrada(idx).?;
            if (e.tipo == fmt.TIPO_LIBRE or e.padre != padre) continue;
            if (fmt.eqlNombre(v.nombreDe(idx), nombre)) return idx;
        }
        return null;
    }

    /// Itera los hijos de un directorio llamando `cb(ctx, indice, entrada)`.
    pub fn hijosDe(
        v: *const Volumen,
        padre: u16,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), u16, *const Entrada) void,
    ) void {
        var i: u32 = 0;
        while (i < fmt.MAX_ENTRADAS) : (i += 1) {
            const idx: u16 = @intCast(i);
            const e = v.entrada(idx).?;
            if (e.tipo == fmt.TIPO_LIBRE or e.padre != padre) continue;
            cb(ctx, idx, e);
        }
    }

    /// Resuelve una ruta desde la raíz ("/a/b/c", soporta "." y "..").
    pub fn resolver(v: *const Volumen, ruta: []const u8) Error!u16 {
        if (ruta.len == 0 or ruta.len > 96) return Error.RutaInvalida;
        var actual: u16 = fmt.RAIZ;
        if (ruta[0] != '/') return Error.RutaInvalida;
        var it = std.mem.splitScalar(u8, ruta, '/');
        var profundidad: u32 = 0;
        while (it.next()) |parte| {
            if (parte.len == 0) continue;
            profundidad += 1;
            if (profundidad > fmt.MAX_PROFUNDIDAD) return Error.RutaInvalida;
            if (std.mem.eql(u8, parte, ".")) continue;
            if (std.mem.eql(u8, parte, "..")) {
                const e = v.entrada(actual) orelse return Error.RutaInvalida;
                actual = if (e.padre == fmt.PADRE_RAIZ) fmt.RAIZ else e.padre;
                continue;
            }
            if (!fmt.nombreValido(parte)) return Error.RutaInvalida;
            actual = v.buscarHijo(actual, parte) orelse return Error.NoExiste;
        }
        return actual;
    }

    /// Resuelve una ruta relativa a `base` (o absoluta si empieza por '/').
    pub fn resolverDesde(v: *const Volumen, base: u16, ruta: []const u8) Error!u16 {
        if (ruta.len > 0 and ruta[0] == '/') return v.resolver(ruta);
        if (ruta.len == 0) return base;
        if (v.tipoDe(base) != fmt.TIPO_DIRECTORIO) return Error.NoEsDirectorio;
        var actual = base;
        var it = std.mem.splitScalar(u8, ruta, '/');
        var profundidad: u32 = 0;
        while (it.next()) |parte| {
            if (parte.len == 0) continue;
            profundidad += 1;
            if (profundidad > fmt.MAX_PROFUNDIDAD) return Error.RutaInvalida;
            if (std.mem.eql(u8, parte, ".")) continue;
            if (std.mem.eql(u8, parte, "..")) {
                const e = v.entrada(actual) orelse return Error.RutaInvalida;
                actual = if (e.padre == fmt.PADRE_RAIZ) fmt.RAIZ else e.padre;
                continue;
            }
            if (!fmt.nombreValido(parte)) return Error.RutaInvalida;
            actual = v.buscarHijo(actual, parte) orelse return Error.NoExiste;
        }
        return actual;
    }

    /// Construye la ruta absoluta de `indice` en `buf`; devuelve su longitud.
    pub fn rutaAbsoluta(v: *const Volumen, indice: u16, buf: []u8) Error!usize {
        var partes: [fmt.MAX_PROFUNDIDAD + 2][]const u8 = undefined;
        var n: usize = 0;
        var actual = indice;
        while (true) {
            const e = v.entrada(actual) orelse return Error.RutaInvalida;
            if (e.padre == fmt.PADRE_RAIZ) break;
            partes[n] = v.nombreDe(actual);
            n += 1;
            if (n >= partes.len) return Error.RutaInvalida;
            actual = e.padre;
        }
        var pos: usize = 0;
        if (buf.len < 1) return Error.Desbordamiento;
        if (n == 0) { // la raíz misma
            buf[0] = '/';
            return 1;
        }
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            if (pos + 1 + partes[i].len > buf.len) return Error.Desbordamiento;
            buf[pos] = '/';
            pos += 1;
            @memcpy(buf[pos .. pos + partes[i].len], partes[i]);
            pos += partes[i].len;
        }
        return pos;
    }

    // ---------------- asignación de bloques ----------------

    /// Reserva una extensión contigua de `n` bloques (primer ajuste).
    fn reservar(v: *Volumen, n: u32) Error!u32 {
        if (n == 0) return 0;
        const bm = v.bitmap();
        var corrida: u32 = 0;
        var b: u32 = 0;
        while (b < v.n_bloques) : (b += 1) {
            if (fmt.bitOcupado(bm, b)) {
                corrida = 0;
            } else {
                corrida += 1;
                if (corrida == n) {
                    const primer = b + 1 - n;
                    var k: u32 = 0;
                    while (k < n) : (k += 1) fmt.ponerBit(bm, primer + k);
                    v.superbloque().bloques_libres -= n;
                    return primer;
                }
            }
        }
        // no hay corrida contigua: distinguir sin espacio de fragmentación
        const li = v.superbloque().bloques_libres;
        if (li < n) return Error.SinEspacio;
        return Error.Fragmentado;
    }

    fn liberar(v: *Volumen, primer: u32, n: u32) void {
        if (n == 0) return;
        // una entrada corrupta (primer/nbloques fuera de rango) no debe
        // tocar el bitmap fuera de límites: se ignora silenciosamente
        if (@as(u64, primer) + n > v.n_bloques) return;
        const bm = v.bitmap();
        var k: u32 = 0;
        while (k < n) : (k += 1) fmt.quitarBit(bm, primer + k);
        v.superbloque().bloques_libres += n;
    }

    /// Validación de la tabla de entradas (defensa en profundidad contra
    /// un volumen corrupto: todo acceso posterior presupone entradas sanas).
    fn entradasSanas(v: *const Volumen) bool {
        var i: u32 = 0;
        while (i < fmt.MAX_ENTRADAS) : (i += 1) {
            const e = v.entrada(@intCast(i)).?;
            if (e.tipo == fmt.TIPO_LIBRE) {
                if (e.padre != 0 and e.tam == 0 and e.nbloques == 0) continue;
                continue;
            }
            if (e.tipo != fmt.TIPO_ARCHIVO and e.tipo != fmt.TIPO_DIRECTORIO) return false;
            if (e.nombre_len == 0 or e.nombre_len > fmt.TAM_NOMBRE) return false;
            if (e.padre != fmt.PADRE_RAIZ and e.padre >= fmt.MAX_ENTRADAS) return false;
            if (e.tam > fmt.TAM_MAX_ARCHIVO) return false;
            if (e.tipo == fmt.TIPO_ARCHIVO) {
                if (@as(u64, e.tam) > @as(u64, e.nbloques) * fmt.TAM_BLOQUE) return false;
                if (@as(u64, e.primer_bloque) + e.nbloques > v.n_bloques) return false;
            } else if (e.nbloques != 0 or e.tam != 0) {
                return false; // un directorio no ocupa bloques
            }
        }
        return true;
    }

    // ---------------- operaciones de archivos ----------------

    /// Crea un archivo o directorio hijo de `padre` con `contenido`
    /// (vacío para directorios).
    pub fn crear(v: *Volumen, padre: u16, nombre: []const u8, tipo: u8, contenido: []const u8) Error!u16 {
        if (v.tipoDe(padre) != fmt.TIPO_DIRECTORIO) return Error.NoEsDirectorio;
        if (!fmt.nombreValido(nombre)) return Error.NombreInvalido;
        if (tipo != fmt.TIPO_ARCHIVO and tipo != fmt.TIPO_DIRECTORIO) return Error.RutaInvalida;
        if (tipo == fmt.TIPO_ARCHIVO and contenido.len > fmt.TAM_MAX_ARCHIVO) return Error.ArchivoGrande;
        if (v.buscarHijo(padre, nombre) != null) return Error.YaExiste;

        var indice_libre: ?u16 = null;
        var i: u32 = 0;
        while (i < fmt.MAX_ENTRADAS) : (i += 1) {
            const idx: u16 = @intCast(i);
            if (v.entrada(idx).?.tipo == fmt.TIPO_LIBRE) {
                indice_libre = idx;
                break;
            }
        }
        const idx = indice_libre orelse return Error.TablaLlena;

        const nbloques: u32 = if (tipo == fmt.TIPO_ARCHIVO)
            @intCast((contenido.len + fmt.TAM_BLOQUE - 1) / fmt.TAM_BLOQUE)
        else
            0;
        const primer = try v.reservar(nbloques);

        const e = v.entrada(idx).?;
        e.tipo = tipo;
        e.flags = 0;
        e.nombre_len = @intCast(nombre.len);
        @memset(&e.nombre, 0);
        @memcpy(e.nombre[0..nombre.len], nombre);
        e.padre = padre;
        e.reservado = 0;
        e.tam = if (tipo == fmt.TIPO_ARCHIVO) @intCast(contenido.len) else 0;
        e.primer_bloque = primer;
        e.nbloques = nbloques;

        if (contenido.len > 0) {
            const zona = v.zonaDatos(primer, nbloques) orelse {
                // no debería ocurrir tras validar superbloque; estado consistente
                e.tipo = fmt.TIPO_LIBRE;
                v.liberar(primer, nbloques);
                return Error.VolumenInvalido;
            };
            @memset(zona, 0);
            @memcpy(zona[0..contenido.len], contenido);
        }
        return idx;
    }

    /// Lee el archivo `indice` en `buf`; devuelve los bytes leídos.
    pub fn leer(v: *const Volumen, indice: u16, buf: []u8) Error!usize {
        const e = v.entrada(indice) orelse return Error.NoExiste;
        if (e.tipo == fmt.TIPO_LIBRE) return Error.NoExiste;
        if (e.tipo != fmt.TIPO_ARCHIVO) return Error.NoEsArchivo;
        // comparación en u64: nbloques corruptos no desbordan u32
        if (@as(u64, e.tam) > @as(u64, e.nbloques) * fmt.TAM_BLOQUE) return Error.VolumenInvalido;
        const t: usize = e.tam;
        if (t > buf.len) return Error.Desbordamiento;
        if (t > 0) {
            const zona = v.zonaDatos(e.primer_bloque, e.nbloques) orelse return Error.VolumenInvalido;
            @memcpy(buf[0..t], zona[0..t]);
        }
        return t;
    }

    /// Tamaño del archivo (bytes).
    pub fn tamDe(v: *const Volumen, indice: u16) Error!u32 {
        const e = v.entrada(indice) orelse return Error.NoExiste;
        if (e.tipo == fmt.TIPO_LIBRE) return Error.NoExiste;
        if (e.tipo != fmt.TIPO_ARCHIVO) return Error.NoEsArchivo;
        return e.tam;
    }

    /// Sustituye el contenido del archivo `indice`.
    pub fn escribir(v: *Volumen, indice: u16, contenido: []const u8) Error!void {
        const e = v.entrada(indice) orelse return Error.NoExiste;
        if (e.tipo == fmt.TIPO_LIBRE) return Error.NoExiste;
        if (e.tipo != fmt.TIPO_ARCHIVO) return Error.NoEsArchivo;
        if (contenido.len > fmt.TAM_MAX_ARCHIVO) return Error.ArchivoGrande;

        const nbloques: u32 = @intCast((contenido.len + fmt.TAM_BLOQUE - 1) / fmt.TAM_BLOQUE);
        // reservar ANTES de liberar la extensión vieja permite crecimiento in situ
        const primer = try v.reservar(nbloques);

        const viejo_primer = e.primer_bloque;
        const viejo_n = e.nbloques;
        if (contenido.len > 0) {
            const zona = v.zonaDatos(primer, nbloques) orelse {
                v.liberar(primer, nbloques);
                return Error.VolumenInvalido;
            };
            @memset(zona, 0);
            @memcpy(zona[0..contenido.len], contenido);
        }
        e.tam = @intCast(contenido.len);
        e.primer_bloque = primer;
        e.nbloques = nbloques;
        v.liberar(viejo_primer, viejo_n);
    }

    /// Anexa `extra` al archivo usando `temp` como búfer de trabajo
    /// (debe medir al menos tam_actual + extra.len).
    pub fn anexar(v: *Volumen, indice: u16, extra: []const u8, temp: []u8) Error!void {
        const e = v.entrada(indice) orelse return Error.NoExiste;
        if (e.tipo != fmt.TIPO_ARCHIVO) return Error.NoEsArchivo;
        const total: usize = @as(usize, e.tam) + extra.len;
        if (total > fmt.TAM_MAX_ARCHIVO) return Error.ArchivoGrande;
        if (total > temp.len) return Error.Desbordamiento;
        const n = try v.leer(indice, temp[0..e.tam]);
        if (n != e.tam) return Error.VolumenInvalido;
        @memcpy(temp[e.tam..total], extra);
        try v.escribir(indice, temp[0..total]);
    }

    /// Elimina un archivo o un directorio vacío.
    pub fn borrar(v: *Volumen, indice: u16) Error!void {
        if (indice == fmt.RAIZ) return Error.RutaInvalida;
        const e = v.entrada(indice) orelse return Error.NoExiste;
        if (e.tipo == fmt.TIPO_LIBRE) return Error.NoExiste;
        if (e.tipo == fmt.TIPO_DIRECTORIO) {
            var vacio = true;
            var i: u32 = 0;
            while (i < fmt.MAX_ENTRADAS) : (i += 1) {
                const h = v.entrada(@intCast(i)).?;
                if (h.tipo != fmt.TIPO_LIBRE and h.padre == indice) {
                    vacio = false;
                    break;
                }
            }
            if (!vacio) return Error.DirectorioNoVacio;
        }
        v.liberar(e.primer_bloque, e.nbloques);
        e.tipo = fmt.TIPO_LIBRE;
        e.tam = 0;
        e.nombre_len = 0;
        e.primer_bloque = 0;
        e.nbloques = 0;
        e.padre = 0;
    }
};

// La reexportación evita calificar dos importaciones en los consumidores
// (y permite un único módulo en build.zig para las herramientas del host)
pub const Entrada = fmt.Entrada;
pub const Superbloque = fmt.Superbloque;
pub const formato = fmt;

// ---------------------------------------------------------------------------
// Pruebas del volumen (host)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn volPrueba() !Volumen {
    const buf = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    return Volumen.formatear(buf, "PRUEBA");
}

test "volumen: formatear y abrir" {
    var v = try volPrueba();
    defer testing.allocator.free(v.datos);
    try testing.expectEqual(@as(u32, 4096), v.n_bloques);
    const sb = v.superbloque();
    try testing.expectEqual(@as(u32, 1), sb.bitmap_bloque);
    try testing.expectEqual(@as(u32, 2), sb.tabla_bloque); // 4096 bits = 512 B = 1 bloque
    // tabla fija de 256 entradas = 16 KiB = 32 bloques
    try testing.expectEqual(@as(u32, 34), sb.datos_bloque);
    try testing.expectEqual(fmt.bloqueDatos(4096), sb.datos_bloque);
    // reabrir debe validar
    var v2 = try Volumen.abrir(v.datos);
    _ = &v2;
}

test "volumen: ciclo crear/leer/escribir/anexar/borrar" {
    var v = try volPrueba();
    defer testing.allocator.free(v.datos);

    const idx = try v.crear(fmt.RAIZ, "prueba.txt", fmt.TIPO_ARCHIVO, "hola alfs");
    try testing.expectEqual(@as(u32, 9), try v.tamDe(idx));

    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 9), try v.leer(idx, &buf));
    try testing.expectEqualStrings("hola alfs", buf[0..9]);

    try v.escribir(idx, "contenido mas largo que antes");
    try testing.expectEqual(@as(u32, 29), try v.tamDe(idx));

    var temp: [128]u8 = undefined;
    try v.anexar(idx, " + anexo", &temp);
    try testing.expectEqual(@as(u32, 37), try v.tamDe(idx));
    var grande: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 37), try v.leer(idx, &grande));
    try testing.expectEqualStrings("contenido mas largo que antes + anexo", grande[0..37]);

    try v.borrar(idx);
    try testing.expectError(Error.NoExiste, v.tamDe(idx));
}

test "volumen: directorios, rutas y mayúsculas" {
    var v = try volPrueba();
    defer testing.allocator.free(v.datos);

    const d = try v.crear(fmt.RAIZ, "docs", fmt.TIPO_DIRECTORIO, "");
    _ = try v.crear(d, "LEEME.TXT", fmt.TIPO_ARCHIVO, "texto");
    // la búsqueda es insensible a mayúsculas
    const idx = try v.resolver("/docs/leeme.txt");
    try testing.expectEqualStrings("texto", blk: {
        var b: [16]u8 = undefined;
        const n = try v.leer(idx, &b);
        break :blk b[0..n];
    });
    // rutas relativas con . y ..
    try testing.expectEqual(d, try v.resolverDesde(fmt.RAIZ, "docs"));
    try testing.expectEqual(fmt.RAIZ, try v.resolverDesde(d, ".."));
    try testing.expectEqual(idx, try v.resolverDesde(d, "./LEEME.TXT"));
    // ruta absoluta inversa
    var ruta: [64]u8 = undefined;
    const n = try v.rutaAbsoluta(idx, &ruta);
    try testing.expectEqualStrings("/docs/LEEME.TXT", ruta[0..n]);
    // nombres inválidos
    try testing.expectError(Error.NombreInvalido, v.crear(d, "con espacio", fmt.TIPO_ARCHIVO, ""));
    try testing.expectError(Error.NombreInvalido, v.crear(d, "a/b", fmt.TIPO_ARCHIVO, ""));
    // duplicado
    try testing.expectError(Error.YaExiste, v.crear(d, "leeme.txt", fmt.TIPO_ARCHIVO, "x"));
    // directorio no vacío no se borra
    try testing.expectError(Error.DirectorioNoVacio, v.borrar(d));
    try testing.expectError(Error.NoEsDirectorio, v.crear(idx, "hijo", fmt.TIPO_DIRECTORIO, ""));
}

test "volumen: límites de tabla y fragmentación" {
    var v = try volPrueba();
    defer testing.allocator.free(v.datos);

    // 255 entradas libres (la raíz ocupa una)
    var i: u32 = 0;
    var ok: u32 = 0;
    while (i < 300) : (i += 1) {
        var nombre: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&nombre, "f{d:0>3}", .{i}) catch unreachable;
        if (v.crear(fmt.RAIZ, s, fmt.TIPO_ARCHIVO, "x")) |_| {
            ok += 1;
        } else |err| {
            try testing.expectEqual(Error.TablaLlena, err);
        }
    }
    try testing.expectEqual(@as(u32, 255), ok);
}

test "volumen: entradas corruptas se rechazan sin pánico" {
    // volumen sano, luego corrompemos campos como haría un disco dañado
    var v = try volPrueba();
    defer testing.allocator.free(v.datos);
    const idx = try v.crear(fmt.RAIZ, "datos.bin", fmt.TIPO_ARCHIVO, "contenido");
    _ = idx;

    // (a) nbloques gigante → desbordamiento u32 si se multiplica en 32 bits
    {
        const e = v.entrada(1).?;
        e.nbloques = 0xFFFF_FFFF;
        var buf: [64]u8 = undefined;
        try testing.expectError(Error.VolumenInvalido, v.leer(1, &buf));
        e.nbloques = 1; // restaurar
    }
    // (b) primer_bloque fuera de rango → zonaDatos devuelve null
    {
        const e = v.entrada(1).?;
        e.primer_bloque = 0xFFFF_FFFF;
        var buf: [64]u8 = undefined;
        try testing.expectError(Error.VolumenInvalido, v.leer(1, &buf));
        e.primer_bloque = v.sb_datos_bloque; // restaurar (bloque inicial válido)
    }
    // (c) liberar con extensión corrupta no toca el bitmap fuera de rango
    {
        const e = v.entrada(1).?;
        const libres_antes = v.libres();
        e.primer_bloque = 0x0080_0000;
        e.nbloques = 0x0100;
        v.borrar(1) catch {}; // liberar interno con límites
        try testing.expectEqual(libres_antes, v.libres()); // nada liberado fuera de rango
    }
    // (d) abrir con la tabla corrupta → VolumenInvalido (no pánico)
    {
        const e = v.entrada(2).?;
        e.tipo = 7; // tipo inválido
        try testing.expectError(Error.VolumenInvalido, Volumen.abrir(v.datos));
        e.tipo = fmt.TIPO_LIBRE;
    }
    // (e) ciclo padre↔hijo: rutas finitas rebotan sin colgarse y las que
    //     superan la profundidad máxima se rechazan; rutaAbsoluta también
    //     se corta (guard de partes), no cuelga
    {
        const a = v.entrada(1).?;
        const b = v.entrada(2).?;
        a.tipo = fmt.TIPO_DIRECTORIO;
        a.padre = 2;
        b.tipo = fmt.TIPO_DIRECTORIO;
        b.padre = 1;
        // 16 ".." dentro del límite: termina (rebotando por el ciclo) sin error
        const r = try v.resolverDesde(1, "../../../../../../../../../../../../../../..");
        try testing.expect(r == 1 or r == 2);
        // 17 componentes superan MAX_PROFUNDIDAD
        try testing.expectError(Error.RutaInvalida, v.resolverDesde(1, "../../../../../../../../../../../../../../../../.."));
        // la ruta absoluta de una entrada en ciclo se corta por el guard
        var ruta: [96]u8 = undefined;
        try testing.expectError(Error.RutaInvalida, v.rutaAbsoluta(1, &ruta));
    }
}
