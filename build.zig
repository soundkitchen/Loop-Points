const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // バージョンは build.zig.zon を唯一の出所にし、ビルドオプションとしてコアに渡す
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    const options_mod = options.createModule();

    // コア(I/O を持たないライブラリ)。他のパッケージからも @import("kiln") で使える
    const kiln = b.addModule("kiln", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = options_mod }},
    });

    // CLI
    const exe = b.addExecutable(.{
        .name = "kiln",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kiln", .module = kiln }},
        }),
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // run は CLI のインストールにだけ依存させ、wasm のビルドを待たない
    const run_step = b.step("run", "CLI を実行する");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(&install_exe.step);
    run_cmd.addPassthruArgs();

    // wasm(wasm32-freestanding)。-Dtarget とは無関係に常に wasm 向けにビルドする
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_optimize: std.lang.Optimize = if (optimize == .debug) .small else optimize;
    const wasm_kiln = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .imports = &.{.{ .name = "build_options", .module = options_mod }},
    });
    const wasm = b.addExecutable(.{
        .name = "kiln",
        .root_module = b.createModule(.{
            .root_source_file = b.path("wasm/main.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{.{ .name = "kiln", .module = wasm_kiln }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    // zig-out/wasm/ に kiln.wasm と JS ラッパーを置く
    const wasm_dir: std.Build.InstallDir = .{ .custom = "wasm" };
    const install_wasm = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = wasm_dir } });
    const install_js = b.addInstallFileWithDir(b.path("wasm/kiln.js"), wasm_dir, "kiln.js");
    const wasm_step = b.step("wasm", "wasm と JS ラッパーをビルドする");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&install_js.step);
    // 既定の zig build でも wasm をビルドし、壊れたら気づけるようにする
    b.getInstallStep().dependOn(wasm_step);

    // テスト(コアと CLI。wasm はネイティブで実行できないため、ビルドの成否で確認する)
    const test_step = b.step("test", "テストを実行する");
    const core_tests = b.addTest(.{ .root_module = kiln });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    const cli_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    test_step.dependOn(wasm_step);
}
