//! AntLex OS — entrenador de la IA AntLex (Fase 4).
//! Entrena en el HOST (floats) la red diminuta: bolsa de palabras → 16
//! ocultas (ReLU) → intenciones (softmax), con el corpus de
//! src/kernel/antlex/corpus.zig. Después CUANTIZA a punto fijo Q4.11 y
//! verifica con la MISMA inferencia entera que usará el kernel (nucleo.zig)
//! antes de emitir src/kernel/antlex/pesos.zig.
//!
//! Determinista: LCG de semilla fija, sin aleatoriedad del SO: ejecutar dos
//! veces produce el mismo archivo byte a byte.
//!
//! Lo invoca build.zig:
//!   zig build entrenar            → reentrena y escribe pesos.zig
//!   zig build entrenar-verificar  → reentrena y compara con lo commiteado
//!
//! Uso directo: zig run tools/entrenar_antlex.zig -- <dir antlex> [--verificar]

const std = @import("std");
const nucleo = @import("nucleo");
const corpus = @import("corpus");

const OCULTAS = nucleo.OCULTAS;
const LR_BASE: f64 = 0.15;
const EPOCAS: usize = 600;

// ---------------------------------------------------------------------------
// LCG determinista
// ---------------------------------------------------------------------------

var semilla: u64 = 0x414E544C_45583031; // "ANTLEX01"

fn azar() u64 {
    semilla = semilla *% 6364136223846793005 +% 1442695040888963407;
    return semilla;
}

/// Uniforme en [-r, r).
fn azarF(r: f64) f64 {
    const u = @as(f64, @floatFromInt(azar() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    return (u * 2.0 - 1.0) * r;
}

fn menosQue(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// datos: vocabulario ordenado, intenciones y bolsas binarias
// ---------------------------------------------------------------------------

const Datos = struct {
    vocab: [][]const u8,
    intenciones: [][]const u8,
    x: [][]u8, // x[e][v] = 1 si el ejemplo e contiene la palabra v
    y: []usize, // intención de cada ejemplo
    n: usize,
};

fn construir(alloc: std.mem.Allocator) !Datos {
    var nbuf: [nucleo.MAX_NORMALIZADO]u8 = undefined;
    var toks: [nucleo.MAX_TOKENS][]const u8 = undefined;

    // 1) vocabulario: todos los tokens de todos los ejemplos, sin repetir
    var vocab_lista = std.ArrayList([]const u8).init(alloc);
    var en_vocab = std.StringHashMap(void).init(alloc);
    for (corpus.EJEMPLOS) |ej| {
        const norm = nucleo.normalizar(ej.texto, &nbuf);
        const nt = nucleo.tokenizar(norm, &toks);
        for (toks[0..nt]) |t| {
            // copia PROPIA del token: `nbuf` se reutiliza por ejemplo y el
            // hashmap retiene las claves (slices colgantes = corrupción)
            if (!en_vocab.contains(t)) {
                const propio = try alloc.dupe(u8, t);
                try en_vocab.put(propio, {});
                try vocab_lista.append(propio);
            }
        }
    }
    std.mem.sort([]const u8, vocab_lista.items, {}, menosQue);
    const vocab = vocab_lista.items;

    // 2) intenciones por orden de aparición (determinista)
    var ints = std.ArrayList([]const u8).init(alloc);
    var idx_int = std.StringHashMap(usize).init(alloc);
    for (corpus.EJEMPLOS) |ej| {
        const gop = try idx_int.getOrPut(ej.intencion);
        if (!gop.found_existing) {
            gop.value_ptr.* = ints.items.len;
            try ints.append(ej.intencion);
        }
    }

    // 3) bolsas binarias con el vocabulario YA ordenado
    var xs = std.ArrayList([]u8).init(alloc);
    var ys = std.ArrayList(usize).init(alloc);
    for (corpus.EJEMPLOS) |ej| {
        const norm = nucleo.normalizar(ej.texto, &nbuf);
        const nt = nucleo.tokenizar(norm, &toks);
        const fila = try alloc.alloc(u8, vocab.len);
        @memset(fila, 0);
        for (toks[0..nt]) |t| {
            fila[indiceDe(vocab, t).?] = 1;
        }
        try xs.append(fila);
        try ys.append(idx_int.get(ej.intencion).?);
    }

    return .{
        .vocab = vocab,
        .intenciones = ints.items,
        .x = xs.items,
        .y = ys.items,
        .n = xs.items.len,
    };
}

fn indiceDe(vocab: [][]const u8, t: []const u8) ?usize {
    for (vocab, 0..) |v, i| {
        if (std.mem.eql(u8, v, t)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// red en flotante + SGD con momento
// ---------------------------------------------------------------------------

const Red = struct {
    n_vocab: usize,
    n_int: usize,
    w1: []f64, // [n_vocab][OCULTAS]
    b1: []f64, // [OCULTAS]
    w2: []f64, // [OCULTAS][n_int]
    b2: []f64, // [n_int]
};

fn crearRed(alloc: std.mem.Allocator, n_vocab: usize, n_int: usize) !Red {
    const r = @as(f64, 0.5) / @sqrt(@as(f64, @floatFromInt(n_vocab)));
    const w1 = try alloc.alloc(f64, n_vocab * OCULTAS);
    const b1 = try alloc.alloc(f64, OCULTAS);
    const w2 = try alloc.alloc(f64, OCULTAS * n_int);
    const b2 = try alloc.alloc(f64, n_int);
    for (w1) |*w| w.* = azarF(r);
    for (b1) |*b| b.* = azarF(r * 0.5);
    for (w2) |*w| w.* = azarF(r * 2.0);
    for (b2) |*b| b.* = azarF(r * 0.5);
    return .{
        .n_vocab = n_vocab,
        .n_int = n_int,
        .w1 = w1,
        .b1 = b1,
        .w2 = w2,
        .b2 = b2,
    };
}

fn adelante(red: *const Red, x: []const u8, a1: *[OCULTAS]f64, logits: []f64) void {
    for (0..OCULTAS) |h| {
        var z = red.b1[h];
        for (x, 0..) |bit, v| {
            if (bit == 1) z += red.w1[v * OCULTAS + h];
        }
        a1[h] = if (z > 0) z else 0;
    }
    for (0..red.n_int) |i| {
        var z = red.b2[i];
        for (0..OCULTAS) |h| z += a1[h] * red.w2[h * red.n_int + i];
        logits[i] = z;
    }
}

fn entrenar(red: *Red, d: *const Datos, buffers_eval: BuffersEval) !struct { exactitud: f64, perdida: f64, epocas: usize } {
    var a1: [OCULTAS]f64 = undefined;
    var logits = [_]f64{0} ** nucleo.MAX_INTENCIONES;
    var probs = [_]f64{0} ** nucleo.MAX_INTENCIONES;

    var aciertos: usize = 0;
    var perdida: f64 = 0;

    for (0..EPOCAS) |epoca| {
        const lr = @max(LR_BASE * std.math.pow(f64, 0.995, @floatFromInt(epoca)), 0.01);
        for (0..d.n) |ei| {
            // ---- adelante ----
            adelante(red, d.x[ei], &a1, logits[0..red.n_int]);
            var m = logits[0];
            for (logits[0..red.n_int]) |v| {
                if (v > m) m = v;
            }
            var s: f64 = 0;
            for (logits[0..red.n_int], 0..) |v, i| {
                probs[i] = @exp(v - m);
                s += probs[i];
            }
            for (probs[0..red.n_int]) |*p| p.* /= s;

            // ---- gradientes (cross-entropy + softmax) ----
            var dh: [OCULTAS]f64 = undefined;
            for (0..OCULTAS) |h| dh[h] = 0;
            for (0..red.n_int) |i| {
                const objetivo: f64 = if (i == d.y[ei]) 1.0 else 0.0;
                const gi = probs[i] - objetivo;
                for (0..OCULTAS) |h| {
                    if (a1[h] > 0) dh[h] += gi * red.w2[h * red.n_int + i];
                }
            }
            // SGD plano (determinista, en orden de corpus): el momento 0.9
            // multiplicaba ~10x el paso efectivo y no convergía (26%);
            // sin él, 600 épocas llegan al 100% (verificado en diagnóstico)
            for (0..red.n_int) |i| {
                const objetivo: f64 = if (i == d.y[ei]) 1.0 else 0.0;
                red.b2[i] -= lr * (probs[i] - objetivo);
            }
            for (0..OCULTAS) |h| {
                if (a1[h] <= 0) continue;
                red.b1[h] -= lr * dh[h];
            }
            const fila_x = d.x[ei];
            for (fila_x, 0..) |bit, v| {
                if (bit != 1) continue;
                for (0..OCULTAS) |h| {
                    if (a1[h] <= 0) continue;
                    red.w1[v * OCULTAS + h] -= lr * dh[h];
                }
            }
            for (0..OCULTAS) |h| {
                if (a1[h] <= 0) continue;
                for (0..red.n_int) |i| {
                    const objetivo: f64 = if (i == d.y[ei]) 1.0 else 0.0;
                    red.w2[h * red.n_int + i] -= lr * (probs[i] - objetivo) * a1[h];
                }
            }
        }

        // métricas cada 20 épocas. PARADA POR MARGEN: no basta con acertar
        // el argmax; TODO el corpus debe clasificar con confianza ≥ MARGEN_PCT
        // en la inferencia CUANTIZADA (la que de verdad se embarca en el
        // kernel). Para entonces los pesos caben en Q4.11 de sobra.
        if (epoca % 20 == 19 or epoca == EPOCAS - 1) {
            aciertos = 0;
            perdida = 0;
            for (0..d.n) |ei| {
                adelante(red, d.x[ei], &a1, logits[0..red.n_int]);
                var m = logits[0];
                for (logits[0..red.n_int]) |v| {
                    if (v > m) m = v;
                }
                var s2: f64 = 0;
                for (logits[0..red.n_int], 0..) |v, i| {
                    probs[i] = @exp(v - m);
                    s2 += probs[i];
                }
                var mejor: usize = 0;
                for (0..red.n_int) |i| {
                    probs[i] /= s2;
                    if (probs[i] > probs[mejor]) mejor = i;
                }
                if (mejor == d.y[ei]) aciertos += 1;
                perdida += -@log(probs[d.y[ei]]);
            }
            perdida /= @floatFromInt(d.n);
            const pct = 100.0 * @as(f64, @floatFromInt(aciertos)) / @as(f64, @floatFromInt(d.n));
            const ev = evaluarCuantizado(red, d, buffers_eval);
            std.debug.print("  epoca {d:>4}: perdida {d:.4} · flotante {d:.1}% · cuantizada {d:.1}% (margen min {d}%)\n", .{ epoca + 1, perdida, pct, ev.pct, ev.min_conf });
            if (ev.todos_con_margen and epoca + 1 < EPOCAS) {
                std.debug.print("  parada por margen: corpus completo ≥{d}% con la red cuantizada\n", .{MARGEN_PCT});
                return .{ .exactitud = pct, .perdida = perdida, .epocas = epoca + 1 };
            }
        }
    }
    return .{
        .exactitud = 100.0 * @as(f64, @floatFromInt(aciertos)) / @as(f64, @floatFromInt(d.n)),
        .perdida = perdida,
        .epocas = EPOCAS,
    };
}

const MARGEN_PCT: u32 = 85;

const BuffersEval = struct {
    w1: []i16,
    b1: []i16,
    w2: []i16,
    b2: []i16,
};

const EvalCuant = struct { pct: f64, min_conf: u32, todos_con_margen: bool };

/// Evalúa el corpus con la MISMA inferencia entera del kernel: cuantiza la
/// red en `buf` y clasifica cada ejemplo con nucleo.clasificar.
fn evaluarCuantizado(red: *const Red, d: *const Datos, buf: BuffersEval) EvalCuant {
    const tope: f64 = 32700.0 / 2048.0;
    for (red.w1, 0..) |w, i| buf.w1[i] = @intFromFloat(@round(std.math.clamp(w, -tope, tope) * 2048.0));
    for (red.b1, 0..) |w, i| buf.b1[i] = @intFromFloat(@round(std.math.clamp(w, -tope, tope) * 2048.0));
    for (red.w2, 0..) |w, i| buf.w2[i] = @intFromFloat(@round(std.math.clamp(w, -tope, tope) * 2048.0));
    for (red.b2, 0..) |w, i| buf.b2[i] = @intFromFloat(@round(std.math.clamp(w, -tope, tope) * 2048.0));
    const pesos = nucleo.Pesos{
        .vocab = d.vocab,
        .intenciones = d.intenciones,
        .w1 = buf.w1,
        .b1 = buf.b1,
        .w2 = buf.w2,
        .b2 = buf.b2,
    };
    var ok: usize = 0;
    var min_conf: u32 = 100;
    for (corpus.EJEMPLOS) |ej| {
        const r = clasificarPregunta(&pesos, ej.texto);
        const idx = indiceDe(d.intenciones, ej.intencion).?;
        if (r.aceptada and r.intencion == idx) {
            ok += 1;
            if (r.confianza_pct < min_conf) min_conf = r.confianza_pct;
        } else {
            min_conf = 0;
        }
    }
    const pct = 100.0 * @as(f64, @floatFromInt(ok)) / @as(f64, @floatFromInt(d.n));
    return .{ .pct = pct, .min_conf = min_conf, .todos_con_margen = ok == d.n and min_conf >= MARGEN_PCT };
}

// ---------------------------------------------------------------------------
// cuantización + verificación con la inferencia ENTERA del kernel
// ---------------------------------------------------------------------------

const Cuantizados = struct {
    w1: []i16,
    b1: []i16,
    w2: []i16,
    b2: []i16,
};

fn cuantizar(alloc: std.mem.Allocator, red: *const Red) !Cuantizados {
    // Q4.11: 1.0 = 2048, rango ±15.99 (cubre pesos ~±3 tras la parada
    // temprana con resolución 1/2048, mejor que la del Q8.8 inicial)
    const tope: f64 = 32700.0 / 2048.0;
    const q = Cuantizados{
        .w1 = try alloc.alloc(i16, red.n_vocab * OCULTAS),
        .b1 = try alloc.alloc(i16, OCULTAS),
        .w2 = try alloc.alloc(i16, OCULTAS * red.n_int),
        .b2 = try alloc.alloc(i16, red.n_int),
    };
    for (red.w1, 0..) |w, i| q.w1[i] = @intFromFloat(@round(std.math.clamp(w, -tope, tope) * 2048.0));
    for (red.b1, 0..) |w, i| q.b1[i] = @intFromFloat(@round(std.math.clamp(w, -tope, tope) * 2048.0));
    for (red.w2, 0..) |w, i| q.w2[i] = @intFromFloat(@round(std.math.clamp(w, -tope, tope) * 2048.0));
    for (red.b2, 0..) |w, i| q.b2[i] = @intFromFloat(@round(std.math.clamp(w, -tope, tope) * 2048.0));
    return q;
}

/// Reescala la red entrenada para que TODOS los pesos quepan en Q4.11 sin
/// recorte. Es exacto para la clasificación: w1,b1 se escalan por t (z1 y a1
/// escalan por t), b2 por k y w2 por k/t, con lo que z2 escala por k y el
/// softmax es invariante a esa escala. Sin esto, pesos |w|>0.496 del
/// entrenamiento saturado (perdida 0.0006) quedaban clampados y la red
/// cuantizada caía al 9% de exactitud.
fn escalarParaCuantizar(red: *Red) void {
    const M: f64 = 15.0; // margen bajo 32700/2048
    var max1: f64 = 0;
    for (red.w1) |w| max1 = @max(max1, @abs(w));
    for (red.b1) |w| max1 = @max(max1, @abs(w));
    const t = @min(@as(f64, 1), M / max1);
    var max_b2: f64 = 0;
    for (red.b2) |w| max_b2 = @max(max_b2, @abs(w));
    var max_w2: f64 = 0;
    for (red.w2) |w| max_w2 = @max(max_w2, @abs(w));
    var k = @min(@as(f64, 1), M / max_b2);
    k = @min(k, t * M / max_w2);
    for (red.w1) |*w| w.* *= t;
    for (red.b1) |*b| b.* *= t;
    for (red.w2) |*w| w.* *= k / t;
    for (red.b2) |*b| b.* *= k;
    std.debug.print("escala cuantizacion: t={d:.4} k={d:.4} (max w1={d:.2} w2={d:.2})\n", .{ t, k, max1, max_w2 });
}

fn clasificarPregunta(pesos: *const nucleo.Pesos, pregunta: []const u8) nucleo.Resultado {
    var nbuf: [nucleo.MAX_NORMALIZADO]u8 = undefined;
    var toks: [nucleo.MAX_TOKENS][]const u8 = undefined;
    const norm = nucleo.normalizar(pregunta, &nbuf);
    const n = nucleo.tokenizar(norm, &toks);
    return nucleo.clasificar(pesos, toks[0..n]);
}

// ---------------------------------------------------------------------------
// emisión de pesos.zig
// ---------------------------------------------------------------------------

fn emitirFilas(w: anytype, datos: []const i16, por_fila: usize) !void {
    // formato manual: el {d:>6} de Zig emite '+' en los positivos y un
    // literal "+713" no compila en el archivo generado
    var i: usize = 0;
    while (i < datos.len) : (i += por_fila) {
        try w.writeAll("    ");
        var j: usize = 0;
        while (j < por_fila) : (j += 1) {
            const v = datos[i + j];
            var buf: [8]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "{d}", .{@abs(v)}) catch "?";
            if (v < 0) try w.writeAll("-");
            var pad: usize = if (txt.len < 6) 6 - txt.len else 0;
            while (pad > 0) : (pad -= 1) try w.writeAll(" ");
            try w.writeAll(txt);
            try w.writeAll(",");
        }
        try w.writeAll("\n");
    }
}

const Met = struct { exactitud: f64, exactitud_q: f64, canon_ok: usize, epocas: usize };

fn emitir(w: anytype, d: *const Datos, q: anytype, met: Met) !void {
    try w.print(
        \\//! GENERADO por tools/entrenar_antlex.zig — NO EDITAR A MANO.
        \\//! Regenerar: zig build entrenar (determinista: misma entrada, mismo fichero)
        \\//! Verificar frente a lo commiteado: zig build entrenar-verificar
        \\//! corpus: {d} ejemplos, {d} intenciones · red: bolsa → {d} ocultas → intenciones
        \\//! entrenamiento: SGD plano lr 0.15, {d} epocas (parada por margen {d}%) · exactitud flotante {d:.1}%
        \\//! exactitud cuantizada (inferencia del kernel): {d:.1}% · canon {d}/{d}
        \\//! punto fijo: pesos Q4.11 (i16), activaciones Q16.16 (i32), sin FPU
        \\
    , .{ corpus.EJEMPLOS.len, d.intenciones.len, OCULTAS, met.epocas, MARGEN_PCT, met.exactitud, met.exactitud_q, met.canon_ok, nucleo.CANON.len });

    try w.writeAll("const nucleo = @import(\"nucleo.zig\");\n\n");
    try w.writeAll("pub const VOCAB = [_][]const u8{\n");
    for (d.vocab) |v| try w.print("    \"{s}\",\n", .{v});
    try w.writeAll("};\n\n");

    try w.writeAll("pub const INTENCIONES = [_][]const u8{\n");
    for (d.intenciones) |v| try w.print("    \"{s}\",\n", .{v});
    try w.writeAll("};\n\n");

    try w.writeAll("/// w1: [VOCAB.len][OCULTAS] fila-major (una fila por palabra).\npub const W1 = [_]i16{\n");
    try emitirFilas(w, q.w1, OCULTAS);
    try w.writeAll("};\n\n");

    try w.writeAll("pub const B1 = [_]i16{\n");
    try emitirFilas(w, q.b1, q.b1.len);
    try w.writeAll("};\n\n");

    try w.writeAll("/// w2: [OCULTAS][INTENCIONES.len] fila-major (una fila por neurona oculta).\npub const W2 = [_]i16{\n");
    try emitirFilas(w, q.w2, d.intenciones.len);
    try w.writeAll("};\n\n");

    try w.writeAll("pub const B2 = [_]i16{\n");
    try emitirFilas(w, q.b2, q.b2.len);
    try w.writeAll("};\n\n");

    try w.writeAll(
        \\pub const PESOS = nucleo.Pesos{
        \\    .vocab = &VOCAB,
        \\    .intenciones = &INTENCIONES,
        \\    .w1 = &W1,
        \\    .b1 = &B1,
        \\    .w2 = &W2,
        \\    .b2 = &B2,
        \\};
        \\
    );
}

// ---------------------------------------------------------------------------

/// Extrae en orden todos los enteros con signo de un texto (para comparar
/// pesos.zig commiteado vs recién generado sin depender del formato).
fn extraerEnteros(alloc: std.mem.Allocator, texto: []const u8) ![]i64 {
    var lista = std.ArrayList(i64).init(alloc);
    var i: usize = 0;
    while (i < texto.len) {
        var j = i;
        var neg = false;
        if (j < texto.len and (texto[j] == '-' or texto[j] == '+')) {
            neg = texto[j] == '-';
            j += 1;
            // el emisor alinea columnas: puede haber espacios entre el signo
            // y las cifras ("-   7"); zig fmt los quita, el parser no debe
            while (j < texto.len and (texto[j] == ' ' or texto[j] == '\t')) j += 1;
        }
        if (j < texto.len and texto[j] >= '0' and texto[j] <= '9') {
            var v: i64 = 0;
            while (j < texto.len and texto[j] >= '0' and texto[j] <= '9') : (j += 1) {
                v = v * 10 + (texto[j] - '0');
            }
            try lista.append(if (neg) -v else v);
            i = j;
        } else {
            i += 1;
        }
    }
    return lista.items;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    var verificar = false;
    var rutas: []const []const u8 = args[1..];
    if (rutas.len > 0 and std.mem.eql(u8, rutas[rutas.len - 1], "--verificar")) {
        verificar = true;
        rutas = rutas[0 .. rutas.len - 1];
    }
    if (rutas.len != 1) {
        std.debug.print("uso: entrenar_antlex <dir src/kernel/antlex> [--verificar]\n", .{});
        return error.Uso;
    }
    const dir = rutas[0];

    var d = try construir(alloc);
    std.debug.print("== entrenar_antlex: {d} ejemplos · {d} intenciones · {d} palabras ==\n", .{ d.n, d.intenciones.len, d.vocab.len });

    var red = try crearRed(alloc, d.vocab.len, d.intenciones.len);
    const buffers_eval = BuffersEval{
        .w1 = try alloc.alloc(i16, d.vocab.len * OCULTAS),
        .b1 = try alloc.alloc(i16, OCULTAS),
        .w2 = try alloc.alloc(i16, OCULTAS * d.intenciones.len),
        .b2 = try alloc.alloc(i16, d.intenciones.len),
    };
    const met = try entrenar(&red, &d, buffers_eval);
    std.debug.print("entrenamiento: {d} epocas · exactitud flotante {d:.1}% · perdida {d:.4}\n", .{ met.epocas, met.exactitud, met.perdida });

    // ---- cuantizar y verificar con la MISMA inferencia del kernel -------
    escalarParaCuantizar(&red); // no-op si todo cabe ya en Q4.11 (parada temprana)
    const q = try cuantizar(alloc, &red);
    const pesos = nucleo.Pesos{
        .vocab = d.vocab,
        .intenciones = d.intenciones,
        .w1 = q.w1,
        .b1 = q.b1,
        .w2 = q.w2,
        .b2 = q.b2,
    };

    var aciertos: usize = 0;
    for (corpus.EJEMPLOS) |ej| {
        const r = clasificarPregunta(&pesos, ej.texto);
        const idx = indiceDe(d.intenciones, ej.intencion).?;
        if (r.aceptada and r.intencion == idx) {
            aciertos += 1;
        } else {
            std.debug.print("  corpus flojo: {s:<32} → {s:<14} {d:>3}% (esperaba {s})\n", .{
                ej.texto,
                if (r.aceptada) d.intenciones[r.intencion] else "(rechazada)",
                r.confianza_pct,
                ej.intencion,
            });
        }
    }
    const exactitud_q = 100.0 * @as(f64, @floatFromInt(aciertos)) / @as(f64, @floatFromInt(d.n));
    std.debug.print("exactitud CUANTIZADA (inferencia del kernel): {d:.1}%\n", .{exactitud_q});

    var canon_ok: usize = 0;
    for (nucleo.CANON) |c| {
        const r = clasificarPregunta(&pesos, c.pregunta);
        var ok = false;
        if (c.esperada) |esp| {
            ok = r.aceptada and std.mem.eql(u8, d.intenciones[r.intencion], esp);
        } else {
            ok = !r.aceptada;
        }
        if (ok) canon_ok += 1;
        std.debug.print("  canon {s:<34} → {s:<14} {d:>3}% {s}\n", .{
            c.pregunta,
            if (r.aceptada) d.intenciones[r.intencion] else "(rechazada)",
            r.confianza_pct,
            if (ok) "OK" else "**FALLA**",
        });
    }
    std.debug.print("canon: {d}/{d}\n", .{ canon_ok, nucleo.CANON.len });

    var adver_ok: usize = 0;
    for (corpus.ADVERSARIALES) |a| {
        const r = clasificarPregunta(&pesos, a);
        if (!r.aceptada) adver_ok += 1;
        std.debug.print("  adversarial {s:<32} → {s:<14} {d:>3}% {s}\n", .{
            a,
            if (r.aceptada) d.intenciones[r.intencion] else "(rechazada)",
            r.confianza_pct,
            if (!r.aceptada) "OK" else "**FALLA**",
        });
    }
    std.debug.print("adversariales rechazados: {d}/{d}\n", .{ adver_ok, corpus.ADVERSARIALES.len });

    // ---- emitir / comparar pesos.zig -------------------------------------
    var salida = std.ArrayList(u8).init(alloc);
    try emitir(salida.writer(), &d, q, .{
        .exactitud = met.exactitud,
        .exactitud_q = exactitud_q,
        .canon_ok = canon_ok,
        .epocas = met.epocas,
    });

    const ruta_pesos = try std.fs.path.join(alloc, &.{ dir, "pesos.zig" });
    if (verificar) {
        // comparación SEMÁNTICA: la secuencia de enteros del archivo frente a
        // la del re-entrenamiento (el paso de build pasa `zig fmt` por encima,
        // así que la comparación byte a byte no sería estable)
        const existente = std.fs.cwd().readFileAlloc(alloc, ruta_pesos, 4 << 20) catch null;
        if (existente == null) {
            std.debug.print("VERIFICACION: no existe pesos.zig (ejecuta 'zig build entrenar')\n", .{});
            return error.PesosDesfasados;
        }
        const enteros_commiteados = try extraerEnteros(alloc, existente.?);
        const enteros_frescos = try extraerEnteros(alloc, salida.items);
        if (enteros_commiteados.len == enteros_frescos.len and
            std.mem.eql(i64, enteros_commiteados, enteros_frescos))
        {
            std.debug.print("VERIFICACION: pesos.zig coincide con el re-entrenamiento ({d} enteros)\n", .{enteros_frescos.len});
        } else {
            std.debug.print("VERIFICACION: pesos.zig DIFIERE ({d} vs {d} enteros; ejecuta 'zig build entrenar' y commitea)\n", .{ enteros_commiteados.len, enteros_frescos.len });
            return error.PesosDesfasados;
        }
    } else {
        try std.fs.cwd().writeFile(.{ .sub_path = ruta_pesos, .data = salida.items });
        std.debug.print("escrito: {s} ({d} bytes)\n", .{ ruta_pesos, salida.items.len });
    }

    if (exactitud_q < 99.0) return error.ExactitudInsuficiente;
    if (canon_ok != nucleo.CANON.len) return error.CanonIncompleto;
    if (adver_ok != corpus.ADVERSARIALES.len) return error.AdversarialAceptado;
    std.debug.print("== entrenar_antlex: TODO OK ==\n", .{});
}
