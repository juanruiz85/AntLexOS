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
    // formato y operaciones ALFS compartidas por kernel, mkalfs y pruebas
    // (alfs_volumen importa alfs_formato de forma relativa: módulo único)
    const mod_alfs_volumen = b.createModule(.{
        .root_source_file = b.path("src/kernel/alfs_volumen.zig"),
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
    const img_base = mki.addOutputFileArg("antlexos_base.img");
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

    // ------------------------------------------------------------------
    // Volumen ALFS inicial desde fsroot/ (misma lógica que el kernel)
    // ------------------------------------------------------------------
    const mkalfs = b.addExecutable(.{
        .name = "mkalfs",
        .root_source_file = b.path("tools/mkalfs.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    mkalfs.root_module.addImport("alfs_volumen", mod_alfs_volumen);
    const correr_mkalfs = b.addRunArtifact(mkalfs);
    correr_mkalfs.addFileArg(img_base);
    correr_mkalfs.addDirectoryArg(b.path("fsroot"));
    const img = correr_mkalfs.addOutputFileArg("antlexos.img");
    correr_mkalfs.addArg(b.fmt("{d}", .{lay.alfs_off}));
    correr_mkalfs.addArg(b.fmt("{d}", .{lay.alfs_size}));
    correr_mkalfs.step.dependOn(&mki.step);

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
    // Persistencia de ALFS (escribir → reinicio → verificar → limpiar)
    // ------------------------------------------------------------------
    const probar_alfs = b.addSystemCommand(&.{ "python3", "tools/probar_alfs.py" });
    probar_alfs.addArg(b.pathFromRoot("zig-out/antlexos.img"));
    probar_alfs.addArg(b.pathFromRoot("build/pruebas_alfs"));
    probar_alfs.addArg("--tiempo");
    probar_alfs.addArg("90");
    probar_alfs.step.dependOn(b.getInstallStep());
    const paso_probar_alfs = b.step("probar-alfs", "Persistencia ALFS: crea archivo, reinicia y verifica");
    paso_probar_alfs.dependOn(&probar_alfs.step);

    // ------------------------------------------------------------------
    // Intérprete completo (Fase 3): historial, TAB, reloj, buscar, apagado
    // ------------------------------------------------------------------
    const probar_interp = b.addSystemCommand(&.{ "python3", "tools/probar_interprete.py" });
    probar_interp.addArg(b.pathFromRoot("zig-out/antlexos.img"));
    probar_interp.addArg(b.pathFromRoot("build/pruebas_interprete"));
    probar_interp.addArg("--tiempo");
    probar_interp.addArg("180");
    probar_interp.step.dependOn(b.getInstallStep());
    const paso_probar_interp = b.step("probar-interprete", "Sesión real por QMP: historial, TAB, reloj, buscar y apagado");
    paso_probar_interp.dependOn(&probar_interp.step);

    // ------------------------------------------------------------------
    // IA AntLex (Fase 4): preguntas reales, memoria aprendida, por qué
    // ------------------------------------------------------------------
    const probar_antlex = b.addSystemCommand(&.{ "python3", "tools/probar_antlex.py" });
    probar_antlex.addArg(b.pathFromRoot("zig-out/antlexos.img"));
    probar_antlex.addArg(b.pathFromRoot("build/pruebas_antlex"));
    probar_antlex.addArg("--tiempo");
    probar_antlex.addArg("180");
    probar_antlex.step.dependOn(b.getInstallStep());
    const paso_probar_antlex = b.step("probar-antlex", "Conversación real con AntLex por QMP: intenciones, aprende, por qué");
    paso_probar_antlex.dependOn(&probar_antlex.step);

    // ------------------------------------------------------------------
    // IA AntLex (Fase 4): nucleo.zig y corpus.zig compartidos por el
    // entrenador (host) y las pruebas; el kernel los importa relativamente.
    // ------------------------------------------------------------------
    const mod_antlex_nucleo = b.createModule(.{
        .root_source_file = b.path("src/kernel/antlex/nucleo.zig"),
    });
    const mod_antlex_corpus = b.createModule(.{
        .root_source_file = b.path("src/kernel/antlex/corpus.zig"),
    });

    const entrenar = b.addExecutable(.{
        .name = "entrenar_antlex",
        .root_source_file = b.path("tools/entrenar_antlex.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    entrenar.root_module.addImport("nucleo", mod_antlex_nucleo);
    entrenar.root_module.addImport("corpus", mod_antlex_corpus);

    const correr_entrenar = b.addRunArtifact(entrenar);
    correr_entrenar.addArg(b.pathFromRoot("src/kernel/antlex"));
    // el archivo generado pasa por `zig fmt` para que `zig fmt --check` en
    // CI no lo rechace (solo alinea columnas; --verificar compara enteros)
    const fmt_pesos = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt" });
    fmt_pesos.addFileArg(b.path("src/kernel/antlex/pesos.zig"));
    fmt_pesos.step.dependOn(&correr_entrenar.step);
    const paso_entrenar = b.step("entrenar", "Reentrena la IA AntLex y regenera pesos.zig (determinista)");
    paso_entrenar.dependOn(&fmt_pesos.step);

    const correr_entrenar_v = b.addRunArtifact(entrenar);
    correr_entrenar_v.addArg(b.pathFromRoot("src/kernel/antlex"));
    correr_entrenar_v.addArg("--verificar");
    const paso_entrenar_v = b.step("entrenar-verificar", "Reentrena y compara pesos.zig con lo commiteado");
    paso_entrenar_v.dependOn(&correr_entrenar_v.step);

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
