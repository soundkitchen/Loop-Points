//! K!LN の CLI。ファイルの読み書きと引数処理だけを担い、処理はコアに任せる。
const std = @import("std");
const Io = std.Io;
const kiln = @import("kiln");
const time = @import("time.zig");

const usage =
    \\Usage:
    \\  kiln trim <input> <output> [--start TIME] [--end TIME | --duration TIME]
    \\  kiln --version
    \\  kiln --help
    \\
    \\Commands:
    \\  trim    Cut an MP3 without re-encoding, accurate to the sample.
    \\          <input> / <output> may be "-" for stdin / stdout.
    \\
    \\TIME:
    \\  1.5         seconds
    \\  1:02.5      minutes:seconds (also hours:minutes:seconds)
    \\  66150s      samples
    \\
;

/// 入力ファイルの大きさの上限
const max_input_len = 1 << 32;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // stdout / stderr はストリーミングで書く。位置指定書き込み(.init)だと、
    // ファイルへのリダイレクト時に先頭から書いてしまい、既存の内容を上書きする
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    // stderr は最後にまとめて書き出す(書けなくても終了コードは変えない)
    defer stderr.flush() catch {};

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try stdout.print("kiln {s}\n", .{kiln.version});
        // 書き込みの失敗(閉じたパイプなど)を終了コードに反映するため、flush のエラーは返す
        try stdout.flush();
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try stdout.writeAll(usage);
        try stdout.flush();
        return 0;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "trim")) {
        return trim(init, args[2..], stdout, stderr);
    }

    try stderr.writeAll(usage);
    return 2;
}

const TrimArgs = struct {
    input: []const u8,
    output: []const u8,
    start: ?time.Time = null,
    end: ?time.Time = null,
    duration: ?time.Time = null,
};

/// trim の引数を解析する。誤りがあれば stderr に書いて null を返す
fn parseTrimArgs(args: []const [:0]const u8, stderr: *Io.Writer) !?TrimArgs {
    var positional: [2][]const u8 = undefined;
    var n: usize = 0;
    var r: TrimArgs = .{ .input = undefined, .output = undefined };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const slot: ?*?time.Time = if (std.mem.eql(u8, arg, "--start"))
            &r.start
        else if (std.mem.eql(u8, arg, "--end"))
            &r.end
        else if (std.mem.eql(u8, arg, "--duration"))
            &r.duration
        else
            null;
        if (slot) |s| {
            i += 1;
            if (i == args.len) {
                try stderr.print("error: {s} needs a value\n", .{arg});
                return null;
            }
            s.* = time.parse(args[i]) catch {
                try stderr.print("error: invalid time for {s}: '{s}'\n", .{ arg, args[i] });
                return null;
            };
        } else if (arg.len > 1 and arg[0] == '-') {
            try stderr.print("error: unknown option '{s}'\n", .{arg});
            return null;
        } else {
            if (n == 2) {
                try stderr.print("error: unexpected argument '{s}'\n", .{arg});
                return null;
            }
            positional[n] = arg;
            n += 1;
        }
    }
    if (n != 2) {
        try stderr.writeAll("error: trim needs <input> and <output>\n");
        return null;
    }
    if (r.end != null and r.duration != null) {
        try stderr.writeAll("error: --end and --duration cannot be used together\n");
        return null;
    }
    r.input = positional[0];
    r.output = positional[1];
    return r;
}

fn trim(init: std.process.Init, args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const a = try parseTrimArgs(args, stderr) orelse {
        try stderr.writeAll("\n" ++ usage);
        return 2;
    };
    const io = init.io;
    const gpa = init.gpa;

    const input = readInput(io, gpa, a.input) catch |err| {
        try stderr.print("error: cannot read '{s}': {t}\n", .{ a.input, err });
        return 1;
    };
    defer gpa.free(input);

    const info = kiln.mp3.probe(input) catch |err| {
        try stderr.print("error: {s}: {s}\n", .{ a.input, describe(err) });
        return 1;
    };

    const sr = info.sample_rate;
    const start = if (a.start) |t| t.toSamples(sr) catch info.samples else 0;
    const end: ?u64 = if (a.end) |t|
        t.toSamples(sr) catch info.samples
    else if (a.duration) |t|
        std.math.add(u64, start, t.toSamples(sr) catch info.samples) catch info.samples
    else
        null;

    // 出力を開く前に区間を確かめ、空の区間で出力ファイルを作ってしまわないようにする
    if (@max(start, info.min_start) >= @min(end orelse info.samples, info.samples)) {
        try stderr.print("error: empty range (input has {d} samples)\n", .{info.samples});
        return 1;
    }

    const options: kiln.mp3.TrimOptions = .{ .start = start, .end = end };
    const r = writeOutput(io, a.output, input, options, stdout) catch |err| {
        try stderr.print("error: cannot write '{s}': {s}\n", .{ a.output, describe(err) });
        return 1;
    };

    // 先頭を指定しなかったときの切り上げ(タグなしの入力で 0 → 529)は、利用者の意図どおりなので黙っておく
    if (a.start != null and r.start != start) {
        try stderr.print("warning: start rounded up to {d} samples (the decoder delay cannot be reproduced)\n", .{r.start});
    }
    if (end) |e| if (r.end != e) {
        try stderr.print("warning: end clamped to the end of the input ({d} samples)\n", .{r.end});
    };
    return 0;
}

fn readInput(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buf: [64 * 1024]u8 = undefined;
        var reader = Io.File.stdin().readerStreaming(io, &buf);
        return reader.interface.allocRemaining(gpa, .limited(max_input_len));
    }
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input_len));
}

fn writeOutput(io: Io, path: []const u8, input: []const u8, options: kiln.mp3.TrimOptions, stdout: *Io.Writer) !kiln.mp3.TrimResult {
    if (std.mem.eql(u8, path, "-")) {
        const r = try kiln.mp3.trim(input, options, stdout);
        try stdout.flush();
        return r;
    }
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const r = try kiln.mp3.trim(input, options, &fw.interface);
    try fw.interface.flush();
    return r;
}

/// コアのエラーを利用者向けの説明にする
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotMp3 => "not an MP3 file",
        error.UnsupportedFormat => "unsupported MPEG audio (only MPEG-1 Layer III is supported)",
        error.EmptyRange => "empty range",
        error.TooLarge => "output is too large",
        else => @errorName(err),
    };
}

test {
    _ = time;
}

test parseTrimArgs {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const ok = (try parseTrimArgs(&.{ "in.mp3", "--start", "1.5", "out.mp3", "--duration", "2s" }, &w)).?;
    try std.testing.expectEqualStrings("in.mp3", ok.input);
    try std.testing.expectEqualStrings("out.mp3", ok.output);
    try std.testing.expectEqual(66150, try ok.start.?.toSamples(44100));
    try std.testing.expectEqual(2, try ok.duration.?.toSamples(44100));
    try std.testing.expectEqual(null, ok.end);
    // "-" は stdin / stdout
    _ = (try parseTrimArgs(&.{ "-", "-" }, &w)).?;

    for ([_][]const [:0]const u8{
        &.{"in.mp3"},
        &.{ "in.mp3", "out.mp3", "x.mp3" },
        &.{ "in.mp3", "out.mp3", "--start" },
        &.{ "in.mp3", "out.mp3", "--start", "abc" },
        &.{ "in.mp3", "out.mp3", "--end", "1", "--duration", "1" },
        &.{ "in.mp3", "out.mp3", "--bogus" },
    }) |bad| {
        try std.testing.expectEqual(null, try parseTrimArgs(bad, &w));
    }
}
