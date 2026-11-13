//! AntLex OS — IA embebida AntLex (Fase 4): la identidad del sistema.
//! Red neuronal diminuta entrenada al compilar (pesos en antlex/pesos.zig),
//! inferencia en punto fijo SIN FPU (antlex/nucleo.zig) y respuestas con
//! datos en vivo del hardware. Memoria aprendida persistida en ALFS
//! (/memoria/antlex.txt). Explicabilidad con "antlex por que".
//!
//! El kernel no tiene FPU: toda la clasificación es entera (Q4.11/Q16.16).

const std = @import("std");
const nucleo = @import("antlex/nucleo.zig");
const pesos = @import("antlex/pesos.zig");
const consola = @import("consola.zig");
const serial = @import("serial.zig");
const version = @import("version.zig");
const mem = @import("mem.zig");
const pit = @import("pit.zig");
const reloj = @import("reloj.zig");
const pantalla = @import("pantalla.zig");
const x86 = @import("x86.zig");
const teclado = @import("teclado.zig");
const boot_info = @import("boot_info.zig");
const alfs = @import("alfs.zig");
const fmt = @import("alfs_formato.zig");
const ata = @import("ata.zig");

// ---------------------------------------------------------------------------
// salida (consola + serie, como el intérprete)
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

/// Prefijo "AntLex: " de cada respuesta (el arnés lo usa de marcador).
fn prefijo() void {
    salidaColor(consola.COLOR_TITULO, "AntLex");
    salida(": ");
}

fn fallo(msg: []const u8) void {
    salidaColor(consola.COLOR_ERROR, "AntLex error: ");
    salida(msg);
    salida("\n");
}

fn entero(n: u64) void {
    var buf: [24]u8 = undefined;
    salida(std.fmt.bufPrint(&buf, "{d}", .{n}) catch return);
}

// ---------------------------------------------------------------------------
// memoria aprendida (pares clave = valor, persistidos en ALFS)
// ---------------------------------------------------------------------------

const MAX_PARES = 64;
const LARGO_CLAVE = 48;
const LARGO_VALOR = 128;
const RUTA_MEMORIA = "memoria/antlex.txt";
const DIR_MEMORIA = "memoria";

const Par = struct {
    clave: [LARGO_CLAVE]u8 = undefined,
    clave_len: usize = 0,
    clave_norm: [LARGO_CLAVE]u8 = undefined,
    clave_norm_len: usize = 0,
    valor: [LARGO_VALOR]u8 = undefined,
    valor_len: usize = 0,

    fn claveStr(self: *const Par) []const u8 {
        return self.clave[0..self.clave_len];
    }
    fn claveNormStr(self: *const Par) []const u8 {
        return self.clave_norm[0..self.clave_norm_len];
    }
    fn valorStr(self: *const Par) []const u8 {
        return self.valor[0..self.valor_len];
    }
};

var pares: [MAX_PARES]Par = undefined;
var pares_n: usize = 0;

/// Carga los pares aprendidos de /memoria/antlex.txt (si existe y ALFS
/// está montado). Se llama tras montar ALFS en el arranque.
pub fn init() void {
    pares_n = 0;
    if (!alfs.montado()) return;
    const v = alfs.actual() orelse return;
    const idx = v.resolverDesde(fmt.RAIZ, RUTA_MEMORIA) catch return;
    const tam = v.tamDe(idx) catch return;
    if (tam == 0 or tam > 64 * 1024) return;
    const p = mem.alloc(tam + 1, 16) catch return;
    const buf: []u8 = @as([*]u8, @ptrFromInt(p))[0 .. tam + 1];
    const leidos = v.leer(idx, buf) catch return;
    // parsear líneas "clave = valor"
    var i: usize = 0;
    while (i < leidos and pares_n < MAX_PARES) {
        var fin = i;
        while (fin < leidos and buf[fin] != '\n') fin += 1;
        anexarParDeLinea(buf[i..fin]);
        i = fin + 1;
    }
}

/// Forma canónica de un texto: normalizado, sin palabras vacías, tokens
/// unidos por un espacio. Es la clave de cotejo de la memoria aprendida:
/// "¿Cuál es tu color favorito?" y "color favorito" canonizan igual.
fn canonica(texto: []const u8, bufer: []u8) []const u8 {
    var nbuf: [nucleo.MAX_NORMALIZADO]u8 = undefined;
    const norm = nucleo.normalizar(texto, &nbuf);
    var toks: [nucleo.MAX_TOKENS][]const u8 = undefined;
    const nt = nucleo.tokenizar(norm, &toks);
    var n: usize = 0;
    for (toks[0..nt], 0..) |t, i| {
        if (i > 0 and n < bufer.len) {
            bufer[n] = ' ';
            n += 1;
        }
        const m = @min(t.len, bufer.len - n);
        @memcpy(bufer[n .. n + m], t[0..m]);
        n += m;
        if (n >= bufer.len) break;
    }
    return bufer[0..n];
}

/// Añade el par codificado en una línea "clave = valor" (sin '\n').
fn anexarParDeLinea(linea: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, linea, '=') orelse return;
    const clave = std.mem.trim(u8, linea[0..eq], " ");
    const valor = std.mem.trim(u8, linea[eq + 1 ..], " ");
    if (clave.len == 0 or valor.len == 0) return;
    if (guardarPar(clave, valor)) |_| {} else |_| {}
}

/// Inserta o sustituye un par. Error.SinEspacio si la memoria está llena.
fn guardarPar(clave: []const u8, valor: []const u8) error{SinEspacio}!void {
    if (clave.len >= LARGO_CLAVE or valor.len >= LARGO_VALOR) return error.SinEspacio;
    // forma canónica de la clave para el cotejo (sin mayúsculas, acentos
    // ni palabras vacías: "¿Cuál es tu color?" == "color")
    var nbuf: [LARGO_CLAVE]u8 = undefined;
    const norm = canonica(clave, &nbuf);
    // ¿existe ya? sustituir
    var i: usize = 0;
    while (i < pares_n) : (i += 1) {
        if (std.mem.eql(u8, pares[i].claveNormStr(), norm)) {
            escribirPar(&pares[i], clave, norm, valor);
            return;
        }
    }
    if (pares_n >= MAX_PARES) return error.SinEspacio;
    escribirPar(&pares[pares_n], clave, norm, valor);
    pares_n += 1;
}

fn escribirPar(destino: *Par, clave: []const u8, norm: []const u8, valor: []const u8) void {
    @memcpy(destino.clave[0..clave.len], clave);
    destino.clave_len = clave.len;
    @memcpy(destino.clave_norm[0..norm.len], norm);
    destino.clave_norm_len = norm.len;
    @memcpy(destino.valor[0..valor.len], valor);
    destino.valor_len = valor.len;
}

/// Busca un par cuya clave normalizada coincida con la pregunta normalizada.
fn buscarPar(norm: []const u8) ?*const Par {
    var i: usize = 0;
    while (i < pares_n) : (i += 1) {
        if (std.mem.eql(u8, pares[i].claveNormStr(), norm)) return &pares[i];
    }
    return null;
}

/// Reescribe /memoria/antlex.txt en ALFS con los pares actuales.
fn persistirPares() bool {
    if (!alfs.montado()) return false;
    const v = alfs.actual() orelse return false;
    // componer el contenido
    const p = mem.alloc(MAX_PARES * (LARGO_CLAVE + LARGO_VALOR + 8), 16) catch return false;
    const buf: []u8 = @as([*]u8, @ptrFromInt(p))[0 .. MAX_PARES * (LARGO_CLAVE + LARGO_VALOR + 8)];
    var n: usize = 0;
    var i: usize = 0;
    while (i < pares_n) : (i += 1) {
        const par = &pares[i];
        if (n + par.clave_len + par.valor_len + 5 > buf.len) break;
        @memcpy(buf[n .. n + par.clave_len], par.claveStr());
        n += par.clave_len;
        @memcpy(buf[n .. n + 3], " = ");
        n += 3;
        @memcpy(buf[n .. n + par.valor_len], par.valorStr());
        n += par.valor_len;
        buf[n] = '\n';
        n += 1;
    }
    const contenido = buf[0..n];
    // crear o actualizar el archivo
    if (v.resolverDesde(fmt.RAIZ, RUTA_MEMORIA)) |idx| {
        v.escribir(idx, contenido) catch return false;
    } else |_| {
        const dir: u16 = v.resolverDesde(fmt.RAIZ, DIR_MEMORIA) catch blk: {
            break :blk v.crear(fmt.RAIZ, DIR_MEMORIA, fmt.TIPO_DIRECTORIO, "") catch return false;
        };
        _ = v.crear(dir, "antlex.txt", fmt.TIPO_ARCHIVO, contenido) catch return false;
    }
    alfs.marcar();
    return true;
}

// ---------------------------------------------------------------------------
// estado de la última respuesta (explicabilidad)
// ---------------------------------------------------------------------------

const Origen = enum { ninguna, red, aprendida, rechazada };

const LARGO_PREGUNTA = 120;
var ult_origen: Origen = .ninguna;
var ult_pregunta: [LARGO_PREGUNTA]u8 = undefined;
var ult_pregunta_len: usize = 0;
var ult_norm: [nucleo.MAX_NORMALIZADO]u8 = undefined;
var ult_norm_len: usize = 0;
var ult_tokens: [nucleo.MAX_TOKENS][]const u8 = undefined;
var ult_tokens_n: usize = 0;
var ult_confianza: u32 = 0;
var ult_cobertura: u32 = 0;
var ult_conocidos: usize = 0;
var ult_intencion: usize = 0;
var ult_segunda_pct: u32 = 0;
var ult_aportes: [nucleo.MAX_TOKENS]i32 = undefined;
var ult_aportes_n: usize = 0;
var ult_par: ?*const Par = null;
var ult_motivo: []const u8 = "";

fn guardarPregunta(q: []const u8) void {
    const n = @min(q.len, ult_pregunta.len);
    @memcpy(ult_pregunta[0..n], q[0..n]);
    ult_pregunta_len = n;
    ult_par = null;
    ult_origen = .ninguna;
}

// ---------------------------------------------------------------------------
// respuestas por intención (datos en vivo del hardware)
// ---------------------------------------------------------------------------

fn responder(intencion: []const u8) void {
    var buf: [160]u8 = undefined;
    if (std.mem.eql(u8, intencion, "saludo")) {
        salida("¡Hola! Soy AntLex, la IA de este sistema: pregúntame por la\nmemoria, el disco, la hora, los comandos... o por mí:\n  antlex quien eres\n");
    } else if (std.mem.eql(u8, intencion, "despedida")) {
        salida("Hasta pronto. Recuerda: 'apagar' sincroniza ALFS y apaga limpio\n(en QEMU la maquina se cierra sola).\n");
    } else if (std.mem.eql(u8, intencion, "identidad")) {
        salida("Soy AntLex, la IA embebida de AntLex OS: una red neuronal diminuta\n(16 neuronas ocultas) que vive DENTRO del kernel. Sin nube ni conexión:\nsolo sé hablar de este sistema. Pregúntame 'antlex que puedes hacer'.\n");
    } else if (std.mem.eql(u8, intencion, "autor")) {
        salida("AntLex OS lo desarrolla juanruiz85 en Zig, desde cero: bootloader,\nkernel, consola gráfica, sistema de archivos ALFS... y yo.\nCódigo y releases: github.com/juanruiz85/AntLexOS\n");
    } else if (std.mem.eql(u8, intencion, "version")) {
        salida("AntLex OS v");
        salida(version.VERSION);
        salida(" — ");
        salida(version.ESLOGAN);
        salida(".\nZig + x86_64, licencia ");
        salida(version.LICENCIA);
        salida(".\n");
    } else if (std.mem.eql(u8, intencion, "sistema_info")) {
        salida("AntLex OS es un sistema operativo experimental x86_64 escrito en\nZig desde cero: bootloader propio (BIOS y UEFI), consola grafica desde\nel arranque, sistema de archivos ALFS y a mi (AntLex) embebida en el\nkernel. Sin Linux, sin GRUB: todo propio.\n");
    } else if (std.mem.eql(u8, intencion, "licencia")) {
        salida("GPL-3.0: software libre. Puedes estudiar, modificar y redistribuir\nel codigo (github.com/juanruiz85/AntLexOS) manteniendo la misma\nlicencia para todos.\n");
    } else if (std.mem.eql(u8, intencion, "memoria")) {
        const m = mem.estadisticas();
        salida(std.fmt.bufPrint(&buf, "{d} MiB totales, {d} MiB libres", .{
            m.total / (1024 * 1024), m.libre / (1024 * 1024),
        }) catch "?");
        salida(" (region heap del mapa E820).\nAhi viven el espejo de ALFS y mis pesos embebidos.\n");
    } else if (std.mem.eql(u8, intencion, "cpu")) {
        var marca = [_]u8{0} ** 48;
        x86.cpuidMarca(&marca);
        salida("CPU: ");
        salida(std.mem.trim(u8, &marca, " "));
        salida("\nx86_64, identificada por CPUID en el arranque.\n");
    } else if (std.mem.eql(u8, intencion, "pantalla")) {
        salida(std.fmt.bufPrint(&buf, "{d}x{d} a 32 bpp", .{
            pantalla.anchoPix(), pantalla.altoPix(),
        }) catch "?");
        salida(" (framebuffer lineal; VBE en BIOS, GOP en UEFI).\nLa fuente es bitmap 8x16 desde GNU Unifont.\n");
    } else if (std.mem.eql(u8, intencion, "disco")) {
        salida("Disco: ");
        salida(ata.modelo());
        salida("\nDriver ATA PIO propio (LBA28). El volumen ALFS vive en su\npropia particion del disco.\n");
    } else if (std.mem.eql(u8, intencion, "alfs")) {
        salida("ALFS (AntLex File System) es el sistema de archivos propio:\nsuperbloque de 512 B, mapa de bits de bloques, 256 entradas jerárquicas\ny archivos por extensiones contiguas. Se monta como espejo en RAM y\n'sincronizar' lo escribe entero al disco.\n");
    } else if (std.mem.eql(u8, intencion, "espacio")) {
        if (alfs.montado()) {
            const v = alfs.actual().?;
            salida(std.fmt.bufPrint(&buf, "{d} de {d} bloques libres ({d} KiB)", .{
                v.libres(), v.n_bloques, @as(u64, v.libres()) * 512 / 1024,
            }) catch "?");
            salida(std.fmt.bufPrint(&buf, " y {d} de {d} entradas libres.\n", .{
                v.entradasLibres(), fmt.MAX_ENTRADAS,
            }) catch "?");
        } else {
            salida("ALFS no esta montado en este arranque.\n");
        }
    } else if (std.mem.eql(u8, intencion, "fecha")) {
        const f = reloj.leer();
        salida("Hoy es ");
        salida(reloj.textoLargo(f, &buf));
        salida("  (");
        salida(reloj.iso(f, &buf));
        salida(" UTC, reloj CMOS).\n");
    } else if (std.mem.eql(u8, intencion, "hora")) {
        const f = reloj.leer();
        salida("Son las ");
        salida(reloj.textoHora(f, &buf));
        salida(" UTC · llevo encendido ");
        salida(reloj.textoUptime(pit.uptimeSeg(), &buf));
        salida(".\n");
    } else if (std.mem.eql(u8, intencion, "uptime")) {
        salida("Llevo encendido ");
        salida(reloj.textoUptime(pit.uptimeSeg(), &buf));
        salida(" (temporizador PIT a 100 Hz).\n");
    } else if (std.mem.eql(u8, intencion, "comandos")) {
        salida("Hay 26 comandos en español con alias en inglés. Útiles:\n  lista · mostrar · escribir · sistema · fecha · antlex\nDetalle completo: 'ayuda'. Y 'antlex <pregunta>' para preguntarme.\n");
    } else if (std.mem.eql(u8, intencion, "teclado")) {
        salida("Teclado en '");
        salida(teclado.distribucion());
        salida("' (la enie y los acentos muertos funcionan).\nCambialo con: teclado es|us\n");
    } else if (std.mem.eql(u8, intencion, "arranque")) {
        if (bi_global) |bi| {
            if (bi.flags & boot_info.MODO_UEFI != 0) {
                salida("Arranque UEFI: BOOTX64.EFI propio (BlockIo + GOP), ExitBootServices\ncon mapa EFI convertido a E820 y salto al kernel en modo largo.\n");
            } else {
                salida("Arranque BIOS: MBR de 512 B + stage2 propios, VBE 1024x768,\nmapa E820 y salto al kernel en modo largo x86_64.\n");
            }
            if (bi.flags & boot_info.MODO_CD != 0) salida("(esta vez desde CD, El Torito.)\n");
        } else {
            salida("No tengo el boot_info a mano en este momento.\n");
        }
    } else if (std.mem.eql(u8, intencion, "apagar")) {
        salida("Para apagar escribe 'apagar': sincroniza ALFS y apaga por ACPI.\nPor seguridad no me apago yo sola (imaginate un malentendido...).\n");
    } else if (std.mem.eql(u8, intencion, "reiniciar")) {
        salida("Para reiniciar escribe 'reiniciar': sincroniza ALFS y reinicia\npor pulso del 8042.\n");
    } else if (std.mem.eql(u8, intencion, "archivos")) {
        salida("Archivos en ALFS: 'lista' ve un directorio, 'mostrar <archivo>'\nlee, 'escribir <archivo> <texto>' crea o sustituye, 'nuevodir' hace\ndirectorios. Con TAB autocompleto rutas y comandos.\n");
    } else if (std.mem.eql(u8, intencion, "sincronizar")) {
        salida("'sincronizar' vuelca el espejo RAM de ALFS al disco real: hazlo\nantes de apagar a lo bruto. 'apagar' y 'reiniciar' ya lo hacen solos.\n");
    } else if (std.mem.eql(u8, intencion, "gracias")) {
        salida("De nada. Si quieres saber como respondo: antlex por que\n(tras cualquier pregunta te cuento mi razonamiento).\n");
    } else {
        salida("Esa intencion la clasifique, pero no tengo respuesta escrita\n(reporte este bug: intencion '");
        salida(intencion);
        salida("').\n");
    }
}

var bi_global: ?*const boot_info.BootInfo = null;

/// Guarda el boot_info (lo llama el intérprete en init).
pub fn fijarBootInfo(bi: *const boot_info.BootInfo) void {
    bi_global = bi;
}

// ---------------------------------------------------------------------------
// comando principal: antlex <pregunta | por que | aprende | olvida | memoria>
// ---------------------------------------------------------------------------

pub fn comando(args: []const u8) void {
    var a = args;
    while (a.len > 0 and a[0] == ' ') a = a[1..];
    while (a.len > 0 and a[a.len - 1] == ' ') a = a[0 .. a.len - 1];

    if (a.len == 0) {
        presentacion();
        return;
    }
    if (std.mem.eql(u8, a, "por que") or std.mem.eql(u8, a, "porque")) {
        explicar();
        return;
    }
    if (std.mem.startsWith(u8, a, "aprende ")) {
        aprender(std.mem.trim(u8, a[8..], " "));
        return;
    }
    if (std.mem.startsWith(u8, a, "olvida ")) {
        olvidar(std.mem.trim(u8, a[7..], " "));
        return;
    }
    if (std.mem.eql(u8, a, "memoria")) {
        listarMemoria();
        return;
    }
    pregunta(a);
}

fn presentacion() void {
    prefijo();
    salida("a tu servicio. Soy la IA de este sistema: pregúntame en\nespañol sobre él (memoria, disco, ALFS, hora, comandos...).\nEjemplos:\n  antlex quien eres\n  antlex cuánta memoria tienes\n  antlex qué es alfs\nTambién puedo aprender: antlex aprende <clave> = <respuesta>\nY explicar mis respuestas: antlex por qué\n");
}

fn pregunta(q: []const u8) void {
    guardarPregunta(q);
    const norm = nucleo.normalizar(q, &ult_norm);
    ult_norm_len = norm.len;
    // forma canónica de la pregunta: clave de cotejo de lo aprendido
    var cbuf: [LARGO_CLAVE]u8 = undefined;
    const canon = canonica(q, &cbuf);
    var toks: [nucleo.MAX_TOKENS][]const u8 = undefined;
    const n = nucleo.tokenizar(norm, &toks);
    ult_tokens_n = @min(n, nucleo.MAX_TOKENS);
    for (0..ult_tokens_n) |i| ult_tokens[i] = toks[i];

    // 1) memoria aprendida (tiene prioridad sobre la red)
    if (buscarPar(canon)) |par| {
        ult_origen = .aprendida;
        ult_par = par;
        prefijo();
        salida("(aprendido) ");
        salida(par.valorStr());
        salida("\n");
        return;
    }

    // 2) red neuronal embebida
    const r = nucleo.clasificar(&pesos.PESOS, toks[0..n]);
    ult_confianza = r.confianza_pct;
    ult_cobertura = r.cobertura_pct;
    ult_conocidos = r.n_conocidos;
    ult_intencion = r.intencion;
    ult_segunda_pct = r.segunda_pct;
    ult_aportes_n = r.n_conocidos;
    for (0..r.n_conocidos) |i| ult_aportes[i] = r.aportes[i];

    if (!r.aceptada) {
        ult_origen = .rechazada;
        if (r.n_conocidos == 0) {
            ult_motivo = "no reconoci ninguna palabra conocida";
            prefijo();
            salida("No reconocí ninguna palabra de tu pregunta: solo sé de AntLex OS\n(memoria, disco, ALFS, reloj, comandos...). Prueba 'antlex que puedes\nhacer' o enséñame: antlex aprende <clave> = <respuesta>\n");
        } else if (r.cobertura_pct < nucleo.COBERTURA_MIN_PCT) {
            ult_motivo = "demasiadas palabras fuera de mi vocabulario";
            prefijo();
            salida("Eso suena a un tema que no es de este sistema: solo hablo de\nAntLex OS (memoria, disco, ALFS, comandos, reloj...). Reformula o\nenséñame: antlex aprende <clave> = <respuesta>\n");
        } else {
            ult_motivo = "confianza insuficiente";
            prefijo();
            salida("No estoy segura de haberte entendido (confianza baja). Solo sé de\nAntLex OS: reformula la pregunta o sé más concreto.\n");
        }
        return;
    }

    ult_origen = .red;
    prefijo();
    responder(pesos.INTENCIONES[r.intencion]);
}

// ---------------------------------------------------------------------------
// aprende / olvida / memoria
// ---------------------------------------------------------------------------

fn aprender(resto: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, resto, '=') orelse {
        fallo("uso: antlex aprende <clave> = <respuesta>\n(la clave es la pregunta exacta que reconocere, sin mayusculas ni acentos da igual)");
        return;
    };
    const clave = std.mem.trim(u8, resto[0..eq], " ");
    const valor = std.mem.trim(u8, resto[eq + 1 ..], " ");
    if (clave.len == 0 or valor.len == 0) {
        fallo("la clave y la respuesta no pueden estar vacias");
        return;
    }
    if (clave.len >= LARGO_CLAVE or valor.len >= LARGO_VALOR) {
        var nbuf: [96]u8 = undefined;
        fallo(std.fmt.bufPrint(&nbuf, "clave max {d} caracteres, respuesta max {d}", .{ LARGO_CLAVE - 1, LARGO_VALOR - 1 }) catch "demasiado largo");
        return;
    }
    var vbuf: [LARGO_CLAVE]u8 = undefined;
    if (canonica(clave, &vbuf).len == 0) {
        fallo("la clave se queda vacía al normalizar (usa palabras con contenido)");
        return;
    }
    guardarPar(clave, valor) catch {
        var nbuf: [96]u8 = undefined;
        fallo(std.fmt.bufPrint(&nbuf, "memoria llena ({d} pares): usa antlex olvida", .{MAX_PARES}) catch "memoria llena");
        return;
    };
    const persistido = persistirPares();
    prefijo();
    salida("aprendido: '");
    salida(clave);
    salida("' -> '");
    salida(valor);
    salida("'");
    if (persistido) {
        salida(" (guardado en /");
        salida(RUTA_MEMORIA);
        salida("; 'sincronizar' lo lleva al disco)\n");
    } else {
        salida(" (ALFS no montado: lo recordare solo hasta reiniciar)\n");
    }
}

fn olvidar(clave: []const u8) void {
    if (clave.len == 0) {
        fallo("uso: antlex olvida <clave>");
        return;
    }
    var nbuf: [LARGO_CLAVE]u8 = undefined;
    const norm = canonica(clave, &nbuf);
    if (norm.len == 0) {
        fallo("esa clave se queda vacía (solo palabras vacías)");
        return;
    }
    var i: usize = 0;
    while (i < pares_n) : (i += 1) {
        if (std.mem.eql(u8, pares[i].claveNormStr(), norm)) {
            var clave_buf: [LARGO_CLAVE]u8 = undefined;
            const n = pares[i].clave_len;
            @memcpy(clave_buf[0..n], pares[i].clave[0..n]);
            var j = i;
            while (j + 1 < pares_n) : (j += 1) pares[j] = pares[j + 1];
            pares_n -= 1;
            _ = persistirPares();
            prefijo();
            salida("olvidado: '");
            salida(clave_buf[0..n]);
            salida("'\n");
            return;
        }
    }
    prefijo();
    salida("no tengo nada aprendido con esa clave (vease antlex memoria)\n");
}

fn listarMemoria() void {
    if (pares_n == 0) {
        prefijo();
        salida("memoria vacía: enséñame con antlex aprende <clave> = <respuesta>\n");
        return;
    }
    prefijo();
    salida("memoria aprendida (");
    entero(pares_n);
    salida(" de ");
    entero(MAX_PARES);
    salida("):\n");
    var i: usize = 0;
    while (i < pares_n) : (i += 1) {
        salida("  ");
        salida(pares[i].claveStr());
        salida(" = ");
        salida(pares[i].valorStr());
        salida("\n");
    }
}

// ---------------------------------------------------------------------------
// explicabilidad
// ---------------------------------------------------------------------------

fn explicar() void {
    salidaColor(consola.COLOR_TITULO, "AntLex (por que):\n");
    if (ult_origen == .ninguna) {
        salida("  aun no me has preguntado nada (prueba: antlex quien eres)\n");
        return;
    }
    salida("  pregunta : ");
    salida(ult_pregunta[0..ult_pregunta_len]);
    salida("\n");
    if (ult_origen == .aprendida) {
        const par = ult_par.?;
        salida("  origen   : memoria aprendida (la clave coincide con tu pregunta)\n");
        salida("  clave    : '");
        salida(par.claveStr());
        salida("' = '");
        salida(par.valorStr());
        salida("'\n  (la red neuronal no se consulto: lo aprendido tiene prioridad)\n");
        return;
    }
    // tokens con su estado (conocido / fuera de vocabulario)
    salida("  tokens   :");
    var conocidos: usize = 0;
    for (ult_tokens[0..ult_tokens_n]) |t| {
        salida(" ");
        if (nucleo.indiceVocab(&pesos.VOCAB, t) != null) {
            salida("[");
            salida(t);
            salida("]");
            conocidos += 1;
        } else {
            salida(t);
            salida("(?)");
        }
    }
    var nbuf: [96]u8 = undefined;
    salida(std.fmt.bufPrint(&nbuf, "\n  cobertura: {d} de {d} conocidos ({d}%, minimo {d}%)\n", .{
        conocidos, ult_tokens_n, ult_cobertura, nucleo.COBERTURA_MIN_PCT,
    }) catch "\n");
    if (ult_origen == .rechazada) {
        salida("  motivo   : ");
        salida(ult_motivo);
        salida(std.fmt.bufPrint(&nbuf, " (confianza {d}%, umbral {d}%)\n", .{ ult_confianza, nucleo.UMBRAL_PCT }) catch "\n");
        return;
    }
    // red: intención, confianza y aportes de cada token
    salida("  origen   : red neuronal embebida (bolsa de palabras -> 16 ocultas -> softmax, punto fijo sin FPU)\n");
    salida("  respuesta: ");
    salida(pesos.INTENCIONES[ult_intencion]);
    salida(std.fmt.bufPrint(&nbuf, " (confianza {d}%, umbral {d}%; segunda opcion {d}%)\n", .{
        ult_confianza, nucleo.UMBRAL_PCT, ult_segunda_pct,
    }) catch "\n");
    if (ult_aportes_n == 0) return;
    salida("  aportaron (gradiente x entrada, Q16.16):\n");
    // top 3 por |aporte|: seleccion simple (pocos tokens)
    var usados = [_]bool{false} ** nucleo.MAX_TOKENS;
    var plazas: usize = @min(@as(usize, 3), ult_aportes_n);
    while (plazas > 0) : (plazas -= 1) {
        var mejor_i: ?usize = null;
        for (0..ult_aportes_n) |i| {
            if (usados[i]) continue;
            if (mejor_i == null or @abs(ult_aportes[i]) > @abs(ult_aportes[mejor_i.?])) mejor_i = i;
        }
        const i = mejor_i.?; // ult_aportes_n > 0 garantiza hallazgo
        usados[i] = true;
        salida("    ");
        salida(tokenConocido(i) orelse "?");
        salida(std.fmt.bufPrint(&nbuf, "  {d}\n", .{ult_aportes[i]}) catch "\n");
    }
}

/// Devuelve el t-ésimo token CONOCIDO (los aportes se indexan así).
fn tokenConocido(t: usize) ?[]const u8 {
    var vistos: usize = 0;
    for (ult_tokens[0..ult_tokens_n]) |tok| {
        if (nucleo.indiceVocab(&pesos.VOCAB, tok) != null) {
            if (vistos == t) return tok;
            vistos += 1;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// autoprueba (la invoca autoprueba.zig: preguntas canónicas → intención)
// ---------------------------------------------------------------------------

pub fn autopruebaCanonica() struct { aciertos: usize, total: usize } {
    var aciertos: usize = 0;
    for (nucleo.CANON) |c| {
        var nbuf: [nucleo.MAX_NORMALIZADO]u8 = undefined;
        var toks: [nucleo.MAX_TOKENS][]const u8 = undefined;
        const norm = nucleo.normalizar(c.pregunta, &nbuf);
        const n = nucleo.tokenizar(norm, &toks);
        const r = nucleo.clasificar(&pesos.PESOS, toks[0..n]);
        const ok = if (c.esperada) |esp|
            (r.aceptada and std.mem.eql(u8, pesos.INTENCIONES[r.intencion], esp))
        else
            !r.aceptada;
        if (ok) aciertos += 1;
    }
    return .{ .aciertos = aciertos, .total = nucleo.CANON.len };
}

/// Número de pares aprendidos (para diagnóstico).
pub fn paresAprendidos() usize {
    return pares_n;
}
