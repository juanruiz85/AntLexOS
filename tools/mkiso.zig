//! AntLex OS — constructor de ISO9660 + El Torito (Fase 6).
//!
//! Ensambla antlexos.iso desde los artefactos ya construidos:
//!   * stage1_cd.bin  → imagen de arranque El Torito «sin emulación»
//!   * stage2_cd.bin  → LBA 1 del área de sistema (lo carga stage1_cd)
//!   * BOOTX64.EFI    → /EFI/BOOT/BOOTX64.EFI (OVMF lo lee del sistema de
//!                      archivos ISO9660; el firmware UEFI con driver
//!                      ISO9660 no necesita entrada El Torito UEFI)
//!   * LEEME.txt      → /LEEME.TXT
//!   * antlexos.img   → de ahí se extraen la partición del kernel (9 MiB)
//!                      y el volumen ALFS (13 MiB), en los mismos offsets
//!                      que el disco: los cargadores leen por LBA fijo.
//!
//! Layout de la ISO (sectores de 2048 B, offsets múltiplos de 2048 como
//! exige layout.zig para funcionar igual con 512 y 2048 B):
//!   LBA 0     área de sistema con la marca "ANTLEX" en el byte 3
//!             (el bootloader UEFI identifica el medio así)
//!   LBA 1     stage2_cd.bin (rellenado a 2048)
//!   LBA 16    PVD · 17 Boot Record VD (catálogo en LBA 19) · 18 terminador
//!   LBA 19    catálogo El Torito (validación + entrada por defecto)
//!   LBA 20    stage1_cd.bin (imagen de arranque, 2048 B)
//!   LBA 21    directorio raíz · 22 /EFI · 23 /EFI/BOOT
//!   LBA 24    tablas de rutas L y M
//!   LBA 25..  datos de archivos (LEEME.TXT, BOOTX64.EFI)
//!   LBA 4608  partición del kernel (9 MiB, del disco)
//!   LBA 6656  volumen ALFS (13 MiB, del disco) → total 29 MiB
//!
//! El arranque UEFI funciona por la entrada El Torito de plataforma 0xEF
//! del catálogo: PartitionDxe (EDK2) expone la FAT16 embebida como
//! partición, el driver FAT la monta y el firmware ejecuta
//! \EFI\BOOT\BOOTX64.EFI (EDK2 moderno NO trae driver ISO9660).
//!
//! Uso: mkiso.zig <salida.iso> <antlexos.img> <stage1_cd.bin>
//!              <stage2_cd.bin> <bootx64.efi> <leeme.txt> <fat16.bin>

const std = @import("std");

const SECTOR = 2048;
const DISCO_TAM: u64 = 29 * 1024 * 1024;
const KERNEL_OFF: u64 = 9 * 1024 * 1024;
const ALFS_OFF: u64 = 13 * 1024 * 1024;

// LBAs fijos del layout anterior (los calculados arriba)
const LBA_STAGE2 = 1;
const LBA_PVD = 16;
const LBA_BRVD = 17;
const LBA_TERM = 18;
const LBA_CATALOGO = 19;
const LBA_STAGE1 = 20;
const LBA_RAIZ = 21;
const LBA_EFI = 22;
const LBA_BOOT = 23;
const LBA_PT = 24;
const LBA_DATOS = 25;

const FECHA = "2026111300000000\x00"; // fija: construcción reproducible

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 8) {
        std.debug.print("uso: mkiso.zig <salida.iso> <antlexos.img> <stage1_cd.bin> <stage2_cd.bin> <bootx64.efi> <leeme.txt> <fat16.bin>\n", .{});
        return error.Uso;
    }
    const ruta_out = args[1];
    const ruta_img = args[2];
    const ruta_s1 = args[3];
    const ruta_s2 = args[4];
    const ruta_efi = args[5];
    const ruta_leeme = args[6];
    const ruta_fat = args[7];

    const img = try std.fs.cwd().readFileAlloc(arena, ruta_img, 64 * 1024 * 1024);
    if (img.len != DISCO_TAM) {
        std.debug.print("ERROR: antlexos.img mide {d} B, se esperaban {d}\n", .{ img.len, DISCO_TAM });
        return error.DiscoRaro;
    }
    const s1 = try std.fs.cwd().readFileAlloc(arena, ruta_s1, 1 * 1024 * 1024);
    const s2 = try std.fs.cwd().readFileAlloc(arena, ruta_s2, 1 * 1024 * 1024);
    const efi = try std.fs.cwd().readFileAlloc(arena, ruta_efi, 8 * 1024 * 1024);
    const leeme = try std.fs.cwd().readFileAlloc(arena, ruta_leeme, 1 * 1024 * 1024);
    const fat = try std.fs.cwd().readFileAlloc(arena, ruta_fat, 16 * 1024 * 1024);
    if (s1.len > SECTOR) return error.Stage1CdGrande;
    if (s2.len > SECTOR) return error.Stage2CdGrande;

    // ---------------- extents de datos ----------------
    const lba_leeme = LBA_DATOS;
    const lba_efi = lba_leeme + sectores(leeme.len);
    const lba_fat = lba_efi + sectores(efi.len);
    const fin_datos = lba_fat + sectores(fat.len);
    if (fin_datos > KERNEL_OFF / SECTOR) return error.DatosSobreKernel;

    // ---------------- imagen completa ----------------
    const espacio: usize = @intCast(DISCO_TAM / SECTOR);
    const iso = try arena.alloc(u8, espacio * SECTOR);
    @memset(iso, 0);

    // área de sistema: marca del medio en el byte 3 (como el MBR)
    @memcpy(iso[3..9], "ANTLEX");

    // LBA 1: stage2_cd
    @memcpy(iso[LBA_STAGE2 * SECTOR .. LBA_STAGE2 * SECTOR + s2.len], s2);

    // ---------------- descriptores de volumen ----------------
    escribirPVD(iso, espacio);
    escribirBRVD(iso);
    escribirTerminador(iso);

    // ---------------- catálogo El Torito ----------------
    escribirCatalogo(iso, lba_fat, @intCast(fat.len));

    // LBA 20: imagen de arranque stage1_cd
    @memcpy(iso[LBA_STAGE1 * SECTOR .. LBA_STAGE1 * SECTOR + s1.len], s1);

    // ---------------- sistema de archivos ISO9660 ----------------
    escribirDirectorios(iso, lba_leeme, lba_efi, leeme.len, efi.len);
    escribirTablasRutas(iso);
    @memcpy(iso[@as(usize, lba_leeme) * SECTOR ..][0..leeme.len], leeme);
    @memcpy(iso[@as(usize, lba_efi) * SECTOR ..][0..efi.len], efi);
    @memcpy(iso[@as(usize, lba_fat) * SECTOR ..][0..fat.len], fat);

    // Partición del kernel, ALINEADA a sector de CD: la cabecera de 512 B
    // va al principio del LBA 4608 y el BINARIO empieza en el LBA 4609
    // (byte +2048). En el disco HDD el binario va pegado a +512; aquí se
    // insertan 1536 B de relleno para que stage2_cd (que lee desde
    // KERNEL_OFF_LBA+1 en sectores de 2048) y el bootloader UEFI (que
    // busca el binario a +tamanio_sector) lo hallen ambos sin cambios.
    {
        const header: *align(1) const [64]u8 = @ptrCast(img[@intCast(KERNEL_OFF)..][0..64]);
        const kernel_size = std.mem.readInt(u32, header[20..24], .little);
        @memcpy(iso[@intCast(KERNEL_OFF)..@intCast(KERNEL_OFF + 512)], img[@intCast(KERNEL_OFF)..@intCast(KERNEL_OFF + 512)]);
        const fuente = img[@intCast(KERNEL_OFF + 512)..@intCast(KERNEL_OFF + 512 + kernel_size)];
        @memcpy(iso[@intCast(KERNEL_OFF + 2048)..][0..fuente.len], fuente);
    }
    @memcpy(iso[@intCast(ALFS_OFF)..@intCast(DISCO_TAM)], img[@intCast(ALFS_OFF)..@intCast(DISCO_TAM)]);

    try std.fs.cwd().writeFile(.{ .sub_path = ruta_out, .data = iso });
    std.debug.print(
        "ISO lista: {d} sectores de 2048 B ({d} MiB) — stage1_cd LBA {d}, stage2_cd LBA {d}, EFI {d} B, kernel en {d} MiB, ALFS en {d} MiB\n",
        .{ espacio, DISCO_TAM / (1024 * 1024), LBA_STAGE1, LBA_STAGE2, efi.len, KERNEL_OFF / (1024 * 1024), ALFS_OFF / (1024 * 1024) },
    );
}

fn sectores(bytes: usize) u32 {
    return @intCast((bytes + SECTOR - 1) / SECTOR);
}

fn fechaEn(destino: []u8) void {
    @memcpy(destino[0..17], FECHA);
}

/// Fecha del registro de directorio (7 bytes: año-1900, mes, día, h, m, s, tz).
fn fechaDir(destino: []u8) void {
    const d = [7]u8{ 126, 11, 13, 0, 0, 0, 0 }; // 2026-11-13 00:00:00 UTC
    @memcpy(destino[0..7], &d);
}

/// Escribe un entero little-endian y su espejo big-endian (formato ISO).
fn ambos(destino: []u8, valor: u32) void {
    std.mem.writeInt(u32, destino[0..4], valor, .little);
    std.mem.writeInt(u32, destino[4..8], valor, .big);
}

fn campo(destino: []u8, texto: []const u8) void {
    // campo de d-caracteres: espacio a la derecha
    @memset(destino, ' ');
    const n = @min(texto.len, destino.len);
    @memcpy(destino[0..n], texto[0..n]);
}

fn escribirPVD(iso: []u8, espacio: usize) void {
    const s = iso[LBA_PVD * SECTOR .. (LBA_PVD + 1) * SECTOR];
    s[0] = 1; // tipo: descriptor de volumen primario
    @memcpy(s[1..6], "CD001");
    s[6] = 1; // versión
    campo(s[11..43], "ANTLEX OS"); // identificador de sistema
    campo(s[43..75], "ANTLEX OS V1"); // identificador de volumen
    ambos(s[80..88], @intCast(espacio)); // tamaño del espacio de volumen
    ambos(s[120..128], 1); // tamaño del conjunto
    ambos(s[128..136], 1); // número de secuencia
    ambos(s[136..144], SECTOR); // tamaño de bloque lógico
    const pt_tam: u32 = 36; // 3 registros (raíz+EFI+BOOT), véase escribirTablasRutas
    ambos(s[140..148], pt_tam);
    std.mem.writeInt(u32, s[148..152], LBA_PT, .little); // tabla L
    std.mem.writeInt(u32, s[152..156], 0, .little); // tabla L opcional
    std.mem.writeInt(u32, s[156..160], LBA_PT, .big); // tabla M
    std.mem.writeInt(u32, s[160..164], 0, .big); // tabla M opcional
    // registro de directorio raíz (34 bytes, nombre "\0") en el byte 164
    // (estructura EFI_ISO9660_PRIMARY_VOLUME_DESCRIPTOR / isofs de Linux)
    escribirRegistroDir(s[164..198], LBA_RAIZ, 2048, true, "\x00");
    campo(s[326..454], "juanruiz85"); // identificador de publicador
    campo(s[454..582], "mkiso.zig"); // preparador de datos
    campo(s[582..710], "AntLex OS"); // aplicación
    fechaEn(s[806..823]); // fecha de creación
    s[874] = 1; // versión de estructura de archivo
}

fn escribirBRVD(iso: []u8) void {
    const s = iso[LBA_BRVD * SECTOR .. (LBA_BRVD + 1) * SECTOR];
    s[0] = 0; // tipo: boot record
    @memcpy(s[1..6], "CD001");
    s[6] = 1;
    // El identificador va CON CEROS detrás (no espacios): SeaBIOS compara
    // con strcmp("CD001\001EL TORITO SPECIFICATION") y exige el '\0' tras
    // la cadena — el relleno con espacios devuelve el código 5
    @memcpy(s[7..30], "EL TORITO SPECIFICATION");
    @memcpy(s[39..45], "ANTLEX");
    std.mem.writeInt(u32, s[71..75], LBA_CATALOGO, .little);
}

fn escribirTerminador(iso: []u8) void {
    const s = iso[LBA_TERM * SECTOR .. (LBA_TERM + 1) * SECTOR];
    s[0] = 255;
    @memcpy(s[1..6], "CD001");
    s[6] = 1;
}

fn escribirCatalogo(iso: []u8, lba_fat_uefi: u32, fat_bytes: usize) void {
    const fat_sect_virtuales: u64 = @as(u64, @intCast(fat_bytes)) / 512;
    const s = iso[LBA_CATALOGO * SECTOR .. (LBA_CATALOGO + 1) * SECTOR];
    // entrada de validación (32 B): identificador (4-27), SUMA DE
    // VERIFICACIÓN (28-29) y CLAVE 55 AA (30-31); las 16 palabras u16
    // del bloque deben sumar 0
    s[0] = 0x01;
    s[1] = 0x00; // plataforma 0 = x86
    @memcpy(s[4..23], "ANTLEX BOOT CATALOG");
    s[30] = 0x55;
    s[31] = 0xAA;
    var suma: u16 = 0;
    var i: usize = 0;
    while (i < 28) : (i += 2) {
        suma +%= std.mem.readInt(u16, s[i..][0..2], .little);
    }
    const ck: u16 = 0 -% suma -% 0xAA55; // compensa también la clave
    std.mem.writeInt(u16, s[28..30], ck, .little);

    // entrada por defecto (32 B): arranque sin emulación (BIOS)
    s[32] = 0x88; // arrancable
    s[33] = 0x00; // sin emulación
    std.mem.writeInt(u16, s[34..36], 0x07C0, .little); // segmento de carga
    s[36] = 0; // tipo de sistema
    std.mem.writeInt(u16, s[38..40], 4, .little); // 4 sectores virtuales (2048 B)
    std.mem.writeInt(u32, s[40..44], LBA_STAGE1, .little); // LBA de la imagen

    // cabecera de sección (32 B) + entrada de sección (32 B) para UEFI
    // (plataforma 0xEF): PartitionDxe de EDK2 expone la FAT como partición
    s[64] = 0x91; // cabecera de sección FINAL
    s[65] = 0xEF; // plataforma UEFI
    @memcpy(s[68..78], "ANTLEX ESP"); // identificador (bytes 4-27 de la entrada)
    std.mem.writeInt(u16, s[92..94], 1, .little); // nº de entradas (bytes 28-29)
    s[96] = 0x88; // entrada de sección arrancable
    s[97] = 0x00; // sin emulación
    std.mem.writeInt(u16, s[98..100], 0x0000, .little); // segmento 0
    s[100] = 0; // tipo de sistema
    // sectores virtuales de 512 B de la FAT (convención de genisoimage);
    // el driver FAT monta por el BPB, no por el tamaño de la partición
    std.mem.writeInt(u16, s[102..104], @intCast(fat_sect_virtuales), .little);
    std.mem.writeInt(u32, s[104..108], lba_fat_uefi, .little); // LBA de la FAT
}

/// Registro de directorio ISO9660 (base de 33 bytes + identificador).
fn escribirRegistroDir(destino: []u8, lba: u32, tam: u32, es_dir: bool, nombre: []const u8) void {
    const nlen = nombre.len;
    const largo: usize = 33 + nlen + @as(usize, if (nlen % 2 == 0) 1 else 0);
    destino[0] = @intCast(largo);
    destino[1] = 0; // sin atributos extendidos
    ambos(destino[2..10], lba);
    ambos(destino[10..18], tam);
    fechaDir(destino[18..25]);
    destino[25] = if (es_dir) 0x02 else 0x00;
    destino[26] = 0; // tamaño de unidad
    destino[27] = 0; // intercalado
    std.mem.writeInt(u16, destino[28..30], 1, .little); // nº de secuencia
    std.mem.writeInt(u16, destino[30..32], 1, .big);
    destino[32] = @intCast(nlen);
    @memcpy(destino[33 .. 33 + nlen], nombre);
    if (nlen % 2 == 0) destino[33 + nlen] = 0;
}

fn escribirDirectorios(iso: []u8, lba_leeme: u32, lba_efi: u32, tam_leeme: usize, tam_efi: usize) void {
    // raíz
    const raiz = iso[LBA_RAIZ * SECTOR .. (LBA_RAIZ + 1) * SECTOR];
    var o: usize = 0;
    escribirRegistroDir(raiz[o..], LBA_RAIZ, 2048, true, "\x00");
    o += raiz[o];
    escribirRegistroDir(raiz[o..], LBA_RAIZ, 2048, true, "\x01");
    o += raiz[o];
    escribirRegistroDir(raiz[o..], LBA_EFI, 2048, true, "EFI");
    o += raiz[o];
    escribirRegistroDir(raiz[o..], lba_leeme, @intCast(tam_leeme), false, "LEEME.TXT;1");
    o += raiz[o];

    // /EFI
    const efi_dir = iso[LBA_EFI * SECTOR .. (LBA_EFI + 1) * SECTOR];
    o = 0;
    escribirRegistroDir(efi_dir[o..], LBA_EFI, 2048, true, "\x00");
    o += efi_dir[o];
    escribirRegistroDir(efi_dir[o..], LBA_RAIZ, 2048, true, "\x01");
    o += efi_dir[o];
    escribirRegistroDir(efi_dir[o..], LBA_BOOT, 2048, true, "BOOT");
    o += efi_dir[o];

    // /EFI/BOOT
    const boot_dir = iso[LBA_BOOT * SECTOR .. (LBA_BOOT + 1) * SECTOR];
    o = 0;
    escribirRegistroDir(boot_dir[o..], LBA_BOOT, 2048, true, "\x00");
    o += boot_dir[o];
    escribirRegistroDir(boot_dir[o..], LBA_EFI, 2048, true, "\x01");
    o += boot_dir[o];
    escribirRegistroDir(boot_dir[o..], lba_efi, @intCast(tam_efi), false, "BOOTX64.EFI;1");
    o += boot_dir[o];
}

fn escribirTablasRutas(iso: []u8) void {
    const s = iso[LBA_PT * SECTOR .. (LBA_PT + 1) * SECTOR];
    // tabla L (little-endian): raíz(1) + EFI + BOOT = 10 + 12 + 14 = 36… +1
    var o: usize = 0;
    // raíz
    s[o] = 1;
    o += 2;
    s[o] = 0; // atributos extendidos
    o += 2;
    std.mem.writeInt(u32, s[o..][0..4], LBA_RAIZ, .little);
    o += 4;
    std.mem.writeInt(u16, s[o..][0..2], 1, .little);
    o += 2;
    s[o] = 0x00;
    o += 1;
    // EFI (padre 1)
    s[o] = 3;
    o += 2;
    s[o] = 0;
    o += 2;
    std.mem.writeInt(u32, s[o..][0..4], LBA_EFI, .little);
    o += 4;
    std.mem.writeInt(u16, s[o..][0..2], 1, .little);
    o += 2;
    @memcpy(s[o .. o + 3], "EFI");
    o += 3;
    s[o] = 0; // relleno a longitud par
    o += 1;
    // BOOT (padre 2)
    s[o] = 4;
    o += 2;
    s[o] = 0;
    o += 2;
    std.mem.writeInt(u32, s[o..][0..4], LBA_BOOT, .little);
    o += 4;
    std.mem.writeInt(u16, s[o..][0..2], 2, .little);
    o += 2;
    @memcpy(s[o .. o + 4], "BOOT");
    o += 4;

    // tabla M (big-endian) tras la L
    const base_m = 64; // hueco fijo tras la tabla L
    var m: usize = base_m;
    s[m] = 1;
    m += 2;
    s[m] = 0;
    m += 2;
    std.mem.writeInt(u32, s[m..][0..4], LBA_RAIZ, .big);
    m += 4;
    std.mem.writeInt(u16, s[m..][0..2], 1, .big);
    m += 2;
    s[m] = 0x00;
    m += 1;
    s[m] = 3;
    m += 2;
    s[m] = 0;
    m += 2;
    std.mem.writeInt(u32, s[m..][0..4], LBA_EFI, .big);
    m += 4;
    std.mem.writeInt(u16, s[m..][0..2], 1, .big);
    m += 2;
    @memcpy(s[m .. m + 3], "EFI");
    m += 3;
    s[m] = 0;
    m += 1;
    s[m] = 4;
    m += 2;
    s[m] = 0;
    m += 2;
    std.mem.writeInt(u32, s[m..][0..4], LBA_BOOT, .big);
    m += 4;
    std.mem.writeInt(u16, s[m..][0..2], 2, .big);
    m += 2;
    @memcpy(s[m .. m + 4], "BOOT");
    m += 4;
}
