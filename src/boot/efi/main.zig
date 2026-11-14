//! AntLex OS — bootloader UEFI propio (BOOTX64.EFI).
//!
//! Estrategia (sin usar SimpleFileSystem, para soportar también el CD):
//!   1. buscar entre los BlockIo un medio AntLex (marca "ANTLEX" en el MBR,
//!      offset 3, para medios de 512 B/sector)
//!   2. leer la partición 2 (kernel: cabecera + binario) por bloques
//!      directamente a 0x100000 y mover el binario al inicio
//!   3. obtener el framebuffer por GOP (32 bpp; se avisa si el orden de
//!      componentes es RGB en vez de BGR)
//!   4. convertir el mapa de memoria EFI al formato E820 del protocolo
//!      boot_info de AntLex
//!   5. ExitBootServices y saltar al kernel (RDI = boot_info, 64 bits)
//!
//! El kernel recibe exactamente el mismo boot_info que produce stage2 en
//! la ruta BIOS (src/kernel/boot_info.zig es la definición compartida).

const std = @import("std");

// símbolo que lld-link espera en imágenes PE con código de coma flotante
// (no usamos flotantes, pero compiler_rt lo referencia al enlazar UEFI)
export var _fltused: i32 = 0;
const uefi = std.os.uefi;
const boot_info = @import("boot_info");
const layout = @import("layout");

const BlockIo = uefi.protocol.BlockIo;
const Gop = uefi.protocol.GraphicsOutput;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;
const Status = uefi.Status;

// offsets de arranque (importados de layout.zig vía opciones de build)
const layout_opts = @import("layout_opts");
const KERNEL_OFF: u64 = layout_opts.kernel_off;
const KERNEL_LOAD: u64 = layout_opts.kernel_load_addr;
const KERNEL_MAX: u64 = layout_opts.kernel_max_size;
const KERNEL_IMG_MAX: u64 = layout_opts.kernel_img_max; // archivo+bss en memoria
const BOOT_MAGIC: u32 = layout_opts.boot_magic;

fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "[ANTLEX EFI] " ++ fmt ++ "\r\n", args) catch return;
    var wbuf: [512]u16 = undefined;
    var n: usize = 0;
    for (txt) |c| {
        if (n >= wbuf.len - 1) break;
        wbuf[n] = c;
        n += 1;
    }
    wbuf[n] = 0;
    const con_out = uefi.system_table.con_out orelse return;
    _ = con_out.outputString(@ptrCast(&wbuf));
}

fn errorEstado(operacion: []const u8, st: Status) noreturn {
    printf("ERROR {s}: 0x{x}", .{ operacion, @intFromEnum(st) });
    while (true) asm volatile ("hlt");
}

pub fn main() void {
    const bs = uefi.system_table.boot_services orelse {
        printf("sin boot services", .{});
        while (true) asm volatile ("hlt");
    };

    printf("AntLex EFI bootloader", .{});

    // ------------------------------------------------------------------
    // 1) localizar un medio AntLex por BlockIo
    // ------------------------------------------------------------------
    var n_manejadores: usize = 0;
    var manejadores: [*]uefi.Handle = undefined;
    const st_lh = bs.locateHandleBuffer(.by_protocol, &BlockIo.guid, null, &n_manejadores, &manejadores);
    if (st_lh != .success) errorEstado("locateHandleBuffer(BlockIo)", st_lh);

    var bloque: ?*BlockIo = null;
    var tamanio_sector: u64 = 0;
    var i: usize = 0;
    while (i < n_manejadores) : (i += 1) {
        const bio = bs.openProtocolSt(BlockIo, manejadores[i]) catch continue;
        if (!bio.media.media_present) continue;
        const bs_sec: u64 = bio.media.block_size;
        if (bs_sec == 0 or bs_sec > 4096) continue;
        // leer el primer bloque y buscar la marca del medio
        var primer: [4096]u8 align(8) = undefined;
        const st_rb = bio.readBlocks(bio.media.media_id, 0, @intCast(bs_sec), &primer);
        if (st_rb != .success) continue;
        if (bs_sec >= 512 and std.mem.eql(u8, primer[3..9], "ANTLEX")) {
            bloque = bio;
            tamanio_sector = bs_sec;
            printf("medio AntLex hallado (sector {d} B)", .{tamanio_sector});
            break;
        }
    }
    if (bloque == null) {
        printf("no se encontro un disco AntLex", .{});
        while (true) asm volatile ("hlt");
    }
    const bio = bloque.?;
    if (KERNEL_OFF % tamanio_sector != 0) {
        printf("offset del kernel no alineado al sector", .{});
        while (true) asm volatile ("hlt");
    }
    const lba_kernel: u64 = KERNEL_OFF / tamanio_sector;

    // ------------------------------------------------------------------
    // 2) leer la cabecera y el kernel
    // ------------------------------------------------------------------
    var buf_cabecera: [4096]u8 align(8) = undefined;
    const st_cab = bio.readBlocks(bio.media.media_id, lba_kernel, @intCast(tamanio_sector), &buf_cabecera);
    if (st_cab != .success) errorEstado("readBlocks(cabecera)", st_cab);
    const cabecera: *const layout.KernelHeader = @alignCast(@ptrCast(&buf_cabecera));
    if (cabecera.magic != layout.kernel_magic) {
        printf("cabecera del kernel invalida (magic 0x{x})", .{cabecera.magic});
        while (true) asm volatile ("hlt");
    }
    if (cabecera.kernel_size == 0 or cabecera.kernel_size > KERNEL_MAX) {
        printf("tamano del kernel fuera de rango: {d}", .{cabecera.kernel_size});
        while (true) asm volatile ("hlt");
    }
    // cabecera endurecida (REV-FASE2): entrada y .bss dentro del binario
    if (cabecera.entry_off >= cabecera.kernel_size) {
        printf("entry_off fuera del kernel: {d}", .{cabecera.entry_off});
        while (true) asm volatile ("hlt");
    }
    if (cabecera.bss_off > KERNEL_IMG_MAX or cabecera.bss_size > KERNEL_IMG_MAX - cabecera.bss_off) {
        printf("rango .bss fuera del kernel: +{d} x{d}", .{ cabecera.bss_off, cabecera.bss_size });
        while (true) asm volatile ("hlt");
    }
    printf("kernel: {d} B, entrada +{d}", .{ cabecera.kernel_size, cabecera.entry_off });

    // reservar [KERNEL_LOAD, KERNEL_LOAD + sector + kernel_size) y leer ahí
    const total_bytes: u64 = tamanio_sector + cabecera.kernel_size;
    const paginas: usize = @intCast((total_bytes + 4095) / 4096);
    var zona_kernel: [*]align(4096) u8 = @ptrFromInt(KERNEL_LOAD);
    const st_ap = bs.allocatePages(.allocate_address, .loader_code, paginas, &zona_kernel);
    if (st_ap != .success) errorEstado("allocatePages(kernel)", st_ap);

    const bloques_datos: u64 = (total_bytes + tamanio_sector - 1) / tamanio_sector;
    const st_leer = bio.readBlocks(
        bio.media.media_id,
        lba_kernel,
        @intCast(bloques_datos * tamanio_sector),
        @ptrFromInt(KERNEL_LOAD),
    );
    if (st_leer != .success) errorEstado("readBlocks(kernel)", st_leer);

    // mover el binario (sin cabecera) al inicio de la zona
    const fuente: [*]u8 = @ptrFromInt(KERNEL_LOAD + tamanio_sector);
    const destino: [*]u8 = @ptrFromInt(KERNEL_LOAD);
    std.mem.copyForwards(u8, destino[0..cabecera.kernel_size], fuente[0..cabecera.kernel_size]);
    // borrar el .bss
    if (cabecera.bss_size > 0) {
        const bss: [*]u8 = @ptrFromInt(KERNEL_LOAD + cabecera.bss_off);
        @memset(bss[0..cabecera.bss_size], 0);
    }

    // ------------------------------------------------------------------
    // 3) framebuffer por GOP
    // ------------------------------------------------------------------
    var gop: ?*Gop = null;
    var n_gop: usize = 0;
    var h_gop: [*]uefi.Handle = undefined;
    if (bs.locateHandleBuffer(.by_protocol, &Gop.guid, null, &n_gop, &h_gop) == .success and n_gop > 0) {
        gop = bs.openProtocolSt(Gop, h_gop[0]) catch null;
    }
    if (gop == null) errorEstado("sin GOP", .not_found);
    const g = gop.?;

    // si el modo actual no es de 32 bpp por componente, buscar uno mejor
    var info = g.mode.info;
    if (info.pixel_format == .bit_mask or info.pixel_format == .blt_only) {
        var m: u32 = 0;
        while (m < g.mode.max_mode) : (m += 1) {
            var tam: usize = 0;
            var cand: *Gop.Mode.Info = undefined;
            if (g.queryMode(m, &tam, &cand) == .success) {
                if (cand.pixel_format == .blue_green_red_reserved_8_bit_per_color or
                    cand.pixel_format == .red_green_blue_reserved_8_bit_per_color)
                {
                    if (g.setMode(m) == .success) {
                        info = g.mode.info;
                        break;
                    }
                }
            }
        }
    }
    const fb_bgr = info.pixel_format == .blue_green_red_reserved_8_bit_per_color;
    printf("GOP: {d}x{d}, BGR={}", .{ info.horizontal_resolution, info.vertical_resolution, fb_bgr });

    // ------------------------------------------------------------------
    // 4) mapa de memoria -> formato E820 de AntLex
    // ------------------------------------------------------------------
    var tam_mapa: usize = 0;
    var clave: usize = 0;
    var tam_desc: usize = 0;
    var ver: u32 = 0;
    _ = bs.getMemoryMap(&tam_mapa, null, &clave, &tam_desc, &ver);
    var buf_mapa: [*]align(8) u8 = undefined;
    const cap_bufer = tam_mapa + tam_desc * 4; // margen para descriptores nuevos
    const st_ap2 = bs.allocatePool(.loader_data, cap_bufer, &buf_mapa);
    if (st_ap2 != .success) errorEstado("allocatePool(memmap)", st_ap2);
    var mapa_ok = false;
    var reintentos: u32 = 0;
    while (reintentos < 8) : (reintentos += 1) {
        var tam2 = cap_bufer;
        const st_gm = bs.getMemoryMap(&tam2, @ptrCast(buf_mapa), &clave, &tam_desc, &ver);
        if (st_gm == .success) {
            tam_mapa = tam2;
            mapa_ok = true;
            break;
        }
    }
    if (!mapa_ok) errorEstado("getMemoryMap", .aborted);

    // página para boot_info + mapa convertido (asignada antes del mapa final)
    var pag_bi: [*]align(4096) u8 = undefined;
    const st_bi = bs.allocatePages(.allocate_any_pages, .loader_data, 1, &pag_bi);
    if (st_bi != .success) errorEstado("allocatePages(boot_info)", st_bi);
    @memset(pag_bi[0..4096], 0);
    const destino_mapa: [*]u8 = pag_bi + 256; // dentro de la misma página

    var n_entradas: u32 = 0;
    var total_desc: u32 = 0;
    var off: usize = 0;
    while (off + tam_desc <= tam_mapa) {
        const desc: *const MemoryDescriptor = @alignCast(@ptrCast(buf_mapa + off));
        off += tam_desc;
        total_desc += 1;
        if (desc.number_of_pages == 0) continue;
        const usable = switch (desc.type) {
            .conventional_memory, .loader_code, .loader_data, .boot_services_code, .boot_services_data, .acpi_reclaim_memory => true,
            else => false,
        };
        const base = desc.physical_start;
        const longitud = desc.number_of_pages * 4096;
        const tipo: u32 = if (usable) 1 else 2;
        // fusionar con la anterior si es contigua del mismo tipo
        if (n_entradas > 0) {
            const prev: *boot_info.EntradaMem = @alignCast(@ptrCast(destino_mapa + @as(usize, n_entradas - 1) * @sizeOf(boot_info.EntradaMem)));
            if (prev.tipo == tipo and prev.base + prev.long == base) {
                prev.long += longitud;
                continue;
            }
        }
        if (n_entradas >= 64) continue; // fuera del límite del protocolo
        const e: *boot_info.EntradaMem = @alignCast(@ptrCast(destino_mapa + @as(usize, n_entradas) * @sizeOf(boot_info.EntradaMem)));
        e.* = .{ .base = base, .long = longitud, .tipo = tipo, .acpi = 1 };
        n_entradas += 1;
    }
    // (nada de consola a partir de aquí: invalidaría la clave del mapa)

    const bi: *volatile boot_info.BootInfo = @ptrCast(pag_bi);
    bi.* = .{
        .magic = BOOT_MAGIC,
        .version = 2, // v2: incluye la posición del volumen ALFS
        .flags = boot_info.MODO_UEFI | (if (tamanio_sector == 2048) boot_info.MODO_CD else 0),
        .reserved = if (fb_bgr) 0 else 1, // bit0: framebuffer con orden RGB (no BGR)
        .fb_addr = g.mode.frame_buffer_base,
        .fb_w = info.horizontal_resolution,
        .fb_h = info.vertical_resolution,
        .fb_pitch = info.pixels_per_scan_line * 4,
        .fb_bpp = 32,
        .memmap_ptr = @intFromPtr(destino_mapa),
        .memmap_count = n_entradas,
        .pad = 0,
        .alfs_ptr = layout.alfs_off, // offset del volumen ALFS en el medio (bytes)
        .alfs_size = @intCast(layout.alfs_size),
        .sector_size = @intCast(tamanio_sector),
        .boot_drive = 0xFFFFFFFF,
    };

    // ------------------------------------------------------------------
    // 5) ExitBootServices y salto al kernel
    //    (si la clave queda desfasada por una asignación del firmware,
    //    se relee el mapa y se reintenta; sin usar la consola)
    // ------------------------------------------------------------------
    var ebs_ok = false;
    var reintento: u32 = 0;
    while (reintento < 5) : (reintento += 1) {
        var tam3 = cap_bufer;
        if (bs.getMemoryMap(&tam3, @ptrCast(buf_mapa), &clave, &tam_desc, &ver) != .success) continue;
        tam_mapa = tam3;
        // rellenar boot_info con el mapa fusionado (silencioso)
        var n2: u32 = 0;
        var off2: usize = 0;
        while (off2 + tam_desc <= tam_mapa) {
            const desc: *const MemoryDescriptor = @alignCast(@ptrCast(buf_mapa + off2));
            off2 += tam_desc;
            if (desc.number_of_pages == 0) continue;
            const usable2 = switch (desc.type) {
                .conventional_memory, .loader_code, .loader_data, .boot_services_code, .boot_services_data, .acpi_reclaim_memory => true,
                else => false,
            };
            const base = desc.physical_start;
            const longitud = desc.number_of_pages * 4096;
            const tipo: u32 = if (usable2) 1 else 2;
            if (n2 > 0) {
                const prev: *boot_info.EntradaMem = @alignCast(@ptrCast(destino_mapa + @as(usize, n2 - 1) * @sizeOf(boot_info.EntradaMem)));
                if (prev.tipo == tipo and prev.base + prev.long == base) {
                    prev.long += longitud;
                    continue;
                }
            }
            if (n2 >= 64) continue;
            const e: *boot_info.EntradaMem = @alignCast(@ptrCast(destino_mapa + @as(usize, n2) * @sizeOf(boot_info.EntradaMem)));
            e.* = .{ .base = base, .long = longitud, .tipo = tipo, .acpi = 1 };
            n2 += 1;
        }
        bi.memmap_count = n2;
        if (bs.exitBootServices(uefi.handle, clave) == .success) {
            ebs_ok = true;
            break;
        }
    }
    if (!ebs_ok) {
        errorEstado("exitBootServices", .invalid_parameter);
    }

    const entrada: usize = @intCast(KERNEL_LOAD + cabecera.entry_off);
    const bi_dir: usize = @intFromPtr(pag_bi);
    asm volatile (
        \\ movq %[bi], %%rdi
        \\ jmpq *%[entrada]
        :
        : [bi] "r" (bi_dir),
          [entrada] "r" (entrada),
        : "memory"
    );
    unreachable;
}
