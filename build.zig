//! AntLex OS — build.zig: kernel, bootloaders, imagen de disco y pruebas.
//! Herramientas: zig 0.14.1, nasm, python3 (solo para probar_boot.py).

const std = @import("std");
const lay = @import("layout.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

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
    // Imagen de disco (MBR + stage2 + kernel + particiones)
    // ------------------------------------------------------------------
    const mki = b.addSystemCommand(&.{ b.graph.zig_exe, "run", "tools/mkimage.zig", "--" });
    mki.addFileArg(kernel.getEmittedBin());
    mki.addFileArg(out_s1);
    mki.addFileArg(out_s2);
    const img = mki.addOutputFileArg("antlexos.img");
    mki.addArgs(&.{
        b.fmt("{d}", .{lay.kernel_off}),
        b.fmt("{d}", .{lay.fat_off}),
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
    // Arranque de prueba en QEMU (serial + captura)
    // ------------------------------------------------------------------
    const probar = b.addSystemCommand(&.{ "python3", "tools/probar_boot.py" });
    probar.addArg(b.pathFromRoot("zig-out/antlexos.img"));
    probar.addArg(b.pathFromRoot("build/pruebas"));
    probar.step.dependOn(b.getInstallStep());
    const paso_probar = b.step("probar", "Arranca en QEMU y valida serial + captura");
    paso_probar.dependOn(&probar.step);

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
