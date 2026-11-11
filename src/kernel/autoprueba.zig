//! AntLex OS — autopruebas del kernel: cada comprobación vuelca
//! "[ OK ]" o "[FALLA]" por el puerto serie y las resume al final.
//! tools/probar_boot.py parsea esta salida para decidir si el arranque pasa.

const serial = @import("serial.zig");
const boot_info = @import("boot_info.zig");
const pantalla = @import("pantalla.zig");
const fuente = @import("fuente.zig");
const teclado = @import("teclado.zig");
const mem = @import("mem.zig");
const pit = @import("pit.zig");
const x86 = @import("x86.zig");
const version = @import("version.zig");

var pasan: u32 = 0;
var fallan: u32 = 0;

fn comprobar(nombre: []const u8, ok: bool, detalle: []const u8) void {
    if (ok) {
        pasan += 1;
        serial.puts("[ OK ] ");
    } else {
        fallan += 1;
        serial.puts("[FALLA] ");
    }
    serial.puts(nombre);
    if (detalle.len > 0) {
        serial.puts(" -> ");
        serial.puts(detalle);
    }
    serial.puts("\n");
}

pub fn ultimaCuenta() struct { pasan: u32, fallan: u32 } {
    return .{ .pasan = pasan, .fallan = fallan };
}

/// Ejecuta la batería de autopruebas (requiere interrupciones activadas para
/// la prueba del temporizador).
pub fn ejecutar(bi: *const boot_info.BootInfo) void {
    pasan = 0;
    fallan = 0;
    serial.puts("\n== AUTOPRUEBAS AntLex OS v");
    serial.puts(version.VERSION);
    serial.puts(" ==\n");

    // 1) boot_info
    comprobar("boot_info", bi.magic == 0x42584C41 and bi.version == 1, "magic ALXB v1");

    // 2) framebuffer
    comprobar(
        "framebuffer",
        pantalla.anchoPix() >= 640 and pantalla.altoPix() >= 480 and pantalla.pasoBytes() >= pantalla.anchoPix() * 4,
        "modo grafico activo",
    );

    // 3) mapa de memoria
    const entradas = bi.memmap_count;
    const total = boot_info.memoriaTotal(bi);
    comprobar("mapa_e820", entradas > 0 and total > 16 * 1024 * 1024, "regiones usables detectadas");

    // 4) CPU
    var marca = [_]u8{0} ** 48;
    x86.cpuidMarca(&marca);
    const marca_txt = marca[0..marca.len];
    var marca_valida = false;
    for (marca_txt) |c| {
        if (c != 0 and c != ' ') marca_valida = true;
    }
    comprobar("cpu_cpuid", marca_valida, "identificacion de marca del procesador");

    // 5) fuente
    const a_ok = fuente.indice('A') != null;
    const enie_ok = fuente.indice(0xF1) != null; // ñ
    const interrogacion = fuente.indice(0xBF) != null; // ¿
    comprobar("fuente_bitmap", a_ok and enie_ok and interrogacion, "glifos A, ñ y ¿ presentes");

    // 6) teclado
    comprobar("teclado_es", teclado.fijarDistribucion("es"), "distribucion espanola activa");

    // 7) memoria dinámica
    const p1 = mem.alloc(1024, 16) catch null;
    const p2 = mem.alloc(4096, 4096) catch null;
    const alineado = if (p2) |p| p % 4096 == 0 else false;
    comprobar("mem_alloc", p1 != null and p2 != null and alineado, "asignador secuencial");

    // 8) temporizador (necesita interrupciones)
    const t0 = pit.tics;
    pit.esperaTics(3);
    comprobar("pit_tics", pit.tics >= t0 + 3, "3 tics a 100 Hz");

    // resumen
    serial.puts("AUTOPRUEBAS ");
    serial.putDec(pasan);
    serial.putc('/');
    serial.putDec(pasan + fallan);
    serial.puts(" correctas\n");
    if (fallan == 0) {
        serial.puts("ANTLEX BOOT OK v");
        serial.puts(version.VERSION);
        serial.puts("\n");
    } else {
        serial.puts("ANTLEX BOOT CON ERRORES\n");
    }
}
