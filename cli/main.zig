// SPDX-License-Identifier: MIT
//! K!LN の CLI。ファイルの読み書きと引数処理だけを担い、処理はコアに任せる。
const std = @import("std");
const Io = std.Io;
const kiln = @import("kiln");
const time = @import("time.zig");

const usage =
    \\Usage:
    \\  kiln trim <input> <output> [--start TIME] [--end TIME | --duration TIME]
    \\            [--format FORMAT] [--sample-format SAMPLE] [--dither DITHER]
    \\  kiln --version
    \\  kiln --help
    \\
    \\Commands:
    \\  trim    Cut an MP3 or WAV file, accurate to the sample, without re-encoding.
    \\          With --format wav, an MP3 input is decoded and written as WAV.
    \\          <input> / <output> may be "-" for stdin / stdout.
    \\          The input format is detected from its contents.
    \\
    \\Options:
    \\  --format FORMAT         output format: mp3 or wav (default: same as the input).
    \\                          Only MP3 to WAV conversion is supported.
    \\  --sample-format SAMPLE  WAV sample format when decoding MP3:
    \\                          u8, i16 (default), i24, i32, f32 or f64
    \\  --dither DITHER         dither when decoding MP3 to an integer format:
    \\                          tpdf (default) or none
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
    format: ?kiln.Format = null,
    sample_format: ?kiln.pcm.Format = null,
    dither: ?kiln.pcm.Dither = null,
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
        if (std.mem.eql(u8, arg, "--sample-format") or std.mem.eql(u8, arg, "--dither")) {
            i += 1;
            if (i == args.len) {
                try stderr.print("error: {s} needs a value\n", .{arg});
                return null;
            }
            if (arg[2] == 's') {
                r.sample_format = std.meta.stringToEnum(kiln.pcm.Format, args[i]) orelse {
                    try stderr.print("error: unknown sample format '{s}' (u8, i16, i24, i32, f32 or f64)\n", .{args[i]});
                    return null;
                };
            } else {
                r.dither = std.meta.stringToEnum(kiln.pcm.Dither, args[i]) orelse {
                    try stderr.print("error: unknown dither '{s}' (tpdf or none)\n", .{args[i]});
                    return null;
                };
            }
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i == args.len) {
                try stderr.print("error: {s} needs a value\n", .{arg});
                return null;
            }
            r.format = std.meta.stringToEnum(kiln.Format, args[i]) orelse {
                try stderr.print("error: unknown format '{s}' (mp3 or wav)\n", .{args[i]});
                return null;
            };
        } else if (slot) |s| {
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

    const in_format = kiln.detect(input) orelse {
        try stderr.print("error: {s}: unknown format (not an MP3 or WAV file)\n", .{a.input});
        return 1;
    };
    const out_format = a.format orelse in_format;
    // 変換できるのは MP3 → WAV だけ(MP3 のエンコーダはない)
    const convert = out_format != in_format;
    if (convert and !(in_format == .mp3 and out_format == .wav)) {
        try stderr.print("error: converting {s} to {s} is not supported\n", .{ in_format.name(), out_format.name() });
        return 1;
    }
    if (!convert and (a.sample_format != null or a.dither != null)) {
        try stderr.writeAll("error: --sample-format and --dither are only used when converting (--format wav for an MP3 input)\n");
        return 2;
    }
    const info = probe(in_format, input) catch |err| {
        try stderr.print("error: {s}: {s}\n", .{ a.input, describe(in_format, err) });
        return 1;
    };

    const sr = info.sample_rate;
    // デコードするときは先頭の切り上げ(タグなしの MP3 の 529)はいらない
    const min_start = if (convert) 0 else info.min_start;
    const start = if (a.start) |t| t.toSamples(sr) catch info.samples else 0;
    const end: ?u64 = if (a.end) |t|
        t.toSamples(sr) catch info.samples
    else if (a.duration) |t|
        // 長さは、切り上げた後の実際の開始位置から数える(出力の長さが指定どおりになるように)
        std.math.add(u64, @max(start, min_start), t.toSamples(sr) catch info.samples) catch info.samples
    else
        null;

    const job: Job = .{
        .format = in_format,
        .input = input,
        .range = .{ .start = start, .end = end },
        .convert = if (convert) .{
            .format = a.sample_format orelse .i16,
            .dither = a.dither orelse .tpdf,
        } else null,
    };
    const r = writeOutput(io, a.output, job, stdout) catch |err| switch (err) {
        error.EmptyRange => {
            try stderr.print("error: empty range (input has {d} samples)\n", .{info.samples});
            return 1;
        },
        else => {
            try stderr.print("error: cannot write '{s}': {s}\n", .{ a.output, describe(in_format, err) });
            return 1;
        },
    };

    // 先頭を指定しなかったときの切り上げ(タグなしの入力で 0 → 529)は、利用者の意図どおりなので黙っておく。
    // デコードするときは切り上げない
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

/// トリムに使う入力の情報(形式によらないもの)
const Info = struct {
    sample_rate: u32,
    /// 長さ(サンプル数)
    samples: u64,
    /// 指定できる先頭の最小値(タグなしの MP3 では 529、それ以外は 0)
    min_start: u64,
};

fn probe(format: kiln.Format, input: []const u8) !Info {
    return switch (format) {
        .mp3 => blk: {
            const i = try kiln.mp3.probe(input);
            break :blk .{ .sample_rate = i.sample_rate, .samples = i.samples, .min_start = i.min_start };
        },
        .wav => blk: {
            const i = try kiln.wav.probe(input);
            break :blk .{ .sample_rate = i.sample_rate, .samples = i.samples, .min_start = 0 };
        },
    };
}

/// 切り出す区間の指定(end が null なら末尾まで)
const Range = struct { start: u64, end: ?u64 };
/// 実際に切り出した区間
const Trimmed = struct { start: u64, end: u64 };

/// 書き出しの内容
const Job = struct {
    format: kiln.Format,
    input: []const u8,
    range: Range,
    /// MP3 をデコードして WAV で書くときの設定(null なら入力と同じ形式で切り出す)
    convert: ?struct { format: kiln.pcm.Format, dither: kiln.pcm.Dither },
};

/// 区間を切り出して(またはデコードして WAV にして)`w` に書き、実際に書いた区間を返す
fn run(job: Job, w: *Io.Writer) !Trimmed {
    const c = job.convert orelse return trimTo(job.format, job.input, job.range, w);
    const info = try kiln.mp3.probe(job.input);
    const end = @min(job.range.end orelse info.samples, info.samples);
    // 空の区間は、ヘッダを書く前に弾く
    if (job.range.start >= end) return error.EmptyRange;
    var enc: kiln.wav.Encoder = try .init(w, .{
        .sample_rate = info.sample_rate,
        .channels = info.channels,
        .format = c.format,
        .dither = c.dither,
        .frames = end - job.range.start,
    });
    const r = try kiln.mp3.decode(job.input, .{ .start = job.range.start, .end = end }, &enc);
    _ = try enc.finish();
    return .{ .start = r.start, .end = r.end };
}

/// 区間を切り出して `w` に書き、実際に切り出した区間を返す
fn trimTo(format: kiln.Format, input: []const u8, range: Range, w: *Io.Writer) !Trimmed {
    return switch (format) {
        .mp3 => blk: {
            const r = try kiln.mp3.trim(input, .{ .start = range.start, .end = range.end }, w);
            break :blk .{ .start = r.start, .end = r.end };
        },
        .wav => blk: {
            const r = try kiln.wav.trim(input, .{ .start = range.start, .end = range.end }, w);
            break :blk .{ .start = r.start, .end = r.end };
        },
    };
}

/// トリムした結果を書き出す。ファイルへは一時ファイルに書き、最後まで書けたときだけ
/// 出力先に置き換える(失敗しても、既存の出力先のファイルは元のまま残る)
fn writeOutput(io: Io, path: []const u8, job: Job, stdout: *Io.Writer) !Trimmed {
    if (std.mem.eql(u8, path, "-")) {
        const r = try run(job, stdout);
        try stdout.flush();
        return r;
    }
    var af = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &buf);
    const r = try run(job, &fw.interface);
    try fw.interface.flush();
    try af.replace(io);
    return r;
}

/// コアのエラーを利用者向けの説明にする
fn describe(format: kiln.Format, err: anyerror) []const u8 {
    return switch (err) {
        error.NotMp3 => "not an MP3 file",
        error.NotWav => "not a WAV file",
        error.InvalidWav => "broken WAV file (missing or invalid fmt / data chunk)",
        error.UnsupportedFormat => switch (format) {
            .mp3 => "unsupported MPEG audio (only MPEG-1 Layer III is supported)",
            .wav => "unsupported WAV (only little-endian RIFF with PCM or IEEE float is supported; RF64, RIFX and compressed encodings are not)",
        },
        error.EmptyRange => "empty range",
        error.TooLarge => "output is too large",
        else => @errorName(err),
    };
}

test {
    _ = time;
}

test parseTrimArgs {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const ok = (try parseTrimArgs(&.{ "in.mp3", "--start", "1.5", "out.mp3", "--duration", "2s" }, &w)).?;
    try std.testing.expectEqualStrings("in.mp3", ok.input);
    try std.testing.expectEqualStrings("out.mp3", ok.output);
    try std.testing.expectEqual(66150, try ok.start.?.toSamples(44100));
    try std.testing.expectEqual(2, try ok.duration.?.toSamples(44100));
    try std.testing.expectEqual(null, ok.end);
    try std.testing.expectEqual(null, ok.format);
    // "-" は stdin / stdout
    _ = (try parseTrimArgs(&.{ "-", "-" }, &w)).?;
    try std.testing.expectEqual(kiln.Format.wav, (try parseTrimArgs(&.{ "a", "b", "--format", "wav" }, &w)).?.format.?);
    const conv = (try parseTrimArgs(&.{ "a", "b", "--format", "wav", "--sample-format", "f32", "--dither", "none" }, &w)).?;
    try std.testing.expectEqual(kiln.pcm.Format.f32, conv.sample_format.?);
    try std.testing.expectEqual(kiln.pcm.Dither.none, conv.dither.?);

    for ([_][]const [:0]const u8{
        &.{"in.mp3"},
        &.{ "in.mp3", "out.mp3", "x.mp3" },
        &.{ "in.mp3", "out.mp3", "--start" },
        &.{ "in.mp3", "out.mp3", "--start", "abc" },
        &.{ "in.mp3", "out.mp3", "--end", "1", "--duration", "1" },
        &.{ "in.mp3", "out.mp3", "--bogus" },
        &.{ "in.mp3", "out.mp3", "--format" },
        &.{ "in.mp3", "out.mp3", "--format", "flac" },
        &.{ "in.mp3", "out.wav", "--sample-format", "s16" },
        &.{ "in.mp3", "out.wav", "--dither" },
        &.{ "in.mp3", "out.wav", "--dither", "rpdf" },
    }) |bad| {
        try std.testing.expectEqual(null, try parseTrimArgs(bad, &w));
    }
}
