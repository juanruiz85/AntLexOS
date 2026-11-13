//! AntLex OS — escritorio con ventanas (Fase 5).
//!
//! Estructura de la pantalla:
//!   ┌────────────────────────┬──────────────────┐
//!   │  TERMINAL (60%)        │  ANTLEX CHAT 40% │  barra de título de panel (18 px)
//!   │  consola del intérprete│  consola del chat│
//!   │                        │  línea de entrada│
//!   ├────────────────────────┴──────────────────┤
//!   │ ∞ INICIO │ TERMINAL CHAT │ Explorador…    │ barra de tareas (28 px)
//!   └───────────────────────────────────────────┘
//!   + ventanas flotantes arrastrables (Explorador, Editor, Acerca de)
//!     con foco, cierre [X] y orden Z (la enfocada se dibuja última).
//!
//! Cursor del ratón en XOR (auto-inverso al mover); el teclado se enruta al
//! elemento con foco (panel terminal, chat o ventana).

const std = @import("std");
const pantalla = @import("pantalla.zig");
const consola = @import("consola.zig");
const fuente = @import("fuente.zig");
const serial = @import("serial.zig");
const teclado = @import("teclado.zig");
const raton = @import("raton.zig");
const pit = @import("pit.zig");
const reloj = @import("reloj.zig");
const mem = @import("mem.zig");
const alfs = @import("alfs.zig");
const fmt = @import("alfs_formato.zig");
const interprete = @import("interprete.zig");
const antlex = @import("antlex.zig");
const apps = @import("apps.zig");
const version = @import("version.zig");
const x86 = @import("x86.zig");

// ---------------------------------------------------------------------------
// geometría y colores
// ---------------------------------------------------------------------------

const ALT_BARRA: u32 = 28;
const ALT_TITULO: u32 = 18; // paneles
const ALT_TITULO_V: u32 = 16; // ventanas
const FUENTE_ALTO: u32 = 16;
const FUENTE_ANCHO: u32 = 8;

const C_FONDO = pantalla.rgb(0x12, 0x18, 0x22); // escritorio
const C_PANEL = pantalla.rgb(0x0A, 0x0E, 0x16); // interior de paneles
const C_PANEL_TIT = pantalla.rgb(0x24, 0x30, 0x3F); // título de panel sin foco
const C_PANEL_TIT_FOCO = pantalla.rgb(0x2C, 0x63, 0xB6); // título con foco
const C_BARRA = pantalla.rgb(0x1B, 0x23, 0x30);
const C_VENTANA = pantalla.rgb(0x10, 0x16, 0x20);
const C_BORDE = pantalla.rgb(0x33, 0x42, 0x55);
const C_TEXTO = pantalla.rgb(0xD8, 0xE4, 0xEE);
const C_TINTA_SUAVE = pantalla.rgb(0x9A, 0xAA, 0xBC);
const C_ACENTO = pantalla.rgb(0x5B, 0x9B, 0xF0);
const C_ALERTA = pantalla.rgb(0xF2, 0xB8, 0x66);

pub const TipoApp = enum(u2) { explorador = 0, editor = 1, acerca = 2 };

const NOMBRE_APP = [3][]const u8{ "Explorador", "Editor", "Acerca de" };

/// Botones de la barra de tareas (coordenadas replicadas por el arnés).
const AN_BOTON: u32 = 24; // alto
const BOTONES = [_]struct { x: u32, an: u32, texto: []const u8 }{
    .{ .x = 2, .an = 56, .texto = "INICIO" },
    .{ .x = 62, .an = 84, .texto = "TERMINAL" },
    .{ .x = 150, .an = 52, .texto = "CHAT" },
    .{ .x = 208, .an = 96, .texto = "Explorador" },
    .{ .x = 308, .an = 60, .texto = "Editor" },
    .{ .x = 372, .an = 60, .texto = "Acerca" },
};

// ---------------------------------------------------------------------------
// estado global del escritorio
// ---------------------------------------------------------------------------

const Foco = enum { terminal, chat, ventana };

const Ventana = struct {
    abierta: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    an: u32 = 0,
    al: u32 = 0,
    // explorador
    expl: apps.Explorador = .{},
    expl_dir: u16 = fmt.RAIZ,
    // editor
    edit: apps.Editor = .{},
    edit_idx: ?u16 = null,
};

var escritorio_activo = false;
var foco: Foco = .terminal;
var foco_ventana: TipoApp = .explorador;
// se inicializan en init() (así el array entero vive en .bss, no en .data)
var ventanas: [3]Ventana = undefined;
var menu_abierto = false;

// arrastre de ventana
const Arrastre = struct { tipo: TipoApp, dx: i32, dy: i32 };
var arrastre: ?Arrastre = null;

// doble clic (explorador)
var ultimo_clic_tics: u64 = 0;
var ultimo_clic_fila: i32 = -1;
var ultimo_clic_app: ?TipoApp = null;

// layout calculado en init()
var ancho: u32 = 0;
var alto: u32 = 0;
var term_x: u32 = 0;
var term_y: u32 = 0;
var term_an: u32 = 0;
var term_al: u32 = 0;
var chat_x: u32 = 0;
var chat_an: u32 = 0;
var barra_y: u32 = 0;

// chat de AntLex (consola propia + línea de entrada)
var chat = consola.Consola{}; // sin cursor de texto propio (bss)
var chat_linea: [96]u8 = undefined;
var chat_len: usize = 0;

// cursor del ratón
var cur_x: u32 = 0;
var cur_y: u32 = 0;
var cur_dibujado = false;

const CURSOR: [16]u16 = [_]u16{
    0b10000000000, 0b11000000000, 0b11100000000, 0b11110000000,
    0b11111000000, 0b11111100000, 0b11111110000, 0b11111111000,
    0b11111111100, 0b11111111110, 0b11111110000, 0b11110010000,
    0b11100001000, 0b11000000100, 0b10000000010, 0b00000000010,
};

var raton_ok = false;
var ult_seg: u64 = 0;

// ---------------------------------------------------------------------------
// helpers de dibujo
// ---------------------------------------------------------------------------

fn texto(x: u32, y: u32, s: []const u8, tinta: u32) void {
    for (s, 0..) |c, i| {
        fuente.dibujar(x + @as(u32, @intCast(i)) * FUENTE_ANCHO, y, c, tinta, null, 1);
    }
}

fn textoLim(x: u32, y: u32, s: []const u8, tinta: u32, max_px: u32) void {
    const n = @min(s.len, max_px / FUENTE_ANCHO);
    texto(x, y, s[0..n], tinta);
}

fn xorPixel(x: u32, y: u32) void {
    if (x >= pantalla.anchoPix() or y >= pantalla.altoPix()) return;
    const fb: [*]volatile u32 = @ptrFromInt(pantalla.direccion());
    const paso = pantalla.pasoBytes() / 4;
    (fb + @as(usize, y) * paso + x)[0] ^= 0x00FFFFFF;
}

fn borrarCursor() void {
    if (!cur_dibujado) return;
    var f: u32 = 0;
    while (f < CURSOR.len) : (f += 1) {
        var b: u16 = 0x400; // bit 10 = columna 0
        var c: u32 = 0;
        while (c < 11) : (c += 1) {
            if (CURSOR[f] & b != 0) xorPixel(cur_x + c, cur_y + f);
            b >>= 1;
        }
    }
    cur_dibujado = false;
}

fn dibujarCursor() void {
    if (cur_dibujado) return;
    var f: u32 = 0;
    while (f < CURSOR.len) : (f += 1) {
        var b: u16 = 0x400;
        var c: u32 = 0;
        while (c < 11) : (c += 1) {
            if (CURSOR[f] & b != 0) xorPixel(cur_x + c, cur_y + f);
            b >>= 1;
        }
    }
    cur_dibujado = true;
}

fn enRect(x: i32, y: i32, rx: i32, ry: i32, an: u32, al: u32) bool {
    return x >= rx and x < rx + @as(i32, @intCast(an)) and
        y >= ry and y < ry + @as(i32, @intCast(al));
}

// ---------------------------------------------------------------------------
// inicialización
// ---------------------------------------------------------------------------

pub fn init() void {
    ancho = pantalla.anchoPix();
    alto = pantalla.altoPix();
    barra_y = alto - ALT_BARRA;

    term_an = ancho * 3 / 5;
    term_al = barra_y;
    term_x = 0;
    term_y = 0;
    chat_x = term_an + 1;
    chat_an = ancho - chat_x;
    const chat_al = barra_y;

    // ratón PS/2 (IRQ12); sin ratón el escritorio funciona solo con teclado
    raton_ok = raton.init();
    if (raton_ok) {
        serial.puts("gui: raton PS/2 activo (IRQ12)\n");
    } else {
        serial.puts("gui: sin raton (");
        serial.puts(raton.fallo_paso);
        serial.puts("); escritorio solo con teclado\n");
    }
    const pos = raton.posicion();
    cur_x = pos.x;
    cur_y = pos.y;

    // panel TERMINAL: la consola por defecto se recoloca aquí
    consola.reubicar(term_x + 2, term_y + ALT_TITULO + 2, term_an - 4, term_al - ALT_TITULO - 4);
    consola.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = C_PANEL });
    consola.limpiar();

    // panel CHAT: consola propia + línea de entrada en la franja inferior
    chat.region(chat_x + 2, ALT_TITULO + 2, chat_an - 4, chat_al - ALT_TITULO - 4 - 24);
    chat.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = C_PANEL });
    chat.limpiar();
    chat.fijarEstilo(.{ .tinta = consola.COLOR_TITULO, .fondo = C_PANEL });
    chat.puts("AntLex, a tu servicio. Escribe tu pregunta y\npulsa INTRO (ej. quien eres).\n");
    chat.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = C_PANEL });

    // ventanas (geometría inicial, en cascada)
    ventanas[@intFromEnum(TipoApp.explorador)] = .{ .x = 40, .y = 40, .an = 360, .al = 330 };
    ventanas[@intFromEnum(TipoApp.editor)] = .{ .x = 150, .y = 90, .an = 480, .al = 330 };
    ventanas[@intFromEnum(TipoApp.acerca)] = .{ .x = 240, .y = 130, .an = 380, .al = 300 };

    dibujarTodo();
    dibujarCursor();
    escritorio_activo = true;
}

pub fn enEscritorio() bool {
    return escritorio_activo;
}

pub fn ratonDisponible() bool {
    return raton_ok;
}

/// Escribe en la consola del chat (lo usa antlex.salida en modo escritorio).
pub fn chatEscribir(txt: []const u8) void {
    chat.puts(txt);
}

// ---------------------------------------------------------------------------
// dibujo del escritorio
// ---------------------------------------------------------------------------

fn dibujarPanel(x: u32, an: u32, titulo: []const u8, enfocado: bool) void {
    const tinta_tit = if (enfocado) C_TEXTO else C_TINTA_SUAVE;
    const color_tit = if (enfocado) C_PANEL_TIT_FOCO else C_PANEL_TIT;
    pantalla.rect(x, 0, an, barra_y, C_FONDO); // marco de 2px alrededor
    pantalla.rect(x, 0, an, ALT_TITULO, color_tit);
    texto(x + 6, 2, titulo, tinta_tit);
}

pub fn dibujarTodo() void {
    borrarCursor();
    pantalla.rect(0, 0, ancho, alto, C_FONDO);
    dibujarPanel(term_x, term_an, "TERMINAL", foco == .terminal);
    consola.instancia().redibujar();
    dibujarPanel(chat_x, chat_an, "ANTLEX — CHAT", foco == .chat);
    chat.redibujar();
    dibujarChatEntrada();

    // ventanas: la enfocada la última (encima de todo)
    var t: u2 = 0;
    while (t < 3) : (t += 1) {
        if (ventanas[t].abierta and (foco != .ventana or @as(TipoApp, @enumFromInt(t)) != foco_ventana)) {
            dibujarVentana(@enumFromInt(t));
        }
    }
    if (foco == .ventana and ventanas[@intFromEnum(foco_ventana)].abierta) {
        dibujarVentana(foco_ventana);
    }
    if (menu_abierto) dibujarMenu();
    dibujarBarra();
    dibujarCursor();
}

fn dibujarChatEntrada() void {
    const y = barra_y - 22;
    pantalla.rect(chat_x + 2, y, chat_an - 4, 20, C_PANEL);
    pantalla.rect(chat_x + 2, y, chat_an - 4, 1, C_BORDE);
    const pref = "Tú > ";
    texto(chat_x + 8, y + 2, pref, C_TINTA_SUAVE);
    const x_texto = chat_x + 8 + @as(u32, pref.len) * FUENTE_ANCHO;
    texto(x_texto, y + 2, chat_linea[0..chat_len], C_TEXTO);
    // cursor de bloque al final de la línea
    pantalla.rect(x_texto + @as(u32, @intCast(chat_len)) * FUENTE_ANCHO, y + 2, FUENTE_ANCHO, FUENTE_ALTO - 3, C_ACENTO);
}

fn dibujarBarra() void {
    pantalla.rect(0, barra_y, ancho, ALT_BARRA, C_BARRA);
    pantalla.rect(0, barra_y, ancho, 1, C_BORDE);
    for (BOTONES, 0..) |b, i| {
        const y = barra_y + 2;
        const activo = switch (i) {
            1 => foco == .terminal,
            2 => foco == .chat,
            3 => ventanas[@intFromEnum(TipoApp.explorador)].abierta,
            4 => ventanas[@intFromEnum(TipoApp.editor)].abierta,
            5 => ventanas[@intFromEnum(TipoApp.acerca)].abierta,
            else => menu_abierto,
        };
        const fondo = if (activo) C_PANEL_TIT_FOCO else C_PANEL_TIT;
        pantalla.rectBorde(b.x, y, b.an, AN_BOTON - 4, fondo, C_BORDE);
        texto(b.x + 6, y + 4, b.texto, C_TEXTO);
    }
    dibujarBarraInfo();
}

fn dibujarBarraInfo() void {
    const m = mem.estadisticas();
    var buf: [64]u8 = undefined;
    const info = std.fmt.bufPrint(&buf, "{d} MiB libres", .{m.libre / (1024 * 1024)}) catch return;
    const f = reloj.leer();
    var bufh: [16]u8 = undefined;
    const hhmm = std.fmt.bufPrint(&bufh, "{d:0>2}:{d:0>2}", .{ f.hora, f.min }) catch return;
    const an_info = @as(u32, @intCast(info.len + hhmm.len + 5)) * FUENTE_ANCHO;
    const x0 = ancho - an_info - 8;
    pantalla.rect(x0, barra_y + 1, an_info + 8, ALT_BARRA - 2, C_BARRA);
    texto(x0, barra_y + 7, info, C_TINTA_SUAVE);
    texto(x0 + @as(u32, @intCast(info.len + 3)) * FUENTE_ANCHO, barra_y + 7, hhmm, C_TEXTO);
}

const MENU_ITEMS = [5][]const u8{
    "Explorador de archivos",
    "Editor de texto",
    "Acerca de AntLex OS",
    "",
    "Apagar el sistema",
};
const MENU_ITEM_AL: u32 = 20;

fn menuRect() struct { x: u32, y: u32, an: u32, al: u32 } {
    const al: u32 = @intCast(MENU_ITEMS.len * MENU_ITEM_AL + 8);
    return .{ .x = 2, .y = barra_y - al - 2, .an = 200, .al = al };
}

fn dibujarMenu() void {
    const r = menuRect();
    pantalla.rectBorde(r.x, r.y, r.an, r.al, C_VENTANA, C_ACENTO);
    for (MENU_ITEMS, 0..) |it, i| {
        const y = r.y + 4 + @as(u32, @intCast(i)) * MENU_ITEM_AL;
        if (it.len == 0) {
            pantalla.rect(r.x + 6, y + 10, r.an - 12, 1, C_BORDE);
        } else {
            texto(r.x + 10, y + 3, it, if (i == 4) C_ALERTA else C_TEXTO);
        }
    }
}

// ---------------------------------------------------------------------------
// ventanas y aplicaciones
// ---------------------------------------------------------------------------

fn tituloVentana(t: TipoApp, buf: []u8) []const u8 {
    const v = &ventanas[@intFromEnum(t)];
    return switch (t) {
        .explorador => std.fmt.bufPrint(buf, "Explorador de archivos", .{}) catch "Explorador",
        .editor => blk: {
            const base = if (v.edit.nombre_len > 0) v.edit.nombreStr() else "(sin archivo)";
            break :blk std.fmt.bufPrint(buf, "Editor — {s}{s}", .{ base, if (v.edit.modificado) " *" else "" }) catch "Editor";
        },
        .acerca => std.fmt.bufPrint(buf, "Acerca de AntLex OS", .{}) catch "Acerca de",
    };
}

fn dibujarVentana(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    const enfocada = foco == .ventana and foco_ventana == t;
    const color_tit = if (enfocada) C_PANEL_TIT_FOCO else C_PANEL_TIT;
    const x: u32 = @intCast(@max(v.x, 0));
    const y: u32 = @intCast(@max(v.y, 0));

    pantalla.rectBorde(x, y, v.an, v.al, C_VENTANA, if (enfocada) C_ACENTO else C_BORDE);
    pantalla.rect(x, y, v.an, ALT_TITULO_V, color_tit);
    var buf: [64]u8 = undefined;
    textoLim(x + 6, y + 1, tituloVentana(t, &buf), C_TEXTO, v.an - 40);
    // botón de cierre [X]
    const bx = x + v.an - 18;
    pantalla.rect(bx, y + 2, 14, 12, if (enfocada) pantalla.rgb(0x8F, 0x2D, 0x2D) else C_PANEL_TIT);
    texto(bx + 3, y + 3, "X", C_TEXTO);

    switch (t) {
        .explorador => dibujarExplorador(v, x, y),
        .editor => dibujarEditor(v, x, y),
        .acerca => dibujarAcerca(x, y),
    }
}

fn dibujarExplorador(v: *Ventana, x: u32, y: u32) void {
    // cabecera con la ruta actual
    var buf: [96]u8 = undefined;
    var ruta: []const u8 = "/";
    if (alfs.montado()) {
        const vol = alfs.actual().?;
        const n = vol.rutaAbsoluta(v.expl_dir, &buf) catch 0;
        ruta = buf[0..n];
    }
    textoLim(x + 6, y + ALT_TITULO_V + 2, ruta, C_TINTA_SUAVE, v.an - 12);
    pantalla.rect(x + 2, y + ALT_TITULO_V + 18, v.an - 4, 1, C_BORDE);

    // filas visibles
    const filas_vis: u32 = if (v.al > ALT_TITULO_V + 40 + 16) (v.al - ALT_TITULO_V - 40) / FUENTE_ALTO else 1;
    var i: u32 = 0;
    while (i < filas_vis) : (i += 1) {
        const idx = v.expl.scroll + i;
        if (idx >= v.expl.n) break;
        const ent = &v.expl.entradas[idx];
        const fy = y + ALT_TITULO_V + 24 + i * FUENTE_ALTO;
        const seleccionada = v.expl.seleccion == @as(i16, @intCast(idx));
        if (seleccionada) {
            pantalla.rect(x + 4, fy, v.an - 8, FUENTE_ALTO, C_PANEL_TIT_FOCO);
        }
        const icono: []const u8 = if (ent.tipo == fmt.TIPO_DIRECTORIO) "> " else "· ";
        const tinta = if (seleccionada) C_TEXTO else if (ent.tipo == fmt.TIPO_DIRECTORIO) C_ACENTO else C_TEXTO;
        texto(x + 8, fy, icono, tinta);
        textoLim(x + 8 + 16, fy, ent.nombreStr(), tinta, v.an - 40);
    }
    // pie de ayuda
    texto(x + 6, y + v.al - 14, "INTRO abrir · ↑↓ elegir · RETROCESO subir", C_TINTA_SUAVE);
}

fn dibujarEditor(v: *Ventana, x: u32, y: u32) void {
    const filas_vis: u32 = if (v.al > ALT_TITULO_V + 34) (v.al - ALT_TITULO_V - 34) / FUENTE_ALTO else 1;
    var i: u32 = 0;
    while (i < filas_vis) : (i += 1) {
        const fila = v.edit.fila - @min(v.edit.fila, filas_vis - 1) + i; // ventana simple anclada al cursor
        if (fila >= v.edit.n) break;
        const l = v.edit.lens[fila];
        const fy = y + ALT_TITULO_V + 4 + i * FUENTE_ALTO;
        textoLim(x + 6, fy, v.edit.lineas[fila][0..l], C_TEXTO, v.an - 12);
        // cursor: celda invertida (o bloque tras el final de línea)
        if (fila == v.edit.fila) {
            const cx = x + 6 + @as(u32, v.edit.col) * FUENTE_ANCHO;
            if (v.edit.col < l) {
                const c = v.edit.lineas[fila][v.edit.col];
                fuente.dibujar(cx, fy, c, C_VENTANA, C_ACENTO, 1);
            } else {
                pantalla.rect(cx, fy, FUENTE_ANCHO, FUENTE_ALTO - 3, C_ACENTO);
            }
        }
    }
    const aviso: []const u8 = v.edit.aviso orelse "F2 guardar · INTRO línea nueva · ESC cerrar";
    texto(x + 6, y + v.al - 14, aviso, if (v.edit.aviso != null) C_ALERTA else C_TINTA_SUAVE);
}

fn dibujarAcerca(x: u32, y: u32) void {
    const lineas = [_][]const u8{
        "AntLex OS v" ++ version.VERSION,
        version.ESLOGAN,
        "",
        "Bootloader propio BIOS + UEFI, kernel Zig",
        "x86_64, consola gráfica, ALFS, IA embebida.",
        "",
        "Licencia GPL-3.0 · juanruiz85",
        "github.com/juanruiz85/AntLexOS",
        "",
        "Escritorio (Fase 5): ratón PS/2, ventanas,",
        "explorador, editor y chat de AntLex.",
    };
    for (lineas, 0..) |l, i| {
        textoLim(x + 12, y + ALT_TITULO_V + 8 + @as(u32, @intCast(i)) * FUENTE_ALTO, l, if (i == 0) C_ACENTO else C_TEXTO, 340);
    }
}

// ---------------------------------------------------------------------------
// pegamento con ALFS
// ---------------------------------------------------------------------------

const CtxExpl = struct { e: *apps.Explorador };

fn cbHijos(ctx: *CtxExpl, idx: u16, ent: *const fmt.Entrada) void {
    apps.explAnadir(ctx.e, idx, ent.tipo, ent.nombre[0..ent.nombre_len]);
}

fn explListar(v: *Ventana) void {
    v.expl = .{};
    if (alfs.montado()) {
        const vol = alfs.actual().?;
        var ctx = CtxExpl{ .e = &v.expl };
        vol.hijosDe(v.expl_dir, &ctx, cbHijos);
    }
}

fn abrirVentana(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.abierta) {
        v.abierta = true;
        serial.puts("gui: ventana abierta ");
        serial.puts(NOMBRE_APP[@intFromEnum(t)]);
        serial.puts("\n");
    }
    if (t == .explorador) explListar(v);
    enfocarVentana(t);
}

fn cerrarVentana(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.abierta) return;
    v.abierta = false;
    serial.puts("gui: ventana cerrada ");
    serial.puts(NOMBRE_APP[@intFromEnum(t)]);
    serial.puts("\n");
    if (arrastre != null and arrastre.?.tipo == t) arrastre = null;
    if (foco == .ventana and foco_ventana == t) enfocar(.terminal);
    dibujarTodo();
}

fn enfocarVentana(t: TipoApp) void {
    foco = .ventana;
    foco_ventana = t;
    serial.puts("gui: foco ventana ");
    serial.puts(NOMBRE_APP[@intFromEnum(t)]);
    serial.puts("\n");
    dibujarTodo();
}

fn enfocar(f: Foco) void {
    if (foco == f and f != .ventana) return;
    foco = f;
    serial.puts(if (f == .terminal) "gui: foco terminal\n" else "gui: foco chat\n");
    dibujarTodo();
}

/// Abre el archivo `idx` en el editor (desde el explorador).
fn editorAbrir(idx: u16, nombre: []const u8) void {
    const v = &ventanas[@intFromEnum(TipoApp.editor)];
    if (!alfs.montado()) {
        serial.puts("gui: editor sin ALFS montado\n");
        return;
    }
    const vol = alfs.actual().?;
    const tam = vol.tamDe(idx) catch return;
    if (tam > 8 * 1024) {
        serial.puts("gui: editor: archivo demasiado grande\n");
        return;
    }
    const p = mem.alloc(tam + 1, 16) catch return;
    const buf: []u8 = @as([*]u8, @ptrFromInt(p))[0 .. tam + 1];
    const n = vol.leer(idx, buf) catch return;
    apps.editorCargar(&v.edit, buf[0..n]);
    const l = @min(nombre.len, apps.EDITOR_MAX_NOMBRE);
    @memcpy(v.edit.nombre[0..l], nombre[0..l]);
    v.edit.nombre_len = @intCast(l);
    v.edit_idx = idx;
    serial.puts("gui: editor abre ");
    serial.puts(v.edit.nombreStr());
    serial.puts("\n");
    abrirVentana(.editor);
}

/// Guarda el editor en su archivo ALFS.
fn editorGuardar() void {
    const v = &ventanas[@intFromEnum(TipoApp.editor)];
    const idx = v.edit_idx orelse return;
    if (!alfs.montado()) return;
    const vol = alfs.actual().?;
    const p = mem.alloc(10 * 1024, 16) catch return;
    const buf: []u8 = @as([*]u8, @ptrFromInt(p))[0 .. 10 * 1024];
    const n = apps.editorSerializar(&v.edit, buf);
    vol.escribir(idx, buf[0..n]) catch {
        serial.puts("gui: editor: error al guardar\n");
        return;
    };
    alfs.marcar();
    v.edit.modificado = false;
    serial.puts("gui: editor guarda ");
    serial.puts(v.edit.nombreStr());
    serial.puts("\n");
    dibujarTodo();
}

fn explAbrir(v: *Ventana, f: *const apps.FilaExpl) void {
    // copiar los datos ANTES de tocar la lista: en el caso de directorio
    // explListar reinicia v.expl (donde apunta f) y el nombre se perdería
    var nbuf: [apps.EXPLORADOR_MAX_NOMBRE]u8 = undefined;
    const nl: usize = @min(f.nombre_len, apps.EXPLORADOR_MAX_NOMBRE);
    @memcpy(nbuf[0..nl], f.nombre[0..nl]);
    const nombre = nbuf[0..nl];
    const idx = f.idx;
    if (f.tipo == fmt.TIPO_DIRECTORIO) {
        v.expl_dir = idx;
        explListar(v);
        serial.puts("gui: explorador entra ");
        serial.puts(nombre);
        serial.puts("\n");
        dibujarTodo();
    } else {
        editorAbrir(idx, nombre);
    }
}

// ---------------------------------------------------------------------------
// procesado de eventos
// ---------------------------------------------------------------------------

fn procesarTecla(c: u8) void {
    switch (foco) {
        .terminal => interprete.tecla(c),
        .chat => chatTecla(c),
        .ventana => {
            if (!ventanas[@intFromEnum(foco_ventana)].abierta) {
                enfocar(.terminal);
                return;
            }
            switch (foco_ventana) {
                .editor => {
                    if (c == teclado.F2) {
                        editorGuardar();
                        return;
                    }
                    if (c == teclado.ESC) {
                        cerrarVentana(.editor);
                        return;
                    }
                    if (apps.editorTecla(&ventanas[@intFromEnum(TipoApp.editor)].edit, c)) {
                        dibujarTodo();
                    }
                },
                .explorador => {
                    const v = &ventanas[@intFromEnum(TipoApp.explorador)];
                    if (c == teclado.ESC) {
                        cerrarVentana(.explorador);
                        return;
                    }
                    switch (c) {
                        teclado.FLECHA_ARRIBA => {
                            apps.explMover(&v.expl, -1);
                            explAjustarScroll(v);
                            dibujarTodo();
                        },
                        teclado.FLECHA_ABAJO => {
                            apps.explMover(&v.expl, 1);
                            explAjustarScroll(v);
                            dibujarTodo();
                        },
                        '\n' => {
                            if (v.expl.seleccionada()) |f| explAbrir(v, f);
                        },
                        8 => { // subir de directorio
                            if (v.expl_dir != fmt.RAIZ) {
                                if (alfs.montado()) {
                                    const vol = alfs.actual().?;
                                    if (vol.entrada(v.expl_dir)) |e| {
                                        if (e.padre != v.expl_dir) v.expl_dir = e.padre;
                                    }
                                }
                                explListar(v);
                                serial.puts("gui: explorador sube\n");
                                dibujarTodo();
                            }
                        },
                        else => {},
                    }
                },
                .acerca => {
                    if (c == teclado.ESC) cerrarVentana(.acerca);
                },
            }
        },
    }
}

fn explAjustarScroll(v: *Ventana) void {
    const filas_vis: i32 = @intCast(if (v.al > ALT_TITULO_V + 40 + 16) (v.al - ALT_TITULO_V - 40) / FUENTE_ALTO else 1);
    if (v.expl.seleccion < 0) return;
    const sel: i32 = v.expl.seleccion;
    if (sel < @as(i32, @intCast(v.expl.scroll))) {
        v.expl.scroll = @intCast(sel);
    } else if (sel >= @as(i32, @intCast(v.expl.scroll)) + filas_vis) {
        v.expl.scroll = @intCast(sel - filas_vis + 1);
    }
}

fn chatTecla(c: u8) void {
    switch (c) {
        '\n' => {
            if (chat_len == 0) return;
            serial.puts("chat> ");
            serial.puts(chat_linea[0..chat_len]);
            serial.puts("\n");
            chat.fijarEstilo(.{ .tinta = consola.COLOR_TITULO, .fondo = C_PANEL });
            chat.puts("Tú > ");
            chat.puts(chat_linea[0..chat_len]);
            chat.putc('\n');
            chat.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = C_PANEL });
            const pregunta = chat_linea[0..chat_len];
            chat_len = 0;
            dibujarChatEntrada();
            antlex.comando(pregunta); // la respuesta llega por chatEscribir
            dibujarChatEntrada();
        },
        8 => {
            if (chat_len > 0) chat_len -= 1;
            dibujarChatEntrada();
        },
        teclado.CTRL_C => {
            chat_len = 0;
            dibujarChatEntrada();
        },
        teclado.FLECHA_ARRIBA, teclado.FLECHA_ABAJO, teclado.FLECHA_IZQ, teclado.FLECHA_DER, teclado.SUPRIMIR, teclado.INICIO, teclado.FIN, teclado.F2, teclado.ESC, '\t' => {},
        else => {
            if (chat_len < chat_linea.len and c >= 32 and c != 127 and (c < 0x80 or c >= 0xA0)) {
                chat_linea[chat_len] = c;
                chat_len += 1;
                dibujarChatEntrada();
            }
        },
    }
}

fn procesarRaton(ev: raton.Evento) void {
    if (ev.tipo == .mover) {
        // arrastre de ventana
        if (arrastre) |a| {
            const v = &ventanas[@intFromEnum(a.tipo)];
            const nx = @as(i32, @intCast(ev.x)) - a.dx;
            const ny = @as(i32, @intCast(ev.y)) - a.dy;
            v.x = std.math.clamp(nx, -@as(i32, @intCast(v.an)) + 60, @as(i32, @intCast(ancho)) - 8);
            v.y = std.math.clamp(ny, 0, @as(i32, @intCast(barra_y)) - @as(i32, ALT_TITULO_V));
            dibujarTodo();
        }
        borrarCursor();
        cur_x = ev.x;
        cur_y = ev.y;
        dibujarCursor();
        return;
    }
    if (ev.tipo == .pulsar and ev.boton == .izq) {
        procesarClic(@intCast(ev.x), @intCast(ev.y));
    }
    if (ev.tipo == .soltar and ev.boton == .izq) {
        if (arrastre) |a| {
            arrastre = null;
            serial.puts("gui: ventana movida ");
            serial.puts(NOMBRE_APP[@intFromEnum(a.tipo)]);
            serial.puts("\n");
            dibujarTodo();
        }
    }
}

fn procesarClic(x: i32, y: i32) void {
    var buf: [48]u8 = undefined;
    serial.puts(std.fmt.bufPrint(&buf, "gui: clic {d},{d}\n", .{ x, y }) catch "gui: clic\n");
    // 1) menú abierto: ítem o fuera
    if (menu_abierto) {
        const r = menuRect();
        if (enRect(x, y, @intCast(r.x), @intCast(r.y), r.an, r.al)) {
            const dy = y - @as(i32, @intCast(r.y)) - 4;
            // el margen de 4 px y el separador no eligen nada: solo los
            // ítems reales (0..4) ejecutan su acción
            if (dy >= 0) {
                const fila: i32 = @divTrunc(dy, @as(i32, MENU_ITEM_AL));
                ejecutarMenuItem(fila);
            }
        }
        menu_abierto = false;
        serial.puts("gui: menu cerrado\n");
        dibujarTodo();
        return;
    }

    // 2) barra de tareas
    if (y >= @as(i32, @intCast(barra_y))) {
        const by = barra_y + 2;
        for (BOTONES, 0..) |b, i| {
            if (enRect(x, y, @intCast(b.x), @intCast(by), b.an, AN_BOTON - 4)) {
                switch (i) {
                    0 => {
                        menu_abierto = true;
                        serial.puts("gui: menu abierto\n");
                    },
                    1 => enfocar(.terminal),
                    2 => enfocar(.chat),
                    3 => abrirVentana(.explorador),
                    4 => abrirVentana(.editor),
                    5 => abrirVentana(.acerca),
                    else => {},
                }
                dibujarTodo();
                return;
            }
        }
        return; // zona de estado: nada
    }

    // 3) ventanas (la enfocada primero: orden Z)
    var orden: [3]TipoApp = .{ .acerca, .editor, .explorador };
    if (foco == .ventana) {
        const fv = foco_ventana;
        var k: usize = 0;
        for (orden) |t| {
            if (t == fv) continue;
            orden[k] = t;
            k += 1;
        }
        orden[2] = fv;
    }
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const t = orden[2 - i]; // desde la de arriba
        const v = &ventanas[@intFromEnum(t)];
        if (!v.abierta) continue;
        if (!enRect(x, y, v.x, v.y, v.an, v.al)) continue;
        clicVentana(t, v, x, y);
        return;
    }

    // 4) paneles
    if (x < @as(i32, @intCast(chat_x))) {
        enfocar(.terminal);
    } else {
        enfocar(.chat);
    }
}

fn clicVentana(t: TipoApp, v: *Ventana, x: i32, y: i32) void {
    const vx = v.x;
    const vy = v.y;
    const an: i32 = @intCast(v.an);

    // botón de cierre
    if (enRect(x, y, vx + an - 18, vy + 2, 14, 12)) {
        cerrarVentana(t);
        return;
    }
    // barra de título: arrastrar
    if (y < vy + @as(i32, ALT_TITULO_V)) {
        arrastre = .{ .tipo = t, .dx = x - vx, .dy = y - vy };
        if (foco != .ventana or foco_ventana != t) enfocarVentana(t);
        return;
    }
    // cuerpo: foco + acción por aplicación
    switch (t) {
        .explorador => {
            const y_lista = vy + @as(i32, @intCast(ALT_TITULO_V + 24));
            if (y >= y_lista and v.expl.n > 0) {
                const fila: i32 = @divTrunc(y - y_lista, @as(i32, FUENTE_ALTO)) + @as(i32, @intCast(v.expl.scroll));
                if (fila >= 0 and fila < @as(i32, @intCast(v.expl.n))) {
                    // doble clic abre; clic selecciona
                    const ahora = pit.leerTics();
                    const doble = ultimo_clic_app == t and ultimo_clic_fila == fila and
                        ahora -| ultimo_clic_tics < 40;
                    v.expl.seleccion = @intCast(fila);
                    ultimo_clic_tics = ahora;
                    ultimo_clic_fila = fila;
                    ultimo_clic_app = t;
                    if (doble) {
                        explAbrir(v, &v.expl.entradas[@intCast(fila)]);
                        return;
                    }
                }
            }
        },
        else => {},
    }
    if (foco != .ventana or foco_ventana != t) enfocarVentana(t) else dibujarTodo();
}

fn ejecutarMenuItem(fila: i32) void {
    switch (fila) {
        0 => abrirVentana(.explorador),
        1 => abrirVentana(.editor),
        2 => abrirVentana(.acerca),
        4 => interprete.apagarSistema(),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// bucle principal del escritorio
// ---------------------------------------------------------------------------

pub fn bucle() noreturn {
    serial.puts("ESCRITORIO LISTO\n");
    while (true) {
        x86.hlt();
        while (teclado.poll()) |c| procesarTecla(c);
        while (raton.poll()) |ev| procesarRaton(ev);
        // reloj y memoria de la barra, una vez por segundo
        const s = pit.uptimeSeg();
        if (s != ult_seg) {
            ult_seg = s;
            dibujarBarraInfo();
        }
    }
}
