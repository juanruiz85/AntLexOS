#!/usr/bin/env python3
"""Re-aplica los parches de la fase 9b (sesión 4) tras un reciclado del
sandbox. Idempotente: falla si un parche ya está aplicado."""
import sys

OK = []


def parche(archivo, viejo, nuevo, nombre):
    s = open(archivo).read()
    if nuevo in s:
        print(f"  ya aplicado: {nombre}")
        return
    if viejo not in s:
        print(f"  !! no encuentro el ancla de «{nombre}» en {archivo}")
        sys.exit(1)
    open(archivo, "w").write(s.replace(viejo, nuevo))
    OK.append(nombre)


# ---------------------------------------------------------------- tls.zig ---
T = "src/kernel/tls.zig"

# 1) CertificateVerify: 64 espacios 0x20 previos al contexto (RFC 8446 §4.4.3)
parche(T, '''    const h_cert = hashDe(&trans);
    const contexto = "TLS 1.3, server CertificateVerify";
    var contenido_firmado: [96]u8 = undefined;
    @memcpy(contenido_firmado[0..contexto.len], contexto);
    contenido_firmado[contexto.len] = 0;
    @memcpy(contenido_firmado[contexto.len + 1 ..][0..32], &h_cert);
    const lon_firmado = contexto.len + 1 + 32;''',
'''    const h_cert = hashDe(&trans);
    const contexto = "TLS 1.3, server CertificateVerify";
    // contenido firmado (RFC 8446 §4.4.3): 64 bytes 0x20 (espacio) +
    // cadena de contexto + un byte 0 separador + hash de la transcripción.
    // Los 64 espacios son los que faltaban.
    var contenido_firmado: [64 + 34 + 32]u8 = undefined;
    @memset(contenido_firmado[0..64], 0x20);
    @memcpy(contenido_firmado[64..][0..contexto.len], contexto);
    contenido_firmado[64 + contexto.len] = 0;
    @memcpy(contenido_firmado[64 + contexto.len + 1 ..][0..32], &h_cert);
    const lon_firmado = 64 + contexto.len + 1 + 32;''', "CV 64 espacios")

# 2) finished = tipo 20 (0x14), no 14
parche(T, '''        11 => return procesarCertificate(msj),
        15 => return procesarCertificateVerify(msj),
        14 => return procesarFinishedServidor(msj),''',
'''        11 => return procesarCertificate(msj),
        15 => return procesarCertificateVerify(msj),
        20 => return procesarFinishedServidor(msj), // finished = 0x14''',
       "despacharMensaje finished=20")
parche(T, '''            var fin_msj: [36]u8 = undefined;
            fin_msj[0] = 14;''',
'''            var fin_msj: [36]u8 = undefined;
            fin_msj[0] = 20; // finished = 0x14''', "fin_msj tipo 20")

# 3) traza del error exacto al verificar con una raíz (diagnóstico serie)
parche(T, '''fn tryVerificarConRaiz(ultima: Certificado, raiz_der: []const u8, ahora: i64) bool {
    const raiz = Certificado{ .buffer = raiz_der, .index = 0 };
    Certificado.verify(ultima, raiz, ahora) catch return false;
    return true;
}''',
'''fn tryVerificarConRaiz(ultima: Certificado, raiz_der: []const u8, ahora: i64) bool {
    const raiz = Certificado{ .buffer = raiz_der, .index = 0 };
    Certificado.verify(ultima, raiz, ahora) catch |e| {
        serial.puts("tls: verificacion con raiz: ");
        serial.puts(@errorName(e));
        serial.puts("\\n");
        return false;
    };
    return true;
}''', "traza errorName raíz")
parche(T, '''    const ultima = Certificado{ .buffer = certs_der[certs_num - 1], .index = 0 };
    if (tryVerificarConRaiz(ultima, RAIZ_ISRG_X1, ahora)) return true;''',
'''    serial.puts("tls: cadena con ");
    serial.putDec(certs_num);
    serial.puts(" cert(s), epoch=");
    serial.putDec(@as(u32, @intCast(ahora)));
    serial.puts("\\n");
    const ultima = Certificado{ .buffer = certs_der[certs_num - 1], .index = 0 };
    if (tryVerificarConRaiz(ultima, RAIZ_ISRG_X1, ahora)) return true;''',
       "traza cadena/epoch")

# 4) pedir(): GET HTTP/1.1 sobre TLS
parche(T, '''/// Cierre limpio: close_notify cifrado + FIN de la TCP.
pub fn cerrar() void {''',
'''/// Respuesta de pedir(): código de estado HTTP y el cuerpo (un slice
/// DENTRO del búfer del llamador, tras las cabeceras).
pub const Respuesta = struct { estado: u16, cuerpo: []const u8 };

/// GET HTTP/1.1 sobre TLS 1.3 contra host/ip:puerto. Recibe la respuesta
/// completa (cabeceras incluidas) en `búfer` y devuelve el estado y el
/// cuerpo ya recortado. Una sola petición por conexión (Connection: close).
pub fn pedir(host: []const u8, ip: [4]u8, puerto: u16, ruta: []const u8, búfer: []u8) ?Respuesta {
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
    anexar(&peticion, &n, " HTTP/1.1\\r\\nHost: ");
    anexar(&peticion, &n, host);
    anexar(&peticion, &n, "\\r\\nUser-Agent: AntLexOS\\r\\nConnection: close\\r\\n\\r\\n");
    if (!enviar(peticion[0..n])) return null;

    // recibir toda la respuesta que quepa en el búfer
    var total: usize = 0;
    var vueltas: u8 = 0;
    while (vueltas < 12) : (vueltas += 1) {
        const r = recibir(búfer[total..], 100); // 1 s por intento
        if (r > 0) {
            vueltas = 0; // con datos seguimos esperando el resto
            total += r;
            if (total == búfer.len) break;
        } else if (fin_notificado or estado_tls != .datos) break;
    }
    if (total < 12) return null; // ni línea de estado

    // estado: "HTTP/1.x NNN ..."
    var codigo: u16 = 0;
    var i: usize = 0;
    while (i < total and búfer[i] != ' ') i += 1;
    i += 1;
    while (i + 1 < total and búfer[i] >= '0' and búfer[i] <= '9') : (i += 1) {
        codigo = codigo * 10 + (búfer[i] - '0');
    }
    // separador de cabeceras
    var cuerpo_ini: usize = total;
    var j: usize = 0;
    while (j + 3 < total) : (j += 1) {
        if (búfer[j] == '\\r' and búfer[j + 1] == '\\n' and búfer[j + 2] == '\\r' and búfer[j + 3] == '\\n') {
            cuerpo_ini = j + 4;
            break;
        }
    }
    return .{ .estado = codigo, .cuerpo = búfer[cuerpo_ini..total] };
}

/// Cierre limpio: close_notify cifrado + FIN de la TCP.
pub fn cerrar() void {''', "pedir() HTTP")

# ---------------------------------------------------------- teclado.zig ---
K = "src/kernel/teclado.zig"
parche(K, '''const std = @import("std");
const x86 = @import("x86.zig");''',
'''const std = @import("std");
const x86 = @import("x86.zig");
const serial = @import("serial.zig");''', "import serial")
parche(K, '''const TAM_BUF = 64;
var buffer: [TAM_BUF]u8 = undefined;''',
'''// 256 teclas: con el eco gráfico de la consola en QEMU (TCG) el drenado
// puede ir por detrás del tecleo rápido (arneses a 45 ms/tecla) y con 64
// se perdían caracteres enteros de líneas largas (base64 de la CA con
// red ca); 256 da margen de sobra.
const TAM_BUF = 256;
var buffer: [TAM_BUF]u8 = undefined;''', "TAM_BUF 256")
parche(K, '''    if (sig == lei) {
        desbordamientos += 1;
        return;
    }''',
'''    if (sig == lei) {
        desbordamientos += 1;
        serial.putc('!'); // tecla perdida en el anillo (diagnóstico)
        return;
    }''', "traza tecla perdida")

# ------------------------------------------------------------- build.zig ---
parche("build.zig", '''        correr_mkalfs.step.dependOn(&correr_mkalx.step);
    }''',
'''        correr_mkalfs.step.dependOn(&correr_mkalx.step);
        // y también a zig-out/apps/ (la tienda y los arneses los usan)
        const inst_alx = b.addInstallFile(alx, b.fmt("apps/{s}.ALX", .{app.nombre}));
        b.getInstallStep().dependOn(&inst_alx.step);
    }''', "ALX en zig-out/apps")

# ------------------------------------------------------------------ CI ---
CI = ".github/workflows/ci.yml"
parche(CI, '''      - name: TCP contra servidor HTTP local (Fase 9b)
        env:
          TC: /noexiste
        run: python3 tools/probar_tcp.py zig-out/antlexos.img build/pruebas_tcp --tiempo 240
''',
'''      - name: TCP contra servidor HTTP local (Fase 9b)
        env:
          TC: /noexiste
        run: python3 tools/probar_tcp.py zig-out/antlexos.img build/pruebas_tcp --tiempo 240

      - name: TLS 1.3 contra servidor local (Fase 9b)
        env:
          TC: /noexiste
        run: python3 tools/probar_tls.py zig-out/antlexos.img build/pruebas_tls --tiempo 300

      - name: Tienda sobre TLS local (Fase 9b)
        env:
          TC: /noexiste
        run: python3 tools/probar_descargar.py zig-out/antlexos.img build/pruebas_descargar --tiempo 300
''', "CI TLS+tienda")
parche(CI, '''            build/pruebas_tcp/serial_final.log
''',
'''            build/pruebas_tcp/serial_final.log
            build/pruebas_tls/serial_final.log
            build/pruebas_descargar/serial_final.log
''', "CI artifacts")
parche(".github/workflows/release.yml",
       "          python3 tools/probar_tcp.py zig-out/antlexos.img build/pruebas_tcp --tiempo 240\n",
       '''          python3 tools/probar_tcp.py zig-out/antlexos.img build/pruebas_tcp --tiempo 240
          python3 tools/probar_tls.py zig-out/antlexos.img build/pruebas_tls --tiempo 300
          python3 tools/probar_descargar.py zig-out/antlexos.img build/pruebas_descargar --tiempo 300
''', "release TLS+tienda")

print(f"{len(OK)} parches aplicados: {', '.join(OK)}")
