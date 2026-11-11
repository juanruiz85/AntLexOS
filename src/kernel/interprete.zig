//! AntLex OS — intérprete de comandos (consola).
//! Comandos en español con alias en inglés; toda la salida se refleja por
//! el puerto serie (consola remota para pruebas automatizadas).
//! Fase 2: comandos de archivos ALFS y base del sistema.
//! Fase 3 (siguiente): historial, autocompletado, reloj, apagado…

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

const LARGO_LINEA = 120;
const LARGO_RUTA = 96;

var bi_global: ?*const boot_info.BootInfo = null;
var cwd: u16 = fmt.RAIZ;
var linea: [LARGO_LINEA]u8 = undefined;
var len: usize = 0;

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
    salida(" (");
    salida(version.ASISTENTE);
    salida(" llega en la Fase 4):\n\n");
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
    var buf: [16]u8 = undefined;
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
    .{ .nombre = "espacio", .alias = "df", .ayuda = "espacio libre del volumen", .uso = "espacio", .ejecutar = cmdEspacio },
    .{ .nombre = "sincronizar", .alias = "sync", .ayuda = "escribe los cambios al disco", .uso = "sincronizar", .ejecutar = cmdSincronizar },
    .{ .nombre = "teclado", .alias = "", .ayuda = "distribucion de teclado es|us", .uso = "teclado es|us", .ejecutar = cmdTeclado },
};

// ---------------------------------------------------------------------------
// bucle principal
// ---------------------------------------------------------------------------

pub fn init(bi: *const boot_info.BootInfo) void {
    bi_global = bi;
    cwd = fmt.RAIZ;
    len = 0;
}

fn prompt() void {
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
pub fn bucle() noreturn {
    salida("CONSOLA LISTA\n");
    while (true) {
        prompt();
        len = 0;
        var terminada = false;
        while (!terminada) {
            x86.hlt();
            while (teclado.poll()) |c| {
                switch (c) {
                    '\n', '\r' => {
                        consola.putc('\n');
                        serial.putc('\n');
                        terminada = true;
                        break;
                    },
                    8 => {
                        if (len > 0) {
                            len -= 1;
                            consola.putc(8);
                            serial.putc(8);
                        }
                    },
                    teclado.CTRL_C => {
                        salida("^C\n");
                        len = 0;
                        terminada = true;
                        break;
                    },
                    0x80...0x9F => {}, // códigos especiales y controles C1
                    else => {
                        // acepta ASCII imprimible y Latin-1 (ñ, acentos, ¿¡…)
                        if (len < linea.len and c >= 32 and c != 127) {
                            linea[len] = c;
                            len += 1;
                            consola.putc(c);
                            serial.putc(c);
                        }
                    },
                }
            }
        }
        ejecutarLinea();
    }
}
