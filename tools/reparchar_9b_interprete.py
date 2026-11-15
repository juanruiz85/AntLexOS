#!/usr/bin/env python3
"""Añade tienda/descargar/red tienda al intérprete (fase 9b, escalera 4)."""
import sys

s = open("src/kernel/interprete.zig").read()
if "cmdDescargar" in s:
    print("ya aplicado")
    sys.exit(0)

ANCLA = "fn cmdHttps(args: []const u8) void {"
BLOQUE = '''// ---------------------------------------------------------------------------
// Fase 9b: tienda de aplicaciones (GitHub: juanruiz85/AntLexApps)
// ---------------------------------------------------------------------------

const TIENDA_REPO = "juanruiz85/AntLexApps/main";
var tienda_ip: [4]u8 = .{ 185, 199, 108, 133 }; // raw.githubusercontent.com (Fastly)
var tienda_puerto: u16 = 443;
var tienda_host: []const u8 = "raw.githubusercontent.com";

fn cmdRedTienda(args: []const u8) void {
    // red tienda [ip [puerto host]] — muestra o cambia el objetivo de la
    // tienda (el arnés de pruebas lo apunta a su servidor local)
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const ip_txt = it.next() orelse "";
    if (ip_txt.len == 0) {
        var b: [24]u8 = undefined;
        salida("tienda: ");
        salida(tienda_host);
        salida(" en ");
        salida(red.formatearIp(tienda_ip, &b));
        salida(":");
        entero(tienda_puerto);
        salida("\\n");
        return;
    }
    const ip = red.parsearIp(ip_txt) orelse {
        fallo("direccion no valida");
        return;
    };
    tienda_ip = ip;
    tienda_puerto = 443;
    tienda_host = "raw.githubusercontent.com";
    if (it.next()) |puerto_txt| {
        var puerto: u32 = 0;
        for (puerto_txt) |c| {
            if (c < '0' or c > '9') {
                fallo("puerto no valido");
                return;
            }
            puerto = puerto * 10 + (c - '0');
        }
        if (puerto == 0 or puerto > 65535) {
            fallo("puerto no valido");
            return;
        }
        tienda_puerto = @intCast(puerto);
    }
    if (it.next()) |host| tienda_host = host;
    var b: [24]u8 = undefined;
    serial.puts("red: tienda -> ");
    serial.puts(red.formatearIp(tienda_ip, &b));
    serial.puts(":");
    serial.putDec(tienda_puerto);
    serial.puts(" (");
    serial.puts(tienda_host);
    serial.puts(")\\n");
    ok("objetivo de la tienda actualizado");
}

/// Trae el INDICE de la tienda al búfer y devuelve su contenido parseado
/// (lineas "nombre|archivo|bytes|sha256|descripcion").
fn traerIndice(búfer: []u8) ?[]const u8 {
    var ruta: [128]u8 = undefined;
    const ruta_s = std.fmt.bufPrint(&ruta, "/{s}/INDICE", .{TIENDA_REPO}) catch return null;
    const r = tls.pedir(tienda_host, tienda_ip, tienda_puerto, ruta_s, búfer) orelse {
        fallo("no se pudo conectar con la tienda (ver serial)");
        return null;
    };
    if (r.estado != 200) {
        salida("tienda: el servidor respondio ");
        entero(r.estado);
        salida("\\n");
        return null;
    }
    return r.cuerpo;
}

fn cmdTienda(args: []const u8) void {
    _ = args;
    if (!red.activaRed()) {
        fallo("red no disponible");
        return;
    }
    const buf_p = mem.alloc(8192, 16) catch {
        fallo("sin memoria para el indice");
        return;
    };
    const búfer: []u8 = @as([*]u8, @ptrFromInt(buf_p))[0..8192];
    const indice = traerIndice(búfer) orelse return;

    // listar: nombre — descripcion (bytes)
    serial.puts("tienda: listado\\n");
    var apps: u32 = 0;
    var it = std.mem.splitScalar(u8, indice, '\\n');
    while (it.next()) |fila| {
        if (fila.len == 0) continue;
        var campos = std.mem.splitScalar(u8, fila, '|');
        const nombre = campos.next() orelse continue;
        _ = campos.next() orelse continue; // archivo
        const bytes_txt = campos.next() orelse continue;
        _ = campos.next() orelse continue; // sha256
        const desc = campos.rest();
        if (nombre.len == 0) continue;
        salida("tienda: ");
        salida(nombre);
        salida(" — ");
        salida(if (desc.len > 0) desc else "(sin descripcion)");
        salida(" (");
        salida(bytes_txt);
        salida(" bytes)\\n");
        apps += 1;
    }
    salida("tienda: ");
    entero(apps);
    salida(" aplicaciones (descargar <nombre>)\\n");
}

fn cmdDescargar(args: []const u8) void {
    const nombre = std.mem.trim(u8, args, " ");
    if (nombre.len == 0) {
        fallo("uso: descargar <nombre>");
        return;
    }
    if (!red.activaRed()) {
        fallo("red no disponible");
        return;
    }
    const buf_p = mem.alloc(8192, 16) catch {
        fallo("sin memoria");
        return;
    };
    const búfer: []u8 = @as([*]u8, @ptrFromInt(buf_p))[0..8192];
    const indice = traerIndice(búfer) orelse return;

    // buscar la entrada del nombre pedido
    var archivo: ?[]const u8 = null;
    var bytes_esperados: u32 = 0;
    var sha_txt: []const u8 = "";
    var it = std.mem.splitScalar(u8, indice, '\\n');
    while (it.next()) |fila| {
        var campos = std.mem.splitScalar(u8, fila, '|');
        const nom = campos.next() orelse continue;
        if (!std.mem.eql(u8, nom, nombre)) continue;
        archivo = campos.next() orelse continue;
        const bytes_txt = campos.next() orelse break;
        sha_txt = campos.next() orelse break;
        bytes_esperados = std.fmt.parseInt(u32, bytes_txt, 10) catch 0;
        break;
    }
    const archivo_s = archivo orelse {
        salida("descargar: no hay ninguna aplicacion llamada ");
        salida(nombre);
        salida("\\n");
        return;
    };
    if (bytes_esperados == 0 or sha_txt.len != 64) {
        fallo("entrada del indice invalida");
        return;
    }

    // descargar la app a un búfer de heap
    const buf_app_p = mem.alloc(bytes_esperados + 4096, 16) catch {
        fallo("sin memoria para la descarga");
        return;
    };
    const buf_app: []u8 = @as([*]u8, @ptrFromInt(buf_app_p))[0 .. bytes_esperados + 4096];
    var ruta: [160]u8 = undefined;
    const ruta_s = std.fmt.bufPrint(&ruta, "/{s}/{s}", .{ TIENDA_REPO, archivo_s }) catch {
        fallo("ruta demasiado larga");
        return;
    };
    const r = tls.pedir(tienda_host, tienda_ip, tienda_puerto, ruta_s, buf_app) orelse {
        fallo("no se pudo descargar (ver serial)");
        return;
    };
    if (r.estado != 200) {
        salida("descargar: el servidor respondio ");
        entero(r.estado);
        salida("\\n");
        return;
    }
    if (r.cuerpo.len != bytes_esperados) {
        salida("descargar: tamano inesperado (");
        entero(@intCast(r.cuerpo.len));
        salida(" != ");
        entero(bytes_esperados);
        salida(")\\n");
        return;
    }

    // verificar SHA-256 contra el indice
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(r.cuerpo, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{digest}) catch unreachable;
    if (!std.mem.eql(u8, &hex, sha_txt)) {
        fallo("sha256 no coincide: descarga corrupta o indice antiguo");
        return;
    }
    salida("descargar: ");
    salida(nombre);
    salida(" verificado (sha256 ok, ");
    entero(bytes_esperados);
    salida(" bytes)\\n");

    // escribir en /APPS/ e instalar (bit de ejecutable)
    const v = volActual() orelse return;
    var destino: [64]u8 = undefined;
    var base = archivo_s;
    if (std.mem.lastIndexOfScalar(u8, archivo_s, '/')) |pos| base = archivo_s[pos + 1 ..];
    const destino_s = std.fmt.bufPrint(&destino, "/APPS/{s}", .{base}) catch {
        fallo("nombre de archivo demasiado largo");
        return;
    };
    const idx = crearEnRuta(v, destino_s, fmt.TIPO_ARCHIVO, r.cuerpo) catch |err| {
        alfsOError(err);
        return;
    };
    if (!alx.ponerBitEjecutable(idx, true)) {
        fallo("no se pudo marcar como ejecutable");
        return;
    }
    alfs.marcar();
    serial.puts("descargar: instalado ");
    serial.puts(destino_s);
    serial.puts("\\n");
    salida("descargar: instalado ");
    salida(destino_s);
    salida(" (ejecutarlo con: ejecutar ");
    salida(nombre);
    salida(".ALX)\\n");
}

fn cmdHttps(args: []const u8) void {'''
assert ANCLA in s
s = s.replace(ANCLA, BLOQUE)

TABLA = '''    .{ .nombre = "https", .alias = "", .ayuda = "GET de prueba sobre TLS 1.3", .uso = "https <ip> <puerto> <host> <ruta>", .ejecutar = cmdHttps },'''
assert TABLA in s
s = s.replace(TABLA, TABLA + '''
    .{ .nombre = "tienda", .alias = "store", .ayuda = "lista las apps del repo AntLexApps", .uso = "tienda", .ejecutar = cmdTienda },
    .{ .nombre = "descargar", .alias = "download", .ayuda = "descarga una app de la tienda, verifica sha256 e instala", .uso = "descargar <nombre>", .ejecutar = cmdDescargar },''')

DESP = '''    if (std.mem.startsWith(u8, args, "ca ")) {
        cmdRedCa(args[3..]);
        return;
    }'''
assert DESP in s
s = s.replace(DESP, DESP + '''
    if (std.mem.startsWith(u8, args, "tienda")) {
        cmdRedTienda(std.mem.trim(u8, args[6..], " "));
        return;
    }''')

open("src/kernel/interprete.zig", "w").write(s)
print("tienda/descargar/red tienda aplicados")
