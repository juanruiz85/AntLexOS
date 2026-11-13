//! AntLex OS — núcleo de la IA AntLex (Fase 4): PURO, sin E/S ni hardware.
//! Lo comparten el kernel (inferencia), tools/entrenar_antlex.zig
//! (preparación de datos) y las pruebas host. El kernel no tiene FPU
//! activada: TODA la aritmética de runtime es entera (punto fijo).
//!
//! Tubería: pregunta → normalizar (minúsculas, sin acentos, sin puntuación)
//! → tokens sin palabras vacías → sinónimos → bolsa de palabras contra el
//! vocabulario embebido → capa oculta (ReLU, 16 neuronas) → intenciones
//! (softmax) → umbral de confianza.
//!
//! Formato de punto fijo:
//!   - pesos embebidos: Q4.11 con signo (i16) — 1.0 = 2048, rango ±15.99
//!   - activaciones/logits: Q16.16 con signo (i32) — 1.0 = 65536

const std = @import("std");

/// Neuronas de la capa oculta (fijo por diseño; el entrenador lo respeta).
pub const OCULTAS = 16;
/// Máximo de tokens por pregunta (el excedente se ignora).
pub const MAX_TOKENS = 32;
/// Máximo de intenciones (el generador lo comprueba).
pub const MAX_INTENCIONES = 32;
/// Umbral de confianza (%): por debajo la pregunta se rechaza educadamente.
/// El canon clasifica con ≥94% y los adversariales quedan ≤71%: 75% separa.
pub const UMBRAL_PCT: u32 = 75;
/// Cobertura mínima: % de palabras de la pregunta que deben existir en el
/// vocabulario, concretamente MÁS DE LA MITAD (51: falla cerrado). Protege
/// de frases ajenas con una palabra que sí conocemos ("como hacer una tarta
/// de queso" → 1 de 3 conocidas → rechazo; "cuentame un chiste" → 1 de 2).
pub const COBERTURA_MIN_PCT: u32 = 51;

// ---------------------------------------------------------------------------
// normalización y tokens
// ---------------------------------------------------------------------------

/// Palabras vacías: se quitan ANTES de buscar en el vocabulario (no añaden
/// señal y encogen la bolsa). Todas ya normalizadas (sin acentos).
pub const PALABRAS_VACIAS = [_][]const u8{
    "a",       "al",     "bajo",    "como",   "cono", "cual",  "cuales", "cuanta",
    "cuantas", "cuanto", "cuantos", "cuando", "de",   "del",   "donde",  "e",
    "el",      "en",     "era",     "es",     "esta", "estan", "estas",  "estoy",
    "fue",     "hay",    "la",      "las",    "le",   "les",   "lo",     "los",
    "mas",     "me",     "menos",   "mi",     "muy",  "o",     "para",   "por",
    "que",     "quien",  "quienes", "se",     "sera", "sin",   "son",    "su",
    "sus",     "te",     "tu",      "tus",    "u",    "un",    "una",    "unas",
    "unos",    "vos",    "y",
};

/// Sinónimos 1:1 (aplicados tras normalizar): jerga y anglicismos comunes.
pub const SINONIMOS = [_][2][]const u8{
    .{ "ram", "memoria" },
    .{ "cpu", "procesador" },
    .{ "micro", "procesador" },
    .{ "os", "sistema" },
    .{ "video", "pantalla" },
    .{ "monitor", "pantalla" },
    .{ "hdd", "disco" },
    .{ "reboot", "reiniciar" },
};

/// Minúscula Latin-1 (NO toca Ñ: se maneja aparte al mapear acentos).
fn minuscula(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 32;
    return c;
}

/// Carácter Latin-1 (ya en minúscula) a letra base sin acento.
/// Devuelve 0 si el carácter no forma palabra (se convierte en espacio).
/// La Ñ también se pliega a "n": el vocabulario queda en [a-z0-9] puro.
fn letraBase(c: u8) u8 {
    return switch (c) {
        'a'...'z', '0'...'9' => c,
        0xF1 => 'n', // ñ
        0xE0...0xE5 => 'a', // à á â ã ä å
        0xE7 => 'c', // ç
        0xE8...0xEB => 'e', // è é ê ë
        0xEC...0xEF => 'i', // ì í î ï
        0xF2...0xF6 => 'o', // ò ó ô õ ö
        0xF9...0xFC => 'u', // ù ú û ü
        0xFD, 0xFF => 'y', // ý ÿ
        else => 0,
    };
}

/// Decodifica el siguiente carácter de `origen` desde `i`. Acepta UTF-8
/// (2-3 bytes: literales del corpus) y, si no hay secuencia válida, toma
/// el byte crudo como Latin-1 (lo que teclea el intérprete por PS/2).
/// Los puntos de código > 0xFF se tratan como "sin letra" (espacio).
fn siguiente(origen: []const u8, i: usize) struct { cp: u21, ancho: usize } {
    const b0 = origen[i];
    if (b0 < 0x80) return .{ .cp = b0, .ancho = 1 };
    if (i + 1 < origen.len and b0 >= 0xC2 and b0 <= 0xDF) {
        const b1 = origen[i + 1];
        if (b1 & 0xC0 == 0x80) {
            return .{ .cp = (@as(u21, b0 & 0x1F) << 6) | (b1 & 0x3F), .ancho = 2 };
        }
    }
    if (i + 2 < origen.len and b0 >= 0xE0 and b0 <= 0xEF) {
        const b1 = origen[i + 1];
        const b2 = origen[i + 2];
        if (b1 & 0xC0 == 0x80 and b2 & 0xC0 == 0x80) {
            return .{ .cp = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | (b2 & 0x3F), .ancho = 3 };
        }
    }
    return .{ .cp = b0, .ancho = 1 }; // byte suelto: Latin-1 crudo
}

/// Normaliza una pregunta a "solo letras/dígitos/ñ y espacios simples".
/// Acepta UTF-8 y Latin-1. `búfer` debe tener al menos el tamaño de
/// `origen` (+1 para el cierre).
pub fn normalizar(origen: []const u8, bufer: []u8) []const u8 {
    var n: usize = 0;
    var prev_espacio = true;
    var i: usize = 0;
    while (i < origen.len) {
        const dec = siguiente(origen, i);
        i += dec.ancho;
        const c: u8 = if (dec.cp <= 0xFF) letraBase(minuscula(@intCast(dec.cp))) else 0;
        if (c == 0) {
            prev_espacio = true;
            continue;
        }
        if (n >= bufer.len) break;
        if (prev_espacio and n > 0) {
            bufer[n] = ' ';
            n += 1;
            if (n >= bufer.len) break;
        }
        bufer[n] = c;
        n += 1;
        prev_espacio = false;
    }
    // recortar espacio final
    if (n > 0 and bufer[n - 1] == ' ') n -= 1;
    return bufer[0..n];
}

fn esVacia(t: []const u8) bool {
    for (PALABRAS_VACIAS) |v| {
        if (std.mem.eql(u8, t, v)) return true;
    }
    return false;
}

fn sinonimoDe(t: []const u8) ?[]const u8 {
    for (SINONIMOS) |par| {
        if (std.mem.eql(u8, t, par[0])) return par[1];
    }
    return null;
}

/// Parte el texto YA NORMALIZADO en tokens (sin vacías, con sinónimos).
/// Los tokens apuntan DENTRO de `texto` (que debe seguir vivo).
/// Devuelve el número de tokens escritos en `salida`.
pub fn tokenizar(texto: []const u8, salida: [][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < texto.len) {
        while (i < texto.len and texto[i] == ' ') i += 1;
        var fin = i;
        while (fin < texto.len and texto[fin] != ' ') fin += 1;
        if (fin > i) {
            var t = texto[i..fin];
            if (t.len <= 16 and !esVacia(t)) {
                if (sinonimoDe(t)) |s| t = s;
                if (n < salida.len and n < MAX_TOKENS) {
                    salida[n] = t;
                    n += 1;
                }
            }
        }
        i = fin;
    }
    return n;
}

// ---------------------------------------------------------------------------
// pesos e inferencia en punto fijo
// ---------------------------------------------------------------------------

/// Pesos embebidos (los produce tools/entrenar_antlex.zig en pesos.zig).
/// w1: [vocab.len][ocultas] aplanado fila-major; w2: [ocultas][intenciones].
pub const Pesos = struct {
    vocab: []const []const u8,
    intenciones: []const []const u8,
    w1: []const i16,
    b1: []const i16,
    w2: []const i16,
    b2: []const i16,
};

pub const Resultado = struct {
    /// Índice de la mejor intención (válido si aceptada).
    intencion: usize = 0,
    /// Confianza 0-100 de la mejor intención.
    confianza_pct: u32 = 0,
    /// Índice y confianza de la segunda intención.
    segunda: usize = 0,
    segunda_pct: u32 = 0,
    /// Tokens de la pregunta que existen en el vocabulario.
    n_conocidos: usize = 0,
    /// % de tokens que existen en el vocabulario (cobertura).
    cobertura_pct: u32 = 0,
    /// ¿Superó umbral Y cobertura? (si no, el kernel rechaza educadamente).
    aceptada: bool = false,
    /// Aporte (grad×entrada) de cada token a la intención elegida, en
    /// Q16.16: positivos empujan hacia la intención, negativos en contra.
    aportes: [MAX_TOKENS]i32 = [_]i32{0} ** MAX_TOKENS,
};

/// Tabla exp2 NEGATIVA de 8 bits fraccionarios (comptime: sin FPU en
/// runtime). LUT[i] = round(2^16 · 2^(-i/256)): decrece de 1.0 a ~0.5.
const LUT_EXP2: [256]u32 = blk: {
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        const v = std.math.exp2(-@as(f64, @floatFromInt(i)) / 256.0) * 65536.0;
        t[i] = @intFromFloat(@round(v));
    }
    break :blk t;
};

/// exp(-d) para d ≥ 0 en Q16.16 → u32 Q16.16. Precisión ~0.3%: de sobra
/// para un umbral al 1%.
/// exp(-d) = 2^(-d·log2(e)); con y = d·log2(e) = ent + frac:
/// exp(-d) = 2^(-ent) · 2^(-frac) = LUT[frac] >> ent.
fn expMenosQ16(d: i64) u32 {
    if (d <= 0) return 65536;
    const LOG2E_Q16: i64 = 94571; // round(log2(e)·2^16)
    const y: i64 = (d * LOG2E_Q16) >> 16; // Q16.16 positivo
    const ent: u32 = @intCast(@divTrunc(y, 65536));
    if (ent >= 17) return 0; // ~1e-6: desborda por abajo
    const frac: u32 = @intCast(y & 0xFFFF);
    const base = LUT_EXP2[frac >> 8];
    return base >> @intCast(ent);
}

/// Índice de `token` en el vocabulario (búsqueda lineal: ~140 entradas).
pub fn indiceVocab(vocab: []const []const u8, token: []const u8) ?usize {
    for (vocab, 0..) |v, i| {
        if (std.mem.eql(u8, v, token)) return i;
    }
    return null;
}

/// Clasifica `tokens` con la red embebida. Sin FPU: solo enteros.
pub fn clasificar(p: *const Pesos, tokens: []const []const u8) Resultado {
    var r = Resultado{};
    const n_int = p.intenciones.len;
    std.debug.assert(p.w1.len == p.vocab.len * OCULTAS);
    std.debug.assert(p.w2.len == OCULTAS * n_int);

    // 1) bolsa de palabras → z1 (Q16.16) → ReLU (pesos Q4.11 → <<5)
    var z1: [OCULTAS]i32 = undefined;
    var a1: [OCULTAS]i32 = undefined;
    for (0..OCULTAS) |h| {
        z1[h] = @as(i32, p.b1[h]) << 5;
    }
    var idx_tokens: [MAX_TOKENS]usize = undefined;
    var n_tok: usize = 0;
    for (tokens) |t| {
        if (n_tok >= MAX_TOKENS) break;
        if (indiceVocab(p.vocab, t)) |vi| {
            const fila = vi * OCULTAS;
            for (0..OCULTAS) |h| {
                z1[h] += @as(i32, p.w1[fila + h]) << 5;
            }
            idx_tokens[n_tok] = vi;
            n_tok += 1;
        }
    }
    r.n_conocidos = n_tok;
    for (0..OCULTAS) |h| {
        a1[h] = if (z1[h] > 0) z1[h] else 0;
    }

    // 2) ocultas → logits (i64 para acotar; luego i32)
    var logits: [MAX_INTENCIONES]i32 = undefined;
    var max_logit: i32 = std.math.minInt(i32);
    for (0..n_int) |i| {
        var acc: i64 = @as(i64, p.b2[i]) << 5;
        for (0..OCULTAS) |h| {
            acc += (@as(i64, a1[h]) * p.w2[h * n_int + i]) >> 11;
        }
        const v: i32 = @intCast(std.math.clamp(acc, -1 << 30, 1 << 30));
        logits[i] = v;
        if (v > max_logit) max_logit = v;
    }

    // 3) softmax entera sobre (max − logit)
    var probs: [MAX_INTENCIONES]u32 = undefined;
    var suma: u64 = 0;
    var mejor: usize = 0;
    var segundo: usize = 0;
    for (0..n_int) |i| {
        probs[i] = expMenosQ16(@as(i64, max_logit) - logits[i]);
        suma += probs[i];
        if (probs[i] > probs[mejor]) {
            segundo = mejor;
            mejor = i;
        } else if (i != mejor and probs[i] > probs[segundo]) {
            segundo = i;
        }
    }
    r.intencion = mejor;
    r.segunda = segundo;
    if (suma > 0) {
        r.confianza_pct = @intCast(std.math.clamp(
            (probs[mejor] * 100 + suma / 2) / suma,
            0,
            100,
        ));
        r.segunda_pct = @intCast(std.math.clamp(
            (probs[segundo] * 100 + suma / 2) / suma,
            0,
            100,
        ));
    }
    // aceptación: confianza alta Y cobertura suficiente (las frases ajenas
    // con muchas palabras fuera de vocabulario no pasan aunque una palabra
    // suelta empuje fuerte hacia una intención)
    if (tokens.len > 0) {
        r.cobertura_pct = @intCast(@min(
            @as(u64, r.n_conocidos) * 100 / tokens.len,
            100,
        ));
    }
    r.aceptada = r.n_conocidos > 0 and
        r.confianza_pct >= UMBRAL_PCT and
        r.cobertura_pct >= COBERTURA_MIN_PCT;

    // 4) aportes grad×entrada por token hacia la intención elegida:
    //    Σ_h relu'(z1[h]) · w1[t][h] · w2[h][mejor]  (Q16.16; i64 al centro)
    for (0..n_tok) |t| {
        var ap: i64 = 0;
        const fila = idx_tokens[t] * OCULTAS;
        for (0..OCULTAS) |h| {
            if (z1[h] <= 0) continue;
            ap += @as(i64, p.w1[fila + h]) * p.w2[h * n_int + mejor];
        }
        r.aportes[t] = @intCast(std.math.clamp(ap >> 11, -(1 << 30), 1 << 30));
    }
    return r;
}

/// Cota de bytes del búfer de normalización para una pregunta del
/// intérprete (LARGO_LINEA = 120).
pub const MAX_NORMALIZADO = 128;

// ---------------------------------------------------------------------------
// preguntas canónicas (autoprueba del kernel + diagnóstico del entrenador)
// ---------------------------------------------------------------------------

pub const Canon = struct {
    pregunta: []const u8,
    /// Intención esperada; null = debe RECHAZARSE (tema ajeno).
    esperada: ?[]const u8 = null,
};

/// 12 preguntas canónicas: 10 de sistema + 2 ajenas que se rechazan.
/// La autoprueba del kernel (fase 4) exige 12/12 con los pesos embebidos.
pub const CANON = [_]Canon{
    .{ .pregunta = "hola antlex", .esperada = "saludo" },
    .{ .pregunta = "quien eres", .esperada = "identidad" },
    .{ .pregunta = "cuanta memoria tienes", .esperada = "memoria" },
    .{ .pregunta = "que hora es", .esperada = "hora" },
    .{ .pregunta = "que dia es hoy", .esperada = "fecha" },
    .{ .pregunta = "que version tienes", .esperada = "version" },
    .{ .pregunta = "cuanto espacio queda", .esperada = "espacio" },
    .{ .pregunta = "que es alfs", .esperada = "alfs" },
    .{ .pregunta = "gracias antlex", .esperada = "gracias" },
    .{ .pregunta = "que comandos hay", .esperada = "comandos" },
    .{ .pregunta = "cual es la capital de francia", .esperada = null },
    .{ .pregunta = "quien gano el partido de futbol", .esperada = null },
};

// ---------------------------------------------------------------------------
// pruebas (corren en host con zig build test)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "normalizar: minúsculas, acentos y puntuación fuera" {
    var buf: [MAX_NORMALIZADO]u8 = undefined;
    try testing.expectEqualStrings("que dia es hoy", normalizar("¿Qué DÍA es HOY?", &buf));
    try testing.expectEqualStrings("cuanta ram tienes", normalizar("¿Cuánta ráM tienes?", &buf));
    try testing.expectEqualStrings("adios", normalizar("  ¡Adiós!  ", &buf));
    try testing.expectEqualStrings("nino y ano", normalizar("Niño y año", &buf));
    try testing.expectEqualStrings("", normalizar("¿¡?.,;", &buf));
    try testing.expectEqualStrings("modo 64 bits", normalizar("modo 64-bits", &buf));
}

test "tokenizar: vacías fuera y sinónimos aplicados" {
    var buf: [MAX_NORMALIZADO]u8 = undefined;
    var toks: [MAX_TOKENS][]const u8 = undefined;
    const texto = normalizar("¿Cuál es la CPU y cuánta RAM hay?", &buf);
    const n = tokenizar(texto, &toks);
    // cual/es/la/y/cuanta/hay son vacías; cpu→procesador, ram→memoria
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("procesador", toks[0]);
    try testing.expectEqualStrings("memoria", toks[1]);
}

test "tokenizar: la ñ se pliega a n" {
    var buf: [MAX_NORMALIZADO]u8 = undefined;
    var toks: [MAX_TOKENS][]const u8 = undefined;
    const texto = normalizar("el niño pequeño", &buf);
    const n = tokenizar(texto, &toks);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("nino", toks[0]);
    try testing.expectEqualStrings("pequeno", toks[1]);
}

test "expMenosQ16: extremos y simetría aproximada" {
    try testing.expectEqual(@as(u32, 65536), expMenosQ16(0));
    try testing.expectEqual(@as(u32, 0), expMenosQ16(@as(i64, 1) << 26)); // d=1024
    // exp(-1) ≈ 0.3679 → ≈24096 en Q16.16 (tolerancia 1%)
    const v = expMenosQ16(65536);
    try testing.expect(@abs(@as(i64, v) - 24113) < 300);
}
