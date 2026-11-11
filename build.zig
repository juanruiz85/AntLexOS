//! AntLex OS — build.zig: kernel, bootloaders (BIOS + UEFI), imagen de
//! disco y pruebas. Herramientas: zig 0.14.1, nasm, python3 (probar_boot.py).

const std = @import("std");
const lay = @import("layout.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ------------------------------------------------------------------
    // Módulos compartidos (boot_info es el protocolo BIOS↔UEFI↔kernel)
    // ------------------------------------------------------------------
    const mod_boot_info = b.createModule(.{
        .root_source_file = b.path("src/kernel/boot_info.zig"),
    });
    const mod_layout = b.createModule(.{
        .root_source_file = b.path("layout.zig"),
    });
    const layout_opts = b.addOptions();
    layout_opts.addOption(u64, "kernel_off", lay.kernel_off);
    layout_opts.addOption(u64, "kernel_load_addr", lay.kernel_load_addr);
    layout_opts.addOption(u64, "kernel_max_size", lay.kernel_max_size);
    layout_opts.addOption(u64, "alfs_off", lay.alfs_off);
    layout_opts.addOption(u64, "alfs_size", lay.alfs_size);
    layout_opts.addOption(u32, "boot_magic", lay.boot_magic);

    // ------------------------------------------------------------------
    // Kernel (x86_64 freestanding, enlazado en 1 MiB)
    // ------------------------------------------------------------------
    const t_kernel = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .freestanding, .abi = .none });
    const kernel = b.addExecutable(.{
        .name = "antlex.kernel",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = t_kernel,
        .optimize = optimize,
    });
    kernel.root_module.red_zone = false; // imprescindible con interrupciones
    kernel.root_module.stack_protector = false; // sin libc
    kernel.setLinkerScript(b.path("linker.ld"));
    kernel.entry = .{ .symbol_name = "kentry" };
    b.installArtifact(kernel);

    // ------------------------------------------------------------------
    // Bootloader UEFI (BOOTX64.EFI)
    // ------------------------------------------------------------------
    const t_uefi = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .uefi, .abi = .none });
    const efi = b.addExecutable(.{
        .name = "BOOTX64",
        .root_source_file = b.path("src/boot/efi/main.zig"),
        .target = t_uefi,
        .optimize = .ReleaseSafe,
    });
    efi.root_module.addImport("boot_info", mod_boot_info);
    efi.root_module.addImport("layout", mod_layout);
    efi.root_module.addOptions("layout_opts", layout_opts);
    const inst_efi = b.addInstallFile(efi.getEmittedBin(), "BOOTX64.EFI");
    b.getInstallStep().dependOn(&inst_efi.step);

    // ------------------------------------------------------------------
    // Bootloaders BIOS (NASM)
    // ------------------------------------------------------------------
    const c1 = b.addSystemCommand(&.{"nasm"});
    c1.addArgs(&.{ "-f", "bin", "-D", "STAGE2_SECTORES=32", "-o" });
    const out_s1 = c1.addOutputFileArg("stage1.bin");
    c1.addFileArg(b.path("src/boot/stage1.asm"));

    const c2 = b.addSystemCommand(&.{"nasm"});
    c2.addArgs(&.{ "-f", "bin", "-o" });
    const out_s2 = c2.addOutputFileArg("stage2.bin");
    c2.addFileArg(b.path("src/boot/stage2.asm"));

    const c2cd = b.addSystemCommand(&.{"nasm"});
    c2cd.addArgs(&.{ "-f", "bin", "-D", "CD=1", "-o" });
    const out_s2cd = c2cd.addOutputFileArg("stage2_cd.bin");
    c2cd.addFileArg(b.path("src/boot/stage2.asm"));

    // ------------------------------------------------------------------
    // Partición FAT16 (EFI/BOOT/BOOTX64.EFI + LEEME.txt)
    // ------------------------------------------------------------------
    const mkfat = b.addSystemCommand(&.{ b.graph.zig_exe, "run", "tools/mkfat.zig", "--" });
    const out_fat = mkfat.addOutputFileArg("antlex.fat16");
    mkfat.addArg(b.fmt("{d}", .{@divExact(lay.fat_size, 512)}));
    mkfat.addFileArg(efi.getEmittedBin());
    mkfat.addFileArg(b.path("fsroot/LEEME.txt"));

    // ------------------------------------------------------------------
    // Imagen de disco (MBR + stage2 + FAT16 + kernel + particiones)
    // ------------------------------------------------------------------
    const mki = b.addSystemCommand(&.{ b.graph.zig_exe, "run", "tools/mkimage.zig", "--" });
    mki.addFileArg(kernel.getEmittedBin());
    mki.addFileArg(out_s1);
    mki.addFileArg(out_s2);
    mki.addFileArg(out_fat);
    const img = mki.addOutputFileArg("antlexos.img");
    mki.addArgs(&.{
        b.fmt("{d}", .{lay.kernel_off}),
        b.fmt("{d}", .{lay.fat_off}),
        b.fmt("{d}", .{lay.fat_size}),
        b.fmt("{d}", .{lay.alfs_off}),
        b.fmt("{d}", .{lay.disk_size}),
        b.fmt("{d}", .{lay.kernel_max_size}),
        b.fmt("{d}", .{lay.kernel_load_addr}),
    });
    mki.step.dependOn(&c1.step);
    mki.step.dependOn(&c2.step);

    const inst_img = b.addInstallFile(img, "antlexos.img");
    b.getInstallStep().dependOn(&inst_img.step);
    const inst_s2cd = b.addInstallFile(out_s2cd, "stage2_cd.bin");
    b.getInstallStep().dependOn(&inst_s2cd.step);

    // ------------------------------------------------------------------
    // Pruebas unitarias en host (tablas, ALFS, LEX…)
    // ------------------------------------------------------------------
    const pruebas = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const correr = b.addRunArtifact(pruebas);
    const paso_test = b.step("test", "Pruebas unitarias en host");
    paso_test.dependOn(&correr.step);

    // ------------------------------------------------------------------
    // Arranque de prueba en QEMU (BIOS y UEFI)
    // ------------------------------------------------------------------
    const probar = b.addSystemCommand(&.{ "python3", "tools/probar_boot.py" });
    probar.addArg(b.pathFromRoot("zig-out/antlexos.img"));
    probar.addArg(b.pathFromRoot("build/pruebas"));
    probar.step.dependOn(b.getInstallStep());
    const paso_probar = b.step("probar", "Arranca en QEMU (BIOS) y valida serial + capturas");
    paso_probar.dependOn(&probar.step);

    const probar_uefi = b.addSystemCommand(&.{ "python3", "tools/probar_boot.py" });
    probar_uefi.addArg(b.pathFromRoot("zig-out/antlexos.img"));
    probar_uefi.addArg(b.pathFromRoot("build/pruebas_uefi"));
    probar_uefi.addArg("--uefi");
    probar_uefi.addArg("--tiempo");
    probar_uefi.addArg("90");
    probar_uefi.step.dependOn(b.getInstallStep());
    const paso_probar_uefi = b.step("probar-uefi", "Arranca en QEMU+OVMF y valida serial + capturas");
    paso_probar_uefi.dependOn(&probar_uefi.step);

    // ------------------------------------------------------------------
    // Regeneración de la fuente bitmap (manual, para reproducibilidad)
    // ------------------------------------------------------------------
    const genf = b.addSystemCommand(&.{ b.graph.zig_exe, "run", "tools/genfont.zig", "--" });
    genf.addFileArg(b.path("assets/unifont.hex"));
    genf.addArg("--subconjunto");
    genf.addFileArg(b.path("assets/unifont_subconjunto.hex"));
    const paso_fuente = b.step("fuente", "Regenera src/kernel/fuente_datos.zig");
    paso_fuente.dependOn(&genf.step);
}
