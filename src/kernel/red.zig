//! AntLex OS — red (Fase 9): virtio-net 1.0, ARP, IPv4 e ICMP.
//!
//! Modelo v1 (documentado en docs/manual_tecnico.md §5g):
//! - **Sin interrupciones**: los comandos sondean (polling) los anillos
//!   RX/TX con esperas acotadas por PIT. Suficiente y honesto para la
//!   Fase 9; una IRQ propia es trabajo futuro.
//! - **IP estática** 10.0.2.15/24 con puerta de enlace 10.0.2.2 (los
//!   valores por defecto de la red de usuario de QEMU; la tabla de IP
//!   ancladas para la tienda llega con `descargar`).
//! - Los búferes son DMA-seguros: el kernel corre con mapa identidad de
//!   4 GiB, así que dirección virtual == física.
//! - Virtio moderno (1.0): PCI capability list + common config MMIO. Sin
//!   patentes: virtio es especificación OASIS (BSD).
//!
//! La parte pura (checksums, ARP, IPv4, ICMP, formatos) está separada del
//! hardware y se prueba en host (`zig build test`) y en la autoprueba 15.

const std = @import("std");
const serial = @import("serial.zig");
const x86 = @import("x86.zig");
const mem = @import("mem.zig");
const pit = @import("pit.zig");

// ---------------------------------------------------------------------------
// constantes de red (QEMU user networking)
// ---------------------------------------------------------------------------

pub const IP_NUESTRA = [4]u8{ 10, 0, 2, 15 };
pub const IP_PUERTA = [4]u8{ 10, 0, 2, 2 };

const ETH_ARP: u16 = 0x0806;
const ETH_IPV4: u16 = 0x0800;
const PROTO_ICMP: u8 = 1;

const MAC_DIFUSION = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

// ---------------------------------------------------------------------------
// helpers de bytes (orden de red = big endian, explícito)
// ---------------------------------------------------------------------------

inline fn pones16(b: []u8, o: usize, v: u16) void {
    b[o] = @intCast(v >> 8);
    b[o + 1] = @intCast(v & 0xFF);
}

inline fn pones32(b: []u8, o: usize, v: u32) void {
    b[o] = @intCast((v >> 24) & 0xFF);
    b[o + 1] = @intCast((v >> 16) & 0xFF);
    b[o + 2] = @intCast((v >> 8) & 0xFF);
    b[o + 3] = @intCast(v & 0xFF);
}

inline fn tomas16(b: []const u8, o: usize) u16 {
    return (@as(u16, b[o]) << 8) | b[o + 1];
}

/// Checksum de Internet (RFC 1071): suma de palabras de 16 bits en orden
/// de red con acarreo y complemento a uno. Vector verificado contra el
/// ejemplo clásico de la Wikipedia (0xB861).
pub fn checksum(datos: []const u8) u16 {
    var suma: u32 = 0;
    var i: usize = 0;
    while (i + 1 < datos.len) : (i += 2) {
        suma +%= (@as(u32, datos[i]) << 8) | datos[i + 1];
    }
    if (i < datos.len) suma +%= @as(u32, datos[i]) << 8; // relleno impar
    while (suma >> 16 != 0) suma = (suma & 0xFFFF) + (suma >> 16);
    return @intCast(~suma & 0xFFFF);
}

/// "10.0.2.2" → {10,0,2,2}; null si no es una IPv4 válida.
pub fn parsearIp(txt: []const u8) ?[4]u8 {
    var ip = [4]u8{ 0, 0, 0, 0 };
    var octeto: usize = 0;
    var valor: u32 = 0;
    var digitos: u8 = 0;
    for (txt) |c| {
        if (c == '.') {
            if (digitos == 0 or valor > 255 or octeto >= 3) return null;
            ip[octeto] = @intCast(valor);
            octeto += 1;
            valor = 0;
            digitos = 0;
        } else if (c >= '0' and c <= '9') {
            valor = valor * 10 + (c - '0');
            digitos += 1;
            if (digitos > 3) return null;
        } else return null;
    }
    if (digitos == 0 or valor > 255 or octeto != 3) return null;
    ip[3] = @intCast(valor);
    return ip;
}

/// "52:54:00:12:34:56" (17 caracteres exactos).
pub fn formatearMac(m: [6]u8, buf: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var i: usize = 0;
    for (m, 0..) |b, k| {
        if (k > 0) {
            buf[i] = ':';
            i += 1;
        }
        buf[i] = hex[b >> 4];
        buf[i + 1] = hex[b & 0xF];
        i += 2;
    }
    return buf[0..i];
}

/// "10.0.2.15" (hasta 15 caracteres).
pub fn formatearIp(ip: [4]u8, buf: []u8) []const u8 {
    var i: usize = 0;
    for (ip, 0..) |o, k| {
        if (k > 0) {
            buf[i] = '.';
            i += 1;
        }
        if (o == 0) {
            buf[i] = '0';
            i += 1;
        } else {
            var tmp: [3]u8 = undefined;
            var n: usize = 0;
            var v = o;
            while (v > 0) : (v /= 10) {
                tmp[n] = @intCast('0' + v % 10);
                n += 1;
            }
            while (n > 0) : (n -= 1) {
                buf[i] = tmp[n - 1];
                i += 1;
            }
        }
    }
    return buf[0..i];
}

// ---------------------------------------------------------------------------
// constructores/parseadores de paquetes (puros: probados en host)
// ---------------------------------------------------------------------------

/// Payload ARP (28 bytes) para petición (oper 1) u respuesta (oper 2). La
/// cabecera Ethernet la añade `enviarTrama`.
pub fn armarPayloadArp(
    buf: []u8,
    oper: u16,
    mac_n: [6]u8,
    ip_n: [4]u8,
    mac_d: [6]u8,
    ip_d: [4]u8,
) usize {
    pones16(buf, 0, 1); // htype: Ethernet
    pones16(buf, 2, ETH_IPV4); // ptype
    buf[4] = 6; // hlen
    buf[5] = 4; // plen
    pones16(buf, 6, oper);
    @memcpy(buf[8..14], &mac_n);
    @memcpy(buf[14..18], &ip_n);
    @memcpy(buf[18..24], &mac_d);
    @memcpy(buf[24..28], &ip_d);
    return 28;
}

/// Cabecera IPv4 de 20 bytes (sin opciones) sobre `paquete`, con checksum
/// válido. Devuelve la longitud de la cabecera (20).
pub fn ponerIPv4(paquete: []u8, lon_total: u16, proto: u8, ip_o: [4]u8, ip_d: [4]u8) usize {
    paquete[0] = 0x45; // versión 4, IHL 5
    paquete[1] = 0; // DSCP/ECN
    pones16(paquete, 2, lon_total);
    pones16(paquete, 4, 0x1234); // identificación (fija, sin fragmentar)
    pones16(paquete, 6, 0x4000); // DF
    paquete[8] = 64; // TTL
    paquete[9] = proto;
    pones16(paquete, 10, 0); // checksum a cero antes de calcular
    @memcpy(paquete[12..16], &ip_o);
    @memcpy(paquete[16..20], &ip_d);
    pones16(paquete, 10, checksum(paquete[0..20]));
    return 20;
}

/// Mensaje ICMP de eco (tipo 8) con `carga` opcional y checksum válido.
pub fn armarEco(icmp: []u8, id: u16, seq: u16, carga: []const u8) usize {
    icmp[0] = 8; // tipo: eco
    icmp[1] = 0;
    pones16(icmp, 2, 0); // checksum a cero
    pones16(icmp, 4, id);
    pones16(icmp, 6, seq);
    if (carga.len > 0) @memcpy(icmp[8 .. 8 + carga.len], carga);
    const n = 8 + carga.len;
    pones16(icmp, 2, checksum(icmp[0..n]));
    return n;
}

/// Respuesta ICMP de eco (tipo 0) que copia la carga recibida.
pub fn armarRespuestaEco(icmp: []u8, id: u16, seq: u16, carga: []const u8) usize {
    icmp[0] = 0; // tipo: respuesta de eco
    icmp[1] = 0;
    pones16(icmp, 2, 0);
    pones16(icmp, 4, id);
    pones16(icmp, 6, seq);
    if (carga.len > 0) @memcpy(icmp[8 .. 8 + carga.len], carga);
    const n = 8 + carga.len;
    pones16(icmp, 2, checksum(icmp[0..n]));
    return n;
}

// ---------------------------------------------------------------------------
// PCI (config space por 0xCF8/0xCFC)
// ---------------------------------------------------------------------------

const PciDev = struct { bus: u8, disp: u8, fun: u8 };

fn pciLeer32(d: PciDev, reg: u8) u32 {
    x86.outd(0xCF8, 0x8000_0000 | (@as(u32, d.bus) << 16) |
        (@as(u32, d.disp) << 11) | (@as(u32, d.fun) << 8) | (reg & 0xFC));
    return x86.ind(0xCFC);
}

fn pciEscribir32(d: PciDev, reg: u8, v: u32) void {
    x86.outd(0xCF8, 0x8000_0000 | (@as(u32, d.bus) << 16) |
        (@as(u32, d.disp) << 11) | (@as(u32, d.fun) << 8) | (reg & 0xFC));
    x86.outd(0xCFC, v);
}

/// Lectura de 8 bits en un offset cualquiera del config space (alineando
/// el acceso a dword, como exige PCI).
fn pciLeer8(d: PciDev, reg: u8) u8 {
    const v = pciLeer32(d, reg & 0xFC);
    const desp: u5 = @intCast((reg & 3) * 8);
    return @truncate(v >> desp);
}

/// Dirección física del BAR `idx` (solo MMIO de 32/64 bits; los BAR de
/// E/S devuelven 0: virtio moderno no los usa para esto).
fn leerBar(d: PciDev, idx: u8) u64 {
    const v = pciLeer32(d, 0x10 + 4 * idx);
    if ((v & 1) != 0) return 0; // BAR de E/S
    if (((v >> 1) & 3) == 2) { // 64 bits: el siguiente BAR lleva la parte alta
        const alto = pciLeer32(d, 0x10 + 4 * (idx + 1));
        return (@as(u64, alto) << 32) | (v & ~@as(u32, 0xF));
    }
    return v & ~@as(u32, 0xF);
}

// ---------------------------------------------------------------------------
// virtio 1.0 (PCI modern)
// ---------------------------------------------------------------------------

/// common config — layout del estándar virtio 1.0 (verificado contra
/// include/uapi/linux/virtio_pci.h; offsets comprobados en comptime). Las
/// direcciones de 64 bits van en pares lo/hi como en la cabecera de Linux:
/// solo exige alineación a 4 del MMIO.
const ComunCfg = extern struct {
    device_feature_select: u32, // +0
    device_feature: u32, // +4
    guest_feature_select: u32, // +8
    guest_feature: u32, // +12
    msix_config: u16, // +16
    num_queues: u16, // +18
    device_status: u8, // +20
    config_generation: u8, // +21
    queue_select: u16, // +22
    queue_size: u16, // +24
    queue_msix_vector: u16, // +26
    queue_enable: u16, // +28
    queue_notify_off: u16, // +30
    queue_desc_lo: u32, // +32
    queue_desc_hi: u32, // +36
    queue_avail_lo: u32, // +40
    queue_avail_hi: u32, // +44
    queue_used_lo: u32, // +48
    queue_used_hi: u32, // +52
};

comptime {
    if (@offsetOf(ComunCfg, "device_status") != 20 or
        @offsetOf(ComunCfg, "queue_select") != 22 or
        @offsetOf(ComunCfg, "queue_size") != 24 or
        @offsetOf(ComunCfg, "queue_notify_off") != 30 or
        @offsetOf(ComunCfg, "queue_desc_lo") != 32 or
        @offsetOf(ComunCfg, "queue_used_hi") != 52 or
        @sizeOf(ComunCfg) != 56) @compileError("layout de ComunCfg no coincide con virtio 1.0");
}

const ST_ACK: u8 = 1;
const ST_DRIVER: u8 = 2;
const ST_DRIVER_OK: u8 = 4;
const ST_FEATURES_OK: u8 = 8;
const ST_FAILED: u8 = 128;

const F_MAC: u32 = 1 << 5;
const F_VERSION_1_ALTA: u32 = 1 << 0; // bit 32 del conjunto de 64 bits

// anillos divididos (virtio 1.0, sin EVENT_IDX ni indirectas)
const QMAX = 256; // tope del tamaño de cola virtio-net
const N_RX = 32; // búferes de recepción repostados
const N_TX = 16; // ranuras de envío
const RX_BUF = 1600; // 10 B de cabecera + trama de 1514 con margen
const TX_BUF = 1514; // trama Ethernet máxima
const HDR_VIRTIO = 12; // cabecera virtio-net: QEMU moderno consume 12 B
// (con num_buffers) aunque no se negocie MRG_RXBUF

const Desc = extern struct { dir: u64, lon: u32, banderas: u16, sig: u16 };
const AnilloAvail = extern struct { banderas: u16, idx: u16, anillo: [QMAX]u16, ev_used: u16 };
const ElemUsed = extern struct { id: u32, lon: u32 };
const AnilloUsed = extern struct { banderas: u16, idx: u16, anillo: [QMAX]ElemUsed, ev_avail: u16 };

const DESC_SIGUIENTE: u16 = 1;
const DESC_ESCRITURA: u16 = 2;

// ---------------------------------------------------------------------------
// estado del driver
// ---------------------------------------------------------------------------

var activa = false;
var mac = [_]u8{0} ** 6;
var dir_comun: usize = 0;
var dir_notify: usize = 0;
var notify_mult: u32 = 0;
var dir_disp: usize = 0;
var qsize: u16 = 0;
var noff_rx: u32 = 0;
var noff_tx: u32 = 0;

var rx_desc: usize = 0;
var rx_avail: usize = 0;
var rx_used: usize = 0;
var rx_bufs: [N_RX]usize = [_]usize{0} ** N_RX;
var rx_vistos: u16 = 0;

var tx_desc: usize = 0;
var tx_avail: usize = 0;
var tx_used: usize = 0;
var tx_hdrs: [N_TX]usize = [_]usize{0} ** N_TX;
var tx_bufs: [N_TX]usize = [_]usize{0} ** N_TX;
var tx_ocupada = [_]bool{false} ** N_TX;
var tx_vistos: u16 = 0;

var cont_tx: u32 = 0;
var cont_rx: u32 = 0;

var arp_ip: [4]u8 = .{ 0, 0, 0, 0 };
var arp_mac: [6]u8 = [_]u8{0} ** 6;
var arp_valida = false;

// eco ICMP pendiente (una petición de ping a la vez)
var eco_id: u16 = 0;
var eco_seq: u16 = 0;
var eco_recibido = false;
var eco_ms: u32 = 0;
var eco_t0: u64 = 0;

inline fn comun() *volatile ComunCfg {
    return @ptrFromInt(dir_comun);
}

fn falloVirtio(motivo: []const u8) void {
    if (dir_comun != 0) comun().device_status |= ST_FAILED;
    serial.puts("red: fallo virtio (");
    serial.puts(motivo);
    serial.puts(")\n");
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

pub fn init() void {
    // 1) localizar el dispositivo virtio-net 1.0 (0x1041 = net moderno)
    const dev = buscarVirtio() orelse {
        serial.puts("red: sin dispositivo virtio-net\n");
        return;
    };

    // 2) capabilities PCI modernas (common/notify/device cfg)
    const caps = leerCaps(dev);
    if (caps.comun == 0 or caps.notify == 0) {
        serial.puts("red: fallo virtio (sin common/notify cfg modernos)\n");
        return;
    }
    dir_comun = caps.comun;
    dir_notify = caps.notify;
    notify_mult = caps.mult;
    dir_disp = caps.disp;

    // 3) bus master + decodificación de memoria (imprescindible para DMA)
    pciEscribir32(dev, 0x04, pciLeer32(dev, 0x04) | 0x6);

    // 4) secuencia de arranque virtio: reset → ACK → DRIVER
    comun().device_status = 0;
    comun().device_status = ST_ACK;
    comun().device_status |= ST_DRIVER;

    // 5) negociación de características: VERSION_1 y MAC, nada más
    comun().device_feature_select = 0;
    const f_bajas = comun().device_feature;
    comun().device_feature_select = 1;
    const f_altas = comun().device_feature;
    if ((f_altas & F_VERSION_1_ALTA) == 0 or (f_bajas & F_MAC) == 0) {
        falloVirtio("el dispositivo no ofrece VERSION_1/MAC");
        return;
    }
    comun().guest_feature_select = 0;
    comun().guest_feature = F_MAC; // bits 0..31: solo MAC
    comun().guest_feature_select = 1;
    comun().guest_feature = F_VERSION_1_ALTA; // bits 32..63: solo VERSION_1
    comun().device_status |= ST_FEATURES_OK;
    if ((comun().device_status & ST_FEATURES_OK) == 0) {
        falloVirtio("FEATURES_OK rechazado");
        return;
    }

    // 6) anillos RX (cola 0) y TX (cola 1)
    if (!prepararColas()) return;

    // 7) MAC del dispositivo (negociada F_MAC)
    if (dir_disp != 0) {
        const m: *volatile [6]u8 = @ptrFromInt(dir_disp);
        var i: usize = 0;
        while (i < 6) : (i += 1) mac[i] = m[i];
    }

    // 8) todo listo: DRIVER_OK y repostar búferes de recepción
    comun().device_status |= ST_DRIVER_OK;
    activa = true;
    llenarRx();

    serial.puts("red: virtio-net 1.0 listo (MAC ");
    var buf: [24]u8 = undefined;
    serial.puts(formatearMac(mac, &buf));
    serial.puts(")\n");
}

fn buscarVirtio() ?PciDev {
    var disp: u8 = 0;
    while (disp < 32) : (disp += 1) {
        var fun: u8 = 0;
        while (fun < 8) : (fun += 1) {
            const d = PciDev{ .bus = 0, .disp = disp, .fun = fun };
            const v = pciLeer32(d, 0);
            if ((v & 0xFFFF) == 0x1AF4 and (v >> 16) == 0x1041) return d;
            // sin multifunción: tras la función 0 no hay más
            // (header type = byte 2 del dword en 0x0C)
            if (fun == 0 and ((pciLeer32(d, 0x0C) >> 16) & 0x80) == 0) break;
        }
    }
    return null;
}

const Caps = struct { comun: usize = 0, notify: usize = 0, mult: u32 = 0, disp: usize = 0 };

/// Recorre la lista de capabilities del config space. La lista mezcla
/// capacidades estándar (p. ej. MSI-X, id 0x11) con las vendor de virtio
/// (id 0x09): se SIGUEN todas y solo se interpretan las vendor.
fn leerCaps(dev: PciDev) Caps {
    var c = Caps{};
    var ptr = pciLeer8(dev, 0x34);
    var vueltas: u8 = 0;
    while (ptr != 0 and vueltas < 48) : (vueltas += 1) {
        const vndr = pciLeer8(dev, ptr);
        if (vndr == 0x09) {
            const tipo = pciLeer8(dev, ptr + 3);
            const bar = pciLeer8(dev, ptr + 4);
            const base = leerBar(dev, bar);
            if (base != 0 and base < (1 << 32)) {
                const dir = base + pciLeer32(dev, ptr + 8);
                switch (tipo) {
                    1 => c.comun = dir, // VIRTIO_PCI_CAP_COMMON_CFG
                    2 => { // VIRTIO_PCI_CAP_NOTIFY_CFG (+mult en el byte 16)
                        c.notify = dir;
                        c.mult = pciLeer32(dev, ptr + 16);
                    },
                    4 => c.disp = dir, // VIRTIO_PCI_CAP_DEVICE_CFG
                    else => {},
                }
            }
        }
        ptr = pciLeer8(dev, ptr + 1);
    }
    return c;
}

fn falloCola() bool {
    serial.puts("red: fallo virtio (sin memoria para anillos)\n");
    return false;
}

fn prepararColas() bool {
    // memoria para los anillos (cada cola trae desc+avail+used)
    const lon_desc = QMAX * @sizeOf(Desc);
    const lon_avail = @sizeOf(AnilloAvail);
    const lon_used = @sizeOf(AnilloUsed);
    const rx_desc_dir = mem.allocCero(lon_desc, 16) catch return falloCola();
    const rx_avail_dir = mem.allocCero(lon_avail, 4) catch return falloCola();
    const rx_used_dir = mem.allocCero(lon_used, 4) catch return falloCola();
    const tx_desc_dir = mem.allocCero(lon_desc, 16) catch return falloCola();
    const tx_avail_dir = mem.allocCero(lon_avail, 4) catch return falloCola();
    const tx_used_dir = mem.allocCero(lon_used, 4) catch return falloCola();
    // búferes de datos
    var i: usize = 0;
    while (i < N_RX) : (i += 1) {
        rx_bufs[i] = mem.allocCero(RX_BUF, 16) catch return falloCola();
    }
    i = 0;
    while (i < N_TX) : (i += 1) {
        tx_hdrs[i] = mem.allocCero(HDR_VIRTIO, 16) catch return falloCola();
        tx_bufs[i] = mem.allocCero(TX_BUF, 16) catch return falloCola();
    }

    // cola 0 (RX): descriptores de un búfer, escritura del dispositivo
    if (!configurarCola(0, rx_desc_dir, rx_avail_dir, rx_used_dir)) return false;
    noff_rx = comun().queue_notify_off;
    const d_rx: *volatile [QMAX]Desc = @ptrFromInt(rx_desc_dir);
    i = 0;
    while (i < N_RX) : (i += 1) {
        d_rx[i].dir = rx_bufs[i];
        d_rx[i].lon = RX_BUF;
        d_rx[i].banderas = DESC_ESCRITURA;
        d_rx[i].sig = 0;
    }

    // cola 1 (TX): cadenas de dos descriptores (cabecera + trama)
    if (!configurarCola(1, tx_desc_dir, tx_avail_dir, tx_used_dir)) return false;
    noff_tx = comun().queue_notify_off;
    const d_tx: *volatile [QMAX]Desc = @ptrFromInt(tx_desc_dir);
    i = 0;
    while (i < N_TX) : (i += 1) {
        d_tx[i * 2].dir = tx_hdrs[i];
        d_tx[i * 2].lon = HDR_VIRTIO;
        d_tx[i * 2].banderas = DESC_SIGUIENTE;
        d_tx[i * 2].sig = @intCast(i * 2 + 1);
        d_tx[i * 2 + 1].dir = tx_bufs[i];
        d_tx[i * 2 + 1].lon = 0;
        d_tx[i * 2 + 1].banderas = 0;
        d_tx[i * 2 + 1].sig = 0;
    }
    return true;
}

fn configurarCola(indice: u16, desc: usize, avail: usize, used: usize) bool {
    comun().queue_select = indice;
    var n = comun().queue_size;
    if (n > QMAX) {
        comun().queue_size = QMAX; // pedir una potencia de dos menor
        n = comun().queue_size;
    }
    if (n == 0 or (n & (n - 1)) != 0) {
        falloVirtio("tamaño de cola inválido");
        return false;
    }
    comun().queue_desc_lo = @truncate(desc);
    comun().queue_desc_hi = @truncate(desc >> 32);
    comun().queue_avail_lo = @truncate(avail);
    comun().queue_avail_hi = @truncate(avail >> 32);
    comun().queue_used_lo = @truncate(used);
    comun().queue_used_hi = @truncate(used >> 32);
    comun().queue_msix_vector = 0xFFFF; // sin vector MSI-X (polling)
    comun().queue_enable = 1;
    if (indice == 0) {
        rx_desc = desc;
        rx_avail = avail;
        rx_used = used;
        qsize = n;
    } else {
        tx_desc = desc;
        tx_avail = avail;
        tx_used = used;
    }
    return true;
}

fn llenarRx() void {
    const a: *volatile AnilloAvail = @ptrFromInt(rx_avail);
    var i: u16 = 0;
    while (i < N_RX) : (i += 1) {
        const slot = a.idx % qsize;
        a.anillo[slot] = i;
        a.idx = a.idx +% 1;
    }
}

// ---------------------------------------------------------------------------
// envío y recepción (polling)
// ---------------------------------------------------------------------------

fn avisar(cola: u16, noff: u32) void {
    const dir = dir_notify + @as(usize, noff) * notify_mult;
    const p: *volatile u32 = @ptrFromInt(dir);
    p.* = cola;
}

/// Envía una trama Ethernet (cabecera + carga) y espera a que el
/// dispositivo la consuma (≤500 ms).
fn enviarTrama(dest: [6]u8, tipo: u16, carga: []const u8) bool {
    var s: usize = 0;
    while (s < N_TX and tx_ocupada[s]) s += 1;
    if (s == N_TX) {
        drenarUsed(true);
        s = 0;
        while (s < N_TX and tx_ocupada[s]) s += 1;
        if (s == N_TX) return false; // todas ocupadas (no debería ocurrir)
    }
    if (carga.len > TX_BUF - 14) return false;
    const buf: [*]u8 = @ptrFromInt(tx_bufs[s]);
    const marco = buf[0..TX_BUF];
    @memcpy(marco[0..6], &dest);
    @memcpy(marco[6..12], &mac);
    pones16(marco, 12, tipo);
    @memcpy(marco[14 .. 14 + carga.len], carga);
    // longitud TOTAL de la trama (cabecera Ethernet incluida) con mínimo
    // de 60 bytes de Ethernet: el relleno son ceros al final
    var lon = 14 + carga.len;
    if (lon < 60) {
        @memset(marco[lon..60], 0); // trama mínima Ethernet
        lon = 60;
    }
    const d: *volatile [QMAX]Desc = @ptrFromInt(tx_desc);
    d[s * 2 + 1].lon = @intCast(lon);
    tx_ocupada[s] = true;
    cont_tx += 1;

    const a: *volatile AnilloAvail = @ptrFromInt(tx_avail);
    const slot = a.idx % qsize;
    a.anillo[slot] = @intCast(s * 2); // descriptor cabecera de la cadena
    a.idx = a.idx +% 1;
    avisar(1, noff_tx);

    // esperar a que el anillo used libere la ranura
    const t0 = pit.leerTics();
    while (pit.leerTics() - t0 < 50) {
        drenarUsed(true);
        if (!tx_ocupada[s]) return true;
    }
    return true; // quedará libre en cuanto el dispositivo la consuma
}

/// Procesa los anillos used de RX y TX. Con `solo_tx` se drena únicamente
/// el anillo de envío.
fn drenarUsed(solo_tx: bool) void {
    if (!activa) return;
    const ut: *volatile AnilloUsed = @ptrFromInt(tx_used);
    while (tx_vistos != ut.idx) {
        const e = ut.anillo[tx_vistos % qsize];
        tx_ocupada[e.id / 2] = false;
        tx_vistos = tx_vistos +% 1;
    }
    if (solo_tx) return;
    const ur: *volatile AnilloUsed = @ptrFromInt(rx_used);
    const a: *volatile AnilloAvail = @ptrFromInt(rx_avail);
    while (rx_vistos != ur.idx) {
        const e = ur.anillo[rx_vistos % qsize];
        const i: usize = @intCast(e.id);
        if (i < N_RX and e.lon > HDR_VIRTIO) {
            const buf: [*]u8 = @ptrFromInt(rx_bufs[i]);
            procesarTrama(buf[HDR_VIRTIO..e.lon]);
            cont_rx += 1;
        }
        const slot = a.idx % qsize;
        a.anillo[slot] = @intCast(i);
        a.idx = a.idx +% 1;
        rx_vistos = rx_vistos +% 1;
    }
}

/// Un golpe de sondeo completo (lo llaman los comandos en espera).
fn procesar() void {
    drenarUsed(false);
}

fn procesarTrama(trama: []const u8) void {
    if (trama.len < 14) return;
    const tipo = tomas16(trama, 12);
    switch (tipo) {
        ETH_ARP => procesarArp(trama),
        ETH_IPV4 => if (trama.len >= 34) procesarIPv4(trama),
        else => {},
    }
}

fn procesarArp(trama: []const u8) void {
    if (trama.len < 42) return;
    const oper = tomas16(trama, 20); // 14 eth + 6 oper
    var spa: [4]u8 = undefined;
    @memcpy(&spa, trama[28..32]); // 14 + 14 spa
    var tpa: [4]u8 = undefined;
    @memcpy(&tpa, trama[38..42]); // 14 + 24 tpa
    if (oper == 2) { // respuesta: ¿es para nuestra IP?
        if (std.mem.eql(u8, &tpa, &IP_NUESTRA)) {
            @memcpy(&arp_ip, &spa);
            @memcpy(&arp_mac, trama[22..28]); // 14 + 8 sha
            arp_valida = true;
            var b: [24]u8 = undefined;
            serial.puts("red: arp ");
            serial.puts(formatearIp(spa, &b));
            serial.puts(" -> ");
            serial.puts(formatearMac(arp_mac, &b));
            serial.puts("\n");
        }
        return;
    }
    if (oper == 1 and std.mem.eql(u8, &tpa, &IP_NUESTRA)) { // petición: contestar
        var mac_solicitante: [6]u8 = undefined;
        @memcpy(&mac_solicitante, trama[22..28]);
        var carga: [28]u8 = undefined;
        _ = armarPayloadArp(&carga, 2, mac, IP_NUESTRA, mac_solicitante, spa);
        _ = enviarTrama(mac_solicitante, ETH_ARP, &carga);
    }
}

fn procesarIPv4(trama: []const u8) void {
    // trama = cabecera Ethernet (14) + paquete IPv4 completo
    const paquete = trama[14..];
    if (paquete.len < 28) return;
    if (paquete[0] != 0x45) return; // solo IPv4 sin opciones
    const lon_total = tomas16(paquete, 2);
    if (lon_total < 20 or lon_total > paquete.len) return; // truncado
    var dst: [4]u8 = undefined;
    @memcpy(&dst, paquete[16..20]);
    if (!std.mem.eql(u8, &dst, &IP_NUESTRA)) return; // no es para nosotros
    var origen: [4]u8 = undefined;
    @memcpy(&origen, paquete[12..16]);
    var mac_origen: [6]u8 = undefined;
    @memcpy(&mac_origen, trama[6..12]);
    switch (paquete[9]) {
        PROTO_ICMP => procesarIcmp(paquete[20..lon_total], origen, mac_origen),
        else => {}, // TCP llega en la Fase 9b
    }
}

fn procesarIcmp(icmp: []const u8, ip_origen: [4]u8, mac_origen: [6]u8) void {
    if (icmp.len < 8) return;
    const id = tomas16(icmp, 4);
    const seq = tomas16(icmp, 6);
    if (icmp[0] == 0 and id == eco_id and seq == eco_seq) { // respuesta de nuestro eco
        eco_recibido = true;
        eco_ms = @intCast((pit.leerTics() - eco_t0) * 10); // tics de 100 Hz → ms
        return;
    }
    if (icmp[0] == 8) { // eco de otro: contestar como buena vecindad
        const c = @min(icmp.len - 8, 36); // cabe en el paquete de 64 B
        var paquete: [64]u8 = [_]u8{0} ** 64;
        const n = armarRespuestaEco(paquete[20..], id, seq, icmp[8 .. 8 + c]);
        _ = ponerIPv4(&paquete, @intCast(20 + n), PROTO_ICMP, IP_NUESTRA, ip_origen);
        _ = enviarTrama(mac_origen, ETH_IPV4, paquete[0 .. 20 + n]);
    }
}

// ---------------------------------------------------------------------------
// API para los comandos
// ---------------------------------------------------------------------------

pub fn activaRed() bool {
    return activa;
}

pub fn macNuestra() [6]u8 {
    return mac;
}

pub fn cacheArp() ?struct { ip: [4]u8, mac: [6]u8 } {
    if (!arp_valida) return null;
    return .{ .ip = arp_ip, .mac = arp_mac };
}

pub fn contadores() struct { tx: u32, rx: u32 } {
    return .{ .tx = cont_tx, .rx = cont_rx };
}

pub const EstadisticaPing = struct {
    arp_resuelta: bool = false,
    mac: [6]u8 = .{0} ** 6,
    enviados: u8 = 0,
    respondidos: u8 = 0,
    ms: [3]u32 = .{ 0, 0, 0 },
    media_ms: u32 = 0,
    fallo: ?[]const u8 = null, // "red no disponible" | "arp sin respuesta"
};

fn resolverArp(ip: [4]u8) bool {
    if (arp_valida and std.mem.eql(u8, &arp_ip, &ip)) return true;
    var intento: u8 = 0;
    while (intento < 3) : (intento += 1) {
        var carga: [28]u8 = undefined;
        _ = armarPayloadArp(&carga, 1, mac, IP_NUESTRA, .{ 0, 0, 0, 0, 0, 0 }, ip);
        if (!enviarTrama(MAC_DIFUSION, ETH_ARP, &carga)) return false;
        const t0 = pit.leerTics();
        while (pit.leerTics() - t0 < 30) { // 300 ms por intento
            procesar();
            if (arp_valida and std.mem.eql(u8, &arp_ip, &ip)) return true;
        }
    }
    return false;
}

/// `ping <ip>`: ARP (si hace falta) + 3 ecos ICMP con espera de 1 s cada uno.
pub fn ping(ip: [4]u8) EstadisticaPing {
    var r = EstadisticaPing{};
    if (!activa) {
        r.fallo = "red no disponible";
        return r;
    }
    if (!resolverArp(ip)) {
        r.fallo = "arp sin respuesta";
        return r;
    }
    r.arp_resuelta = true;
    r.mac = arp_mac;
    var total: u64 = 0;
    var seq: usize = 1;
    while (seq <= 3) : (seq += 1) {
        r.enviados += 1;
        eco_id = 0x414C; // «AL»
        eco_seq = @intCast(seq);
        eco_recibido = false;
        var paquete: [64]u8 = [_]u8{0} ** 64;
        const n = armarEco(paquete[20..], eco_id, eco_seq, "antlex");
        _ = ponerIPv4(&paquete, @intCast(20 + n), PROTO_ICMP, IP_NUESTRA, ip);
        eco_t0 = pit.leerTics();
        if (enviarTrama(arp_mac, ETH_IPV4, paquete[0 .. 20 + n])) {
            while (pit.leerTics() - eco_t0 < 100) { // 1 s por eco
                procesar();
                if (eco_recibido) break;
            }
            if (eco_recibido) {
                r.ms[seq - 1] = eco_ms;
                r.respondidos += 1;
                total += eco_ms;
            }
        }
        if (seq < 3) pit.esperaTics(5); // 50 ms entre ecos
    }
    if (r.respondidos > 0) r.media_ms = @intCast(total / r.respondidos);
    return r;
}

// ---------------------------------------------------------------------------
// autoprueba 15 (lógica pura, sin dispositivo)
// ---------------------------------------------------------------------------

pub fn autopruebaPaquetes() bool {
    // 1) checksum con vector conocido (cabecera IPv4 clásica)
    var h: [20]u8 = [_]u8{0} ** 20;
    h[0] = 0x45;
    pones16(&h, 2, 0x73);
    pones16(&h, 6, 0x4000);
    h[8] = 0x40;
    h[9] = 0x11;
    pones32(&h, 12, 0xC0A80001);
    pones32(&h, 16, 0xC0A800C7);
    if (checksum(&h) != 0xB861) return false;

    // 2) cabecera IPv4 con checksum insertado: re-verificar da 0
    var cab: [20]u8 = [_]u8{0} ** 20;
    _ = ponerIPv4(&cab, 0x54, PROTO_ICMP, IP_NUESTRA, IP_PUERTA);
    if (checksum(&cab) != 0) return false;
    if (tomas16(&cab, 2) != 0x54 or cab[9] != PROTO_ICMP) return false;

    // 3) payload ARP de petición y respuesta
    var carga: [28]u8 = [_]u8{0} ** 28;
    if (armarPayloadArp(&carga, 1, .{ 1, 2, 3, 4, 5, 6 }, IP_NUESTRA, .{ 0, 0, 0, 0, 0, 0 }, IP_PUERTA) != 28) return false;
    if (tomas16(&carga, 2) != 0x0800 or tomas16(&carga, 6) != 1) return false;
    if (carga[4] != 6 or carga[5] != 4) return false;
    if (carga[24] != IP_PUERTA[0] or carga[27] != IP_PUERTA[3]) return false;
    _ = armarPayloadArp(&carga, 2, .{ 1, 2, 3, 4, 5, 6 }, IP_NUESTRA, .{ 9, 9, 9, 9, 9, 9 }, IP_PUERTA);
    if (tomas16(&carga, 6) != 2 or carga[18] != 9) return false;

    // 4) eco ICMP con checksum válido y parseo de IP
    var eco: [32]u8 = [_]u8{0} ** 32;
    if (armarEco(&eco, 0x414C, 7, "antlex") != 14) return false;
    if (checksum(eco[0..14]) != 0) return false;
    if (eco[0] != 8 or tomas16(&eco, 4) != 0x414C or tomas16(&eco, 6) != 7) return false;
    const ip = parsearIp("10.0.2.2") orelse return false;
    if (!std.mem.eql(u8, &ip, &IP_PUERTA)) return false;
    if (parsearIp("10.0.2") != null or parsearIp("300.1.1.1") != null or parsearIp("hola") != null) return false;
    return true;
}

// ---------------------------------------------------------------------------
// pruebas en host (zig build test)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "red: checksum de Internet con vectores verificados" {
    var h: [20]u8 = [_]u8{0} ** 20;
    h[0] = 0x45;
    pones16(&h, 2, 0x73);
    pones16(&h, 6, 0x4000);
    h[8] = 0x40;
    h[9] = 0x11;
    pones32(&h, 12, 0xC0A80001);
    pones32(&h, 16, 0xC0A800C7);
    try testing.expectEqual(@as(u16, 0xB861), checksum(&h));
    // eco ICMP con carga «antlex» (vector calculado con Python)
    var eco: [14]u8 = .{ 8, 0, 0, 0, 0x41, 0x4C, 0, 1, 0, 0, 0, 0, 0, 0 };
    @memcpy(eco[8..14], "antlex");
    try testing.expectEqual(@as(u16, 0x7B5F), checksum(&eco));
}

test "red: cabecera IPv4 con checksum autovalidado" {
    var cab: [20]u8 = [_]u8{0} ** 20;
    try testing.expectEqual(@as(usize, 20), ponerIPv4(&cab, 0x54, PROTO_ICMP, IP_NUESTRA, IP_PUERTA));
    try testing.expectEqual(@as(u8, 0x45), cab[0]);
    try testing.expectEqual(@as(u16, 0x54), tomas16(&cab, 2));
    try testing.expectEqual(PROTO_ICMP, cab[9]);
    try testing.expectEqual(@as(u16, 0), checksum(&cab));
}

test "red: payload ARP de petición y respuesta" {
    var p: [28]u8 = [_]u8{0} ** 28;
    try testing.expectEqual(@as(usize, 28), armarPayloadArp(&p, 1, .{ 1, 2, 3, 4, 5, 6 }, IP_NUESTRA, .{ 0, 0, 0, 0, 0, 0 }, IP_PUERTA));
    try testing.expectEqual(@as(u16, 1), tomas16(&p, 0)); // htype Ethernet
    try testing.expectEqual(ETH_IPV4, tomas16(&p, 2)); // ptype IPv4
    try testing.expectEqual(@as(u8, 6), p[4]);
    try testing.expectEqual(@as(u8, 4), p[5]);
    try testing.expectEqual(@as(u16, 1), tomas16(&p, 6)); // petición
    try testing.expectEqual(IP_PUERTA, p[24..28].*);

    try testing.expectEqual(@as(usize, 28), armarPayloadArp(&p, 2, .{ 1, 2, 3, 4, 5, 6 }, IP_NUESTRA, .{ 9, 9, 9, 9, 9, 9 }, IP_PUERTA));
    try testing.expectEqual(@as(u16, 2), tomas16(&p, 6)); // respuesta
    try testing.expectEqual(@as(u8, 9), p[18]); // mac destino en tha
}

test "red: eco y respuesta ICMP" {
    var eco: [32]u8 = [_]u8{0} ** 32;
    try testing.expectEqual(@as(usize, 14), armarEco(&eco, 0x414C, 7, "antlex"));
    try testing.expectEqual(@as(u8, 8), eco[0]);
    try testing.expectEqual(@as(u16, 0x414C), tomas16(&eco, 4));
    try testing.expectEqual(@as(u16, 7), tomas16(&eco, 6));
    try testing.expectEqual(@as(u16, 0), checksum(eco[0..14]));

    var resp: [32]u8 = [_]u8{0} ** 32;
    try testing.expectEqual(@as(usize, 14), armarRespuestaEco(&resp, 0x414C, 7, "antlex"));
    try testing.expectEqual(@as(u8, 0), resp[0]);
    try testing.expectEqual(@as(u16, 0), checksum(resp[0..14]));
}

test "red: parseo y formato de direcciones" {
    try testing.expectEqual(IP_PUERTA, parsearIp("10.0.2.2").?);
    try testing.expectEqual(@as(?[4]u8, null), parsearIp("10.0.2"));
    try testing.expectEqual(@as(?[4]u8, null), parsearIp("256.1.1.1"));
    try testing.expectEqual(@as(?[4]u8, null), parsearIp("hola"));
    try testing.expectEqual(@as(?[4]u8, null), parsearIp(""));

    var bi: [16]u8 = undefined;
    try testing.expectEqualStrings("10.0.2.15", formatearIp(IP_NUESTRA, &bi));
    var bm: [24]u8 = undefined;
    try testing.expectEqualStrings("52:54:00:12:34:56", formatearMac(.{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }, &bm));
}

test "red: autoprueba de paquetes completa" {
    try testing.expect(autopruebaPaquetes());
}
