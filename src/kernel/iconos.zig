//! AntLex OS — iconos.zig (Fase 8): iconos de 32×32 y miniaturas de 14×14
//! dibujados con rectángulos sobre el framebuffer, estilo clásico de
//! escritorio. Cada icono es arte ORIGINAL del proyecto (no se copian
//! recursos de terceros); las formas evocan las metáforas de siempre:
//! carpeta, página, pantalla, dado…
//!
//! Se usa desde la GUI: iconos de los grupos (Administrador de Programas),
//! iconos de ventanas minimizadas sobre el escritorio y miniaturas en la
//! barra de título.

const pantalla = @import("pantalla.zig");
const fuente = @import("fuente.zig");

pub const TAM: u32 = 32;

// paleta de los iconos
const NEGRO = pantalla.rgb(0x00, 0x00, 0x00);
const BLANCO = pantalla.rgb(0xFF, 0xFF, 0xFF);
const GRIS = pantalla.rgb(0xC0, 0xC0, 0xC0);
const GRIS_OSC = pantalla.rgb(0x80, 0x80, 0x80);
const AZUL = pantalla.rgb(0x00, 0x00, 0x80);
const AZUL_CLARO = pantalla.rgb(0x3A, 0x6E, 0xC8);
const AMARILLO = pantalla.rgb(0xFF, 0xD8, 0x00);
const AMARILLO_OSC = pantalla.rgb(0xC0, 0x98, 0x00);
const VERDE = pantalla.rgb(0x00, 0x88, 0x30);
const VERDE_LUZ = pantalla.rgb(0x60, 0xF0, 0x80);
const ROJO = pantalla.rgb(0xC0, 0x20, 0x20);
const NEGRO_PANT = pantalla.rgb(0x0A, 0x0E, 0x16);

pub const Icono = enum {
    grupo,
    explorador,
    editor,
    terminal,
    chat,
    adivina,
    calculadora,
    reloj,
    acerca,
    sistema,
};

fn rect(x: u32, y: u32, an: u32, al: u32, color: u32) void {
    pantalla.rect(x, y, an, al, color);
}

/// Dibuja el icono de 32×32 en (x, y).
pub fn dibujar(i: Icono, x: u32, y: u32) void {
    switch (i) {
        .grupo => iconoGrupo(x, y),
        .explorador => iconoExplorador(x, y),
        .editor => iconoEditor(x, y),
        .terminal => iconoTerminal(x, y),
        .chat => iconoChat(x, y),
        .adivina => iconoAdivina(x, y),
        .calculadora => iconoCalculadora(x, y),
        .reloj => iconoReloj(x, y),
        .acerca => iconoAcerca(x, y),
        .sistema => iconoSistema(x, y),
    }
}

/// Miniatura de 14×14 para la barra de título.
pub fn dibujarMini(i: Icono, x: u32, y: u32) void {
    // ventana genérica de 12×11 con una franja del color del icono
    rect(x, y, 12, 11, GRIS);
    rect(x, y, 12, 1, BLANCO);
    rect(x, y, 1, 11, BLANCO);
    rect(x, y + 10, 12, 1, GRIS_OSC);
    rect(x + 11, y, 1, 11, GRIS_OSC);
    rect(x + 1, y + 1, 10, 3, AZUL);
    const tinta: u32 = switch (i) {
        .explorador => AMARILLO_OSC,
        .editor, .acerca => BLANCO,
        .terminal => VERDE_LUZ,
        .chat => AZUL_CLARO,
        .adivina => ROJO,
        .calculadora => VERDE,
        .reloj => NEGRO,
        .grupo => AMARILLO,
        .sistema => VERDE,
    };
    rect(x + 2, y + 6, 8, 3, tinta);
}

// ---------------------------------------------------------------------------
// Los iconos (32×32 cada uno)
// ---------------------------------------------------------------------------

/// Grupo de programas: ventana con dos programitas dentro.
fn iconoGrupo(x: u32, y: u32) void {
    ventanaBase(x + 2, y + 4, 28, 25);
    // dos iconos dentro: una carpeta y una página
    rect(x + 6, y + 12, 8, 6, AMARILLO);
    rect(x + 6, y + 10, 4, 2, AMARILLO);
    rect(x + 6, y + 12, 8, 1, AMARILLO_OSC);
    rect(x + 18, y + 11, 7, 10, BLANCO);
    rect(x + 18, y + 11, 7, 1, GRIS_OSC);
    rect(x + 18, y + 20, 7, 1, GRIS_OSC);
    rect(x + 22, y + 11, 1, 10, GRIS_OSC);
    rect(x + 20, y + 14, 4, 1, AZUL);
    rect(x + 20, y + 16, 4, 1, GRIS_OSC);
    rect(x + 20, y + 18, 4, 1, GRIS_OSC);
}

/// Explorador: carpeta amarilla con pestaña.
fn iconoExplorador(x: u32, y: u32) void {
    rect(x + 2, y + 8, 13, 4, AMARILLO); // pestaña
        rect(x + 2, y + 8, 13, 1, AMARILLO_OSC);
        rect(x + 2, y + 11, 3, 2, AMARILLO);
        rect(x + 1, y + 12, 30, 16, AMARILLO); // cuerpo
        rect(x + 1, y + 12, 30, 2, pantalla.rgb(0xFF, 0xF0, 0x60)); // brillo sup.
        rect(x + 1, y + 27, 30, 1, AMARILLO_OSC);
    rect(x + 1, y + 12, 1, 16, AMARILLO_OSC);
    rect(x + 30, y + 12, 1, 16, AMARILLO_OSC);
        rect(x + 5, y + 17, 22, 2, AMARILLO_OSC); // líneas de contenido
    rect(x + 5, y + 21, 22, 2, AMARILLO_OSC);
    rect(x + 5, y + 25, 14, 2, AMARILLO_OSC);
    }

/// Editor: página con esquina doblada y líneas de texto.
fn iconoEditor(x: u32, y: u32) void {
    rect(x + 7, y + 3, 18, 26, BLANCO);
    rect(x + 7, y + 3, 18, 1, GRIS_OSC);
    rect(x + 7, y + 3, 1, 26, GRIS_OSC);
    rect(x + 7, y + 28, 18, 1, GRIS_OSC);
    rect(x + 24, y + 3, 1, 26, GRIS_OSC);
    // esquina doblada
    rect(x + 20, y + 3, 5, 5, GRIS);
    rect(x + 21, y + 4, 3, 3, BLANCO);
    // líneas de texto
    rect(x + 10, y + 11, 12, 2, AZUL);
    rect(x + 10, y + 15, 12, 2, GRIS_OSC);
    rect(x + 10, y + 19, 12, 2, GRIS_OSC);
    rect(x + 10, y + 23, 7, 2, GRIS_OSC);
}

/// Terminal: monitor con prompt ">_".
fn iconoTerminal(x: u32, y: u32) void {
    rect(x + 2, y + 4, 28, 22, GRIS);
    rect(x + 2, y + 4, 28, 1, BLANCO);
    rect(x + 2, y + 4, 1, 22, BLANCO);
    rect(x + 2, y + 25, 28, 1, GRIS_OSC);
    rect(x + 29, y + 4, 1, 22, GRIS_OSC);
    rect(x + 5, y + 7, 22, 16, NEGRO_PANT);
    rect(x + 5, y + 7, 22, 1, GRIS_OSC);
    fuente.dibujar(x + 8, y + 10, '>', VERDE_LUZ, null, 1);
    fuente.dibujar(x + 18, y + 10, '_', VERDE_LUZ, null, 1);
    // pie
    rect(x + 13, y + 26, 6, 3, GRIS_OSC);
    rect(x + 8, y + 29, 16, 2, GRIS);
}

/// Chat: dos bocadillos de diálogo.
fn iconoChat(x: u32, y: u32) void {
    // bocadillo trasero (azul)
    rect(x + 12, y + 3, 18, 11, AZUL_CLARO);
    rect(x + 12, y + 3, 18, 1, AZUL);
    rect(x + 12, y + 13, 18, 1, AZUL);
    rect(x + 12, y + 3, 1, 11, AZUL);
    rect(x + 29, y + 3, 1, 11, AZUL);
    rect(x + 15, y + 14, 4, 3, AZUL_CLARO);
    // bocadillo delantero (blanco)
    rect(x + 2, y + 13, 18, 11, BLANCO);
    rect(x + 2, y + 13, 18, 1, GRIS_OSC);
    rect(x + 2, y + 23, 18, 1, GRIS_OSC);
    rect(x + 2, y + 13, 1, 11, GRIS_OSC);
    rect(x + 19, y + 13, 1, 11, GRIS_OSC);
    rect(x + 5, y + 24, 4, 3, BLANCO);
    // puntos de conversación
    rect(x + 6, y + 17, 3, 3, AZUL);
    rect(x + 11, y + 17, 3, 3, AZUL);
    rect(x + 16, y + 17, 3, 3, AZUL);
    rect(x + 17, y + 6, 3, 3, BLANCO);
    rect(x + 22, y + 6, 3, 3, BLANCO);
}

/// Adivina: dado con pipas.
fn iconoAdivina(x: u32, y: u32) void {
    rect(x + 4, y + 4, 24, 24, BLANCO);
    rect(x + 4, y + 4, 24, 1, GRIS_OSC);
    rect(x + 4, y + 27, 24, 1, GRIS_OSC);
    rect(x + 4, y + 4, 1, 24, GRIS_OSC);
    rect(x + 27, y + 4, 1, 24, GRIS_OSC);
    // pipas: 4 en esquinas + centro (la cara del 5)
    rect(x + 9, y + 9, 4, 4, NEGRO);
    rect(x + 19, y + 9, 4, 4, NEGRO);
    rect(x + 9, y + 19, 4, 4, NEGRO);
    rect(x + 19, y + 19, 4, 4, NEGRO);
    rect(x + 14, y + 14, 4, 4, ROJO); // centro marcado
}

/// Calculadora: cuerpo gris, display verde y botones.
fn iconoCalculadora(x: u32, y: u32) void {
    rect(x + 5, y + 2, 22, 28, GRIS);
    rect(x + 5, y + 2, 22, 1, BLANCO);
    rect(x + 5, y + 2, 1, 28, BLANCO);
    rect(x + 5, y + 29, 22, 1, GRIS_OSC);
    rect(x + 26, y + 2, 1, 28, GRIS_OSC);
    // display
    rect(x + 8, y + 5, 16, 6, NEGRO_PANT);
    rect(x + 10, y + 7, 10, 2, VERDE_LUZ);
    // botones 3×3 + la tecla roja de C
    var f: u32 = 0;
    while (f < 3) : (f += 1) {
        var c: u32 = 0;
        while (c < 3) : (c += 1) {
            rect(x + 8 + c * 6, y + 14 + f * 6, 4, 4, GRIS_OSC);
        }
    }
    rect(x + 8 + 2 * 6, y + 14, 4, 4, ROJO);
}

/// Reloj: caja con esfera y agujas.
fn iconoReloj(x: u32, y: u32) void {
    rect(x + 9, y + 1, 14, 4, GRIS); // campana sup.
    rect(x + 6, y + 5, 20, 23, BLANCO);
    rect(x + 6, y + 5, 20, 1, GRIS_OSC);
    rect(x + 6, y + 27, 20, 1, GRIS_OSC);
    rect(x + 6, y + 5, 1, 23, GRIS_OSC);
    rect(x + 25, y + 5, 1, 23, GRIS_OSC);
    rect(x + 8, y + 7, 16, 3, AZUL); // franja sup. de esfera
    // agujas
    rect(x + 15, y + 12, 2, 6, NEGRO); // minutero (arriba)
    rect(x + 15, y + 17, 7, 2, NEGRO); // horario (derecha)
    rect(x + 14, y + 16, 4, 4, ROJO); // centro
    rect(x + 10, y + 28, 12, 2, GRIS_OSC); // pie
}

/// Acerca de: círculo azul con «i».
fn iconoAcerca(x: u32, y: u32) void {
    // círculo aproximado por filas (10..21 centro)
    rect(x + 10, y + 4, 12, 2, AZUL);
    rect(x + 7, y + 6, 18, 3, AZUL);
    rect(x + 6, y + 9, 20, 12, AZUL);
    rect(x + 7, y + 21, 18, 3, AZUL);
    rect(x + 10, y + 24, 12, 2, AZUL);
    rect(x + 11, y + 5, 10, 1, AZUL_CLARO); // brillo
    // la «i»
    rect(x + 14, y + 8, 4, 4, BLANCO);
    rect(x + 14, y + 14, 4, 9, BLANCO);
}

/// App externa genérica (.ALX): ventana con una pieza de puzle verde.
fn iconoSistema(x: u32, y: u32) void {
    ventanaBase(x + 3, y + 3, 26, 26);
    // puzle: bloque con pestaña
    rect(x + 10, y + 11, 12, 11, VERDE);
    rect(x + 10, y + 11, 12, 1, VERDE_LUZ);
    rect(x + 14, y + 8, 4, 4, VERDE); // pestaña sup.
    rect(x + 9, y + 14, 3, 4, VERDE); // pestaña izq.
    rect(x + 10, y + 21, 12, 1, pantalla.rgb(0x00, 0x60, 0x20));
}

/// Ventana base para los iconos que la llevan (grupo, sistema): cara gris,
/// borde biselado y barra de título azul.
fn ventanaBase(x: u32, y: u32, an: u32, al: u32) void {
    rect(x, y, an, al, GRIS);
    rect(x, y, an, 1, BLANCO);
    rect(x, y, 1, al, BLANCO);
    rect(x, y + al - 1, an, 1, GRIS_OSC);
    rect(x + an - 1, y, 1, al, GRIS_OSC);
    rect(x + 1, y + 1, an - 2, 3, AZUL);
}
