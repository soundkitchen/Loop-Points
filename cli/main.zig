//! K!LN の CLI。ファイルの読み書きと引数処理だけを担い、処理はコアに任せる。
const std = @import("std");
const Io = std.Io;
const kiln = @import("kiln");

const usage =
    \\Usage: kiln [--version] [--help]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // stdout / stderr はストリーミングで書く。位置指定書き込み(.init)だと、
    // ファイルへのリダイレクト時に先頭から書いてしまい、既存の内容を上書きする
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try stdout.print("kiln {s}\n", .{kiln.version});
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try stdout.writeAll(usage);
        return 0;
    }

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll(usage);
    try stderr.flush();
    return 2;
}
