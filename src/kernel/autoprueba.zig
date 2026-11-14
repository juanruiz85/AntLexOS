//! AntLex OS — autopruebas del kernel: cada comprobación vuelca
//! "[ OK ]" o "[FALLA]" por el puerto serie y las resume al final.
//! tools/probar_boot.py parsea esta salida para decidir si el arranque pasa.

const std = @import("std");
const serial = @import("serial.zig");
const consola = @import("consola.zig");
const boot_info = @import("boot_info.zig");
const pantalla = @import("pantalla.zig");
const fuente = @import("fuente.zig");
const teclado = @import("teclado.zig");
const mem = @import("mem.zig");
const pit = @import("pit.zig");
const reloj = @import("reloj.zig");
const x86 = @import("x86.zig");
const version = @import("version.zig");
const ata = @import("ata.zig");
const alfs = @import("alfs.zig");
const red = @import("red.zig");
const fmt = @import("alfs_formato.zig");
const antlex = @import("antlex.zig");
const raton = @import("raton.zig");

var pasan: u32 = 0;
var fallan: u32 = 0;

/// Cuando está activo, la salida también se dibuja en la consola gráfica
/// (lo usa el comando `pruebas` del intérprete).
var eco_consola = false;

pub fn activarEcoConsola(v: bool) void {
    eco_consola = v;
}

fn eco(txt: []const u8) void {
    serial.puts(txt);
    if (eco_consola) consola.puts(txt);
}

fn comprobar(nombre: []const u8, ok: bool, detalle: []const u8) void {
    if (ok) {
        pasan += 1;
        eco("[ OK ] ");
    } else {
        fallan += 1;
        eco("[FALLA] ");
    }
    eco(nombre);
    if (detalle.len > 0) {
        eco(" -> ");
        eco(detalle);
    }
    eco("\n");
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

    // 1) boot_info (protocolo v2)
    comprobar("boot_info", bi.magic == 0x42584C41 and bi.version == 2, "magic ALXB v2");

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
    const t0 = pit.leerTics();
    pit.esperaTics(3);
    comprobar("pit_tics", pit.leerTics() >= t0 + 3, "3 tics a 100 Hz");

    // 9) disco ATA
    comprobar("ata_identify", ata.estaDisponible() and ata.modelo().len > 0, "disco identificado");

    // 10) ALFS montado
    comprobar("alfs_montado", alfs.montado() and alfs.actual() != null, "volumen validado en RAM");

    // 11) operaciones ALFS (en RAM; el disco no se toca)
    if (alfs.actual()) |v| {
        var ok_ops = true;
        // crear archivo en la raíz (un fallo se registra y salta al resumen:
        // el arnés debe ver el marcador final siempre)
        crear: {
            const idx = v.crear(fmt.RAIZ, "autopru.txt", fmt.TIPO_ARCHIVO, "prueba interna") catch |e| {
                comprobar("alfs_operaciones", false, @errorName(e));
                break :crear;
            };
            // leer y comparar
            var buf: [32]u8 = undefined;
            const n = v.leer(idx, &buf) catch 0;
            if (n != 14 or !std.mem.eql(u8, buf[0..n], "prueba interna")) ok_ops = false;
            // crear directorio + archivo dentro + resolver con ..
            const d = v.crear(fmt.RAIZ, "autopdir", fmt.TIPO_DIRECTORIO, "") catch 0;
            if (d != 0) {
                _ = v.crear(d, "hijo.txt", fmt.TIPO_ARCHIVO, "x") catch {
                    ok_ops = false;
                };
                const r = v.resolverDesde(d, "../autopru.txt") catch 0;
                if (r != idx) ok_ops = false;
                _ = v.borrar(v.resolverDesde(d, "hijo.txt") catch 0) catch {
                    ok_ops = false;
                };
                v.borrar(d) catch {
                    ok_ops = false;
                };
            } else ok_ops = false;
            // borrar el archivo de prueba (deja el volumen como estaba)
            v.borrar(idx) catch {
                ok_ops = false;
            };
            comprobar("alfs_operaciones", ok_ops, "crear/leer/rutas/borrar en RAM");
        }
    } else {
        comprobar("alfs_operaciones", false, "ALFS no montado");
    }

    // 12) reloj de tiempo real (CMOS)
    const f = reloj.leer();
    comprobar("reloj_rtc", reloj.valida(f), "fecha y hora del CMOS");

    // 13) IA AntLex: las preguntas canónicas deben clasificar a su intención
    // (y las ajenas, rechazarse) con la inferencia de punto fijo embebida
    {
        const c = antlex.autopruebaCanonica();
        var dbuf: [64]u8 = undefined;
        comprobar("antlex_canonica", c.aciertos == c.total, std.fmt.bufPrint(&dbuf, "{d}/{d} preguntas canonicas (red embebida)", .{ c.aciertos, c.total }) catch "preguntas canonicas");
    }

    // 14) ratón PS/2: decodificación de paquetes y acotado del cursor
    {
        var ok14 = true;
        var mov = raton.decodificar(.{ 0x08, 40, 0 });
        ok14 = ok14 and mov.dx == 40 and mov.dy == 0 and mov.botones == 0;
        mov = raton.decodificar(.{ 0x38, 0xE2, 0xFD }); // dx negativo
        ok14 = ok14 and mov.dx == -30 and mov.dy == -3;
        mov = raton.decodificar(.{ 0x09, 0, 0 });
        ok14 = ok14 and mov.botones == 1; // botón izquierdo
        ok14 = ok14 and raton.decodificar(.{ 0x48, 1, 1 }).desborde; // overflow
        ok14 = ok14 and raton.acotar(-25, 0, 1023) == 0 and raton.acotar(4096, 0, 1023) == 1023;
        comprobar("raton_paquetes", ok14, "decodificacion y acotado PS/2");
    }

    // 15) red (Fase 9): checksums y paquetes ARP/IPv4/ICMP bien formados.
    // Lógica pura: el propio dispositivo se prueba con el arnés probar_red.py
    comprobar("red_paquetes", red.autopruebaPaquetes(), "checksum, ARP e ICMP bien formados");

    // resumen
    var nbuf: [48]u8 = undefined;
    eco("AUTOPRUEBAS ");
    eco(std.fmt.bufPrint(&nbuf, "{d}/{d} correctas", .{ pasan, pasan + fallan }) catch "?/?");
    eco("\n");
    if (fallan == 0) {
        eco("ANTLEX BOOT OK v");
        eco(version.VERSION);
        eco("\n");
    } else {
        eco("ANTLEX BOOT CON ERRORES\n");
    }
}
