//! AntLex OS — gui.zig: escritorio clásico (Fase 8, v1.3.0).
//!
//! Modelo de escritorio tradicional inspirado en los de principios de los
//! 90, reinterpretado con código y gráficos 100% propios (nada se copia de
//! otros sistemas): ventanas con relieve biselado 3D, barra de título azul
//! (gris si pierde el foco), botones de control ▼ ▲ ✕, sombra tras la
//! ventana activa, minimizar a ICONO sobre el escritorio, Administrador de
//! Programas con grupos de iconos, organización en cascada y mosaico,
//! Alt+Tab (recuadro con el nombre), Alt+F4, arrastre por el título y
//! redimensionado por los bordes. El TERMINAL y el CHAT son ventanas más.
//!
//! La lógica pura de las apps internas vive en apps.zig (probada en host);
//! las apps externas .ALX se cargan con alx.zig y se dibujan vía la tabla
//! `alx_def.Api` (Fase 7).

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
const alx = @import("alx.zig");
const alx_def = @import("alx_def.zig");
const iconos = @import("iconos.zig");
const version = @import("version.zig");
const x86 = @import("x86.zig");

// ---------------------------------------------------------------------------
// paleta y métricas
// ---------------------------------------------------------------------------

const ALT_TITULO_V: u32 = 16; // barra de título de ventana
const ALT_MENU_V: u32 = 16; // barra de menú de los grupos
const FUENTE_ALTO: u32 = 16;
const FUENTE_ANCHO: u32 = 8;

// cromo clásico (gris/beige con relieve)
const C_ESCRITORIO = pantalla.rgb(0x00, 0x7A, 0x7A); // fondo sólido verde azulado
const C_CARA = pantalla.rgb(0xC0, 0xC0, 0xC0); // cara de ventana
const C_CLARO = pantalla.rgb(0xFF, 0xFF, 0xFF); // bisel claro (arriba/izq)
const C_OSCURO = pantalla.rgb(0x80, 0x80, 0x80); // bisel oscuro (abajo/der)
const C_TIT_ACT = pantalla.rgb(0x00, 0x00, 0x8A); // título activo: azul marino
const C_TIT_INACT = pantalla.rgb(0x90, 0x90, 0x90); // título inactivo: gris
const C_TEXTO_TIT_INACT = pantalla.rgb(0xE8, 0xE8, 0xE8);
const C_TEXTO_NEG = pantalla.rgb(0x00, 0x00, 0x00); // texto negro sobre gris
const C_SOMBRA = pantalla.rgb(0x2E, 0x40, 0x40); // sombra de la ventana activa
const C_SEL = C_TIT_ACT; // selección de iconos

// paleta oscura de las áreas de cliente (apps internas y consolas)
const C_PANEL = pantalla.rgb(0x10, 0x16, 0x20);
const C_VENTANA = pantalla.rgb(0x10, 0x16, 0x20);
const C_BORDE = pantalla.rgb(0x33, 0x42, 0x55);
const C_TEXTO = pantalla.rgb(0xD8, 0xE4, 0xEE);
const C_TINTA_SUAVE = pantalla.rgb(0x9A, 0xAA, 0xBC);
const C_ACENTO = pantalla.rgb(0x5B, 0x9B, 0xF0);
const C_ALERTA = pantalla.rgb(0xF2, 0xB8, 0x66);

const AN_VENTANA_MIN: u32 = 200;
const AL_VENTANA_MIN: u32 = 120;

// ---------------------------------------------------------------------------
// tipos de ventana
// ---------------------------------------------------------------------------

pub const TipoApp = enum(u4) {
    explorador = 0,
    editor = 1,
    acerca = 2,
    adivina = 3,
    app = 4, // app externa .ALX
    terminal = 5,
    chat = 6,
    grupo_principal = 7, // Administrador de Programas
    grupo_accesorios = 8,
};
const N_VENTANAS: u4 = 9;

const NOMBRE_APP = [N_VENTANAS][]const u8{
    "Explorador", "Editor", "Acerca de", "Adivina", "Aplicacion",
    "Terminal",   "Chat",   "Programas", "Accesorios",
};

const Ventana = struct {
    abierta: bool = false,
    minimizada: bool = false, // vive como icono en el escritorio
    maximizada: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    an: u32 = 0,
    al: u32 = 0,
    // geometría antes de maximizar (para restaurar)
    prev_x: i32 = 0,
    prev_y: i32 = 0,
    prev_an: u32 = 0,
    prev_al: u32 = 0,
    // grupos: icono seleccionado (-1 = ninguno)
    sel_icono: i8 = -1,
    // explorador
    expl: apps.Explorador = .{},
    expl_dir: u16 = fmt.RAIZ,
    // editor
    edit: apps.Editor = .{},
    edit_idx: ?u16 = null,
    // juego Adivina
    adv: apps.Adivina = .{},
    // app externa .ALX: título dinámico
    app_titulo: [24]u8 = undefined,
    app_titulo_len: u8 = 0,
};

var ventanas: [N_VENTANAS]Ventana = undefined;
var foco_ventana: TipoApp = .terminal;

fn esGrupo(t: TipoApp) bool {
    return t == .grupo_principal or t == .grupo_accesorios;
}

/// Geometría efectiva (una ventana maximizada ocupa todo el escritorio).
const Geom = struct { x: i32, y: i32, an: u32, al: u32 };
fn geomVentana(v: *const Ventana) Geom {
    if (v.maximizada) return .{ .x = 0, .y = 0, .an = ancho, .al = alto };
    return .{ .x = v.x, .y = v.y, .an = v.an, .al = v.al };
}

// ---------------------------------------------------------------------------
// iconos de los grupos (Administrador de Programas)
// ---------------------------------------------------------------------------

const AccionIcono = union(enum) {
    ventana: TipoApp,
    grupo: TipoApp,
    alx: []const u8, // ruta del ejecutable .ALX
};

const ItemIcono = struct {
    icono: iconos.Icono,
    nombre: []const u8, // ≤11 caracteres (cabe en la celda)
    accion: AccionIcono,
};

const ICONOS_PRINCIPAL = [_]ItemIcono{
    .{ .icono = .explorador, .nombre = "Explorador", .accion = .{ .ventana = .explorador } },
    .{ .icono = .editor, .nombre = "Editor", .accion = .{ .ventana = .editor } },
    .{ .icono = .terminal, .nombre = "Terminal", .accion = .{ .ventana = .terminal } },
    .{ .icono = .chat, .nombre = "Chat", .accion = .{ .ventana = .chat } },
    .{ .icono = .acerca, .nombre = "Acerca de", .accion = .{ .ventana = .acerca } },
    .{ .icono = .grupo, .nombre = "Accesorios", .accion = .{ .grupo = .grupo_accesorios } },
};

const ICONOS_ACCESORIOS = [_]ItemIcono{
    .{ .icono = .adivina, .nombre = "Adivina", .accion = .{ .ventana = .adivina } },
    .{ .icono = .calculadora, .nombre = "Calculadora", .accion = .{ .alx = "/APPS/CALC.ALX" } },
    .{ .icono = .reloj, .nombre = "Reloj", .accion = .{ .alx = "/APPS/RELOJ.ALX" } },
};

fn iconosDe(t: TipoApp) []const ItemIcono {
    return if (t == .grupo_principal) &ICONOS_PRINCIPAL else &ICONOS_ACCESORIOS;
}

// ---------------------------------------------------------------------------
// estado global del escritorio
// ---------------------------------------------------------------------------

var escritorio_activo = false;
var raton_ok = false;

var ancho: u32 = 0;
var alto: u32 = 0;

// chat de AntLex (consola propia + línea de entrada)
var chat = consola.Consola{}; // sin cursor de texto propio (bss)
var chat_linea: [96]u8 = undefined;
var chat_len: usize = 0;

// doble clic (cualquier zona con identidad numérica)
var ult_clic_id: u32 = 0xFFFF_FFFF;
var ult_clic_tics: u64 = 0;

// icono del escritorio seleccionado (ventana minimizada)
var icono_sel: ?TipoApp = null;

// menú emergente (control ▼, Archivo, Ventana)
const AccionMenu = enum {
    restaurar,
    mover,
    tamano,
    minimizar,
    maximizar,
    cerrar,
    apagar,
    cerrar_grupo,
    cascada,
    mosaico,
    enfocar,
};
const MenuItem = struct { texto: []const u8, accion: AccionMenu, objetivo: TipoApp = .terminal };
const MENU_MAX: u8 = 14;
const MENU_ITEM_AL: u32 = 18;
const Menu = struct {
    abierto: bool = false,
    x: u32 = 0,
    y: u32 = 0,
    an: u32 = 120,
    items: [MENU_MAX]MenuItem = undefined,
    n: u8 = 0,
};
var menu = Menu{};

// arrastre de ventana (mover) y redimensionado (bordes)
const Lado = enum { izq, der, arriba, abajo, esq_arr_izq, esq_arr_der, esq_aba_izq, esq_aba_der };
const ModoArrastre = enum { mover, redimensionar };
const Arrastre = struct {
    tipo: TipoApp,
    modo: ModoArrastre,
    lado: Lado = .der,
    dx: i32 = 0, // offset del puntero para mover
    dy: i32 = 0,
    ox: i32 = 0, // geometría original (para redimensionar/cancelar)
    oy: i32 = 0,
    oan: u32 = 0,
    oal: u32 = 0,
    px: i32 = 0, // puntero inicial
    py: i32 = 0,
};
var arrastre: ?Arrastre = null;

// Mover/Tamaño por teclado (menú de control)
const EdicionGeom = struct {
    tipo: TipoApp,
    modo: enum { mover, tamano },
    ox: i32,
    oy: i32,
    oan: u32,
    oal: u32,
};
var edicion_geom: ?EdicionGeom = null;

// recuadro Alt+Tab (sin vista previa, como los clásicos)
var alttab_hasta: u64 = 0;
var alttab_nombre: [24]u8 = undefined;
var alttab_len: u8 = 0;

// cursor del ratón
var cur_x: u32 = 0;
var cur_y: u32 = 0;
const CURSOR: [16]u16 = [_]u16{
    0b1000000000000000,
    0b1100000000000000,
    0b1110000000000000,
    0b1111000000000000,
    0b1111100000000000,
    0b1111110000000000,
    0b1111111000000000,
    0b1111111100000000,
    0b1111100000000000,
    0b1110110000000000,
    0b1100011000000000,
    0b1000011000000000,
    0b0000001100000000,
    0b0000000110000000,
    0b0000000110000000,
    0b0000000011000000,
};

var ult_seg: u64 = 0;

// ---------------------------------------------------------------------------
// utilidades
// ---------------------------------------------------------------------------

fn texto(x: u32, y: u32, s: []const u8, color: u32) void {
    var i: u32 = 0;
    while (i < s.len) : (i += 1) {
        fuente.dibujar(x + i * FUENTE_ANCHO, y, s[i], color, null, 1);
    }
}

fn textoLim(x: u32, y: u32, s: []const u8, color: u32, max: u32) void {
    const n = @min(s.len, @as(usize, max / FUENTE_ANCHO));
    texto(x, y, s[0..n], color);
}

fn enRect(x: i32, y: i32, rx: i32, ry: i32, an: u32, al: u32) bool {
    return x >= rx and y >= ry and x < rx + @as(i32, @intCast(an)) and
        y < ry + @as(i32, @intCast(al));
}

/// Relieve biselado hundido (oscuro arriba/izquierda, claro abajo/derecha).
fn biselHundido(x: u32, y: u32, an: u32, al: u32) void {
    pantalla.rect(x, y, an, 1, C_OSCURO);
    pantalla.rect(x, y, 1, al, C_OSCURO);
    pantalla.rect(x, y + al - 1, an, 1, C_CLARO);
    pantalla.rect(x + an - 1, y, 1, al, C_CLARO);
}

/// Nombre corto de una ventana (trazas de serie; la .ALX usa su título).
fn nombreVentana(t: TipoApp) []const u8 {
    if (t == .app) {
        const v = &ventanas[@intFromEnum(t)];
        if (v.app_titulo_len > 0) return v.app_titulo[0..v.app_titulo_len];
    }
    return NOMBRE_APP[@intFromEnum(t)];
}

fn tituloVentana(t: TipoApp, buf: []u8) []const u8 {
    const v = &ventanas[@intFromEnum(t)];
    return switch (t) {
        .explorador => std.fmt.bufPrint(buf, "Explorador de archivos", .{}) catch "Explorador",
        .adivina => std.fmt.bufPrint(buf, "Adivina — juego del numero", .{}) catch "Adivina",
        .editor => blk: {
            const base = if (v.edit.nombre_len > 0) v.edit.nombreStr() else "(sin archivo)";
            break :blk std.fmt.bufPrint(buf, "Editor — {s}{s}", .{ base, if (v.edit.modificado) " *" else "" }) catch "Editor";
        },
        .acerca => std.fmt.bufPrint(buf, "Acerca de AntLex OS", .{}) catch "Acerca de",
        .app => std.fmt.bufPrint(buf, "{s}", .{nombreVentana(.app)}) catch "Aplicacion",
        .terminal => std.fmt.bufPrint(buf, "Terminal de AntLex", .{}) catch "Terminal",
        .chat => std.fmt.bufPrint(buf, "Chat de AntLex", .{}) catch "Chat",
        .grupo_principal => std.fmt.bufPrint(buf, "Administrador de Programas", .{}) catch "Programas",
        .grupo_accesorios => std.fmt.bufPrint(buf, "Accesorios", .{}) catch "Accesorios",
    };
}

fn iconoDe(t: TipoApp) iconos.Icono {
    return switch (t) {
        .explorador => .explorador,
        .editor => .editor,
        .acerca => .acerca,
        .adivina => .adivina,
        .terminal => .terminal,
        .chat => .chat,
        .grupo_principal => .grupo,
        .grupo_accesorios => .grupo,
        .app => iconoAppActual(),
    };
}

fn iconoAppActual() iconos.Icono {
    if (!alx.cargada()) return .sistema;
    const n = alx.nombreStr();
    if (std.mem.eql(u8, n, "CALC")) return .calculadora;
    if (std.mem.eql(u8, n, "RELOJ")) return .reloj;
    return .sistema;
}

/// Área de cliente de una ventana (debajo de título y, en los grupos,
/// de la barra de menú).
fn clienteDe(v: *const Ventana, t: TipoApp) Geom {
    const g = geomVentana(v);
    const extra: u32 = if (esGrupo(t)) ALT_MENU_V else 0;
    return .{
        .x = g.x + 2,
        .y = g.y + @as(i32, @intCast(ALT_TITULO_V + extra + 2)),
        .an = g.an - 4,
        .al = g.al - ALT_TITULO_V - extra - 4,
    };
}

/// Detección de doble clic sobre una zona con identidad `id`.
fn dobleClic(id: u32) bool {
    const ahora = pit.leerTics();
    const doble = ult_clic_id == id and ahora -| ult_clic_tics < 40; // <400 ms
    ult_clic_id = id;
    ult_clic_tics = ahora;
    return doble;
}

// ---------------------------------------------------------------------------
// dibujo
// ---------------------------------------------------------------------------

pub fn dibujarTodo() void {
    borrarCursor();
    pantalla.rect(0, 0, ancho, alto, C_ESCRITORIO);
    dibujarIconosEscritorio();
    // ventanas no enfocadas en orden del array (índice alto = encima),
    // y la enfocada la última de todas
    var t: u4 = 0;
    while (t < N_VENTANAS) : (t += 1) {
        const ta: TipoApp = @enumFromInt(t);
        const v = &ventanas[t];
        if (v.abierta and !v.minimizada and ta != foco_ventana) dibujarVentana(ta);
    }
    const vf = ventanas[@intFromEnum(foco_ventana)];
    if (vf.abierta and !vf.minimizada) dibujarVentana(foco_ventana);
    if (menu.abierto) dibujarMenu();
    dibujarAltTab();
    dibujarCursor();
}

/// Dibuja los iconos de las ventanas minimizadas (parte baja del escritorio).
fn dibujarIconosEscritorio() void {
    var slot: u32 = 0;
    var t: u4 = 0;
    while (t < N_VENTANAS) : (t += 1) {
        const ta: TipoApp = @enumFromInt(t);
        const v = &ventanas[t];
        if (!(v.abierta and v.minimizada)) continue;
        const ix: u32 = 12 + slot * 92;
        const iy: u32 = alto - 72;
        iconos.dibujar(iconoDe(ta), ix, iy);
        // etiqueta (máx. 11 caracteres), resaltada si está seleccionada
        const nombre = nombreVentana(ta);
        const n = @min(nombre.len, @as(usize, 11));
        const ancho_et: u32 = @as(u32, @intCast(n)) * FUENTE_ANCHO;
        const off: u32 = if (ancho_et < iconos.TAM) (iconos.TAM - ancho_et) / 2 else 0;
        const lx: u32 = ix + off;
        if (icono_sel == ta) {
            pantalla.rect(lx - 2, iy + iconos.TAM + 2, @as(u32, @intCast(n)) * 8 + 4, 14, C_SEL);
            texto(lx, iy + iconos.TAM + 3, nombre[0..n], C_CLARO);
        } else {
            texto(lx, iy + iconos.TAM + 3, nombre[0..n], C_CLARO);
        }
        slot += 1;
    }
}

fn dibujarVentana(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    const enfocada = foco_ventana == t;
    const g = geomVentana(v);
    const x: u32 = @intCast(@max(g.x, 0));
    const y: u32 = @intCast(@max(g.y, 0));

    // sombra tras la ventana activa (marca visual del foco)
    if (enfocada) pantalla.rect(x + 4, y + 4, g.an, g.al, C_SOMBRA);

    // cara + bisel exterior 3D (claro arriba/izquierda, oscuro abajo/derecha)
    pantalla.rect(x, y, g.an, g.al, C_CARA);
    pantalla.rect(x, y, g.an, 1, C_CLARO);
    pantalla.rect(x, y, 1, g.al, C_CLARO);
    pantalla.rect(x, y + g.al - 1, g.an, 1, C_OSCURO);
    pantalla.rect(x + g.an - 1, y, 1, g.al, C_OSCURO);

    // barra de título (azul activa / gris inactiva) con miniatura y botones
    pantalla.rect(x + 1, y + 1, g.an - 2, ALT_TITULO_V - 2, if (enfocada) C_TIT_ACT else C_TIT_INACT);
    iconos.dibujarMini(iconoDe(t), x + 3, y + 1);
    var buf: [64]u8 = undefined;
    textoLim(x + 20, y + 1, tituloVentana(t, &buf), if (enfocada) C_CLARO else C_TEXTO_TIT_INACT, g.an -| 78);
    botonTitulo(t, x + g.an -| 18, y + 1, .cerrar);
    botonTitulo(t, x + g.an -| 36, y + 1, .maximizar);
    botonTitulo(t, x + g.an -| 54, y + 1, .control);

    // barra de menú de los grupos: [Archivo] [Ventana]
    if (esGrupo(t)) {
        const my = y + ALT_TITULO_V;
        pantalla.rect(x + 1, my, g.an - 2, ALT_MENU_V, C_CARA);
        texto(x + 8, my + 1, "Archivo", C_TEXTO_NEG);
        texto(x + 80, my + 1, "Ventana", C_TEXTO_NEG);
        pantalla.rect(x + 1, my + ALT_MENU_V, g.an - 2, 1, C_OSCURO);
        pantalla.rect(x + 1, my + ALT_MENU_V + 1, g.an - 2, 1, C_CLARO);
    }

    // área de cliente: hundida y oscura para las apps, gris para los grupos
    const c = clienteDe(v, t);
    const cx: u32 = @intCast(@max(c.x, 0));
    const cy: u32 = @intCast(@max(c.y, 0));
    if (!esGrupo(t)) {
        pantalla.rect(cx, cy, c.an, c.al, C_VENTANA);
        pantalla.rect(cx, cy, c.an, 1, C_BORDE);
        pantalla.rect(cx, cy, 1, c.al, C_BORDE);
    } else {
        biselHundido(cx, cy, c.an, c.al);
    }

    switch (t) {
        .terminal => {
            consola.recolocarGlobal(cx, cy, c.an, c.al);
            consola.redibujar();
        },
        .chat => {
            chat.recolocar(cx, cy, c.an, c.al -| 24);
            chat.redibujar();
            dibujarChatEntrada();
        },
        .explorador => dibujarExplorador(v, x, y),
        .editor => dibujarEditor(v, x, y),
        .acerca => dibujarAcerca(x, y),
        .adivina => dibujarAdivina(v, x, y),
        .grupo_principal, .grupo_accesorios => dibujarGrupo(v, t, x, y),
        .app => despacharApp(&.{
            .tipo = alx_def.EV_DIBUJAR,
            .tecla = 0,
            .x = c.x,
            .y = c.y,
            .an = c.an,
            .al = c.al,
        }),
    }
}

const BotonTitulo = enum { control, maximizar, cerrar };

/// Caja biselada de 16×14 de la barra de título con su glifo dibujado.
fn botonTitulo(t: TipoApp, x: u32, y: u32, cual: BotonTitulo) void {
    pantalla.rect(x, y, 16, 14, C_CARA);
    pantalla.rect(x, y, 16, 1, C_CLARO);
    pantalla.rect(x, y, 1, 14, C_CLARO);
    pantalla.rect(x, y + 13, 16, 1, C_OSCURO);
    pantalla.rect(x + 15, y, 1, 14, C_OSCURO);
    switch (cual) {
        .control => glifoAbajo(x + 4, y + 5), // ▼ menú de control
        .maximizar => {
            if (ventanas[@intFromEnum(t)].maximizada) {
                glifoRestaurar(x + 3, y + 3); // dos cuadritos superpuestos
            } else {
                glifoArriba(x + 3, y + 4); // ▲
            }
        },
        .cerrar => fuente.dibujar(x + 4, y + 1, 'X', C_TEXTO_NEG, null, 1),
    }
}

fn glifoAbajo(x: u32, y: u32) void {
    var i: u32 = 0;
    while (i < 4) : (i += 1) pantalla.rect(x + i, y + i, 8 - 2 * i, 1, C_TEXTO_NEG);
}

fn glifoArriba(x: u32, y: u32) void {
    var i: u32 = 0;
    while (i < 4) : (i += 1) pantalla.rect(x + 3 - i, y + i, 1 + 2 * i, 1, C_TEXTO_NEG);
}

fn glifoRestaurar(x: u32, y: u32) void {
    // cuadrito trasero (contorno) + cuadrito delantero (relleno)
    pantalla.rect(x, y + 3, 7, 7, C_TEXTO_NEG);
    pantalla.rect(x + 1, y + 4, 5, 5, C_CARA);
    pantalla.rect(x + 3, y, 7, 7, C_TEXTO_NEG);
    pantalla.rect(x + 4, y + 1, 5, 5, C_CARA);
    pantalla.rect(x + 3, y, 7, 2, C_TEXTO_NEG);
}

fn dibujarChatEntrada() void {
    const v = &ventanas[@intFromEnum(TipoApp.chat)];
    const g = geomVentana(v);
    const y: u32 = @as(u32, @intCast(@max(g.y, 0))) + g.al - 22;
    const x: u32 = @intCast(@max(g.x, 0));
    pantalla.rect(x + 2, y, g.an - 4, 20, C_PANEL);
    pantalla.rect(x + 2, y, g.an - 4, 1, C_BORDE);
    const pref = "Tú > ";
    texto(x + 8, y + 2, pref, C_TINTA_SUAVE);
    const x_texto = x + 8 + @as(u32, pref.len) * FUENTE_ANCHO;
    textoLim(x_texto, y + 2, chat_linea[0..chat_len], C_TEXTO, g.an -| 24);
    const cx = x_texto + @as(u32, @intCast(chat_len)) * FUENTE_ANCHO;
    pantalla.rect(cx, y + 2, FUENTE_ANCHO, FUENTE_ALTO - 3, C_ACENTO);
}

fn dibujarExplorador(v: *Ventana, x: u32, y: u32) void {
    var buf: [96]u8 = undefined;
    var ruta: []const u8 = "/";
    if (alfs.montado()) {
        const vol = alfs.actual().?;
        const n = vol.rutaAbsoluta(v.expl_dir, &buf) catch 0;
        ruta = buf[0..n];
    }
    textoLim(x + 6, y + ALT_TITULO_V + 2, ruta, C_TINTA_SUAVE, v.an - 12);
    pantalla.rect(x + 2, y + ALT_TITULO_V + 18, v.an - 4, 1, C_BORDE);

    const filas_vis: u32 = if (v.al > ALT_TITULO_V + 40 + 16) (v.al - ALT_TITULO_V - 40) / FUENTE_ALTO else 1;
    var i: u32 = 0;
    while (i < filas_vis) : (i += 1) {
        const idx = v.expl.scroll + i;
        if (idx >= v.expl.n) break;
        const ent = &v.expl.entradas[idx];
        const fy = y + ALT_TITULO_V + 24 + i * FUENTE_ALTO;
        const seleccionada = v.expl.seleccion == @as(i16, @intCast(idx));
        if (seleccionada) {
            pantalla.rect(x + 4, fy, v.an - 8, FUENTE_ALTO, C_TIT_ACT);
        }
        const icono: []const u8 = if (ent.tipo == fmt.TIPO_DIRECTORIO) "> " else "· ";
        const tinta = if (seleccionada) C_TEXTO else if (ent.tipo == fmt.TIPO_DIRECTORIO) C_ACENTO else C_TEXTO;
        texto(x + 8, fy, icono, tinta);
        textoLim(x + 8 + 16, fy, ent.nombreStr(), tinta, v.an - 40);
        if (ent.flags & fmt.FLAG_EJECUTABLE != 0) {
            texto(x + v.an - 12, fy, "*", C_ALERTA); // marca de ejecutable
        }
    }
    texto(x + 6, y + v.al - 14, "INTRO abrir · ↑↓ elegir · RETROCESO subir", C_TINTA_SUAVE);
}

fn dibujarEditor(v: *Ventana, x: u32, y: u32) void {
    const filas_vis: u32 = if (v.al > ALT_TITULO_V + 34) (v.al - ALT_TITULO_V - 34) / FUENTE_ALTO else 1;
    var i: u32 = 0;
    while (i < filas_vis) : (i += 1) {
        const fila = v.edit.fila - @min(v.edit.fila, filas_vis - 1) + i; // ventana anclada al cursor
        if (fila >= v.edit.n) break;
        const l = v.edit.lens[fila];
        const fy = y + ALT_TITULO_V + 4 + i * FUENTE_ALTO;
        textoLim(x + 6, fy, v.edit.lineas[fila][0..l], C_TEXTO, v.an - 12);
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
        "Ejecutables .ALX y escritorio clásico (Fase 7-8).",
        "",
        "Licencia GPL-3.0 · juanruiz85",
        "github.com/juanruiz85/AntLexOS",
    };
    for (lineas, 0..) |l, i| {
        textoLim(x + 12, y + ALT_TITULO_V + 8 + @as(u32, @intCast(i)) * FUENTE_ALTO, l, if (i == 0) C_ACENTO else C_TEXTO, 340);
    }
}

fn dibujarAdivina(v: *Ventana, x: u32, y: u32) void {
    const a = &v.adv;
    textoLim(x + 6, y + ALT_TITULO_V + 8, a.msgStr(), if (a.acertado) C_ACENTO else C_TEXTO, v.an - 12);
    var buf: [64]u8 = undefined;
    const linea = std.fmt.bufPrint(&buf, "Tu numero: [{s: >3}]", .{a.intentoStr()}) catch "?";
    texto(x + 8, y + ALT_TITULO_V + 34, linea, C_ACENTO);
    var buf2: [64]u8 = undefined;
    const stats = std.fmt.bufPrint(&buf2, "Intentos: {d}", .{a.intentos}) catch "?";
    texto(x + 8, y + ALT_TITULO_V + 54, stats, C_TEXTO);
    texto(x + 6, y + v.al - 14, if (a.acertado) "INTRO otra ronda · ESC cerrar" else "0-9 cifra · INTRO probar · ESC cerrar", C_TINTA_SUAVE);
}

// ---------------------------------------------------------------------------
// grupos: rejilla de iconos dentro del Administrador de Programas
// ---------------------------------------------------------------------------

const CELDA_AN: u32 = 100;
const CELDA_AL: u32 = 76;

fn celdaDe(v: *const Ventana, i: usize) struct { x: u32, y: u32 } {
    const cols: u32 = @max((v.an -| 16) / CELDA_AN, 1);
    const gx = (v.an -| (cols * CELDA_AN)) / 2; // rejilla centrada
    return .{
        .x = gx + @as(u32, @intCast((i % cols) * CELDA_AN)) + (CELDA_AN - iconos.TAM) / 2,
        .y = ALT_TITULO_V + ALT_MENU_V + 10 + @as(u32, @intCast(i / cols)) * CELDA_AL,
    };
}

fn dibujarGrupo(v: *Ventana, t: TipoApp, x: u32, y: u32) void {
    const items = iconosDe(t);
    for (items, 0..) |it, i| {
        const c = celdaDe(v, i);
        iconos.dibujar(it.icono, x + c.x, y + c.y);
        // etiqueta centrada bajo el icono (anclada a la izquierda si es
        // más ancha que él): todo en u32, sin offsets negativos
        const n = @min(it.nombre.len, @as(usize, 11));
        const ancho_et: u32 = @as(u32, @intCast(n)) * FUENTE_ANCHO;
        const off: u32 = if (ancho_et < iconos.TAM) (iconos.TAM - ancho_et) / 2 else 0;
        const lx: u32 = x + c.x + off;
        const seleccionado = v.sel_icono == @as(i8, @intCast(i));
        if (seleccionado) {
            pantalla.rect(lx -| 2, y + c.y + iconos.TAM + 2, ancho_et + 4, 14, C_SEL);
        }
        texto(lx, y + c.y + iconos.TAM + 3, it.nombre[0..n], if (seleccionado) C_CLARO else C_TEXTO_NEG);
    }
    texto(x + 6, y + v.al -| 14, "doble clic abre · flechas elegir · INTRO abrir", C_OSCURO);
}

// ---------------------------------------------------------------------------
// menú emergente
// ---------------------------------------------------------------------------

fn dibujarMenu() void {
    const al: u32 = @as(u32, menu.n) * MENU_ITEM_AL + 6;
    pantalla.rect(menu.x, menu.y, menu.an, al, C_CARA);
    pantalla.rect(menu.x, menu.y, menu.an, 1, C_CLARO);
    pantalla.rect(menu.x, menu.y, 1, al, C_CLARO);
    pantalla.rect(menu.x, menu.y + al - 1, menu.an, 1, C_OSCURO);
    pantalla.rect(menu.x + menu.an - 1, menu.y, 1, al, C_OSCURO);
    var i: u8 = 0;
    while (i < menu.n) : (i += 1) {
        const it = &menu.items[i];
        const iy = menu.y + 3 + @as(u32, i) * MENU_ITEM_AL;
        texto(menu.x + 8, iy, it.texto, C_TEXTO_NEG);
    }
}

fn menuAncho(items: []const MenuItem) u32 {
    var max: u32 = 0;
    for (items) |it| max = @max(max, @as(u32, @intCast(it.texto.len)) * FUENTE_ANCHO);
    return max + 16;
}

fn menuAbrir(x: i32, y: i32, items: []const MenuItem) void {
    if (items.len == 0 or items.len > MENU_MAX) return;
    menu.n = @intCast(items.len);
    for (items, 0..) |it, i| menu.items[i] = it;
    menu.an = menuAncho(items);
    menu.x = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(ancho -| menu.an))));
    menu.y = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(alto -| @as(u32, menu.n) * MENU_ITEM_AL + 6))));
    menu.abierto = true;
    serial.puts("gui: menu abierto\n");
    dibujarTodo();
}

fn menuCerrar() void {
    if (!menu.abierto) return;
    menu.abierto = false;
    serial.puts("gui: menu cerrado\n");
}

// ---------------------------------------------------------------------------
// recuadro Alt+Tab
// ---------------------------------------------------------------------------

fn dibujarAltTab() void {
    if (pit.leerTics() >= alttab_hasta or alttab_len == 0) return;
    const an: u32 = 260;
    const x = (ancho -| an) / 2;
    const y = (alto -| 44) / 2;
    pantalla.rect(x + 3, y + 3, an, 38, C_SOMBRA);
    pantalla.rect(x, y, an, 38, C_CARA);
    pantalla.rect(x, y, an, 1, C_CLARO);
    pantalla.rect(x, y, 1, 38, C_CLARO);
    pantalla.rect(x, y + 37, an, 1, C_OSCURO);
    pantalla.rect(x + an - 1, y, 1, 38, C_OSCURO);
    textoLim(x + 12, y + 11, alttab_nombre[0..alttab_len], C_TEXTO_NEG, an - 24);
}

// ---------------------------------------------------------------------------
// cursor del ratón (XOR: se borra volviéndolo a pintar)
// ---------------------------------------------------------------------------

fn borrarCursor() void {
    dibujarCursor();
}

fn dibujarCursor() void {
    if (!raton_ok) return;
    var f: u32 = 0;
    while (f < CURSOR.len) : (f += 1) {
        var c: u32 = 0;
        while (c < 16) : (c += 1) {
            if (CURSOR[f] & (@as(u16, 1) << @intCast(15 - c)) != 0) {
                xorPixel(cur_x + c, cur_y + f);
            }
        }
    }
}

fn xorPixel(x: u32, y: u32) void {
    if (x >= ancho or y >= alto) return;
    const fb: [*]volatile u32 = @ptrFromInt(pantalla.direccion());
    const paso = pantalla.pasoBytes() / 4;
    (fb + @as(usize, y) * paso + x)[0] ^= 0x00FFFFFF;
}

// ---------------------------------------------------------------------------
// arranque del escritorio
// ---------------------------------------------------------------------------

pub fn init() void {
    ancho = pantalla.anchoPix();
    alto = pantalla.altoPix();

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

    // geometría inicial de las ventanas
    ventanas[@intFromEnum(TipoApp.explorador)] = .{ .x = 300, .y = 60, .an = 360, .al = 330 };
    ventanas[@intFromEnum(TipoApp.editor)] = .{ .x = 170, .y = 100, .an = 480, .al = 330 };
    ventanas[@intFromEnum(TipoApp.acerca)] = .{ .x = 430, .y = 210, .an = 380, .al = 260 };
    ventanas[@intFromEnum(TipoApp.adivina)] = .{ .x = 340, .y = 190, .an = 340, .al = 230 };
    ventanas[@intFromEnum(TipoApp.app)] = .{ .x = 300, .y = 140, .an = 320, .al = 240 };
    ventanas[@intFromEnum(TipoApp.terminal)] = .{ .x = 250, .y = 120, .an = 560, .al = 420 };
    ventanas[@intFromEnum(TipoApp.chat)] = .{ .x = 210, .y = 160, .an = 500, .al = 340 };
    ventanas[@intFromEnum(TipoApp.grupo_principal)] = .{ .x = 10, .y = 8, .an = 424, .al = 210 };
    ventanas[@intFromEnum(TipoApp.grupo_accesorios)] = .{ .x = 60, .y = 52, .an = 330, .al = 140 };

    // estilo de las consolas (paleta oscura de siempre); la región del chat
    // se fija ANTES de limpiar (sin región hay 0 filas y el scroll desborda)
    consola.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = C_PANEL });
    const vchat = &ventanas[@intFromEnum(TipoApp.chat)];
    chat.region(
        @intCast(vchat.x + 2),
        @intCast(vchat.y + @as(i32, @intCast(ALT_TITULO_V + 2))),
        vchat.an - 4,
        vchat.al - ALT_TITULO_V - 4 - 24,
    );
    chat.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = C_PANEL });
    chat.limpiar();
    chat.fijarEstilo(.{ .tinta = consola.COLOR_TITULO, .fondo = C_PANEL });
    chat.puts("AntLex, a tu servicio. Escribe tu pregunta y\npulsa INTRO (ej. quien eres).\n");
    chat.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = C_PANEL });

    escritorio_activo = true;

    // arranque clásico: el Administrador de Programas y el Terminal;
    // el foco empieza en el Terminal (la consola sigue viva con su historial
    // de arranque visible dentro de la ventana)
    abrirVentana(.grupo_principal);
    abrirVentana(.terminal);

    serial.puts("gui: escritorio clasico listo (Fase 8)\n");
    dibujarTodo();
}

pub fn enEscritorio() bool {
    return escritorio_activo;
}

pub fn ratonDisponible() bool {
    return raton_ok;
}

pub fn chatEscribir(txt: []const u8) void {
    if (!escritorio_activo) return;
    chat.fijarEstilo(.{ .tinta = consola.COLOR_TEXTO, .fondo = C_PANEL });
    chat.puts(txt);
    chat.putc('\n');
    dibujarTodo();
}


// ---------------------------------------------------------------------------
// gestión de ventanas
// ---------------------------------------------------------------------------

fn abrirVentana(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.abierta) {
        v.abierta = true;
        v.minimizada = false;
        serial.puts("gui: ventana abierta ");
        serial.puts(nombreVentana(t));
        serial.puts("\n");
    }
    if (t == .explorador) explListar(v);
    enfocarVentana(t, true);
    if (t == .adivina) { // ronda nueva tras el foco: el orden de trazas lo espera el arnés
        apps.adivinaNueva(&v.adv, @truncate(pit.leerTics()));
        serial.puts("gui: adivina nueva\n");
    }
}

fn cerrarVentana(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.abierta) return;
    v.abierta = false;
    v.minimizada = false;
    v.maximizada = false;
    if (t == .app) { // Fase 7: avisar y descargar la app externa
        despacharApp(&.{ .tipo = alx_def.EV_CERRAR, .tecla = 0, .x = 0, .y = 0, .an = 0, .al = 0 });
        alx.descargar();
    }
    serial.puts("gui: ventana cerrada ");
    serial.puts(nombreVentana(t));
    serial.puts("\n");
    if (arrastre != null and arrastre.?.tipo == t) arrastre = null;
    if (icono_sel == t) icono_sel = null;
    if (foco_ventana == t) {
        if (!refocar()) serial.puts("gui: sin foco (todas cerradas)\n");
    }
    dibujarTodo();
}

fn enfocarVentana(t: TipoApp, dibujar: bool) void {
    const cambio = foco_ventana != t or ventanas[@intFromEnum(t)].minimizada;
    foco_ventana = t;
    if (cambio) {
        serial.puts("gui: foco ventana ");
        serial.puts(nombreVentana(t));
        serial.puts("\n");
    }
    if (dibujar) dibujarTodo();
}

/// Pasa el foco a la primera ventana abierta y visible (orden del array).
fn refocar() bool {
    var t: u4 = 0;
    while (t < N_VENTANAS) : (t += 1) {
        const v = &ventanas[t];
        if (v.abierta and !v.minimizada) {
            enfocarVentana(@enumFromInt(t), true);
            return true;
        }
    }
    return false;
}

fn minimizarVentana(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.abierta or v.minimizada) return;
    v.minimizada = true;
    serial.puts("gui: ventana minimizada ");
    serial.puts(nombreVentana(t));
    serial.puts("\n");
    if (foco_ventana == t) {
        if (!refocar()) serial.puts("gui: sin foco (solo iconos)\n");
    }
    dibujarTodo();
}

/// Restaurar una ventana minimizada (desde icono o desde el menú ▼).
fn restaurarVentana(t: TipoApp, desde_icono: bool) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.abierta or !v.minimizada) return;
    v.minimizada = false;
    icono_sel = null;
    serial.puts(if (desde_icono) "gui: icono restaurado " else "gui: ventana restaurada ");
    serial.puts(nombreVentana(t));
    serial.puts("\n");
    enfocarVentana(t, true);
}

fn maximizarVentana(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.abierta or v.maximizada) return;
    v.prev_x = v.x;
    v.prev_y = v.y;
    v.prev_an = v.an;
    v.prev_al = v.al;
    v.maximizada = true;
    v.minimizada = false;
    serial.puts("gui: ventana maximizada ");
    serial.puts(nombreVentana(t));
    serial.puts("\n");
    dibujarTodo();
}

fn restaurarDeMaximizada(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.maximizada) return;
    v.x = v.prev_x;
    v.y = v.prev_y;
    v.an = v.prev_an;
    v.al = v.prev_al;
    v.maximizada = false;
    serial.puts("gui: ventana restaurada ");
    serial.puts(nombreVentana(t));
    serial.puts("\n");
    dibujarTodo();
}

fn alternarMaximizada(t: TipoApp) void {
    if (ventanas[@intFromEnum(t)].maximizada) restaurarDeMaximizada(t) else maximizarVentana(t);
}

/// Organizar en cascada: ventanas de 480×320 desfasadas 24 px.
fn cascada() void {
    var i: u32 = 0;
    var t: u4 = 0;
    while (t < N_VENTANAS) : (t += 1) {
        const v = &ventanas[t];
        if (!(v.abierta and !v.minimizada)) continue;
        v.maximizada = false;
        v.x = @intCast(std.math.clamp(@as(i32, @intCast(24 + i * 24)), 0, @as(i32, @intCast(ancho)) - 200));
        v.y = @intCast(std.math.clamp(@as(i32, @intCast(24 + i * 24)), 0, @as(i32, @intCast(alto)) - 120));
        v.an = @min(@as(u32, 480), ancho);
        v.al = @min(@as(u32, 320), alto);
        i += 1;
    }
    serial.puts("gui: cascada\n");
    dibujarTodo();
}

/// Organizar en mosaico: rejilla que cubre el escritorio.
fn mosaico() void {
    var n: u32 = 0;
    var t: u4 = 0;
    while (t < N_VENTANAS) : (t += 1) {
        if (ventanas[t].abierta and !ventanas[t].minimizada) n += 1;
    }
    if (n == 0) return;
    var cols: u32 = 1;
    while (cols * cols < n) cols += 1; // ceil(sqrt(n)) en entero
    const filas: u32 = (n + cols - 1) / cols;
    const w = ancho / cols;
    const h = alto / filas;
    var i: u32 = 0;
    t = 0;
    while (t < N_VENTANAS) : (t += 1) {
        const v = &ventanas[t];
        if (!(v.abierta and !v.minimizada)) continue;
        v.maximizada = false;
        v.x = @intCast((i % cols) * w);
        v.y = @intCast((i / cols) * h);
        v.an = w;
        v.al = h;
        i += 1;
    }
    serial.puts("gui: mosaico\n");
    dibujarTodo();
}

// ---------------------------------------------------------------------------
// menús (control ▼, Archivo, Ventana)
// ---------------------------------------------------------------------------

fn menuControl(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    if (!v.abierta) return;
    const g = geomVentana(v);
    var its: [6]MenuItem = .{
        .{ .texto = "Restaurar", .accion = .restaurar, .objetivo = t },
        .{ .texto = "Mover", .accion = .mover, .objetivo = t },
        .{ .texto = "Tamaño", .accion = .tamano, .objetivo = t },
        .{ .texto = "Minimizar", .accion = .minimizar, .objetivo = t },
        .{ .texto = "Maximizar", .accion = .maximizar, .objetivo = t },
        .{ .texto = "Cerrar", .accion = .cerrar, .objetivo = t },
    };
    menuAbrir(g.x + @as(i32, @intCast(g.an)) - 60, g.y + ALT_TITULO_V, &its);
}

fn menuArchivo(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    const g = geomVentana(v);
    var its: [2]MenuItem = .{
        .{ .texto = "Apagar el sistema", .accion = .apagar, .objetivo = t },
        .{ .texto = "Cerrar grupo", .accion = .cerrar_grupo, .objetivo = t },
    };
    menuAbrir(g.x + 6, g.y + @as(i32, @intCast(ALT_TITULO_V + ALT_MENU_V)), &its);
}

/// Menú Ventana de los grupos: cascada, mosaico y lista de ventanas abiertas.
fn menuVentanaLista(t: TipoApp) void {
    const v = &ventanas[@intFromEnum(t)];
    const g = geomVentana(v);
    var its: [2 + N_VENTANAS]MenuItem = undefined;
    its[0] = .{ .texto = "Cascada", .accion = .cascada };
    its[1] = .{ .texto = "Mosaico", .accion = .mosaico };
    var n: usize = 2;
    var i: u4 = 0;
    while (i < N_VENTANAS) : (i += 1) {
        if (!ventanas[i].abierta) continue;
        its[n] = .{
            .texto = nombreVentana(@enumFromInt(i)),
            .accion = .enfocar,
            .objetivo = @enumFromInt(i),
        };
        n += 1;
    }
    menuAbrir(g.x + 78, g.y + @as(i32, @intCast(ALT_TITULO_V + ALT_MENU_V)), its[0..n]);
}

fn clicMenu(x: i32, y: i32) void {
    const al: u32 = @as(u32, menu.n) * MENU_ITEM_AL + 6;
    if (enRect(x, y, @intCast(menu.x), @intCast(menu.y), menu.an, al)) {
        const dy = y - @as(i32, @intCast(menu.y)) - 3;
        if (dy >= 0) {
            const fila: usize = @intCast(@divTrunc(dy, @as(i32, MENU_ITEM_AL)));
            if (fila < menu.n) {
                const it = menu.items[fila];
                menuCerrar();
                serial.puts("gui: menu accion ");
                serial.puts(it.texto);
                serial.puts("\n");
                ejecutarMenuAccion(it);
                dibujarTodo();
                return;
            }
        }
    }
    menuCerrar();
    dibujarTodo();
}

fn ejecutarMenuAccion(it: MenuItem) void {
    const t = it.objetivo;
    const v = &ventanas[@intFromEnum(t)];
    switch (it.accion) {
        .restaurar => {
            if (v.maximizada) restaurarDeMaximizada(t) else if (v.minimizada) restaurarVentana(t, false);
        },
        .mover => {
            if (v.abierta and !v.minimizada) {
                const g = geomVentana(v);
                edicion_geom = .{ .tipo = t, .modo = .mover, .ox = g.x, .oy = g.y, .oan = g.an, .oal = g.al };
            }
        },
        .tamano => {
            if (v.abierta and !v.minimizada) {
                const g = geomVentana(v);
                edicion_geom = .{ .tipo = t, .modo = .tamano, .ox = g.x, .oy = g.y, .oan = g.an, .oal = g.al };
            }
        },
        .minimizar => minimizarVentana(t),
        .maximizar => alternarMaximizada(t),
        .cerrar => cerrarVentana(t),
        .apagar => interprete.apagarSistema(),
        .cerrar_grupo => cerrarVentana(t),
        .cascada => cascada(),
        .mosaico => mosaico(),
        .enfocar => {
            if (v.minimizada) restaurarVentana(t, false) else enfocarVentana(t, true);
        },
    }
}

// ---------------------------------------------------------------------------
// eventos del ratón
// ---------------------------------------------------------------------------

fn procesarRaton(ev: raton.Evento) void {
    if (ev.tipo == .mover) {
        if (arrastre) |a| {
            aplicarArrastre(a, @intCast(ev.x), @intCast(ev.y));
            dibujarTodo();
        }
        borrarCursor();
        cur_x = ev.x;
        cur_y = ev.y;
        dibujarCursor();
        return;
    }
    if (ev.tipo == .pulsar and ev.boton == .izq) procesarClic(@intCast(ev.x), @intCast(ev.y));
    if (ev.tipo == .soltar and ev.boton == .izq) {
        if (arrastre) |a| {
            arrastre = null;
            serial.puts(if (a.modo == .mover) "gui: ventana movida " else "gui: ventana redimensionada ");
            serial.puts(nombreVentana(a.tipo));
            serial.puts("\n");
            dibujarTodo();
        }
    }
}

fn aplicarArrastre(a: Arrastre, px: i32, py: i32) void {
    const v = &ventanas[@intFromEnum(a.tipo)];
    switch (a.modo) {
        .mover => {
            v.x = std.math.clamp(px - a.dx, -@as(i32, @intCast(v.an)) + 80, @as(i32, @intCast(ancho)) - 40);
            v.y = std.math.clamp(py - a.dy, 0, @as(i32, @intCast(alto)) - 40);
        },
        .redimensionar => {
            const dx = px - a.px;
            const dy = py - a.py;
            v.x = a.ox;
            v.y = a.oy;
            v.an = a.oan;
            v.al = a.oal;
            const an_i: i32 = @intCast(a.oan);
            const al_i: i32 = @intCast(a.oal);
            const min_w: i32 = @intCast(AN_VENTANA_MIN);
            const min_h: i32 = @intCast(AL_VENTANA_MIN);
            const max_x: i32 = @intCast(ancho);
            const max_y: i32 = @intCast(alto);
            switch (a.lado) {
                .der => v.an = @intCast(std.math.clamp(an_i + dx, min_w, max_x -| a.ox)),
                .abajo => v.al = @intCast(std.math.clamp(al_i + dy, min_h, max_y -| a.oy)),
                .izq => {
                    const nuevo_x = std.math.clamp(a.ox + dx, 0, a.ox + an_i - min_w);
                    v.x = nuevo_x;
                    v.an = @intCast(an_i - (nuevo_x - a.ox));
                },
                .arriba => {
                    const nuevo_y = std.math.clamp(a.oy + dy, 0, a.oy + al_i - min_h);
                    v.y = nuevo_y;
                    v.al = @intCast(al_i - (nuevo_y - a.oy));
                },
                .esq_arr_izq => {
                    const nuevo_x = std.math.clamp(a.ox + dx, 0, a.ox + an_i - min_w);
                    const nuevo_y = std.math.clamp(a.oy + dy, 0, a.oy + al_i - min_h);
                    v.x = nuevo_x;
                    v.an = @intCast(an_i - (nuevo_x - a.ox));
                    v.y = nuevo_y;
                    v.al = @intCast(al_i - (nuevo_y - a.oy));
                },
                .esq_arr_der => {
                    const nuevo_y = std.math.clamp(a.oy + dy, 0, a.oy + al_i - min_h);
                    v.y = nuevo_y;
                    v.al = @intCast(al_i - (nuevo_y - a.oy));
                    v.an = @intCast(std.math.clamp(an_i + dx, min_w, max_x -| a.ox));
                },
                .esq_aba_izq => {
                    const nuevo_x = std.math.clamp(a.ox + dx, 0, a.ox + an_i - min_w);
                    v.x = nuevo_x;
                    v.an = @intCast(an_i - (nuevo_x - a.ox));
                    v.al = @intCast(std.math.clamp(al_i + dy, min_h, max_y -| a.oy));
                },
                .esq_aba_der => {
                    v.an = @intCast(std.math.clamp(an_i + dx, min_w, max_x -| a.ox));
                    v.al = @intCast(std.math.clamp(al_i + dy, min_h, max_y -| a.oy));
                },
            }
        },
    }
}

fn procesarClic(x: i32, y: i32) void {
    var buf: [48]u8 = undefined;
    serial.puts(std.fmt.bufPrint(&buf, "gui: clic {d},{d}\n", .{ x, y }) catch "gui: clic\n");
    if (menu.abierto) {
        clicMenu(x, y);
        return;
    }
    // ventanas de arriba abajo: la enfocada primero y luego índice descendente
    if (ventanas[@intFromEnum(foco_ventana)].abierta and !ventanas[@intFromEnum(foco_ventana)].minimizada) {
        if (clicVentana(foco_ventana, x, y)) return;
    }
    var i: u4 = N_VENTANAS;
    while (i > 0) {
        i -= 1;
        const t: TipoApp = @enumFromInt(i);
        if (t == foco_ventana) continue;
        if (ventanas[i].abierta and !ventanas[i].minimizada) {
            if (clicVentana(t, x, y)) return;
        }
    }
    // iconos del escritorio (ventanas minimizadas)
    clicIconoEscritorio(x, y);
}

/// Clic sobre una ventana; devuelve true si lo consumió.
fn clicVentana(t: TipoApp, x: i32, y: i32) bool {
    const v = &ventanas[@intFromEnum(t)];
    const g = geomVentana(v);
    if (!enRect(x, y, g.x, g.y, g.an, g.al)) return false;
    const lx = x - g.x;
    const ly = y - g.y;

    // 1) botones de la barra de título (✕ ▲ ▼, de derecha a izquierda)
    if (ly >= 1 and ly < ALT_TITULO_V) {
        const gi: i32 = @intCast(g.an);
        if (enRect(x, y, g.x + gi - 18, g.y + 1, 16, 14)) {
            cerrarVentana(t);
            return true;
        }
        if (enRect(x, y, g.x + gi - 36, g.y + 1, 16, 14)) {
            alternarMaximizada(t);
            return true;
        }
        if (enRect(x, y, g.x + gi - 54, g.y + 1, 16, 14)) {
            if (foco_ventana != t) enfocarVentana(t, false);
            menuControl(t);
            return true;
        }
    }

    // 2) bordes para redimensionar (excepto maximizada)
    if (!v.maximizada) {
        if (zonaBorde(lx, ly, g.an, g.al)) |lado| {
            if (foco_ventana != t) enfocarVentana(t, false);
            arrastre = .{
                .tipo = t,
                .modo = .redimensionar,
                .lado = lado,
                .ox = v.x,
                .oy = v.y,
                .oan = v.an,
                .oal = v.al,
                .px = x,
                .py = y,
            };
            return true;
        }
    }

    // 3) barra de título: icono del programa (doble clic cierra) y arrastre
    if (ly >= 1 and ly < ALT_TITULO_V) {
        if (foco_ventana != t) enfocarVentana(t, true);
        if (enRect(x, y, g.x + 2, g.y + 1, 16, 14)) {
            if (dobleClic((@as(u32, @intFromEnum(t)) << 8) | 1)) cerrarVentana(t);
            return true;
        }
        if (dobleClic((@as(u32, @intFromEnum(t)) << 8) | 2)) {
            alternarMaximizada(t); // doble clic en el título: maximizar/restaurar
            return true;
        }
        if (!v.maximizada) {
            arrastre = .{ .tipo = t, .modo = .mover, .dx = lx, .dy = ly };
        }
        return true;
    }

    // 4) barra de menú de los grupos: [Archivo] [Ventana]
    if (esGrupo(t) and ly >= ALT_TITULO_V and ly < ALT_TITULO_V + ALT_MENU_V) {
        if (foco_ventana != t) enfocarVentana(t, true);
        if (lx >= 6 and lx < 74) menuArchivo(t);
        if (lx >= 78 and lx < 146) menuVentanaLista(t);
        return true;
    }

    // 5) área de cliente
    if (foco_ventana != t) enfocarVentana(t, true);
    clicCliente(t, x, y);
    return true;
}

const BORDE_ZONA: i32 = 5;

fn zonaBorde(lx: i32, ly: i32, an: u32, al: u32) ?Lado {
    const ai: i32 = @intCast(an);
    const ali: i32 = @intCast(al);
    const izq = lx < BORDE_ZONA;
    const der = lx >= ai - BORDE_ZONA;
    const arr = ly < BORDE_ZONA;
    const aba = ly >= ali - BORDE_ZONA;
    if (!izq and !der and !arr and !aba) return null;
    if (arr and izq) return .esq_arr_izq;
    if (arr and der) return .esq_arr_der;
    if (aba and izq) return .esq_aba_izq;
    if (aba and der) return .esq_aba_der;
    if (izq) return .izq;
    if (der) return .der;
    if (arr) return .arriba;
    return .abajo;
}

fn clicCliente(t: TipoApp, x: i32, y: i32) void {
    const v = &ventanas[@intFromEnum(t)];
    const g = geomVentana(v);
    switch (t) {
        .explorador => {
            const y_lista = g.y + @as(i32, @intCast(ALT_TITULO_V + 24));
            if (y >= y_lista and v.expl.n > 0) {
                const fila: i32 = @divTrunc(y - y_lista, @as(i32, FUENTE_ALTO)) + @as(i32, @intCast(v.expl.scroll));
                if (fila >= 0 and fila < @as(i32, @intCast(v.expl.n))) {
                    // doble clic abre; clic selecciona
                    const id = (@as(u32, @intFromEnum(t)) << 8) | @as(u32, @intCast(fila)) | 0x80;
                    const doble = dobleClic(id);
                    v.expl.seleccion = @intCast(fila);
                    if (doble) {
                        explAbrir(v, &v.expl.entradas[@intCast(fila)]);
                        return;
                    }
                }
            }
            dibujarTodo();
        },
        .grupo_principal, .grupo_accesorios => clicGrupo(t, x, y),
        else => dibujarTodo(), // el foco ya se ha puesto
    }
}

fn clicGrupo(t: TipoApp, x: i32, y: i32) void {
    const v = &ventanas[@intFromEnum(t)];
    const g = geomVentana(v);
    const items = iconosDe(t);
    const cols: u32 = @max((v.an -| 16) / CELDA_AN, 1);
    const gx: i32 = @as(i32, @intCast((v.an -| (cols * CELDA_AN)) / 2));
    const gy: i32 = @as(i32, @intCast(ALT_TITULO_V + ALT_MENU_V + 10));
    const lx = x - g.x;
    const ly = y - g.y;
    if (lx < gx or ly < gy) {
        v.sel_icono = -1;
        dibujarTodo();
        return;
    }
    const col: usize = @intCast(@divTrunc(lx - gx, @as(i32, @intCast(CELDA_AN))));
    const fila: usize = @intCast(@divTrunc(ly - gy, @as(i32, @intCast(CELDA_AL))));
    const idx = fila * cols + col;
    if (idx >= items.len) {
        v.sel_icono = -1;
        dibujarTodo();
        return;
    }
    v.sel_icono = @intCast(idx);
    if (dobleClic((@as(u32, @intFromEnum(t)) << 8) | 0x40 | @as(u32, @intCast(idx)))) {
        lanzarIcono(items[idx]);
        return;
    }
    dibujarTodo();
}

fn lanzarIcono(it: ItemIcono) void {
    serial.puts("gui: icono lanza ");
    serial.puts(it.nombre);
    serial.puts("\n");
    switch (it.accion) {
        .ventana => |tv| abrirVentana(tv),
        .grupo => |tg| abrirVentana(tg),
        .alx => |ruta| lanzarAlx(ruta),
    }
}

fn lanzarAlx(ruta: []const u8) void {
    if (!alfs.montado()) {
        consola.puts("aviso: ALFS no esta montado\n");
        return;
    }
    const vol = alfs.actual().?;
    const idx = vol.resolver(ruta) catch {
        consola.puts("aviso: no encuentro ");
        consola.puts(ruta);
        consola.puts("\n");
        return;
    };
    if (!alx.esEjecutable(idx)) {
        consola.puts("aviso: ");
        consola.puts(ruta);
        consola.puts(" no es ejecutable\n");
        return;
    }
    _ = abrirApp(idx);
}

/// Clic sobre un icono del escritorio (ventana minimizada).
fn clicIconoEscritorio(x: i32, y: i32) void {
    var slot: u32 = 0;
    var t: u4 = 0;
    while (t < N_VENTANAS) : (t += 1) {
        const ta: TipoApp = @enumFromInt(t);
        const v = &ventanas[t];
        if (!(v.abierta and v.minimizada)) continue;
        const ix: i32 = @intCast(12 + slot * 92);
        const iy: i32 = @intCast(alto - 72);
        if (enRect(x, y, ix - 6, iy - 4, 92, 64)) {
            const id = (@as(u32, t) << 8) | 0xC0;
            if (dobleClic(id)) {
                restaurarVentana(ta, true);
            } else {
                icono_sel = ta;
                dibujarTodo();
            }
            return;
        }
        slot += 1;
    }
    if (icono_sel != null) {
        icono_sel = null;
        dibujarTodo();
    }
}

// ---------------------------------------------------------------------------
// eventos del teclado
// ---------------------------------------------------------------------------

fn procesarTecla(c: u8) void {
    // 0) menú abierto: ESC lo cierra, el resto se ignora (solo ratón)
    if (menu.abierto) {
        if (c == teclado.ESC) {
            menuCerrar();
            dibujarTodo();
        }
        return;
    }
    // 1) edición de geometría por teclado (Mover/Tamaño del menú ▼)
    if (edicion_geom != null) {
        teclasGeometria(c);
        return;
    }
    // 2) combinaciones con Alt: Tab, F4 y Espacio
    if (teclado.altPulsada()) {
        if (c == '\t') {
            altTab();
            return;
        }
        if (c == teclado.F4) {
            cerrarVentana(foco_ventana);
            return;
        }
        if (c == ' ') {
            menuControl(foco_ventana);
            return;
        }
    }
    // 3) la ventana enfocada debe existir y estar visible
    const vf = &ventanas[@intFromEnum(foco_ventana)];
    if (!vf.abierta or vf.minimizada) {
        if (!refocar()) return;
    }
    switch (foco_ventana) {
        .terminal => interprete.tecla(c),
        .chat => chatTecla(c),
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
        .adivina => {
            if (c == teclado.ESC) {
                cerrarVentana(.adivina);
                return;
            }
            const ev = apps.adivinaTecla(&ventanas[@intFromEnum(TipoApp.adivina)].adv, c);
            switch (ev) {
                .nada => {},
                .intento => serial.puts("gui: adivina intento\n"),
                .acierto => serial.puts("gui: adivina acierto\n"),
                .nueva => serial.puts("gui: adivina nueva\n"),
            }
            dibujarTodo();
        },
        .app => {
            if (c == teclado.ESC) {
                cerrarVentana(.app);
                return;
            }
            const v = &ventanas[@intFromEnum(TipoApp.app)];
            const cgeom = clienteDe(v, .app);
            despacharApp(&.{
                .tipo = alx_def.EV_TECLA,
                .tecla = c,
                .x = cgeom.x,
                .y = cgeom.y,
                .an = cgeom.an,
                .al = cgeom.al,
            });
            dibujarTodo();
        },
        .grupo_principal, .grupo_accesorios => teclasGrupo(c),
    }
}

/// Teclado de un grupo: flechas eligen icono, INTRO lo abre, ESC cierra.
fn teclasGrupo(c: u8) void {
    const v = &ventanas[@intFromEnum(foco_ventana)];
    const items = iconosDe(foco_ventana);
    const cols: i32 = @intCast(@max((v.an -| 16) / CELDA_AN, 1));
    const n: i32 = @intCast(items.len);
    const sel: i32 = v.sel_icono;
    switch (c) {
        teclado.ESC => cerrarVentana(foco_ventana),
        teclado.FLECHA_IZQ => {
            if (sel > 0) v.sel_icono -= 1;
            dibujarTodo();
        },
        teclado.FLECHA_DER => {
            if (sel < n - 1) v.sel_icono += 1;
            dibujarTodo();
        },
        teclado.FLECHA_ARRIBA => {
            if (sel >= cols) v.sel_icono -= @intCast(cols);
            dibujarTodo();
        },
        teclado.FLECHA_ABAJO => {
            if (sel + cols < n) v.sel_icono += @intCast(cols);
            dibujarTodo();
        },
        '\n' => {
            if (sel >= 0 and sel < n) lanzarIcono(items[@intCast(sel)]);
        },
        else => {},
    }
}

/// Mover/Tamaño por teclado (como en los escritorios clásicos): flechas
/// ajustan, INTRO confirma y ESC deja la ventana como estaba.
fn teclasGeometria(c: u8) void {
    const eg = &(edicion_geom.?);
    const v = &ventanas[@intFromEnum(eg.tipo)];
    const paso: i32 = 8;
    switch (c) {
        teclado.FLECHA_IZQ => {
            if (eg.modo == .mover) {
                v.x = std.math.clamp(v.x - paso, -@as(i32, @intCast(v.an)) + 80, @as(i32, @intCast(ancho)) - 40);
            } else if (v.an > AN_VENTANA_MIN + paso) {
                v.an -= paso;
            }
        },
        teclado.FLECHA_DER => {
            if (eg.modo == .mover) {
                v.x = std.math.clamp(v.x + paso, -@as(i32, @intCast(v.an)) + 80, @as(i32, @intCast(ancho)) - 40);
            } else if (v.an < ancho -| 8) {
                v.an += paso;
            }
        },
        teclado.FLECHA_ARRIBA => {
            if (eg.modo == .mover) {
                v.y = std.math.clamp(v.y - paso, 0, @as(i32, @intCast(alto)) - 40);
            } else if (v.al > AL_VENTANA_MIN + paso) {
                v.al -= paso;
            }
        },
        teclado.FLECHA_ABAJO => {
            if (eg.modo == .mover) {
                v.y = std.math.clamp(v.y + paso, 0, @as(i32, @intCast(alto)) - 40);
            } else if (v.al < alto -| 8) {
                v.al += paso;
            }
        },
        '\n' => {
            serial.puts(if (eg.modo == .mover) "gui: ventana movida " else "gui: ventana redimensionada ");
            serial.puts(nombreVentana(eg.tipo));
            serial.puts("\n");
            edicion_geom = null;
        },
        teclado.ESC => {
            v.x = eg.ox;
            v.y = eg.oy;
            v.an = eg.oan;
            v.al = eg.oal;
            edicion_geom = null;
        },
        else => return,
    }
    dibujarTodo();
}

/// Alt+Tab: siguiente ventana abierta (las minimizadas se restauran) y un
/// recuadro con su nombre, sin vista previa.
fn altTab() void {
    var i: u4 = @intFromEnum(foco_ventana);
    var intentos: u4 = 0;
    while (intentos < N_VENTANAS) : (intentos += 1) {
        i = (i + 1) % N_VENTANAS;
        if (!ventanas[i].abierta) continue;
        const t: TipoApp = @enumFromInt(i);
        if (ventanas[i].minimizada) restaurarVentana(t, false);
        enfocarVentana(t, false);
        const nombre = nombreVentana(t);
        const l = @min(nombre.len, alttab_nombre.len);
        @memcpy(alttab_nombre[0..l], nombre[0..l]);
        alttab_len = @intCast(l);
        alttab_hasta = pit.leerTics() + 50; // visible medio segundo
        serial.puts("gui: alt-tab -> ");
        serial.puts(nombre);
        serial.puts("\n");
        dibujarTodo();
        return;
    }
}

// ---------------------------------------------------------------------------
// chat de AntLex
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Fase 7 — API de aplicaciones externas (.ALX)
// ---------------------------------------------------------------------------

/// Origen del área de cliente mientras se atiende un evento de la app.
var alx_origen_x: i32 = 0;
var alx_origen_y: i32 = 0;
/// `tam()` solo se acepta durante EV_INIT.
var alx_en_init = false;

/// Entrega un evento a la app externa cargada (si la hay).
fn despacharApp(ev: *const alx_def.Evento) void {
    const entrada = alx.entrada() orelse return;
    alx_origen_x = ev.x;
    alx_origen_y = ev.y;
    entrada(&api_alx, ev);
}

const api_alx = alx_def.Api{
    .texto = alxTexto,
    .textoLim = alxTextoLim,
    .rect = alxRect,
    .bisel = alxBisel,
    .tam = alxTam,
    .titulo = alxTitulo,
    .tics = alxTics,
    .hora = alxHora,
    .consola = alxConsola,
    .leer = alxLeer,
    .escribir = alxEscribir,
};

fn alxTexto(x: i32, y: i32, str: [*:0]const u8, color: u32) callconv(.c) void {
    const px = alx_origen_x + x;
    const py = alx_origen_y + y;
    if (px < 0 or py < 0) return;
    texto(@intCast(px), @intCast(py), std.mem.span(str), color);
}

fn alxTextoLim(x: i32, y: i32, str: [*:0]const u8, color: u32, max: u32) callconv(.c) void {
    const px = alx_origen_x + x;
    const py = alx_origen_y + y;
    if (px < 0 or py < 0) return;
    textoLim(@intCast(px), @intCast(py), std.mem.span(str), color, max);
}

fn alxRect(x: i32, y: i32, an: u32, al: u32, color: u32) callconv(.c) void {
    const px = alx_origen_x + x;
    const py = alx_origen_y + y;
    if (px < 0 or py < 0) return;
    pantalla.rect(@intCast(px), @intCast(py), an, al, color);
}

/// Relieve biselado 3D: claro arriba/izquierda, oscuro abajo/derecha
/// (invertido si está hundido). El estilo clásico del escritorio.
fn alxBisel(x: i32, y: i32, an: u32, al: u32, hundido: bool) callconv(.c) void {
    const claro = pantalla.rgb(0xEF, 0xEF, 0xE3);
    const oscuro = pantalla.rgb(0x50, 0x50, 0x46);
    const arriba = if (hundido) oscuro else claro;
    const abajo = if (hundido) claro else oscuro;
    alxRect(x, y, an, 1, arriba);
    alxRect(x, y, 1, al, arriba);
    alxRect(x, y + @as(i32, @intCast(al)) - 1, an, 1, abajo);
    alxRect(x + @as(i32, @intCast(an)) - 1, y, 1, al, abajo);
}

fn alxTam(an: u32, al: u32) callconv(.c) void {
    if (!alx_en_init) return; // solo durante EV_INIT
    const v = &ventanas[@intFromEnum(TipoApp.app)];
    v.an = @min(@max(an, 120), 600);
    v.al = @min(@max(al, 80), 400);
}

fn alxTitulo(str: [*:0]const u8) callconv(.c) void {
    const v = &ventanas[@intFromEnum(TipoApp.app)];
    const t = std.mem.span(str);
    const l = @min(t.len, v.app_titulo.len);
    @memcpy(v.app_titulo[0..l], t[0..l]);
    v.app_titulo_len = @intCast(l);
}

fn alxTics() callconv(.c) u32 {
    return @truncate(pit.leerTics());
}

fn alxHora() callconv(.c) u32 {
    const f = reloj.leer();
    return (@as(u32, f.hora) * 100 + f.min) * 100 + f.seg;
}

fn alxConsola(str: [*:0]const u8) callconv(.c) void {
    const t = std.mem.span(str);
    consola.puts(t);
    serial.puts(t);
}

fn alxLeer(ruta: [*:0]const u8, buf: [*]u8, cap: u32) callconv(.c) i32 {
    if (!alfs.montado()) return -1;
    const vol = alfs.actual() orelse return -1;
    const idx = vol.resolver(std.mem.span(ruta)) catch return -1;
    const tam = vol.tamDe(idx) catch return -1;
    if (tam > cap) return -1;
    const n = vol.leer(idx, buf[0..tam]) catch return -1;
    return @intCast(n);
}

fn alxEscribir(ruta: [*:0]const u8, buf: [*]const u8, len: u32) callconv(.c) i32 {
    if (!alfs.montado()) return -1;
    const vol = alfs.actual() orelse return -1;
    const rp = std.mem.span(ruta);
    const contenido = buf[0..len];
    if (vol.resolver(rp)) |idx| {
        vol.escribir(idx, contenido) catch return -1;
    } else |_| {
        // crear: separar padre y nombre por la última '/'
        const i = std.mem.lastIndexOfScalar(u8, rp, '/') orelse return -1;
        if (i == 0 or i + 1 >= rp.len) return -1;
        const padre = vol.resolver(rp[0..i]) catch return -1;
        _ = vol.crear(padre, rp[i + 1 ..], fmt.TIPO_ARCHIVO, contenido) catch return -1;
    }
    alfs.marcar();
    return 0;
}

/// Carga la app .ALX `idx` y abre su ventana (desde `ejecutar`, `abrir`,
/// un icono o el explorador). Devuelve false con el error en consola.
pub fn abrirApp(idx: u16) bool {
    if (ventanas[@intFromEnum(TipoApp.app)].abierta) cerrarVentana(.app);
    const entrada = alx.cargar(idx) catch |err| {
        const msg = switch (err) {
            alx.Error.SinAlfs => "ALFS no esta montado",
            alx.Error.TamGrande => "el .ALX es demasiado grande",
            alx.Error.CabeceraInvalida => "cabecera .ALX invalida",
            alx.Error.SinMemoria => "sin memoria para cargar la app",
            alx.Error.LecturaAlfs => "fallo leyendo el .ALX",
        };
        consola.puts("error: ");
        consola.puts(msg);
        consola.puts("\n");
        serial.puts("alx: error: ");
        serial.puts(msg);
        serial.puts("\n");
        return false;
    };
    _ = entrada;
    const v = &ventanas[@intFromEnum(TipoApp.app)];
    v.abierta = false; // la abre abrirVentana()
    v.minimizada = false;
    v.maximizada = false;
    v.x = 300;
    v.y = 140;
    v.an = 320;
    v.al = 240;
    v.app_titulo_len = 0;
    const t = alx.nombreStr();
    const l = @min(t.len, v.app_titulo.len);
    @memcpy(v.app_titulo[0..l], t[0..l]);
    v.app_titulo_len = @intCast(l);
    // EV_INIT: la app define título y tamaño antes del primer dibujado
    alx_en_init = true;
    const c0 = clienteDe(v, .app);
    despacharApp(&.{
        .tipo = alx_def.EV_INIT,
        .tecla = 0,
        .x = c0.x,
        .y = c0.y,
        .an = c0.an,
        .al = c0.al,
    });
    alx_en_init = false;
    abrirVentana(.app);
    return true;
}

// ---------------------------------------------------------------------------
// pegamento con ALFS (explorador y editor)
// ---------------------------------------------------------------------------

const CtxExpl = struct { e: *apps.Explorador };

fn cbHijos(ctx: *CtxExpl, idx: u16, ent: *const fmt.Entrada) void {
    apps.explAnadir(ctx.e, idx, ent.tipo, ent.flags, ent.nombre[0..ent.nombre_len]);
}

fn explListar(v: *Ventana) void {
    v.expl = .{};
    if (alfs.montado()) {
        const vol = alfs.actual().?;
        var ctx = CtxExpl{ .e = &v.expl };
        vol.hijosDe(v.expl_dir, &ctx, cbHijos);
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
    } else if (alx_def.esAlx(nombre)) {
        // ejecutable .ALX: hace falta el bit de ejecutable (instalar)
        if (alx.esEjecutable(idx)) {
            _ = abrirApp(idx);
        } else {
            serial.puts("gui: explorador: sin bit de ejecutable\n");
            consola.puts("aviso: ");
            consola.puts(nombre);
            consola.puts(" no es ejecutable (usa 'instalar ");
            consola.puts(nombre);
            consola.puts("')\n");
            dibujarTodo();
        }
    } else {
        editorAbrir(idx, nombre);
    }
}

/// Abre el archivo `idx` en el editor (desde el explorador o `abrir`).
pub fn editorAbrir(idx: u16, nombre: []const u8) void {
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

// ---------------------------------------------------------------------------
// bucle principal del escritorio
// ---------------------------------------------------------------------------

pub fn bucle() noreturn {
    serial.puts("ESCRITORIO LISTO\n");
    while (true) {
        x86.hlt();
        while (teclado.poll()) |c| procesarTecla(c);
        while (raton.poll()) |ev| procesarRaton(ev);
        // reloj de 1 Hz: tick para la app externa y caja Alt+Tab caducada
        const s = pit.uptimeSeg();
        if (s != ult_seg) {
            ult_seg = s;
            if (ventanas[@intFromEnum(TipoApp.app)].abierta and !ventanas[@intFromEnum(TipoApp.app)].minimizada) {
                const v = &ventanas[@intFromEnum(TipoApp.app)];
                const cgeom = clienteDe(v, .app);
                despacharApp(&.{
                    .tipo = alx_def.EV_TICK,
                    .tecla = 0,
                    .x = cgeom.x,
                    .y = cgeom.y,
                    .an = cgeom.an,
                    .al = cgeom.al,
                });
                dibujarTodo();
            } else if (pit.leerTics() < alttab_hasta) {
                dibujarTodo(); // mantiene la caja Alt+Tab hasta que caduque
            }
        }
    }
}
