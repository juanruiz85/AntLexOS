//! AntLex OS — layout canónico del medio de arranque (fuente única de verdad).
//!
//! Todos los offsets son BYTES absolutos desde el inicio del disco/ISO y
//! múltiplos de 2048, de modo que el mismo layout funciona en medios de
//! 512 B/sector (imagen HDD) y de 2048 B/sector (El Torito CD).
//!
//! El kernel se enlaza en 0x100000 (1 MiB) y su binario crudo vive en la
//! "partición 2" del medio precedido de una cabecera de un sector.

pub const disk_size: u64 = 29 * 1024 * 1024; // tamaño total de antlexos.img

pub const mbr_lba: u32 = 0; // sector 0: MBR propio (BIOS)
pub const stage2_lba: u32 = 1; // stage2 justo tras el MBR (BIOS/HDD)
// stage1 carga 32 sectores (16 KiB); además stage2 debe dejar libre la zona
// 0xA000..0xB0FF (búferes VESA de stage2), así que su tamaño práctico máximo
// es ~8 KiB. mkimage lo exige en tiempo de construcción.
pub const stage2_max_bytes: u32 = 0x2000 - 0x100;

// Partición 1: FAT16 de 8 MiB (EFI/BOOT/BOOTX64.EFI + LEEME.txt)
pub const fat_off: u64 = 1 * 1024 * 1024;
pub const fat_size: u64 = 8 * 1024 * 1024;

// Partición 2: kernel (cabecera de 1 sector + binario crudo), 4 MiB
pub const kernel_off: u64 = 9 * 1024 * 1024;
pub const kernel_region_size: u64 = 4 * 1024 * 1024;

// Partición 3: volumen ALFS, 16 MiB
pub const alfs_off: u64 = 13 * 1024 * 1024;
pub const alfs_size: u64 = 16 * 1024 * 1024;

pub const kernel_load_addr: u64 = 0x100000;
pub const kernel_max_size: u32 = 576 * 1024; // límite del archivo (staging de stage2: 0x10000..0xA0000, sin tocar los búferes VESA)
pub const kernel_img_max: u32 = 2 * 1024 * 1024; // límite archivo+bss en memoria (loader UEFI; la partición P2 es de 4 MiB)
pub const kernel_stack_size: u32 = 64 * 1024;

// Direcciones fijas del protocolo de arranque (BIOS stage2 y EFI las respetan)
pub const boot_info_addr: u64 = 0x5000;
pub const memmap_addr: u64 = 0x6000;
pub const memmap_max_entries: u32 = 64;
pub const memmap_entry_size: u32 = 24;

pub const boot_magic: u32 = 0x42584C41; // "ALXB" little-endian
pub const kernel_magic: u32 = 0x524B4C41; // "ALKR" little-endian

/// Cabecera del kernel en el medio (offset 0 de la partición 2, 1 sector).
pub const KernelHeader = extern struct {
    magic: u32, // kernel_magic
    hdr_version: u16,
    flags: u16,
    entry_off: u32, // desde kernel_load_addr
    bss_off: u32,
    bss_size: u32,
    kernel_size: u32, // bytes del binario crudo
    crc32: u32, // del binario crudo
    reserved: [9]u32, // completa 64 bytes
};

/// LBA del kernel en un medio con tamaño de sector dado (bytes -> LBA).
pub fn kernelLba(sector_size: u64) u64 {
    return kernel_off / sector_size;
}

/// LBA del volumen ALFS en un medio con tamaño de sector dado.
pub fn alfsLba(sector_size: u64) u64 {
    return alfs_off / sector_size;
}

comptime {
    // Validación: los offsets crudos deben ser múltiplos de 2048 (512 y 2048 a la vez)
    if (kernel_off % 2048 != 0) @compileError("kernel_off debe ser múltiplo de 2048");
    if (alfs_off % 2048 != 0) @compileError("alfs_off debe ser múltiplo de 2048");
    if (fat_off + fat_size != kernel_off) @compileError("P1 debe terminar donde empieza P2");
    if (kernel_off + kernel_region_size != alfs_off) @compileError("P2 debe terminar donde empieza P3");
    if (alfs_off + alfs_size != disk_size) @compileError("P3 debe terminar exactamente al final del disco");
}
