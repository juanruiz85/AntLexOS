//! AntLex OS — intérprete de comandos (consola).
//! Comandos en español con alias en inglés; toda la salida se refleja por
//! el puerto serie (consola remota para pruebas automatizadas).
//! Fase 2: comandos de archivos ALFS y base del sistema.
//! Fase 3: historial con flechas, autocompletado con TAB, reloj RTC,
//!         sistema (sysinfo), pruebas, renombrar, buscar, apagar/reiniciar.

const std = @import("std");
const consola = @import("consola.zig");
const serial = @import("serial.zig");
const teclado = @import("teclado.zig");
const version = @import("version.zig");
const alfs = @import("alfs.zig");
const fmt = @import("alfs_formato.zig");
const mem = @import("mem.zig");
const ata = @import("ata.zig");
const x86 = @import("x86.zig");
const boot_info = @import("boot_info.zig");
const pantalla = @import("pantalla.zig");
const pit = @import("pit.zig");
const reloj = @import("reloj.zig");
const alx = @import("alx.zig");
const alx_def = @import("alx_def.zig");
const gui = @import("gui.zig"); // abrirApp/editorAbrir (Fase 7)
const autoprueba = @import("autoprueba.zig");
const antlex = @import("antlex.zig");

const LARGO_LINEA = 120;
const LARGO_RUTA = 96;

var bi_global: ?*const boot_info.BootInfo = null;
var cwd: u16 = fmt.RAIZ;
var linea: [LARGO_LINEA]u8 = undefined;
var len: usize = 0;

// ---------------------------------------------------------------------------
// historial de comandos (Fase 3)
// ---------------------------------------------------------------------------

const HISTORIA_MAX = 16;
var historial: [HISTORIA_MAX][LARGO_LINEA]u8 = undefined;
var historial_len: [HISTORIA_MAX]usize = undefined;
var historia_primera: usize = 0; // número absoluto (0-based) de la más antigua
var historia_num: usize = 0; // total de líneas guardadas
var nav_pos: usize = 0; // posición de navegación (historia_num = línea nueva)
var en_curso: [LARGO_LINEA]u8 = undefined;
var en_curso_len: usize = 0;
var navegando = false;

fn guardarHistorial(l: []const u8) void {
    // recortar espacios y descartar líneas vacías
    var s = l;
    while (s.len > 0 and s[0] == ' ') s = s[1..];
    while (s.len > 0 and s[s.len - 1] == ' ') s = s[0 .. s.len - 1];
    if (s.len == 0) return;
    // sin duplicados consecutivos
    if (historia_num > historia_primera) {
        const ult = historia_num - 1;
        if (std.mem.eql(u8, historial[ult - historia_primera][0..historial_len[ult - historia_primera]], s)) return;
    }
    if (historia_num - historia_primera == HISTORIA_MAX) {
        // desplazar: se pierde la más antigua
        var i: usize = 1;
        while (i < HISTORIA_MAX) : (i += 1) {
            historial[i - 1] = historial[i];
            historial_len[i - 1] = historial_len[i];
        }
        historia_primera += 1;
    }
    const slot = historia_num - historia_primera;
    @memcpy(historial[slot][0..s.len], s);
    historial_len[slot] = s.len;
    historia_num += 1;
}

/// Sustituye la línea en edición por otra: borra lo escrito (retrocesos)
/// y hace el eco de la nueva, en consola y serie.
fn cargarLinea(nueva: []const u8) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        // retroceso + espacio + retroceso: borra el glifo en consola y en serie
        consola.putc(8);
        consola.putc(' ');
        consola.putc(8);
        serial.putc(8);
        serial.putc(' ');
        serial.putc(8);
    }
    const n = @min(nueva.len, linea.len);
    @memcpy(linea[0..n], nueva[0..n]);
    len = n;
    salida(linea[0..len]);
}

fn flechaArriba() void {
    if (historia_num == 0 or nav_pos <= historia_primera) return;
    if (!navegando) {
        @memcpy(en_curso[0..len], linea[0..len]);
        en_curso_len = len;
        navegando = true;
    }
    nav_pos -= 1;
    const slot = nav_pos - historia_primera;
    cargarLinea(historial[slot][0..historial_len[slot]]);
}

fn flechaAbajo() void {
    if (!navegando) return;
    if (nav_pos >= historia_num) return;
    nav_pos += 1;
    if (nav_pos == historia_num) {
        navegando = false;
        cargarLinea(en_curso[0..en_curso_len]);
        return;
    }
    const slot = nav_pos - historia_primera;
    cargarLinea(historial[slot][0..historial_len[slot]]);
}

// ---------------------------------------------------------------------------
// salida (consola + serie)
// ---------------------------------------------------------------------------

fn salida(txt: []const u8) void {
    consola.puts(txt);
    serial.puts(txt);
}

fn salidaColor(color: u32, txt: []const u8) void {
    const previo = consola.estiloActual();
    consola.fijarEstilo(.{ .tinta = color, .fondo = previo.fondo });
    consola.puts(txt);
    serial.puts(txt);
    consola.fijarEstilo(previo);
}

fn fallo(msg: []const u8) void {
    salidaColor(consola.COLOR_ERROR, "error: ");
    salida(msg);
    salida("\n");
}

fn ok(msg: []const u8) void {
    salidaColor(consola.COLOR_OK, "ok: ");
    salida(msg);
    salida("\n");
}

fn entero(n: u64) void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    salida(s);
}

// ---------------------------------------------------------------------------
// utilidades de ALFS
// ---------------------------------------------------------------------------

fn textoErrorAlfs(err: alfs.Error) []const u8 {
    return switch (err) {
        Error.VolumenInvalido => "volumen ALFS invalido o corrupto",
        Error.TablaLlena => "tabla de archivos llena (256 entradas)",
        Error.SinEspacio => "no queda espacio en el volumen",
        Error.Fragmentado => "no hay bloques contiguos suficientes (fragmentacion)",
        Error.YaExiste => "ya existe un archivo con ese nombre",
        Error.NoExiste => "no existe esa ruta",
        Error.NoEsDirectorio => "no es un directorio",
        Error.NoEsArchivo => "no es un archivo",
        Error.DirectorioNoVacio => "el directorio no esta vacio",
        Error.NombreInvalido => "nombre invalido (vacio, con espacio, '/' o >44 caracteres)",
        Error.RutaInvalida => "ruta invalida",
        Error.ArchivoGrande => "archivo demasiado grande (maximo 4 MiB)",
        Error.Desbordamiento => "búfer insuficiente",
    };
}

const Error = alfs.Error;

fn alfsOError(err: alfs.Error) void {
    fallo(textoErrorAlfs(err));
}

fn volActual() ?*alfs.Volumen {
    if (alfs.montado()) return alfs.actual();
    fallo("ALFS no esta montado");
    return null;
}

/// Divide `args` en su primera palabra y el resto.
fn partir(args: []const u8) struct { primero: []const u8, resto: []const u8 } {
    var i: usize = 0;
    while (i < args.len and args[i] == ' ') i += 1;
    var fin = i;
    while (fin < args.len and args[fin] != ' ') fin += 1;
    var j = fin;
    while (j < args.len and args[j] == ' ') j += 1;
    return .{ .primero = args[i..fin], .resto = args[j..] };
}

// ---------------------------------------------------------------------------
// comandos
// ---------------------------------------------------------------------------

fn cmdAyuda(args: []const u8) void {
    const p = partir(args);
    if (p.primero.len > 0) {
        for (COMANDOS) |c| {
            if (std.mem.eql(u8, c.nombre, p.primero) or (c.alias.len > 0 and std.mem.eql(u8, c.alias, p.primero))) {
                salida(c.nombre);
                if (c.alias.len > 0) {
                    salida(" (");
                    salida(c.alias);
                    salida(")");
                }
                salida(" — ");
                salida(c.ayuda);
                salida("\nuso: ");
                salida(c.uso);
                salida("\n");
                return;
            }
        }
        fallo("no conozco ese comando; escribe 'ayuda' sin argumentos");
        return;
    }
    salida("Comandos de AntLex OS v");
    salida(version.VERSION);
    salida(" (la IA del sistema responde con: antlex <pregunta>):\n\n");
    for (COMANDOS) |c| {
        salida("  ");
        salidaColor(consola.COLOR_TITULO, c.nombre);
        if (c.alias.len > 0) {
            salida(" / ");
            salida(c.alias);
        }
        var pad: usize = c.nombre.len + c.alias.len;
        while (pad < 14) : (pad += 1) salida(" ");
        salida("  ");
        salida(c.ayuda);
        salida("\n");
    }
    salida("\nDetalle de un comando: ayuda <comando>\n");
}

fn cmdVer(args: []const u8) void {
    _ = args;
    const m = mem.estadisticas();
    salida(version.NOMBRE);
    salida(" v");
    salida(version.VERSION);
    salida(" — ");
    salida(version.ESLOGAN);
    salida("\n");
    salida("arquitectura: ");
    salida(version.ARQUITECTURA);
    salida(" · licencia: ");
    salida(version.LICENCIA);
    salida(" · teclado: ");
    salida(teclado.distribucion());
    salida("\nmemoria: ");
    entero(m.total / 1024);
    salida(" KiB totales, ");
    entero(m.libre / 1024);
    salida(" KiB libres · arranque: ");
    if (bi_global) |bi| {
        salida(if (bi.flags & boot_info.MODO_UEFI != 0) "UEFI" else "BIOS");
        salida(if (bi.flags & boot_info.MODO_CD != 0) " (CD)" else "");
    }
    salida("\ndisco: ");
    salida(ata.modelo());
    var buf: [80]u8 = undefined;
    const f = reloj.leer();
    salida("\nreloj: ");
    salida(reloj.iso(f, &buf));
    salida(" · encendido: ");
    salida(reloj.textoUptime(pit.uptimeSeg(), &buf));
    salida("\n");
}

fn cmdEco(args: []const u8) void {
    salida(args);
    salida("\n");
}

fn cmdLimpiar(args: []const u8) void {
    _ = args;
    consola.limpiar();
}

const ContextoLista = struct {
    archivos: u32 = 0,
    directorios: u32 = 0,
    bytes: u64 = 0,
};

fn cbLista(ctx: *ContextoLista, indice: u16, e: *const fmt.Entrada) void {
    _ = indice;
    const nombre = nombreEntrada(e);
    salida(if (e.tipo == fmt.TIPO_DIRECTORIO) "  <DIR>  " else "         ");
    salidaColor(if (e.tipo == fmt.TIPO_DIRECTORIO) consola.COLOR_TITULO else consola.COLOR_TEXTO, nombre);
    var pad: usize = nombre.len;
    while (pad < 30) : (pad += 1) salida(" ");
    salida(" ");
    var buf: [24]u8 = undefined; // 19+ bytes: "99999999 B  999 blk"
    if (e.tipo == fmt.TIPO_ARCHIVO) {
        const s = std.fmt.bufPrint(&buf, "{d:>8} B  {d:>3} blk", .{ e.tam, e.nbloques }) catch "";
        salida(s);
        ctx.archivos += 1;
        ctx.bytes += e.tam;
    } else {
        const s = std.fmt.bufPrint(&buf, "{s:>13}", .{"--- DIR ---"}) catch "";
        salida(s);
        ctx.directorios += 1;
    }
    salida("\n");
}

fn nombreEntrada(e: *const fmt.Entrada) []const u8 {
    const n = @min(@as(u32, e.nombre_len), fmt.TAM_NOMBRE);
    return e.nombre[0..n];
}

fn cmdLista(args: []const u8) void {
    const v = volActual() orelse return;
    const objetivo = if (args.len == 0) cwd else v.resolverDesde(cwd, args) catch |err| {
        alfsOError(err);
        return;
    };
    if (v.tipoDe(objetivo) != fmt.TIPO_DIRECTORIO) {
        fallo("no es un directorio (usa 'mostrar' para archivos)");
        return;
    }
    var ruta: [LARGO_RUTA]u8 = undefined;
    const n = v.rutaAbsoluta(objetivo, &ruta) catch 0;
    salida("Contenido de ");
    salida(ruta[0..n]);
    salida(":\n");
    var ctx = ContextoLista{};
    v.hijosDe(objetivo, &ctx, cbLista);
    salida("\n  ");
    entero(ctx.archivos);
    salida(" archivo(s), ");
    entero(ctx.directorios);
    salida(" directorio(s), ");
    entero(v.libres());
    salida(" bloques libres\n");
}

fn cmdIr(args: []const u8) void {
    const v = volActual() orelse return;
    if (args.len == 0) {
        cwd = fmt.RAIZ;
        return;
    }
    const objetivo = v.resolverDesde(cwd, args) catch |err| {
        alfsOError(err);
        return;
    };
    if (v.tipoDe(objetivo) != fmt.TIPO_DIRECTORIO) {
        fallo("no es un directorio");
        return;
    }
    cwd = objetivo;
}

fn cmdRuta(args: []const u8) void {
    _ = args;
    const v = volActual() orelse return;
    var ruta: [LARGO_RUTA]u8 = undefined;
    const n = v.rutaAbsoluta(cwd, &ruta) catch 0;
    salida(ruta[0..n]);
    salida("\n");
}

fn cmdMostrar(args: []const u8) void {
    const v = volActual() orelse return;
    if (args.len == 0) {
        fallo("uso: mostrar <archivo>");
        return;
    }
    const idx = v.resolverDesde(cwd, args) catch |err| {
        alfsOError(err);
        return;
    };
    const tam = v.tamDe(idx) catch |err| {
        alfsOError(err);
        return;
    };
    if (tam > 512 * 1024) {
        fallo("archivo demasiado grande para mostrar (max 512 KiB)");
        return;
    }
    const buf_p = mem.alloc(tam + 1, 16) catch {
        fallo("sin memoria para leer");
        return;
    };
    const buf: []u8 = @as([*]u8, @ptrFromInt(buf_p))[0 .. tam + 1];
    const leidos = v.leer(idx, buf) catch |err| {
        alfsOError(err);
        return;
    };
    // volcar con caracteres visibles (los de control salvo \n se sustituyen)
    var i: usize = 0;
    while (i < leidos) : (i += 1) {
        const c = buf[i];
        if (c == '\n' or c == '\t' or c == '\r') {
            consola.putc(c);
            serial.putc(c);
        } else if (c >= 32 and c != 127) {
            consola.putc(c);
            serial.putc(c);
        } else {
            consola.putc('.');
            serial.putc('.');
        }
    }
    salida("\n[");
    entero(leidos);
    salida(" bytes]\n");
}

/// Divide una ruta en (directorio, nombre_final).
fn dividirRuta(ruta: []const u8) struct { dir: []const u8, nombre: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, ruta, '/')) |i| {
        return .{ .dir = ruta[0..i], .nombre = ruta[i + 1 ..] };
    }
    return .{ .dir = ".", .nombre = ruta };
}

/// Crea un archivo/directorio en una ruta con directorios intermedios
/// ya existentes. Devuelve el índice creado.
fn crearEnRuta(v: *alfs.Volumen, ruta: []const u8, tipo: u8, contenido: []const u8) alfs.Error!u16 {
    const d = dividirRuta(ruta);
    const padre: u16 = if (d.dir.len == 0)
        fmt.RAIZ // ruta absoluta "/nombre"
    else
        try v.resolverDesde(cwd, d.dir);
    return v.crear(padre, d.nombre, tipo, contenido);
}

fn cmdEscribir(args: []const u8) void {
    const v = volActual() orelse return;
    const p = partir(args);
    if (p.primero.len == 0) {
        fallo("uso: escribir <archivo> <texto>");
        return;
    }
    // si el archivo existe, se sustituye; si no, se crea
    const idx_existente: ?u16 = if (v.resolverDesde(cwd, p.primero)) |idx| idx else |err| switch (err) {
        Error.NoExiste => null,
        else => {
            alfsOError(err);
            return;
        },
    };
    if (idx_existente) |idx| {
        if (v.tipoDe(idx) != fmt.TIPO_ARCHIVO) {
            fallo("esa ruta es un directorio");
            return;
        }
        v.escribir(idx, p.resto) catch |err| {
            alfsOError(err);
            return;
        };
        alfs.marcar();
        salida("sustituido ");
        salida(p.primero);
        salida(" (");
        entero(p.resto.len);
        salida(" bytes)\n");
    } else {
        _ = crearEnRuta(v, p.primero, fmt.TIPO_ARCHIVO, p.resto) catch |err| {
            alfsOError(err);
            return;
        };
        alfs.marcar();
        salida("creado ");
        salida(p.primero);
        salida(" (");
        entero(p.resto.len);
        salida(" bytes)\n");
    }
}

fn cmdAnexar(args: []const u8) void {
    const v = volActual() orelse return;
    const p = partir(args);
    if (p.primero.len == 0) {
        fallo("uso: anexar <archivo> <texto>");
        return;
    }
    const idx = v.resolverDesde(cwd, p.primero) catch |err| {
        alfsOError(err);
        return;
    };
    const tam = v.tamDe(idx) catch |err| {
        alfsOError(err);
        return;
    };
    const total: usize = @as(usize, tam) + p.resto.len;
    const buf_p = mem.alloc(total, 16) catch {
        fallo("sin memoria");
        return;
    };
    const temp: []u8 = @as([*]u8, @ptrFromInt(buf_p))[0..total];
    v.anexar(idx, p.resto, temp) catch |err| {
        alfsOError(err);
        return;
    };
    alfs.marcar();
    ok("anexado a ");
    salida(p.primero);
    salida(" (ahora ");
    entero(total);
    salida(" bytes)\n");
}

fn cmdNuevoDir(args: []const u8) void {
    const v = volActual() orelse return;
    if (args.len == 0) {
        fallo("uso: nuevodir <nombre>");
        return;
    }
    _ = crearEnRuta(v, args, fmt.TIPO_DIRECTORIO, "") catch |err| {
        alfsOError(err);
        return;
    };
    alfs.marcar();
    ok("directorio creado\n");
}

fn cmdBorrar(args: []const u8) void {
    const v = volActual() orelse return;
    if (args.len == 0) {
        fallo("uso: borrar <ruta>");
        return;
    }
    const idx = v.resolverDesde(cwd, args) catch |err| {
        alfsOError(err);
        return;
    };
    if (idx == cwd) {
        fallo("no puedes borrar el directorio actual");
        return;
    }
    v.borrar(idx) catch |err| {
        alfsOError(err);
        return;
    };
    alfs.marcar();
    salida("borrado ");
    salida(args);
    salida("\n");
}

fn cmdCopiar(args: []const u8) void {
    const v = volActual() orelse return;
    const p = partir(args);
    if (p.primero.len == 0 or p.resto.len == 0) {
        fallo("uso: copiar <origen> <destino>");
        return;
    }
    const pd = partir(p.resto);
    if (pd.resto.len > 0) {
        fallo("uso: copiar <origen> <destino>");
        return;
    }
    const origen = v.resolverDesde(cwd, p.primero) catch |err| {
        alfsOError(err);
        return;
    };
    const tam = v.tamDe(origen) catch |err| {
        alfsOError(err);
        return;
    };
    const buf_p = mem.alloc(if (tam == 0) 1 else tam, 16) catch {
        fallo("sin memoria");
        return;
    };
    const buf: []u8 = @as([*]u8, @ptrFromInt(buf_p))[0..tam];
    _ = v.leer(origen, buf) catch |err| {
        alfsOError(err);
        return;
    };
    _ = crearEnRuta(v, pd.primero, fmt.TIPO_ARCHIVO, buf) catch |err| {
        alfsOError(err);
        return;
    };
    alfs.marcar();
    salida("copiado a ");
    salida(pd.primero);
    salida(" (");
    entero(tam);
    salida(" bytes)\n");
}

fn cmdEspacio(args: []const u8) void {
    _ = args;
    const v = volActual() orelse return;
    const sb = v.superbloque();
    var fin: usize = 0;
    while (fin < sb.etiqueta.len and sb.etiqueta[fin] != 0) fin += 1;
    salida("Volumen ALFS \"");
    salida(sb.etiqueta[0..fin]);
    salida("\"\n  bloques: ");
    entero(v.n_bloques);
    salida(" x 512 B (");
    entero(@as(u64, v.n_bloques) * 512 / 1024);
    salida(" KiB)\n  libres: ");
    entero(v.libres());
    salida(" bloques (");
    entero(@as(u64, v.libres()) * 512 / 1024);
    salida(" KiB)\n  entradas de tabla libres: ");
    entero(v.entradasLibres());
    salida(" de ");
    entero(fmt.MAX_ENTRADAS);
    salida("\n  disco: ");
    salida(ata.modelo());
    salida("\n");
}

fn cmdSincronizar(args: []const u8) void {
    _ = args;
    if (!alfs.montado()) {
        fallo("ALFS no esta montado");
        return;
    }
    const n = alfs.sincronizar() catch {
        fallo("fallo la escritura al disco");
        return;
    };
    ok("ALFS SINCRONIZADO (");
    entero(n / 1024);
    salida(" KiB escritos)\n");
}

fn cmdTeclado(args: []const u8) void {
    if (args.len == 0) {
        salida("teclado actual: ");
        salida(teclado.distribucion());
        salida("\nuso: teclado es|us\n");
        return;
    }
    if (teclado.fijarDistribucion(args)) {
        ok("teclado cambiado a ");
        salida(args);
        salida("\n");
    } else {
        fallo("distribucion desconocida (usa 'es' o 'us')");
    }
}

// ---------------------------------------------------------------------------
// autocompletado con TAB (Fase 3)
// ---------------------------------------------------------------------------

fn appendCaracteres(s: []const u8) void {
    for (s) |c| {
        if (len < linea.len) {
            linea[len] = c;
            len += 1;
            consola.putc(c);
            serial.putc(c);
        }
    }
}

/// ¿Empieza `nombre` por `prefijo`? (comparación sin mayúsculas, ASCII)
fn empiezaConCI(nombre: []const u8, prefijo: []const u8) bool {
    if (nombre.len < prefijo.len) return false;
    for (prefijo, 0..) |c, i| {
        const a = if (c >= 'A' and c <= 'Z') c + 32 else c;
        const b0 = nombre[i];
        const b = if (b0 >= 'A' and b0 <= 'Z') b0 + 32 else b0;
        if (a != b) return false;
    }
    return true;
}

/// ¿Contiene `pajar` a `aguja`? (sin mayúsculas)
fn contieneCI(pajar: []const u8, aguja: []const u8) bool {
    if (aguja.len == 0) return true;
    if (pajar.len < aguja.len) return false;
    var i: usize = 0;
    while (i + aguja.len <= pajar.len) : (i += 1) {
        if (empiezaConCI(pajar[i..], aguja)) return true;
    }
    return false;
}

const MAX_COINC = 24;
var coinc_nombres: [MAX_COINC][]const u8 = undefined;
var coinc_es_dir = [_]bool{false} ** MAX_COINC;
var coinc_n: usize = 0;

/// Completa la coincidencia única o muestra las opciones (y amplía el
/// prefijo común). `escrito` = caracteres ya tecleados del nombre.
fn resolverCoincidencias(escrito: usize, es_comando: bool) void {
    if (coinc_n == 0) return;
    if (coinc_n == 1) {
        const nom = coinc_nombres[0];
        if (nom.len > escrito) appendCaracteres(nom[escrito..]);
        if (es_comando or !coinc_es_dir[0]) {
            appendCaracteres(" ");
        } else {
            appendCaracteres("/");
        }
        return;
    }
    // prefijo común entre las coincidencias
    var comun = escrito;
    comun: while (comun < coinc_nombres[0].len) {
        const c = coinc_nombres[0][comun];
        for (coinc_nombres[0..coinc_n]) |nom| {
            if (comun >= nom.len or nom[comun] != c) break :comun;
        }
        comun += 1;
    }
    if (comun > escrito) appendCaracteres(coinc_nombres[0][escrito..comun]);
    // listar opciones y redibujar prompt+línea
    salida("\n");
    for (coinc_nombres[0..coinc_n]) |nom| {
        salida(nom);
        salida("  ");
    }
    salida("\n");
    prompt();
    salida(linea[0..len]);
}

fn autocompletarComando(prefijo: []const u8) void {
    coinc_n = 0;
    for (COMANDOS) |c| {
        if (coinc_n >= MAX_COINC) break;
        const por_nombre = empiezaConCI(c.nombre, prefijo);
        if (por_nombre) {
            coinc_nombres[coinc_n] = c.nombre;
            coinc_es_dir[coinc_n] = false;
            coinc_n += 1;
        }
        // un alias también completa, con el propio alias como texto
        if (!por_nombre and c.alias.len > 0 and empiezaConCI(c.alias, prefijo)) {
            coinc_nombres[coinc_n] = c.alias;
            coinc_es_dir[coinc_n] = false;
            coinc_n += 1;
        }
    }
    resolverCoincidencias(prefijo.len, true);
}

const CtxComp = struct {
    nombre: []const u8,
    n: usize,
};

fn cbComp(ctx: *CtxComp, indice: u16, e: *const fmt.Entrada) void {
    _ = indice;
    if (ctx.n >= MAX_COINC) return;
    const nom = nombreEntrada(e);
    if (empiezaConCI(nom, ctx.nombre)) {
        coinc_nombres[ctx.n] = nom;
        coinc_es_dir[ctx.n] = e.tipo == fmt.TIPO_DIRECTORIO;
        ctx.n += 1;
    }
}

fn autocompletarRuta(prefijo: []const u8) void {
    if (!alfs.montado()) return;
    const v = alfs.actual().?;
    var dir_parte: []const u8 = ".";
    var nombre = prefijo;
    if (std.mem.lastIndexOfScalar(u8, prefijo, '/')) |i| {
        dir_parte = prefijo[0..i];
        nombre = prefijo[i + 1 ..];
    }
    const dir_idx = v.resolverDesde(cwd, dir_parte) catch return;
    if (v.tipoDe(dir_idx) != fmt.TIPO_DIRECTORIO) return;
    var ctx = CtxComp{ .nombre = nombre, .n = 0 };
    v.hijosDe(dir_idx, &ctx, cbComp);
    coinc_n = ctx.n;
    resolverCoincidencias(nombre.len, false);
}

fn autocompletar() void {
    if (len == 0) return;
    var inicio: usize = len;
    while (inicio > 0 and linea[inicio - 1] != ' ') inicio -= 1;
    const prefijo = linea[inicio..len];
    if (inicio == 0) {
        autocompletarComando(prefijo);
    } else {
        autocompletarRuta(prefijo);
    }
}

// ---------------------------------------------------------------------------
// comandos de Fase 3
// ---------------------------------------------------------------------------

fn cmdSistema(args: []const u8) void {
    _ = args;
    const m = mem.estadisticas();
    var buf: [96]u8 = undefined;

    salidaColor(consola.COLOR_TITULO,
        \\      \  /
        \\    ( o o )      AntLex OS
        \\     \ - /
        \\   .-'~~~'-.
        \\  / |     | \
        \\    |     |
        \\   _|     |_
    );
    salida("\n\n");

    const modo: []const u8 = if (bi_global) |bi| (if (bi.flags & boot_info.MODO_UEFI != 0) "UEFI" else "BIOS") else "?";
    const modo_cd: []const u8 = if (bi_global) |bi| (if (bi.flags & boot_info.MODO_CD != 0) " + CD" else "") else "";

    salida("  sistema    : ");
    salida(version.NOMBRE);
    salida(" v");
    salida(version.VERSION);
    salida(" (");
    salida(modo);
    salida(modo_cd);
    salida(")\n");

    var marca = [_]u8{0} ** 48;
    x86.cpuidMarca(&marca);
    salida("  cpu        : ");
    salida(std.mem.trim(u8, &marca, " "));
    salida("\n  memoria    : ");
    salida(std.fmt.bufPrint(&buf, "{d} MiB totales, {d} MiB libres", .{ m.total / (1024 * 1024), m.libre / (1024 * 1024) }) catch "?");
    salida("\n  pantalla   : ");
    salida(std.fmt.bufPrint(&buf, "{d}x{d}, {d} bpp", .{ pantalla.anchoPix(), pantalla.altoPix(), 32 }) catch "?");
    salida("\n  disco      : ");
    salida(ata.modelo());
    if (alfs.montado()) {
        const v = alfs.actual().?;
        salida(std.fmt.bufPrint(&buf, " (ALFS: {d}/{d} bloques libres)", .{ v.libres(), v.n_bloques }) catch "");
    }
    salida("\n  teclado    : ");
    salida(teclado.distribucion());
    salida(" (cambia con 'teclado es|us')");
    salida("\n  encendido  : ");
    salida(reloj.textoUptime(pit.uptimeSeg(), &buf));
    const f = reloj.leer();
    salida("\n  fecha      : ");
    salida(reloj.iso(f, &buf));
    salida("\n  licencia   : ");
    salida(version.LICENCIA);
    salida(" · autor: juanruiz85\n");
}

fn cmdFecha(args: []const u8) void {
    _ = args;
    const f = reloj.leer();
    var buf: [80]u8 = undefined;
    salida("Hoy es ");
    salida(reloj.textoLargo(f, &buf));
    salida("  (");
    salida(reloj.iso(f, &buf));
    salida(" UTC)\n");
}

fn cmdHora(args: []const u8) void {
    _ = args;
    const f = reloj.leer();
    var buf: [80]u8 = undefined;
    salida("Son las ");
    salida(reloj.textoHora(f, &buf));
    salida(" UTC · encendido: ");
    salida(reloj.textoUptime(pit.uptimeSeg(), &buf));
    salida("\n");
}

fn cmdPruebas(args: []const u8) void {
    _ = args;
    const bi = bi_global orelse {
        fallo("boot_info no disponible");
        return;
    };
    salida("Ejecutando autopruebas (detalle tambien por COM1):\n");
    autoprueba.activarEcoConsola(true);
    autoprueba.ejecutar(bi);
    autoprueba.activarEcoConsola(false);
    const c = autoprueba.ultimaCuenta();
    if (c.fallan == 0) {
        var nbuf: [48]u8 = undefined;
        ok(std.fmt.bufPrint(&nbuf, "autopruebas {d}/{d} correctas", .{ c.pasan, c.pasan + c.fallan }) catch "autopruebas correctas");
        salida("\n");
    } else {
        fallo("hay autopruebas fallidas (ver detalle)");
    }
}

fn cmdHistoria(args: []const u8) void {
    _ = args;
    if (historia_num == 0) {
        salida("(historial vacio)\n");
        return;
    }
    var n = historia_primera;
    while (n < historia_num) : (n += 1) {
        var nbuf: [16]u8 = undefined;
        salida("  ");
        salida(std.fmt.bufPrint(&nbuf, "{d:>3}", .{n + 1}) catch "  ?");
        salida("  ");
        salida(historial[n - historia_primera][0..historial_len[n - historia_primera]]);
        salida("\n");
    }
}

fn cmdRenombrar(args: []const u8) void {
    const v = volActual() orelse return;
    const p = partir(args);
    if (p.primero.len == 0 or p.resto.len == 0) {
        fallo("uso: renombrar <archivo> <nuevo-nombre>");
        return;
    }
    const pd = partir(p.resto);
    if (pd.resto.len > 0) {
        fallo("el nuevo nombre debe ser un nombre simple, sin espacios ni rutas");
        return;
    }
    const idx = v.resolverDesde(cwd, p.primero) catch |err| {
        alfsOError(err);
        return;
    };
    if (v.tipoDe(idx) != fmt.TIPO_ARCHIVO) {
        fallo("solo se renombran archivos (directorios en una fase futura)");
        return;
    }
    const tam = v.tamDe(idx) catch |err| {
        alfsOError(err);
        return;
    };
    const buf_p = mem.alloc(if (tam == 0) 1 else tam, 16) catch {
        fallo("sin memoria");
        return;
    };
    const buf: []u8 = @as([*]u8, @ptrFromInt(buf_p))[0..tam];
    _ = v.leer(idx, buf) catch |err| {
        alfsOError(err);
        return;
    };
    const d = dividirRuta(p.primero);
    const padre: u16 = if (d.dir.len == 0) fmt.RAIZ else v.resolverDesde(cwd, d.dir) catch |err| {
        alfsOError(err);
        return;
    };
    // crear el nuevo y borrar el viejo: si crear falla, el original queda intacto
    _ = v.crear(padre, pd.primero, fmt.TIPO_ARCHIVO, buf) catch |err| {
        alfsOError(err);
        return;
    };
    v.borrar(idx) catch |err| {
        salida("renombrado a ");
        salida(pd.primero);
        salida(" PERO no se pudo borrar el original (");
        salida(textoErrorAlfs(err));
        salida("); quedan dos archivos\n");
        alfs.marcar();
        return;
    };
    alfs.marcar();
    salida("renombrado a ");
    salida(pd.primero);
    salida(" (");
    entero(tam);
    salida(" bytes)\n");
}

const BufNivel = struct {
    indices: [64]u16 = undefined,
    tipos: [64]u8 = undefined,
    nombres: [64][48]u8 = undefined,
    nombres_len: [64]u8 = undefined,
    n: usize = 0,
};

const PROFUNDIDAD_MAX = 16; // límite de ALFS
var niveles_buscar: [PROFUNDIDAD_MAX]BufNivel = undefined;
var buf_ruta_buscar: [PROFUNDIDAD_MAX][128]u8 = undefined;

const CtxNivel = struct { nivel: *BufNivel };

fn cbNivel(ctx: *CtxNivel, indice: u16, e: *const fmt.Entrada) void {
    const b = ctx.nivel;
    if (b.n >= 64) return;
    const nom = nombreEntrada(e);
    const n = @min(nom.len, 48);
    @memcpy(b.nombres[b.n][0..n], nom[0..n]);
    b.nombres_len[b.n] = @intCast(n);
    b.indices[b.n] = indice;
    b.tipos[b.n] = e.tipo;
    b.n += 1;
}

const CtxBuscar = struct {
    patron: []const u8,
    resultados: u32 = 0,
    limite: u32 = 100,
};

fn buscarRec(ctx: *CtxBuscar, v: *alfs.Volumen, dir: u16, prefijo: []const u8, nivel: usize) void {
    if (nivel >= PROFUNDIDAD_MAX or ctx.resultados >= ctx.limite) return;
    const b = &niveles_buscar[nivel];
    b.n = 0;
    var ctxn = CtxNivel{ .nivel = b };
    v.hijosDe(dir, &ctxn, cbNivel);
    var i: usize = 0;
    while (i < b.n and ctx.resultados < ctx.limite) : (i += 1) {
        const nom = b.nombres[i][0..b.nombres_len[i]];
        // la coincidencia se comprueba SIEMPRE (usa `nom`, no la ruta)
        const coincide = contieneCI(nom, ctx.patron);
        const ruta_buf = &buf_ruta_buscar[nivel];
        const ruta = std.fmt.bufPrint(ruta_buf, "{s}/{s}", .{ prefijo, nom }) catch {
            // la ruta completa no cabe: informa con el nombre relativo y
            // no se puede descender en este subdirectorio (límite documentado)
            if (coincide) {
                salida("  .../");
                salida(nom);
                salida("\n");
                ctx.resultados += 1;
            }
            continue;
        };
        if (coincide) {
            salida("  ");
            salida(ruta);
            salida("\n");
            ctx.resultados += 1;
        }
        if (b.tipos[i] == fmt.TIPO_DIRECTORIO) {
            buscarRec(ctx, v, b.indices[i], ruta, nivel + 1);
        }
    }
}

fn cmdBuscar(args: []const u8) void {
    const v = volActual() orelse return;
    const p = partir(args);
    if (p.primero.len == 0) {
        fallo("uso: buscar <texto> [ruta]");
        return;
    }
    var inicio = cwd;
    if (p.resto.len > 0) {
        inicio = v.resolverDesde(cwd, p.resto) catch |err| {
            alfsOError(err);
            return;
        };
        if (v.tipoDe(inicio) != fmt.TIPO_DIRECTORIO) {
            fallo("no es un directorio");
            return;
        }
    }
    var ruta_raiz: [LARGO_RUTA]u8 = undefined;
    const n = v.rutaAbsoluta(inicio, &ruta_raiz) catch 0;
    salida("Buscando \"");
    salida(p.primero);
    salida("\" desde ");
    salida(ruta_raiz[0..n]);
    salida(":\n");
    var ctx = CtxBuscar{ .patron = p.primero };
    buscarRec(&ctx, v, inicio, ruta_raiz[0..n], 0);
    if (ctx.resultados >= ctx.limite) {
        salida("  (limite de ");
        var nbuf2: [16]u8 = undefined;
        salida(std.fmt.bufPrint(&nbuf2, "{d}", .{ctx.limite}) catch "?");
        salida(" resultados alcanzado)\n");
    }
    if (ctx.resultados == 0) {
        salida("  (sin coincidencias)\n");
    } else {
        var nbuf: [48]u8 = undefined;
        salida("  ");
        salida(std.fmt.bufPrint(&nbuf, "{d} coincidencia(s)", .{ctx.resultados}) catch "?");
        salida("\n");
    }
}

fn cmdApagar(args: []const u8) void {
    _ = args;
    salida("APAGANDO: ");
    if (alfs.montado() and alfs.hayCambiosSinSincronizar()) {
        salida("sincronizando ALFS... ");
        if (alfs.sincronizar()) |_| {
            salida("hecho. ");
        } else |_| {}
    }
    salida("hasta pronto.\n");
    x86.cli();
    // ACPI (QEMU y hardware moderno)
    x86.outw(0x604, 0x2000);
    x86.outw(0xB004, 0x2000);
    while (true) x86.hlt();
}

fn cmdReiniciar(args: []const u8) void {
    _ = args;
    salida("REINICIANDO: ");
    if (alfs.montado() and alfs.hayCambiosSinSincronizar()) {
        salida("sincronizando ALFS... ");
        if (alfs.sincronizar()) |_| {
            salida("hecho. ");
        } else |_| {}
    }
    salida("adios.\n");
    x86.cli();
    // pulso de reset del controlador 8042
    x86.outb(0x64, 0xFE);
    x86.ioWait();
    x86.ioWait();
    // plan B: triple fallo (IDT nula + interrupcion inevitable)
    var idt_nula = [_]u8{0} ** 10;
    asm volatile ("lidtq (%[d])"
        :
        : [d] "r" (&idt_nula),
    );
    asm volatile ("int3");
    while (true) x86.hlt();
}

fn cmdAntLex(args: []const u8) void {
    antlex.comando(args);
}

// ---------------------------------------------------------------------------
// tabla de comandos
// ---------------------------------------------------------------------------

const Comando = struct {
    nombre: []const u8,
    alias: []const u8,
    ayuda: []const u8,
    uso: []const u8,
    ejecutar: *const fn ([]const u8) void,
};

const COMANDOS = [_]Comando{
    .{ .nombre = "ayuda", .alias = "help", .ayuda = "lista de comandos", .uso = "ayuda [comando]", .ejecutar = cmdAyuda },
    .{ .nombre = "ver", .alias = "version", .ayuda = "version y datos del sistema", .uso = "ver", .ejecutar = cmdVer },
    .{ .nombre = "sistema", .alias = "sysinfo", .ayuda = "resumen grafico del sistema", .uso = "sistema", .ejecutar = cmdSistema },
    .{ .nombre = "eco", .alias = "echo", .ayuda = "muestra texto", .uso = "eco <texto>", .ejecutar = cmdEco },
    .{ .nombre = "limpiar", .alias = "cls", .ayuda = "borra la pantalla", .uso = "limpiar", .ejecutar = cmdLimpiar },
    .{ .nombre = "lista", .alias = "ls", .ayuda = "contenido de un directorio", .uso = "lista [ruta]", .ejecutar = cmdLista },
    .{ .nombre = "ir", .alias = "cd", .ayuda = "cambia de directorio", .uso = "ir <ruta>", .ejecutar = cmdIr },
    .{ .nombre = "ruta", .alias = "pwd", .ayuda = "muestra el directorio actual", .uso = "ruta", .ejecutar = cmdRuta },
    .{ .nombre = "mostrar", .alias = "cat", .ayuda = "muestra un archivo de texto", .uso = "mostrar <archivo>", .ejecutar = cmdMostrar },
    .{ .nombre = "escribir", .alias = "write", .ayuda = "crea o sustituye un archivo de texto", .uso = "escribir <archivo> <texto>", .ejecutar = cmdEscribir },
    .{ .nombre = "anexar", .alias = "append", .ayuda = "añade texto al final de un archivo", .uso = "anexar <archivo> <texto>", .ejecutar = cmdAnexar },
    .{ .nombre = "nuevodir", .alias = "mkdir", .ayuda = "crea un directorio", .uso = "nuevodir <nombre>", .ejecutar = cmdNuevoDir },
    .{ .nombre = "borrar", .alias = "rm", .ayuda = "elimina archivo o directorio vacio", .uso = "borrar <ruta>", .ejecutar = cmdBorrar },
    .{ .nombre = "copiar", .alias = "cp", .ayuda = "copia un archivo", .uso = "copiar <origen> <destino>", .ejecutar = cmdCopiar },
    .{ .nombre = "renombrar", .alias = "mv", .ayuda = "cambia el nombre de un archivo", .uso = "renombrar <archivo> <nuevo>", .ejecutar = cmdRenombrar },
    .{ .nombre = "buscar", .alias = "find", .ayuda = "busca archivos por nombre", .uso = "buscar <texto> [ruta]", .ejecutar = cmdBuscar },
    .{ .nombre = "espacio", .alias = "df", .ayuda = "espacio libre del volumen", .uso = "espacio", .ejecutar = cmdEspacio },
    .{ .nombre = "sincronizar", .alias = "sync", .ayuda = "escribe los cambios al disco", .uso = "sincronizar", .ejecutar = cmdSincronizar },
    .{ .nombre = "teclado", .alias = "", .ayuda = "distribucion de teclado es|us", .uso = "teclado es|us", .ejecutar = cmdTeclado },
    .{ .nombre = "fecha", .alias = "date", .ayuda = "fecha del reloj de tiempo real", .uso = "fecha", .ejecutar = cmdFecha },
    .{ .nombre = "hora", .alias = "time", .ayuda = "hora y tiempo de encendido", .uso = "hora", .ejecutar = cmdHora },
    .{ .nombre = "historia", .alias = "history", .ayuda = "historial de comandos", .uso = "historia", .ejecutar = cmdHistoria },
    .{ .nombre = "pruebas", .alias = "test", .ayuda = "ejecuta las autopruebas", .uso = "pruebas", .ejecutar = cmdPruebas },
    .{ .nombre = "antlex", .alias = "ai", .ayuda = "pregunta a la IA del sistema", .uso = "antlex <pregunta> | antlex por que | antlex aprende <clave> = <respuesta> | antlex memoria", .ejecutar = cmdAntLex },
    .{ .nombre = "ejecutar", .alias = "run", .ayuda = "carga una app .ALX instalada", .uso = "ejecutar <app.ALX>", .ejecutar = cmdEjecutar },
    .{ .nombre = "instalar", .alias = "install", .ayuda = "marca un .ALX como ejecutable", .uso = "instalar <app.ALX>", .ejecutar = cmdInstalar },
    .{ .nombre = "abrir", .alias = "open", .ayuda = "abre un archivo segun su extension", .uso = "abrir <archivo>", .ejecutar = cmdAbrir },
    .{ .nombre = "asociar", .alias = "assoc", .ayuda = "ver o cambiar asociaciones", .uso = "asociar [ext editor|ejecutar|mostrar]", .ejecutar = cmdAsociar },
    .{ .nombre = "atributos", .alias = "attrib", .ayuda = "tipo, tamano y bit de ejecutable", .uso = "atributos <archivo>", .ejecutar = cmdAtributos },
    .{ .nombre = "apagar", .alias = "shutdown", .ayuda = "sincroniza y apaga (QEMU cierra)", .uso = "apagar", .ejecutar = cmdApagar },
    .{ .nombre = "reiniciar", .alias = "reboot", .ayuda = "sincroniza y reinicia", .uso = "reiniciar", .ejecutar = cmdReiniciar },
};

// ---------------------------------------------------------------------------
// Fase 7 — ejecutables .ALX, bit de ejecutable y asociaciones
// ---------------------------------------------------------------------------

fn cmdEjecutar(args: []const u8) void {
    if (args.len == 0) {
        fallo("uso: ejecutar <app.ALX>");
        return;
    }
    const v = volActual() orelse return;
    const idx = v.resolverDesde(cwd, args) catch |err| {
        alfsOError(err);
        return;
    };
    const e = v.entrada(idx) orelse {
        fallo("no existe");
        return;
    };
    if (e.tipo != fmt.TIPO_ARCHIVO) {
        fallo("no es un archivo");
        return;
    }
    if (!alx_def.esAlx(args)) {
        fallo("los ejecutables de AntLex OS terminan en .ALX");
        return;
    }
    if ((e.flags & fmt.FLAG_EJECUTABLE) == 0) {
        fallo("no es ejecutable (instalalo primero: instalar <app.ALX>)");
        return;
    }
    salida("ejecutando ");
    salida(args);
    salida("...\n");
    if (!gui.abrirApp(idx)) {
        fallo("no se pudo cargar la aplicacion");
    }
}

fn cmdInstalar(args: []const u8) void {
    if (args.len == 0) {
        fallo("uso: instalar <app.ALX>");
        return;
    }
    const v = volActual() orelse return;
    const idx = v.resolverDesde(cwd, args) catch |err| {
        alfsOError(err);
        return;
    };
    if (!alx_def.esAlx(args)) {
        fallo("solo se instalan ejecutables .ALX");
        return;
    }
    if (!alx.ponerBitEjecutable(idx, true)) {
        fallo("no se pudo instalar (tiene que ser un archivo)");
        return;
    }
    salida("ok: instalado ");
    salida(args);
    salida(" (bit de ejecutable activo)\n");
}

fn cmdAbrir(args: []const u8) void {
    if (args.len == 0) {
        fallo("uso: abrir <archivo>");
        return;
    }
    const v = volActual() orelse return;
    const idx = v.resolverDesde(cwd, args) catch |err| {
        alfsOError(err);
        return;
    };
    const e = v.entrada(idx) orelse {
        fallo("no existe");
        return;
    };
    if (e.tipo != fmt.TIPO_ARCHIVO) {
        fallo("no es un archivo");
        return;
    }
    const accion = alx.asociaciones.accionPara(args) orelse {
        fallo("sin asociacion para esa extension (usa: asociar <ext> <accion>)");
        return;
    };
    switch (accion) {
        .ejecutar => cmdEjecutar(args),
        .mostrar => cmdMostrar(args),
        .editor => {
            const nombre = e.nombre[0..e.nombre_len];
            serial.puts("consola: abrir ");
            serial.puts(nombre);
            serial.puts(" con el editor\n");
            gui.editorAbrir(idx, nombre);
        },
    }
}

fn nombreAccion(a: alx_def.Accion) []const u8 {
    return switch (a) {
        .editor => "editor",
        .ejecutar => "ejecutar",
        .mostrar => "mostrar",
    };
}

fn cmdAsociar(args: []const u8) void {
    if (args.len == 0) {
        salida("asociaciones por extension:\n");
        var i: usize = 0;
        while (i < alx.asociaciones.n) : (i += 1) {
            const a = &alx.asociaciones.entradas[i];
            salida("  .");
            salida(a.ext[0..a.ext_len]);
            salida(" -> ");
            salida(nombreAccion(a.accion));
            salida("\n");
        }
        return;
    }
    // asociar <ext> <accion>
    const sep = std.mem.indexOfScalar(u8, args, ' ') orelse {
        fallo("uso: asociar <ext> <editor|ejecutar|mostrar>");
        return;
    };
    const ext = args[0..sep];
    const accion_txt = args[sep + 1 ..];
    var accion: alx_def.Accion = .mostrar;
    if (std.ascii.eqlIgnoreCase(accion_txt, "editor")) {
        accion = .editor;
    } else if (std.ascii.eqlIgnoreCase(accion_txt, "ejecutar")) {
        accion = .ejecutar;
    } else if (std.ascii.eqlIgnoreCase(accion_txt, "mostrar")) {
        accion = .mostrar;
    } else {
        fallo("accion no valida (editor, ejecutar o mostrar)");
        return;
    }
    if (!alx.asociaciones.asociar(ext, accion)) {
        fallo("extension invalida (max 6 letras) o tabla llena");
        return;
    }
    salida("ok: .");
    salida(ext);
    salida(" -> ");
    salida(nombreAccion(accion));
    salida("\n");
}

fn cmdAtributos(args: []const u8) void {
    if (args.len == 0) {
        fallo("uso: atributos <archivo>");
        return;
    }
    const v = volActual() orelse return;
    const idx = v.resolverDesde(cwd, args) catch |err| {
        alfsOError(err);
        return;
    };
    const e = v.entrada(idx) orelse return;
    salida(args);
    salida(": ");
    salida(if (e.tipo == fmt.TIPO_DIRECTORIO) "directorio" else "archivo");
    if (e.tipo == fmt.TIPO_ARCHIVO) {
        salida(", ");
        entero(e.tam);
        salida(" bytes");
        if ((e.flags & fmt.FLAG_EJECUTABLE) != 0) {
            salida(", EJECUTABLE");
        }
    }
    salida("\n");
}

// ---------------------------------------------------------------------------
// bucle principal
// ---------------------------------------------------------------------------

pub fn init(bi: *const boot_info.BootInfo) void {
    bi_global = bi;
    cwd = fmt.RAIZ;
    len = 0;
    historia_primera = 0;
    historia_num = 0;
    nav_pos = 0;
    navegando = false;
}

pub fn prompt() void {
    const previo = consola.estiloActual();
    consola.fijarEstilo(.{ .tinta = consola.COLOR_TITULO, .fondo = previo.fondo });
    salida("antlex:");
    if (alfs.montado()) {
        var ruta: [LARGO_RUTA]u8 = undefined;
        const v = alfs.actual().?;
        const n = v.rutaAbsoluta(cwd, &ruta) catch 0;
        salida(ruta[0..n]);
    } else {
        salida("/?");
    }
    salida("> ");
    consola.fijarEstilo(previo);
}

fn ejecutarLinea() void {
    var l = linea[0..len];
    // recortar espacios
    while (l.len > 0 and l[0] == ' ') l = l[1..];
    while (l.len > 0 and l[l.len - 1] == ' ') l = l[0 .. l.len - 1];
    if (l.len == 0) return;
    const p = partir(l);
    for (COMANDOS) |c| {
        if (std.mem.eql(u8, c.nombre, p.primero) or (c.alias.len > 0 and std.mem.eql(u8, c.alias, p.primero))) {
            c.ejecutar(p.resto);
            return;
        }
    }
    salidaColor(consola.COLOR_ERROR, "comando desconocido: ");
    salida(p.primero);
    salida(" (escribe 'ayuda')\n");
}

/// Bucle principal del intérprete (no vuelve nunca).
/// Prepara una línea nueva (lo llama la GUI y el propio bucle).
pub fn iniciarLinea() void {
    len = 0;
    nav_pos = historia_num;
    navegando = false;
}

/// Arranque en modo GUI: prompt + línea nueva (sin bloquear).
pub fn arrancar() void {
    prompt();
    iniciarLinea();
}

/// Procesa UNA tecla (lo llama la GUI cuando el TERMINAL tiene el foco).
/// En '\n' ejecuta la línea y devuelve el prompt, igual que el bucle clásico.
pub fn tecla(c: u8) void {
    switch (c) {
        '\n', '\r' => {
            consola.putc('\n');
            serial.putc('\n');
            guardarHistorial(linea[0..len]);
            ejecutarLinea();
            iniciarLinea();
            prompt();
        },
        8 => {
            if (len > 0) {
                len -= 1;
                consola.putc(8);
                serial.putc(8);
            }
        },
        '\t' => autocompletar(),
        teclado.FLECHA_ARRIBA => flechaArriba(),
        teclado.FLECHA_ABAJO => flechaAbajo(),
        teclado.FLECHA_IZQ, teclado.FLECHA_DER, teclado.SUPRIMIR, teclado.INICIO, teclado.FIN, teclado.F2, teclado.ESC => {},
        teclado.CTRL_C => {
            salida("^C\n");
            iniciarLinea();
            prompt();
        },
        else => {
            // acepta ASCII imprimible y Latin-1 (ñ, acentos, ¿¡…);
            // el rango C1 (0x80-0x9F) se descarta: es de control
            if (len < linea.len and c >= 32 and c != 127 and (c < 0x80 or c >= 0xA0)) {
                linea[len] = c;
                len += 1;
                consola.putc(c);
                serial.putc(c);
            }
        },
    }
}

pub fn bucle() noreturn {
    salida("CONSOLA LISTA\n");
    prompt();
    iniciarLinea();
    while (true) {
        x86.hlt();
        while (teclado.poll()) |c| tecla(c);
    }
}

/// Apagado limpio desde la GUI (menú INICIO): sincroniza y apaga por ACPI.
pub fn apagarSistema() void {
    cmdApagar("");
}
