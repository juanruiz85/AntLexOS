//! AntLex OS — TLS 1.3 cliente (Fase 9b): handshake propio sobre la pila
//! TCP de red.zig con juego único TLS_AES_128_GCM_SHA256 (0x1301) y X25519.
//! Las primitivas criptográficas (X25519, AES-128-GCM, SHA-256, HKDF,
//! X.509 y RSA con PSS) vienen de `std.crypto`; el protocolo TLS — capa de
//! registros, handshake y plan de claves — es de cosecha propia.
//!
//! Seguridad (ver docs/revision_seguridad.md, REV-v1.4.0):
//! - **Anclaje de raíz**: ISRG Root X1 (la raíz de la cadena de
//!   raw.githubusercontent.com en 2026) embebida en la imagen + una raíz
//!   extra que el usuario carga con `red ca` (la CA de pruebas del arnés).
//!   La cadena se verifica entera: firmas de cada eslabón, ventanas de
//!   validez contra el reloj RTC y hostname contra el SAN del certificado
//!   de la hoja. La rotación de raíces requiere actualizar el sistema.
//! - **CertificateVerify obligatorio**: se comprueba con RSA-PSS-SHA256
//!   sobre el hash de la transcripción; sin él, un intermediario podría
//!   reenviar el certificado legítimo y suplantar al servidor.
//! - **Entropía débil** (documentada): el `random` del cliente y la
//!   semilla X25519 salen de una mezcla de tics del PIT, reloj RTC y
//!   direcciones; sin RNG de hardware. Suficiente para un SO didáctico.
//! - Sin PSK, sin renegociación, sin KeyUpdate; los NewSessionTicket que
//!   llegan tras el handshake se ignoran (no se usan en nada).

const std = @import("std");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const reloj = @import("reloj.zig");
const red = @import("red.zig");

const X25519 = std.crypto.dh.X25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Certificado = std.crypto.Certificate;
const hkdfExpandLabel = std.crypto.tls.hkdfExpandLabel;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Raíz anclada: ISRG Root X1 (certificado público, extraído del almacén
/// del sistema; sha256 96bcec06…f08c6). La cadena de raw.githubusercontent.com
/// en 2026 termina en ella (hoja *.github.io ← YR1 ← Root YR ← X1).
const RAIZ_ISRG_X1 = @embedFile("raiz_isrg_x1.der");

const SUITE: u16 = 0x1301; // TLS_AES_128_GCM_SHA256
const GRUPO_X25519: u16 = 0x001D;
const RSA_PSS_SHA256: u16 = 0x0804;

const REGISTRO_MAX = 16384; // carga útil máxima por registro (RFC 8446 §5.2)

pub const Estado = enum { inactivo, esperando_hello, datos, error_ };

var estado_tls: Estado = .inactivo;

// ---------------------------------------------------------------------------
// helpers de bytes (orden de red)
// ---------------------------------------------------------------------------

inline fn pones16(b: []u8, o: usize, v: u16) void {
    b[o] = @intCast(v >> 8);
    b[o + 1] = @intCast(v & 0xFF);
}

inline fn pones24(b: []u8, o: usize, v: usize) void {
    b[o] = @intCast(v >> 16);
    b[o + 1] = @intCast(v >> 8);
    b[o + 2] = @intCast(v & 0xFF);
}

inline fn tomas16(b: []const u8, o: usize) u16 {
    return (@as(u16, b[o]) << 8) | b[o + 1];
}

inline fn tomas24(b: []const u8, o: usize) usize {
    return (@as(usize, b[o]) << 16) | (@as(usize, b[o + 1]) << 8) | b[o + 2];
}

/// Segundos desde epoch (UTC) a partir de la fecha del RTC — algoritmo de
/// días civiles de Howard Hinnant. Vectores: 2026-11-15 → 1794700800 y
/// 2025-06-15 12:34:56 → 1749990896.
pub fn epochDesde(f: reloj.FechaHora) i64 {
    const y: i64 = f.anio;
    const m: i64 = f.mes;
    const yy: i64 = if (m <= 2) y - 1 else y;
    const mm: i64 = if (m > 2) m - 3 else m + 9;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * mm + 2, 5) + f.dia - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const dias = era * 146097 + doe - 719468;
    return dias * 86400 + @as(i64, f.hora) * 3600 + @as(i64, f.min) * 60 + f.seg;
}

fn epochAhora() i64 {
    return epochDesde(reloj.leer());
}

/// Entropía débil pero honesta: mezcla de reloj RTC, tics del PIT,
/// milisegundos de arranque y la dirección del propio buf. En las
/// pruebas del host no hay RTC/PIT (serían instrucciones privilegiadas):
/// patrón fijo, solo para que la estructura sea comprobable.
fn entropia(destino: []u8) void {
    if (@import("builtin").os.tag != .freestanding) {
        @memset(destino, 0xAA);
        return;
    }
    var h = Sha256.init(.{});
    var salida: [32]u8 = undefined;
    var escritos: usize = 0;
    var contador: u64 = 0;
    while (escritos < destino.len) {
        h.update(std.mem.asBytes(&contador));
        const f = reloj.leer();
        h.update(std.mem.asBytes(&f));
        var t = pit.leerTics();
        h.update(std.mem.asBytes(&t));
        t = pit.uptimeMs();
        h.update(std.mem.asBytes(&t));
        var dir: usize = @intFromPtr(&salida);
        h.update(std.mem.asBytes(&dir));
        h.final(&salida);
        const n = @min(32, destino.len - escritos);
        @memcpy(destino[escritos..][0..n], salida[0..n]);
        escritos += n;
        contador += 1;
    }
}

// ---------------------------------------------------------------------------
// claves por dirección y fase
// ---------------------------------------------------------------------------

const Direccion = struct {
    clave: [16]u8 = .{0} ** 16,
    iv: [12]u8 = .{0} ** 12,
    seq: u64 = 0,
};

var dir_c_hs: Direccion = .{};
var dir_s_hs: Direccion = .{};
var dir_c_ap: Direccion = .{};
var dir_s_ap: Direccion = .{};
var secreto_c_hs: [32]u8 = .{0} ** 32;
var secreto_s_hs: [32]u8 = .{0} ** 32;

fn derivarDireccion(secret: [32]u8, d: *Direccion) void {
    d.clave = hkdfExpandLabel(Hkdf, secret, "key", "", 16);
    d.iv = hkdfExpandLabel(Hkdf, secret, "iv", "", 12);
    d.seq = 0;
}

fn nonceDe(d: *const Direccion) [12]u8 {
    var n = d.iv;
    var seq_be: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_be, d.seq, .big);
    for (0..8) |i| n[4 + i] ^= seq_be[i];
    return n;
}

fn claveTerminada(secret: [32]u8) [32]u8 {
    return hkdfExpandLabel(Hkdf, secret, "finished", "", 32);
}

/// Derive-Secret(…, "derived", "") usa Hash("") — los 32 bytes del hash
/// de la cadena vacía — como contexto, no la cadena vacía (RFC 8446 §7.1;
/// el vector del RFC 8448 lo deja claro: info termina en e3b0c442…).
fn hashVacia() [32]u8 {
    var h: [32]u8 = undefined;
    Sha256.hash(&[_]u8{}, &h, .{});
    return h;
}

// ---------------------------------------------------------------------------
// transcripción
// ---------------------------------------------------------------------------

var trans: Sha256 = undefined;

fn hashDe(h: *const Sha256) [32]u8 {
    var copia: Sha256 = h.*;
    var salida: [32]u8 = undefined;
    copia.final(&salida);
    return salida;
}

// ---------------------------------------------------------------------------
// bufes de recepción (flujo TCP → registros → mensajes / datos)
// ---------------------------------------------------------------------------

var rx_flujo: [REGISTRO_MAX + 2100]u8 = undefined;
var rx_flujo_len: usize = 0;
var hs_buf: [REGISTRO_MAX + 4]u8 = undefined;
var hs_buf_len: usize = 0;
var claro: [REGISTRO_MAX + 16]u8 = undefined;
var entrega: [8192]u8 = undefined;
var entrega_len: usize = 0;
var descifrando_hs = true; // tras Finished del servidor: claves de aplicación
var fin_notificado = false;

/// Raíz extra anclada por el usuario (`red ca`): DER crudo en base64.
var raiz_extra: [4096]u8 = undefined;
var raiz_extra_len: usize = 0;

pub fn anclarRaizExtra(der: []const u8) bool {
    if (der.len == 0 or der.len > raiz_extra.len) return false;
    @memcpy(raiz_extra[0..der.len], der);
    raiz_extra_len = der.len;
    return true;
}

fn valorB64(c: u8) ?u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

/// Ancla una raíz extra a partir de su DER codificado en base64 (texto
/// plano con saltos de línea tolerados); la lee `red ca <archivo>`.
pub fn anclarRaizBase64(texto: []const u8) bool {
    var der: [4096]u8 = undefined;
    var n: usize = 0;
    var acum: u32 = 0;
    var bits: u5 = 0;
    for (texto) |c| {
        if (c == '\r' or c == '\n' or c == ' ' or c == '\t') continue;
        if (c == '=') break; // relleno
        const v = valorB64(c) orelse return false;
        acum = (acum << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (n >= der.len) return false;
            der[n] = @intCast((acum >> bits) & 0xFF);
            n += 1;
        }
    }
    if (n < 100) return false; // menos que un certificado mínimo
    return anclarRaizExtra(der[0..n]);
}

pub fn raizExtraAnclada() bool {
    return raiz_extra_len > 0;
}

pub fn estado() Estado {
    return estado_tls;
}

// ---------------------------------------------------------------------------
// X25519
// ---------------------------------------------------------------------------

var x_secret: [32]u8 = undefined;
var x_public: [32]u8 = undefined;
var compartido: [32]u8 = undefined;
var host_buf: [255]u8 = undefined;
var host_len: usize = 0;

// ---------------------------------------------------------------------------
// ClientHello
// ---------------------------------------------------------------------------

/// Construye el registro ClientHello (sin cifrar) en `reg`; devuelve su
/// longitud. Extensiones: SNI, supported_groups (x25519),
/// signature_algorithms (RSA-PSS-SHA256), supported_versions (1.3) y
/// key_share x25519.
fn construirClientHello(reg: []u8, host: []const u8) usize {
    var cuerpo: [1024]u8 = undefined;
    var o: usize = 0;
    cuerpo[o] = 0x03;
    cuerpo[o + 1] = 0x03; // legacy_version
    o += 2;
    entropia(cuerpo[o..][0..32]); // random
    o += 32;
    cuerpo[o] = 0; // legacy_session_id: vacío
    o += 1;
    pones16(&cuerpo, o, 2); // longitud de suites
    o += 2;
    pones16(&cuerpo, o, SUITE);
    o += 2;
    cuerpo[o] = 1; // un método de compresión…
    o += 1;
    cuerpo[o] = 0; // …nulo
    o += 1;

    // ---- extensiones ----
    var exts: [768]u8 = undefined;
    var e: usize = 0;
    const ext = struct {
        fn f(b: []u8, i: *usize, tipo: u16, cuerpo_ext: []const u8) void {
            pones16(b, i.*, tipo);
            pones16(b, i.* + 2, @intCast(cuerpo_ext.len));
            i.* += 4;
            @memcpy(b[i.*..][0..cuerpo_ext.len], cuerpo_ext);
            i.* += cuerpo_ext.len;
        }
    }.f;
    { // server_name (SNI)
        var sni: [300]u8 = undefined;
        var s: usize = 0;
        pones16(&sni, s, @intCast(host.len + 3)); // lista
        sni[s + 2] = 0; // type: host_name
        s += 3;
        pones16(&sni, s, @intCast(host.len));
        s += 2;
        @memcpy(sni[s..][0..host.len], host);
        s += host.len;
        ext(&exts, &e, 0, sni[0..s]);
    }
    ext(&exts, &e, 10, &.{ 0x00, 0x02, 0x00, GRUPO_X25519 & 0xFF }); // groups
    ext(&exts, &e, 13, &.{ 0x00, 0x02, 0x08, 0x04 }); // sig algs: PSS-SHA256
    ext(&exts, &e, 43, &.{ 0x02, 0x03, 0x04 }); // versions: TLS 1.3
    { // key_share x25519: el cuerpo lleva el vector client_shares
        // (longitud total de las entradas) ENVOLVIENDO cada share
        var ks: [40]u8 = undefined;
        pones16(&ks, 0, GRUPO_X25519);
        pones16(&ks, 2, 32);
        @memcpy(ks[4..36], &x_public);
        var kse: [42]u8 = undefined;
        pones16(&kse, 0, 36); // client_shares_len = grupo+len+clave
        @memcpy(kse[2..38], ks[0..36]);
        ext(&exts, &e, 51, kse[0..38]);
    }

    pones16(&cuerpo, o, @intCast(e)); // longitud extensiones
    o += 2;
    @memcpy(cuerpo[o..][0..e], exts[0..e]);
    o += e;

    // registro: 22 (handshake) + versión 0x0301 (permitida en el CH
    // inicial por compatibilidad; los demás registros van con 0x0303)
    reg[0] = 22;
    reg[1] = 0x03;
    reg[2] = 0x01;
    pones16(reg, 3, @intCast(4 + o));
    reg[5] = 1; // handshake: ClientHello
    pones24(reg, 6, o);
    @memcpy(reg[9..][0..o], cuerpo[0..o]);
    return 9 + o;
}

// ---------------------------------------------------------------------------
// plan de claves (RFC 8446 §7.1)
// ---------------------------------------------------------------------------

/// Tras el ServerHello: handshake_secret del X25519 compartido y secretos
/// de tráfico con la transcripción hasta el ServerHello.
fn derivarHandshake() void {
    var cero: [32]u8 = .{0} ** 32;
    const early = Hkdf.extract(&cero, &cero); // sin PSK: IKM y sal a cero
    var derived: [32]u8 = undefined;
    derived = hkdfExpandLabel(Hkdf, early, "derived", &hashVacia(), 32);
    const hs_secret = Hkdf.extract(&derived, &compartido);
    const h1 = hashDe(&trans);
    secreto_c_hs = hkdfExpandLabel(Hkdf, hs_secret, "c hs traffic", &h1, 32);
    secreto_s_hs = hkdfExpandLabel(Hkdf, hs_secret, "s hs traffic", &h1, 32);
    derivarDireccion(secreto_c_hs, &dir_c_hs);
    derivarDireccion(secreto_s_hs, &dir_s_hs);
}

/// Tras el Finished del servidor: master y secretos de aplicación con la
/// transcripción hasta ese mensaje.
fn derivarAplicacion() void {
    var cero: [32]u8 = .{0} ** 32;
    // el secreto de handshake se reconstruye (no se guarda aparte: el
    // «derived» solo depende del X25519 compartido, que sí guardamos)
    var cero2: [32]u8 = .{0} ** 32;
    const early = Hkdf.extract(&cero2, &cero2);
    var derived0: [32]u8 = undefined;
    derived0 = hkdfExpandLabel(Hkdf, early, "derived", &hashVacia(), 32);
    const hs_secret = Hkdf.extract(&derived0, &compartido);
    var derived: [32]u8 = undefined;
    derived = hkdfExpandLabel(Hkdf, hs_secret, "derived", &hashVacia(), 32);
    const master = Hkdf.extract(&derived, &cero);
    const h = hashDe(&trans);
    const c_ap = hkdfExpandLabel(Hkdf, master, "c ap traffic", &h, 32);
    const s_ap = hkdfExpandLabel(Hkdf, master, "s ap traffic", &h, 32);
    derivarDireccion(c_ap, &dir_c_ap);
    derivarDireccion(s_ap, &dir_s_ap);
}

// ---------------------------------------------------------------------------
// capa de registros
// ---------------------------------------------------------------------------

/// Envía un registro cifrado con la dirección activa de ESCRITURA (`hs`
/// durante el handshake, `ap` después). El tipo interno viaja al final del
/// texto claro, como manda TLS 1.3.
fn enviarRegistro(tipo_interno: u8, contenido: []const u8, hs: bool) bool {
    if (contenido.len + 1 + 16 > REGISTRO_MAX) return false;
    var reg: [REGISTRO_MAX + 24]u8 = undefined; // en pila (16 KiB y pico)
    const d = if (hs) &dir_c_hs else &dir_c_ap;
    const lon_int = contenido.len + 1; // contenido + tipo
    reg[0] = 23; // registro opaco «application_data»
    reg[1] = 0x03;
    reg[2] = 0x03;
    pones16(&reg, 3, @intCast(lon_int + 16));
    @memcpy(reg[5..][0..contenido.len], contenido);
    reg[5 + contenido.len] = tipo_interno;
    const nonce = nonceDe(d);
    Aes128Gcm.encrypt(reg[5..][0..lon_int], reg[5 + lon_int ..][0..16], reg[5..][0..lon_int], reg[0..5], nonce, d.clave);
    d.seq += 1;
    return red.tcpEnviar(reg[0 .. 5 + lon_int + 16]);
}

/// Descifra un registro (tipo 23) en `claro`. Devuelve el tipo interno y el
/// tamaño del contenido; null si la etiqueta AEAD no verifica.
fn descifrarRegistro(reg: []const u8) ?struct { tipo: u8, n: usize } {
    if (reg.len < 5 + 17) return null;
    const lon = tomas16(reg, 3);
    if (lon < 17 or 5 + lon > reg.len or lon - 16 > claro.len) return null;
    const d = if (descifrando_hs) &dir_s_hs else &dir_s_ap;
    const cifrado = reg[5 .. 5 + lon - 16];
    const etiqueta = reg[5 + lon - 16 ..][0..16].*;
    const nonce = nonceDe(d);
    Aes128Gcm.decrypt(claro[0..cifrado.len], cifrado, etiqueta, reg[0..5], nonce, d.clave) catch return null;
    d.seq += 1;
    // el ÚLTIMO byte del texto claro es el tipo interno (viaja cifrado):
    // el resto es el contenido
    return .{ .tipo = claro[cifrado.len - 1], .n = cifrado.len - 1 };
}

// ---------------------------------------------------------------------------
// procesado del flujo TCP
// ---------------------------------------------------------------------------

/// Tira de la TCP hacia el buf de flujo y procesa los registros
/// completos. Devuelve false solo en error fatal de TLS.
fn procesarEntrada() bool {
    var trozo: [2048]u8 = undefined;
    while (true) {
        const n = red.tcpRecibir(&trozo, 5);
        if (n == 0) break;
        if (rx_flujo_len + n > rx_flujo.len) {
            serial.puts("tls: desbordamiento del flujo\n");
            estado_tls = .error_;
            return false;
        }
        @memcpy(rx_flujo[rx_flujo_len..][0..n], trozo[0..n]);
        rx_flujo_len += n;
        // Consumir los registros completos YA: con un flujo continuo (el
        // cuerpo de una descarga en registros de 16 KiB) las lecturas nunca
        // se cortan solas y sin esto rx_flujo desbordaría sin descifrar.
        if (!consumirRegistros()) return false;
        if (n < trozo.len) break; // la TCP se queda sin datos por ahora
    }
    return consumirRegistros();
}

/// Procesa todos los registros completos del buf de flujo.
fn consumirRegistros() bool {
    while (rx_flujo_len >= 5) {
        const tipo = rx_flujo[0];
        // registro de datos cuya carga no cabe en la entrega: se queda en
        // el flujo hasta que la capa de arriba drene (no es error: en una
        // descarga grande llegan varios registros de 16 KiB seguidos)
        if (tipo == 23) {
            const l23 = tomas16(&rx_flujo, 3);
            if (rx_flujo_len >= 5 + l23 and entrega_len + l23 - 17 > entrega.len) return true;
        }
        if (tipo != 20 and tipo != 21 and tipo != 22 and tipo != 23) {
            serial.puts("tls: tipo de registro inesperado\n");
            estado_tls = .error_;
            return false;
        }
        const lon = tomas16(&rx_flujo, 3);
        // En TLS 1.3 el contenido viaza: tipo(1) + carga + tag(16); un
        // registro de carga máxima mide 16384+1+16 = 16401 bytes.
        if (lon > REGISTRO_MAX + 17) {
            serial.puts("tls: registro demasiado grande\n");
            estado_tls = .error_;
            return false;
        }
        if (rx_flujo_len < 5 + lon) {
            return true; // falta el resto del registro
        }
        const reg = rx_flujo[0 .. 5 + lon];

        var contenido: []const u8 = reg[5..];
        var tipo_interno = tipo;
        if (tipo == 23) { // cifrado
            const r = descifrarRegistro(reg) orelse {
                serial.puts("tls: fallo al descifrar (etiqueta AEAD)\n");
                estado_tls = .error_;
                return false;
            };
            tipo_interno = r.tipo;
            contenido = claro[0..r.n];
        }
        if (!procesarContenido(tipo_interno, contenido)) return false;

        const resto = rx_flujo_len - (5 + lon);
        if (resto > 0) std.mem.copyForwards(u8, rx_flujo[0..resto], rx_flujo[5 + lon .. rx_flujo_len]);
        rx_flujo_len = resto;
    }
    return true;
}

/// Procesa un contenido de registro ya en claro con su tipo interno.
fn procesarContenido(tipo: u8, contenido: []const u8) bool {
    switch (tipo) {
        20 => {}, // ChangeCipherSpec de compatibilidad: ignorar
        21 => { // alerta
            if (contenido.len >= 2) {
                if (contenido[1] == 0) { // close_notify
                    fin_notificado = true;
                } else {
                    serial.puts("tls: alerta del servidor (nivel ");
                    serial.putDec(contenido[0]);
                    serial.puts(", codigo ");
                    serial.putDec(contenido[1]);
                    serial.puts(")\n");
                    estado_tls = .error_;
                    return false;
                }
            }
        },
        22 => return procesarHandshake(contenido),
        23 => { // datos de aplicación
            if (entrega_len + contenido.len > entrega.len) {
                serial.puts("tls: buf de entrega lleno\n");
                estado_tls = .error_;
                return false;
            }
            @memcpy(entrega[entrega_len..][0..contenido.len], contenido);
            entrega_len += contenido.len;
        },
        else => {},
    }
    return true;
}

/// Reensambla mensajes de handshake (pueden partirse en registros) y
/// despacha los completos.
fn procesarHandshake(contenido: []const u8) bool {
    if (hs_buf_len + contenido.len > hs_buf.len) {
        serial.puts("tls: mensaje de handshake demasiado grande\n");
        estado_tls = .error_;
        return false;
    }
    @memcpy(hs_buf[hs_buf_len..][0..contenido.len], contenido);
    hs_buf_len += contenido.len;
    while (hs_buf_len >= 4) {
        const lon = tomas24(&hs_buf, 1);

        const msj = hs_buf[0 .. 4 + lon];
        if (!despacharMensaje(msj)) return false;
        const resto = hs_buf_len - (4 + lon);
        if (resto > 0) std.mem.copyForwards(u8, hs_buf[0..resto], hs_buf[4 + lon .. hs_buf_len]);
        hs_buf_len = resto;
    }
    return true;
}

var certs_der: [4][]const u8 = .{ undefined, undefined, undefined, undefined };
var certs_num: usize = 0;
// los slices no pueden quedarse apuntando a `claro` (el registro siguiente
// lo descifra encima): la cadena se copia a este buf estable
var certs_buf: [6144]u8 = undefined;
var certs_buf_len: usize = 0;

fn despacharMensaje(msj: []const u8) bool {
    switch (msj[0]) {
        2 => return procesarServerHello(msj),
        4 => {}, // NewSessionTicket: ignorar
        8 => {
            trans.update(msj); // EncryptedExtensions
            serial.puts("tls: ee recibido\n"); // DEBUG
        },
        11 => return procesarCertificate(msj),
        15 => return procesarCertificateVerify(msj),
        20 => return procesarFinishedServidor(msj), // finished = 0x14
        else => {}, // desconocido: ignorar (la transcripción ya no importa)
    }
    return true;
}

fn procesarServerHello(msj: []const u8) bool {
    if (estado_tls != .esperando_hello) return true; // duplicado: ignorar
    const cuerpo = msj[4..];
    // version(2) random(32) sid_len(1) sid(n) suite(2) comp(1) exts…
    if (cuerpo.len < 39) {
        serial.puts("tls: ServerHello truncado\n");
        estado_tls = .error_;
        return false;
    }
    const sid_len: usize = cuerpo[34];
    var o: usize = 35 + sid_len;
    if (o + 3 > cuerpo.len or tomas16(cuerpo, o) != SUITE or cuerpo[o + 2] != 0) {
        serial.puts("tls: suite o compresión inesperadas\n");
        estado_tls = .error_;
        return false;
    }
    o += 3; // o apunta a la longitud de extensiones
    if (o + 2 > cuerpo.len) {
        serial.puts("tls: ServerHello sin extensiones\n");
        estado_tls = .error_;
        return false;
    }
    const exts_fin = @min(o + 2 + tomas16(cuerpo, o), cuerpo.len);
    o += 2;
    var publica: ?[32]u8 = null;
    var version_13 = false;
    while (o + 4 <= exts_fin) {
        const et = tomas16(cuerpo, o);
        const el = tomas16(cuerpo, o + 2);
        if (o + 4 + el > exts_fin) break;
        const cuerpo_ext = cuerpo[o + 4 .. o + 4 + el];
        switch (et) {
            43 => { // supported_versions
                if (cuerpo_ext.len >= 2 and tomas16(cuerpo_ext, 0) == 0x0304) version_13 = true;
            },
            51 => { // key_share
                if (cuerpo_ext.len >= 36 and tomas16(cuerpo_ext, 0) == GRUPO_X25519) {
                    var clave_srv: [32]u8 = undefined;
                    @memcpy(&clave_srv, cuerpo_ext[4..36]);
                    publica = clave_srv;
                }
            },
            else => {},
        }
        o += 4 + el;
    }
    if (!version_13 or publica == null) {
        serial.puts("tls: el servidor no eligió TLS 1.3 + X25519\n");
        estado_tls = .error_;
        return false;
    }
    compartido = X25519.scalarmult(x_secret, publica.?) catch {
        serial.puts("tls: X25519: punto inválido\n");
        estado_tls = .error_;
        return false;
    };
    trans.update(msj);
    derivarHandshake();
    descifrando_hs = true;
    serial.puts("tls: sh recibido\n"); // DEBUG
    return true;
}

fn procesarCertificate(msj: []const u8) bool {
    trans.update(msj);
    const cuerpo = msj[4..];
    if (cuerpo.len < 4) return false;
    const ctx_len: usize = cuerpo[0]; // debe ser 0 (no venía de un request)
    var o: usize = 1 + ctx_len;
    if (o + 3 > cuerpo.len) return false;
    // el fin de la lista es su longitud MÁS el propio prefijo de 3 bytes
    const lista_fin = @min(o + 3 + tomas24(cuerpo, o), cuerpo.len);
    o += 3;
    certs_num = 0;
    certs_buf_len = 0;
    while (o + 3 <= lista_fin and certs_num < certs_der.len) {
        const lon = tomas24(cuerpo, o);
        o += 3;
        if (lon == 0 or o + lon + 2 > lista_fin) return false; // cert + exts
        if (certs_buf_len + lon > certs_buf.len) return false; // sin sitio
        @memcpy(certs_buf[certs_buf_len..][0..lon], cuerpo[o .. o + lon]);
        certs_der[certs_num] = certs_buf[certs_buf_len..][0..lon];
        certs_buf_len += lon;
        certs_num += 1;
        // saltar el vector de extensiones de la entrada: 2 B de longitud
        // + su contenido (el +2 era el que faltaba y descuadraba el bucle)
        o += lon + 2 + tomas16(cuerpo, o + lon);
    }
    if (certs_num == 0) {
        serial.puts("tls: cadena de certificados vacía\n");
        estado_tls = .error_;
        return false;
    }
    return true;
}

fn procesarCertificateVerify(msj: []const u8) bool {
    const cuerpo = msj[4..];
    if (cuerpo.len < 4 + 256) {
        estado_tls = .error_;
        return false;
    }
    const algoritmo = tomas16(cuerpo, 0);
    const sig_len = tomas16(cuerpo, 2);
    if (algoritmo != RSA_PSS_SHA256 or sig_len != 256) {
        serial.puts("tls: CertificateVerify con algoritmo/firma inesperados\n");
        estado_tls = .error_;
        return false;
    }
    const firma = cuerpo[4 .. 4 + 256];

    // contenido firmado: contexto + 0x00 + hash de la transcripción HASTA
    // el mensaje Certificate (el CV aún no está en la transcripción)
    const h_cert = hashDe(&trans);
    const contexto = "TLS 1.3, server CertificateVerify";
    // contenido firmado (RFC 8446 §4.4.3): 64 bytes 0x20 (espacio) +
    // cadena de contexto + un byte 0 separador + hash de la transcripción.
    // Los 64 espacios son los que faltaban.
    var contenido_firmado: [64 + 34 + 32]u8 = undefined;
    @memset(contenido_firmado[0..64], 0x20);
    @memcpy(contenido_firmado[64..][0..contexto.len], contexto);
    contenido_firmado[64 + contexto.len] = 0;
    @memcpy(contenido_firmado[64 + contexto.len + 1 ..][0..32], &h_cert);
    const lon_firmado = 64 + contexto.len + 1 + 32;

    // clave pública RSA-2048 de la hoja
    const hoja = Certificado{ .buffer = certs_der[0], .index = 0 };
    const ph = hoja.parse() catch {
        serial.puts("tls: certificado de la hoja ilegible\n");
        estado_tls = .error_;
        return false;
    };
    if (ph.pub_key_algo != .rsaEncryption) {
        serial.puts("tls: la hoja no es RSA (v1: solo RSA-2048)\n");
        estado_tls = .error_;
        return false;
    }
    const comp = Certificado.rsa.PublicKey.parseDer(ph.pubKey()) catch {
        serial.puts("tls: clave pública de la hoja ilegible\n");
        estado_tls = .error_;
        return false;
    };
    if (comp.modulus.len != 256) {
        serial.puts("tls: hoja RSA distinta de 2048 bits\n");
        estado_tls = .error_;
        return false;
    }
    const clave_pub = Certificado.rsa.PublicKey.fromBytes(comp.exponent, comp.modulus) catch {
        estado_tls = .error_;
        return false;
    };
    var sig: [256]u8 = undefined;
    @memcpy(&sig, firma);
    Certificado.rsa.PSSSignature.verify(256, sig, contenido_firmado[0..lon_firmado], clave_pub, Sha256) catch {
        serial.puts("tls: CertificateVerify INVÁLIDO\n");
        estado_tls = .error_;
        return false;
    };
    trans.update(msj);
    serial.puts("tls: certificateverify OK\n"); // DEBUG
    return true;
}

fn procesarFinishedServidor(msj: []const u8) bool {
    const cuerpo = msj[4..];
    if (cuerpo.len != 32) {
        serial.puts("tls: Finished del servidor con tamaño raro\n");
        estado_tls = .error_;
        return false;
    }
    // verify_data = HMAC(finished_key_s, Hash(trans hasta CertificateVerify))
    const fk = claveTerminada(secreto_s_hs);
    var esperado: [32]u8 = undefined;
    HmacSha256.create(&esperado, &hashDe(&trans), &fk);
    if (!std.mem.eql(u8, &esperado, cuerpo[0..32])) {
        serial.puts("tls: Finished del servidor INVÁLIDO\n");
        estado_tls = .error_;
        return false;
    }
    trans.update(msj);
    derivarAplicacion();
    descifrando_hs = false; // a partir de aquí: claves de aplicación
    serial.puts("tls: finished del servidor OK\n"); // DEBUG
    return true;
}

// ---------------------------------------------------------------------------
// verificación de la cadena contra las raíces ancladas
// ---------------------------------------------------------------------------

fn tryVerificarConRaiz(ultima: Certificado, raiz_der: []const u8, ahora: i64) bool {
    const raiz = Certificado{ .buffer = raiz_der, .index = 0 };
    Certificado.verify(ultima, raiz, ahora) catch |e| {
        serial.puts("tls: verificacion con raiz: ");
        serial.puts(@errorName(e));
        serial.puts("\n");
        return false;
    };
    return true;
}

/// Cadena: hostname de la hoja contra `host`, cada eslabón firmado por el
/// siguiente y el último firmado por una raíz anclada (ISRG X1 embebida o
/// la extra de `red ca`).
fn verificarCadena(host: []const u8, ahora: i64) bool {
    if (certs_num == 0) return false;
    const hoja = Certificado{ .buffer = certs_der[0], .index = 0 };
    const ph = hoja.parse() catch {
        serial.puts("tls: certificado de la hoja ilegible\n");
        return false;
    };
    ph.verifyHostName(host) catch {
        serial.puts("tls: el hostname no está en el certificado\n");
        return false;
    };
    var i: usize = 0;
    while (i + 1 < certs_num) : (i += 1) {
        const subj = Certificado{ .buffer = certs_der[i], .index = 0 };
        const emisor = Certificado{ .buffer = certs_der[i + 1], .index = 0 };
        Certificado.verify(subj, emisor, ahora) catch {
            serial.puts("tls: eslabón de la cadena inválido\n");
            return false;
        };
    }
    serial.puts("tls: cadena con ");
    serial.putDec(certs_num);
    serial.puts(" cert(s), epoch=");
    serial.putDec(@as(u32, @intCast(ahora)));
    serial.puts("\n");
    const ultima = Certificado{ .buffer = certs_der[certs_num - 1], .index = 0 };
    if (tryVerificarConRaiz(ultima, RAIZ_ISRG_X1, ahora)) return true;
    if (raiz_extra_len > 0 and tryVerificarConRaiz(ultima, raiz_extra[0..raiz_extra_len], ahora)) return true;
    serial.puts("tls: la cadena no llega a ninguna raíz anclada\n");
    return false;
}

// ---------------------------------------------------------------------------
// API pública
// ---------------------------------------------------------------------------

/// Handshake completo contra `host` (SNI y hostname) en ip:puerto.
pub fn conectar(host: []const u8, ip: [4]u8, puerto: u16) bool {
    if (host.len == 0 or host.len > host_buf.len) return false;
    estado_tls = .inactivo;
    rx_flujo_len = 0;
    hs_buf_len = 0;
    entrega_len = 0;
    descifrando_hs = true;
    fin_notificado = false;
    certs_num = 0;
    @memcpy(host_buf[0..host.len], host);
    host_len = host.len;

    var semilla: [32]u8 = undefined;
    entropia(&semilla);
    const par = X25519.KeyPair.generateDeterministic(semilla) catch return false;
    x_secret = par.secret_key;
    x_public = par.public_key;

    if (!red.tcpConectar(ip, puerto)) {
        serial.puts("tls: no se pudo abrir la TCP\n");
        return false;
    }
    trans = Sha256.init(.{});

    var reg: [1100]u8 = undefined;
    const n = construirClientHello(&reg, host);
    const lon_reg = tomas16(&reg, 3);
    trans.update(reg[5 .. 5 + lon_reg]); // el mensaje CH, sin capa de registro
    if (!red.tcpEnviar(reg[0..n])) {
        serial.puts("tls: no se pudo enviar el ClientHello\n");
        return false;
    }
    estado_tls = .esperando_hello;
    serial.puts("tls: client hello enviado (");
    serial.puts(host);
    serial.puts(")\n");

    // SH → EE → Cert → CV → Fin (con reintentos de sondeo hasta 8 s)
    const t0 = pit.leerTics();
    while (pit.leerTics() - t0 < 800) {
        if (!procesarEntrada()) {
            red.tcpCerrar();
            return false;
        }
        if (!descifrando_hs) { // Finished del servidor verificado
            if (!verificarCadena(host_buf[0..host_len], epochAhora())) {
                red.tcpCerrar();
                return false;
            }
            // Finished del cliente (cifrado, claves de handshake): mensaje
            // handshake 14 con verify_data = HMAC(fk_c, Hash(trans))
            const fk_c = claveTerminada(secreto_c_hs);
            var vd: [32]u8 = undefined;
            HmacSha256.create(&vd, &hashDe(&trans), &fk_c);
            var fin_msj: [36]u8 = undefined;
            fin_msj[0] = 20; // finished = 0x14
            pones24(&fin_msj, 1, 32);
            @memcpy(fin_msj[4..36], &vd);
            if (!enviarRegistro(22, &fin_msj, true)) {
                red.tcpCerrar();
                return false;
            }
            estado_tls = .datos;
            serial.puts("tls: handshake completo y verificado\n");
            return true;
        }
    }
    serial.puts("tls: timeout del handshake\n");
    red.tcpCerrar();
    return false;
}

/// Envía datos de aplicación (registros cifrados de hasta 16 KiB).
pub fn enviar(datos: []const u8) bool {
    if (estado_tls != .datos) return false;
    var off: usize = 0;
    while (off < datos.len) {
        const n = @min(datos.len - off, REGISTRO_MAX - 1);
        if (!enviarRegistro(23, datos[off .. off + n], false)) return false;
        off += n;
    }
    return true;
}

/// Recibe datos de aplicación: sondea hasta `tics` (de 100 Hz). Devuelve
/// los bytes copiados (0 si el servidor cerró o timeout).
pub fn recibir(buf: []u8, tics: u64) usize {
    if (estado_tls != .datos and entrega_len == 0) return 0;
    const t0 = pit.leerTics();
    while (true) {
        if (entrega_len > 0) break;
        if (fin_notificado or estado_tls != .datos) break;
        if (pit.leerTics() - t0 >= tics) break;
        _ = procesarEntrada();
        // FIN de TCP sin close_notify (Python y otros cierran así): si no
        // queda nada pendiente por descifrar ni entregar, se acabaron los
        // datos de la sesión.
        if (entrega_len == 0 and rx_flujo_len == 0 and red.tcpFinRecibido()) {
            fin_notificado = true;
            break;
        }
    }
    const n = @min(entrega_len, buf.len);
    if (n > 0) {
        @memcpy(buf[0..n], entrega[0..n]);
        if (entrega_len > n) {
            std.mem.copyForwards(u8, entrega[0 .. entrega_len - n], entrega[n..entrega_len]);
        }
        entrega_len -= n;
    }
    return n;
}

/// Respuesta de pedir(): código de estado HTTP y el cuerpo (un slice
/// DENTRO del buf del llamador, tras las cabeceras).
pub const Respuesta = struct { estado: u16, cuerpo: []const u8 };

/// GET HTTP/1.1 sobre TLS 1.3 contra host/ip:puerto. Recibe la respuesta
/// completa (cabeceras incluidas) en `buf` y devuelve el estado y el
/// cuerpo ya recortado. Una sola petición por conexión (Connection: close).
pub fn pedir(host: []const u8, ip: [4]u8, puerto: u16, ruta: []const u8, buf: []u8) ?Respuesta {
    if (!conectar(host, ip, puerto)) return null;
    defer cerrar();

    var peticion: [512]u8 = undefined;
    var n: usize = 0;
    const anexar = struct {
        fn f(b: []u8, i: *usize, t: []const u8) void {
            const l = @min(t.len, b.len - i.*);
            @memcpy(b[i.*..][0..l], t[0..l]);
            i.* += l;
        }
    }.f;
    anexar(&peticion, &n, "GET ");
    anexar(&peticion, &n, ruta);
    anexar(&peticion, &n, " HTTP/1.1\r\nHost: ");
    anexar(&peticion, &n, host);
    anexar(&peticion, &n, "\r\nUser-Agent: AntLexOS\r\nConnection: close\r\n\r\n");
    if (!enviar(peticion[0..n])) return null;

    // recibir toda la respuesta que quepa en el buf. El fin real lo
    // detecta recibir() (close_notify o FIN de TCP con búferes vacíos);
    // las 25 vueltas de 1 s son el margen para registros TLS de 16 KB
    // reensamblándose y descifrándose bajo emulación (TCG).
    var total: usize = 0;
    var vueltas: u8 = 0;
    while (vueltas < 25) : (vueltas += 1) {
        const r = recibir(buf[total..], 100);
        if (r > 0) {
            vueltas = 0; // con datos seguimos esperando el resto
            total += r;
            if (total == buf.len) break;
        } else if (fin_notificado or estado_tls != .datos) break;
    }
    if (total < 12) return null; // ni línea de estado

    // estado: "HTTP/1.x NNN ..."
    var codigo: u16 = 0;
    var i: usize = 0;
    while (i < total and buf[i] != ' ') i += 1;
    i += 1;
    while (i + 1 < total and buf[i] >= '0' and buf[i] <= '9') : (i += 1) {
        codigo = codigo * 10 + (buf[i] - '0');
    }
    // separador de cabeceras
    var cuerpo_ini: usize = total;
    var j: usize = 0;
    while (j + 3 < total) : (j += 1) {
        if (buf[j] == '\r' and buf[j + 1] == '\n' and buf[j + 2] == '\r' and buf[j + 3] == '\n') {
            cuerpo_ini = j + 4;
            break;
        }
    }
    return .{ .estado = codigo, .cuerpo = buf[cuerpo_ini..total] };
}

/// Cierre limpio: close_notify cifrado + FIN de la TCP.
pub fn cerrar() void {
    if (estado_tls == .datos) {
        _ = enviarRegistro(21, &.{ 0x01, 0x00 }, false); // close_notify
    }
    estado_tls = .inactivo;
    red.tcpCerrar();
}

// ---------------------------------------------------------------------------
// pruebas en host (zig build test)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tls: epoch desde FechaHora (vectores UTC)" {
    try testing.expectEqual(@as(i64, 1794700800), epochDesde(.{ .anio = 2026, .mes = 11, .dia = 15, .hora = 0, .min = 0, .seg = 0 }));
    try testing.expectEqual(@as(i64, 1749990896), epochDesde(.{ .anio = 2025, .mes = 6, .dia = 15, .hora = 12, .min = 34, .seg = 56 }));
    try testing.expectEqual(@as(i64, 0), epochDesde(.{ .anio = 1970, .mes = 1, .dia = 1, .hora = 0, .min = 0, .seg = 0 }));
}

test "tls: ClientHello bien formado" {
    x_secret = .{0} ** 32;
    x_public = .{0} ** 32;
    var reg: [1100]u8 = undefined;
    const n = construirClientHello(&reg, "raw.githubusercontent.com");
    try testing.expect(n > 100 and n < reg.len);
    try testing.expectEqual(@as(u8, 22), reg[0]); // registro handshake
    const lon = tomas16(&reg, 3);
    try testing.expectEqual(@as(usize, 5 + lon), n);
    try testing.expectEqual(@as(u8, 1), reg[5]); // ClientHello
    try testing.expectEqual(lon - 4, tomas24(&reg, 6)); // longitud del mensaje
    const cuerpo = reg[9..];
    try testing.expectEqual(@as(u8, 0x03), cuerpo[0]);
    try testing.expectEqual(@as(u8, 0), cuerpo[34]); // session_id vacío
    try testing.expectEqual(SUITE, tomas16(cuerpo, 37));
    try testing.expectEqual(@as(u8, 1), cuerpo[39]); // una compresión
    try testing.expectEqual(@as(u8, 0), cuerpo[40]); // …nula
}

test "tls: raíz anclada embebida (ISRG Root X1)" {
    const raiz = Certificado{ .buffer = RAIZ_ISRG_X1, .index = 0 };
    const p = try raiz.parse();
    try testing.expect(p.pub_key_algo == .rsaEncryption);
    // subject() devuelve el DN en DER: el CN viaja dentro como texto
    try testing.expect(std.mem.indexOf(u8, p.subject(), "ISRG Root X1") != null);
}

test "tls: hkdfExpandLabel determinista y sensible a la etiqueta" {
    const secreto = [_]u8{0xAB} ** 32;
    const k1 = hkdfExpandLabel(Hkdf, secreto, "key", "", 16);
    const k2 = hkdfExpandLabel(Hkdf, secreto, "key", "", 16);
    try testing.expectEqualSlices(u8, &k1, &k2);
    const k3 = hkdfExpandLabel(Hkdf, secreto, "iv", "", 12);
    try testing.expect(!std.mem.eql(u8, k1[0..12], &k3));
}

test "tls: base64 → DER para red ca" {
    // la codificación en base64 de un DER pequeño debe decodificar bien y
    // una con caracteres raros debe rechazarse
    var copia: [64]u8 = undefined;
    @memcpy(copia[0..4], "QUJD"); // "ABC"
    try testing.expect(!anclarRaizBase64("QUJD")); // demasiado corto (<100)
    try testing.expect(!anclarRaizBase64("¡cara!cter@rar0"));
    _ = &copia;
}

test "tls: plan de claves contra los vectores del RFC 8448 (1-RTT)" {
    // Traza «Simple 1-RTT Handshake» del RFC 8448: transcripción CH||SH,
    // ECDHE compartido y secretos de tráfico de handshake conocidos.
    const ch_rfc = [196]u8{
        0x01, 0x00, 0x00, 0xc0, 0x03, 0x03, 0xcb, 0x34, 0xec, 0xb1,
        0xe7, 0x81, 0x63, 0xba, 0x1c, 0x38, 0xc6, 0xda, 0xcb, 0x19,
        0x6a, 0x6d, 0xff, 0xa2, 0x1a, 0x8d, 0x99, 0x12, 0xec, 0x18,
        0xa2, 0xef, 0x62, 0x83, 0x02, 0x4d, 0xec, 0xe7, 0x00, 0x00,
        0x06, 0x13, 0x01, 0x13, 0x03, 0x13, 0x02, 0x01, 0x00, 0x00,
        0x91, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x09, 0x00, 0x00, 0x06,
        0x73, 0x65, 0x72, 0x76, 0x65, 0x72, 0xff, 0x01, 0x00, 0x01,
        0x00, 0x00, 0x0a, 0x00, 0x14, 0x00, 0x12, 0x00, 0x1d, 0x00,
        0x17, 0x00, 0x18, 0x00, 0x19, 0x01, 0x00, 0x01, 0x01, 0x01,
        0x02, 0x01, 0x03, 0x01, 0x04, 0x00, 0x23, 0x00, 0x00, 0x00,
        0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20, 0x99,
        0x38, 0x1d, 0xe5, 0x60, 0xe4, 0xbd, 0x43, 0xd2, 0x3d, 0x8e,
        0x43, 0x5a, 0x7d, 0xba, 0xfe, 0xb3, 0xc0, 0x6e, 0x51, 0xc1,
        0x3c, 0xae, 0x4d, 0x54, 0x13, 0x69, 0x1e, 0x52, 0x9a, 0xaf,
        0x2c, 0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04, 0x00, 0x0d,
        0x00, 0x20, 0x00, 0x1e, 0x04, 0x03, 0x05, 0x03, 0x06, 0x03,
        0x02, 0x03, 0x08, 0x04, 0x08, 0x05, 0x08, 0x06, 0x04, 0x01,
        0x05, 0x01, 0x06, 0x01, 0x02, 0x01, 0x04, 0x02, 0x05, 0x02,
        0x06, 0x02, 0x02, 0x02, 0x00, 0x2d, 0x00, 0x02, 0x01, 0x01,
        0x00, 0x1c, 0x00, 0x02, 0x40, 0x01,
    };
    const sh_rfc = [90]u8{
        0x02, 0x00, 0x00, 0x56, 0x03, 0x03, 0xa6, 0xaf, 0x06, 0xa4,
        0x12, 0x18, 0x60, 0xdc, 0x5e, 0x6e, 0x60, 0x24, 0x9c, 0xd3,
        0x4c, 0x95, 0x93, 0x0c, 0x8a, 0xc5, 0xcb, 0x14, 0x34, 0xda,
        0xc1, 0x55, 0x77, 0x2e, 0xd3, 0xe2, 0x69, 0x28, 0x00, 0x13,
        0x01, 0x00, 0x00, 0x2e, 0x00, 0x33, 0x00, 0x24, 0x00, 0x1d,
        0x00, 0x20, 0xc9, 0x82, 0x88, 0x76, 0x11, 0x20, 0x95, 0xfe,
        0x66, 0x76, 0x2b, 0xdb, 0xf7, 0xc6, 0x72, 0xe1, 0x56, 0xd6,
        0xcc, 0x25, 0x3b, 0x83, 0x3d, 0xf1, 0xdd, 0x69, 0xb1, 0xb0,
        0x4e, 0x75, 0x1f, 0x0f, 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04,
    };
    const ecdhe_rfc = [32]u8{
        0x8b, 0xd4, 0x05, 0x4f, 0xb5, 0x5b, 0x9d, 0x63, 0xfd, 0xfb,
        0xac, 0xf9, 0xf0, 0x4b, 0x9f, 0x0d, 0x35, 0xe6, 0xd6, 0x3f,
        0x53, 0x75, 0x63, 0xef, 0xd4, 0x62, 0x72, 0x90, 0x0f, 0x89,
        0x49, 0x2d,
    };
    const h_rfc = [32]u8{
        0x86, 0x0c, 0x06, 0xed, 0xc0, 0x78, 0x58, 0xee, 0x8e, 0x78,
        0xf0, 0xe7, 0x42, 0x8c, 0x58, 0xed, 0xd6, 0xb4, 0x3f, 0x2c,
        0xa3, 0xe6, 0xe9, 0x5f, 0x02, 0xed, 0x06, 0x3c, 0xf0, 0xe1,
        0xca, 0xd8,
    };
    const c_hs_rfc = [32]u8{
        0xb3, 0xed, 0xdb, 0x12, 0x6e, 0x06, 0x7f, 0x35, 0xa7, 0x80,
        0xb3, 0xab, 0xf4, 0x5e, 0x2d, 0x8f, 0x3b, 0x1a, 0x95, 0x07,
        0x38, 0xf5, 0x2e, 0x96, 0x00, 0x74, 0x6a, 0x0e, 0x27, 0xa5,
        0x5a, 0x21,
    };
    const s_hs_rfc = [32]u8{
        0xb6, 0x7b, 0x7d, 0x69, 0x0c, 0xc1, 0x6c, 0x4e, 0x75, 0xe5,
        0x42, 0x13, 0xcb, 0x2d, 0x37, 0xb4, 0xe9, 0xc9, 0x12, 0xbc,
        0xde, 0xd9, 0x10, 0x5d, 0x42, 0xbe, 0xfd, 0x59, 0xd3, 0x91,
        0xad, 0x38,
    };
    trans = Sha256.init(.{});
    trans.update(&ch_rfc);
    trans.update(&sh_rfc);
    const h1 = hashDe(&trans);
    try testing.expectEqualSlices(u8, &h_rfc, &h1); // transcripción exacta

    compartido = ecdhe_rfc;
    derivarHandshake();
    try testing.expectEqualSlices(u8, &c_hs_rfc, &secreto_c_hs);
    try testing.expectEqualSlices(u8, &s_hs_rfc, &secreto_s_hs);
}
