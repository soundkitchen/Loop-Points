// SPDX-License-Identifier: MIT
const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // バージョンは build.zig.zon を唯一の出所にし、ビルドオプションとしてコアに渡す
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    const options_mod = options.createModule();

    // wasm(wasm32-freestanding)。-Dtarget とは無関係に常に wasm 向けにビルドする
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_optimize: std.lang.Optimize = if (optimize == .debug) .small else optimize;
    const wasm_kiln = b.createModule(kilnModuleOptions(b, wasm_target, wasm_optimize, options_mod));
    addVendored(b, wasm_kiln);
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

    // zig-out/kiln.wasm に置く。JS 側の包み(wasm/kiln.ts)は、Loop Points がソースから直接 import する
    const install_wasm = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .prefix } });
    const wasm_step = b.step("wasm", "wasm をビルドする");
    wasm_step.dependOn(&install_wasm.step);
    b.getInstallStep().dependOn(wasm_step);

    // テスト(コア。wasm はネイティブで実行できないため、ビルドの成否で確認する)
    const test_step = b.step("test", "テストを実行する");
    // コアのテストは testdata/ の音声を使うため、testdata モジュールを import できる
    // テスト専用のモジュールで実行する(wasm に入れる kiln モジュールには含めない)
    const testdata = b.createModule(.{ .root_source_file = b.path("testdata/testdata.zig") });
    const core_test_mod = b.createModule(kilnModuleOptions(b, target, optimize, options_mod));
    addVendored(b, core_test_mod);
    core_test_mod.addImport("testdata", testdata);
    const core_tests = b.addTest(.{ .root_module = core_test_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(wasm_step);
}

/// コアのモジュールの定義。wasm とテストのモジュールで共有し、定義がずれないようにする
fn kilnModuleOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    options_mod: *std.Build.Module,
) std.Build.Module.CreateOptions {
    return .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = b.allocator.dupe(std.Build.Module.Import, &.{
            .{ .name = "build_options", .module = options_mod },
        }) catch @panic("OOM"),
    };
}

/// libvorbis のうち、エンコーダーに要るファイル(vendor/libvorbis/lib/)
const vorbis_sources = [_][]const u8{
    "analysis.c", "bitrate.c", "block.c",      "codebook.c", "envelope.c",  "floor0.c",    "floor1.c",
    "info.c",     "lookup.c",  "lpc.c",        "lsp.c",      "mapping0.c",  "mdct.c",      "psy.c",
    "registry.c", "res0.c",    "sharedbook.c", "smallft.c",  "synthesis.c", "vorbisenc.c", "window.c",
};

/// 取り込んだ C のコード(vendor/ の libvorbis と、それが使う libogg のビットの読み書き)と、それを Zig から呼ぶ包み
/// (src/c/vorbis_enc.c)を、コアのモジュールに足す。libc はリンクせず、C のコードが使う関数は src/c/ で用意する
/// (ヘッダーは src/c/include/、実装は src/c/libc.zig。docs/ogg.md §8.2)
fn addVendored(b: *std.Build, m: *std.Build.Module) void {
    // src/c/include を先に置き、stdlib.h などを kiln のものにする
    m.addIncludePath(b.path("src/c/include"));
    m.addIncludePath(b.path("vendor/libogg/include"));
    m.addIncludePath(b.path("vendor/libvorbis/include"));
    m.addIncludePath(b.path("vendor/libvorbis/lib"));
    const flags = [_][]const u8{ "-std=gnu99", "-ffreestanding" };
    // HAVE_ALLOCA_H: libvorbis の os.h に alloca.h を読ませる。
    // -fno-sanitize=shift-base: libvorbis は負の値を左にシフトする(psy.c の `(lo-1)<<16` など)。C99 では未定義だが、
    // どのコンパイラも 2 の補数のシフトにする(C23 で定義された)。デバッグのビルド(コアのテスト)で Zig が入れる
    // 検査がこれで止まるので、この検査だけを外す。取り込んだソースは変えない
    const vendored_flags = flags ++ [_][]const u8{ "-DHAVE_ALLOCA_H", "-fno-sanitize=shift-base", "-fno-sanitize=bounds" };
    m.addCSourceFiles(.{ .root = b.path("vendor/libvorbis/lib"), .files = &vorbis_sources, .flags = &vendored_flags });
    m.addCSourceFiles(.{ .root = b.path("vendor/libogg/src"), .files = &.{"bitwise.c"}, .flags = &vendored_flags });
    m.addCSourceFiles(.{ .root = b.path("src/c"), .files = &.{"vorbis_enc.c"}, .flags = &flags });
}
