// SPDX-License-Identifier: MIT
//! K!LN の CLI。ファイルの読み書きと引数処理だけを担い、処理はコアに任せる。
const std = @import("std");
const Io = std.Io;
const kiln = @import("kiln");
const time = @import("time.zig");

const usage =
    \\Usage:
    \\  kiln trim <input> <output> [--start TIME] [--end TIME | --duration TIME]
    \\            [--format FORMAT] [--sample-format SAMPLE] [--bits N]
    \\            [--compression N] [--dither DITHER]
    \\  kiln info <input>
    \\  kiln --version
    \\  kiln --help
    \\
    \\Commands:
    \\  trim    Cut an MP3, WAV or FLAC file, accurate to the sample. MP3 and WAV are
    \\          cut without re-encoding; FLAC re-encodes only the frames at the cut
    \\          points (losslessly). With --format, convert while cutting: MP3 or
    \\          FLAC to WAV, and WAV or MP3 to FLAC.
    \\          <input> / <output> may be "-" for stdin / stdout.
    \\          The input format is detected from its contents.
    \\  info    Show the format, sample rate, channels and length of an MP3, WAV,
    \\          FLAC, Ogg (Vorbis / Opus), M4A (AAC / ALAC) or AAC (ADTS) file.
    \\          Cutting Ogg, M4A and AAC files is not supported yet.
    \\
    \\Options:
    \\  --format FORMAT         output format: mp3, wav or flac (default: same as the input)
    \\  --sample-format SAMPLE  WAV sample format when decoding MP3 or FLAC:
    \\                          u8, i16, i24, i32, f32 or f64 (default: i16 for MP3,
    \\                          the smallest one that keeps the bit depth for FLAC)
    \\  --bits N                FLAC bit depth when converting to FLAC, 4 to 32
    \\                          (default: the bit depth of an integer WAV, otherwise 16)
    \\  --compression N         FLAC compression level when converting to FLAC,
    \\                          0 (fastest) to
++ std.fmt.comptimePrint(" {d}", .{kiln.flac.max_compression}) ++
    \\ (smallest), as in the flac command
    \\                          (default: 5)
    \\  --dither DITHER         dither when converting to an integer format with less
    \\                          precision: tpdf (default) or none
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
    if (args.len >= 2 and std.mem.eql(u8, args[1], "info")) {
        return infoCommand(init, args[2..], stdout, stderr);
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
    bits: ?u8 = null,
    compression: ?u8 = null,
    dither: ?kiln.pcm.Dither = null,
};

/// `args[i.*]` のオプションの値を読み、`i` を進める。値がなければ stderr に書いて null を返す
fn optionValue(args: []const [:0]const u8, i: *usize, stderr: *Io.Writer) !?[]const u8 {
    const name = args[i.*];
    i.* += 1;
    if (i.* == args.len) {
        try stderr.print("error: {s} needs a value\n", .{name});
        return null;
    }
    return args[i.*];
}

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
        if (std.mem.eql(u8, arg, "--sample-format")) {
            const v = try optionValue(args, &i, stderr) orelse return null;
            r.sample_format = std.meta.stringToEnum(kiln.pcm.Format, v) orelse {
                try stderr.print("error: unknown sample format '{s}' (u8, i16, i24, i32, f32 or f64)\n", .{v});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--bits")) {
            const v = try optionValue(args, &i, stderr) orelse return null;
            r.bits = std.fmt.parseInt(u8, v, 10) catch null;
            if (r.bits == null or r.bits.? < 4 or r.bits.? > 32) {
                try stderr.print("error: invalid --bits '{s}' (4 to 32)\n", .{v});
                return null;
            }
        } else if (std.mem.eql(u8, arg, "--compression")) {
            const v = try optionValue(args, &i, stderr) orelse return null;
            r.compression = std.fmt.parseInt(u8, v, 10) catch null;
            if (r.compression == null or r.compression.? > kiln.flac.max_compression) {
                try stderr.print("error: invalid --compression '{s}' (0 to {d})\n", .{ v, kiln.flac.max_compression });
                return null;
            }
        } else if (std.mem.eql(u8, arg, "--dither")) {
            const v = try optionValue(args, &i, stderr) orelse return null;
            r.dither = std.meta.stringToEnum(kiln.pcm.Dither, v) orelse {
                try stderr.print("error: unknown dither '{s}' (tpdf or none)\n", .{v});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i == args.len) {
                try stderr.print("error: {s} needs a value\n", .{arg});
                return null;
            }
            r.format = std.meta.stringToEnum(kiln.Format, args[i]);
            if (r.format == null or !writable(r.format.?)) {
                try stderr.print("error: unknown format '{s}' (mp3, wav or flac)\n", .{args[i]});
                return null;
            }
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
        try stderr.print("error: {s}: unknown format (not an MP3, WAV or FLAC file)\n", .{a.input});
        return 1;
    };
    if (!writable(in_format)) {
        try stderr.print("error: {s}: cutting {s} files is not supported yet (try 'kiln info')\n", .{ a.input, in_format.name() });
        return 1;
    }
    const out_format = a.format orelse in_format;
    // 変換できるのは MP3 / FLAC → WAV と WAV / MP3 → FLAC(MP3 のエンコーダはない)
    const convert = out_format != in_format;
    if (convert and out_format == .mp3) {
        try stderr.print("error: converting {s} to {s} is not supported\n", .{ in_format.name(), out_format.name() });
        return 1;
    }
    if (!convert and a.dither != null) {
        try stderr.writeAll("error: --dither is only used when converting (with --format)\n");
        return 2;
    }
    if (a.sample_format != null and !(convert and out_format == .wav)) {
        try stderr.writeAll("error: --sample-format is only used when converting to WAV (--format wav for an MP3 or FLAC input)\n");
        return 2;
    }
    if ((a.bits != null or a.compression != null) and !(convert and out_format == .flac)) {
        try stderr.writeAll("error: --bits and --compression are only used when converting to FLAC (--format flac for a WAV or MP3 input)\n");
        return 2;
    }
    // FLAC はフレームの一覧を 1 回だけ作り、解析と書き出しで使い回す(区切りを探す走査を繰り返さない)
    var flac_index: ?kiln.flac.Index = null;
    defer if (flac_index) |*ix| ix.deinit(gpa);
    const info = probe(gpa, in_format, input, &flac_index) catch |err| {
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
        .convert = if (!convert) null else switch (out_format) {
            .wav => .{
                .wav = .{
                    // 省いたとき: MP3 は 16bit 整数、FLAC はビット深度を保つ形式(コアが決める)
                    .format = a.sample_format orelse if (in_format == .mp3) .i16 else null,
                    .dither = a.dither orelse .tpdf,
                },
            },
            .flac => .{
                .flac = .{
                    // 省いたとき: 整数の WAV は元のビット深度、それ以外は 16(コアが決める)
                    .bits_per_sample = a.bits,
                    .compression = a.compression orelse 5,
                    .dither = a.dither orelse .tpdf,
                },
            },
            // MP3 のエンコーダはなく、Ogg / m4a / aac は --format に渡せない
            .mp3, .ogg, .m4a, .aac => unreachable,
        },
        .gpa = gpa,
        .flac_index = if (flac_index) |*ix| ix else null,
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
    if (r.invalid_frames > 0) {
        const why = switch (in_format) {
            .mp3 => "broken side information",
            else => "broken frame or CRC mismatch",
        };
        try stderr.print("warning: {d} frame(s) could not be decoded ({s}) and were output as silence\n", .{ r.invalid_frames, why });
    }
    return 0;
}

fn infoCommand(init: std.process.Init, args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    if (args.len != 1 or (args[0].len > 1 and args[0][0] == '-')) {
        try stderr.writeAll("error: info needs exactly one <input>\n\n" ++ usage);
        return 2;
    }
    const path = args[0];
    const input = readInput(init.io, init.gpa, path) catch |err| {
        try stderr.print("error: cannot read '{s}': {t}\n", .{ path, err });
        return 1;
    };
    defer init.gpa.free(input);
    const format = kiln.detect(input) orelse {
        try stderr.print("error: {s}: unknown format (not an MP3, WAV, FLAC, Ogg, M4A or AAC file)\n", .{path});
        return 1;
    };
    writeInfo(format, input, stdout) catch |err| switch (err) {
        error.WriteFailed => return err,
        else => {
            try stderr.print("error: {s}: {s}\n", .{ path, describe(format, err) });
            return 1;
        },
    };
    try stdout.flush();
    return 0;
}

/// 解析した情報を 1 行ずつ「名前: 値」で書く
fn writeInfo(format: kiln.Format, input: []const u8, w: *Io.Writer) !void {
    try w.print("format:            {s}\n", .{format.name()});
    switch (format) {
        .mp3 => {
            const i = try kiln.mp3.probe(input);
            try writeCommon(w, i.sample_rate, i.channels, i.samples);
            try w.print("frames:            {d}\n", .{i.frames});
            try w.print("min start:         {d} samples\n", .{i.min_start});
        },
        .wav => {
            const i = try kiln.wav.probe(input);
            try w.print("sample format:     {t}\n", .{i.format});
            try writeCommon(w, i.sample_rate, i.channels, i.samples);
        },
        .flac => {
            const i = try kiln.flac.probe(input);
            try w.print("bits per sample:   {d}\n", .{i.bits_per_sample});
            try writeCommon(w, i.sample_rate, i.channels, i.samples);
            try w.print("frames:            {d}\n", .{i.frames});
        },
        .ogg => {
            const i = try kiln.ogg.probe(input);
            try w.print("codec:             {t}\n", .{i.codec});
            try writeCommon(w, i.sample_rate, i.channels, i.samples);
            if (i.codec == .opus) {
                if (i.input_sample_rate != 0) try w.print("input sample rate: {d} Hz\n", .{i.input_sample_rate});
                try w.print("pre-skip:          {d} samples\n", .{i.pre_skip});
            }
            if (i.invalid_pages > 0) try w.print("invalid pages:     {d}\n", .{i.invalid_pages});
        },
        .m4a => {
            const i = try kiln.m4a.probe(input);
            switch (i.codec) {
                .alac => {
                    try w.writeAll("codec:             alac\n");
                    try w.print("bits per sample:   {d}\n", .{i.bits_per_sample});
                },
                .aac => try w.print("codec:             aac ({s})\n", .{aacProfile(i.object_type, i.sbr, i.ps)}),
            }
            try writeCommon(w, i.sample_rate, i.channels, i.samples);
            try w.print("encoder delay:     {d} samples\n", .{i.encoder_delay});
            if (i.codec == .aac and (i.sbr == null or i.ps == null)) {
                try w.writeAll("note:              the file does not say whether it is HE-AAC (SBR / PS);\n" ++
                    "                   if it is, the decoded sample rate or channels differ\n");
            }
        },
        .aac => {
            const i = try kiln.aac.probe(input);
            try w.print("codec:             aac ({s}, MPEG-{d})\n", .{ aacProfile(@as(u8, @backingInt(i.profile)) + 1, false, false), i.mpeg_version });
            try writeCommon(w, i.sample_rate, i.channels, i.samples);
            try w.print("frames:            {d}\n", .{i.frames});
            try w.writeAll("note:              ADTS headers cannot say whether it is HE-AAC (SBR / PS);\n" ++
                "                   if it is, the decoded sample rate is twice the one above\n" ++
                "                   (and HE-AAC v2 decodes to 2 channels)\n");
        },
    }
}

fn writeCommon(w: *Io.Writer, sample_rate: u32, channels: u16, samples: u64) !void {
    try w.print("sample rate:       {d} Hz\n", .{sample_rate});
    try w.print("channels:          {d}\n", .{channels});
    const seconds = @as(f64, @floatFromInt(samples)) / @as(f64, @floatFromInt(sample_rate));
    try w.print("length:            {d} samples ({d:.3} s)\n", .{ samples, seconds });
}

/// AAC の種類の名前。SBR / PS が分からないときは中心の方式の名前
fn aacProfile(object_type: u8, sbr: ?bool, ps: ?bool) []const u8 {
    if (ps == true) return "HE-AAC v2";
    if (sbr == true) return "HE-AAC";
    return switch (object_type) {
        1 => "Main",
        2 => "LC",
        3 => "SSR",
        4 => "LTP",
        else => "other",
    };
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

/// 入力を解析する。FLAC はフレームの一覧を `flac_index` に作る(呼び出し側が解放する)
fn probe(gpa: std.mem.Allocator, format: kiln.Format, input: []const u8, flac_index: *?kiln.flac.Index) !Info {
    return switch (format) {
        .mp3 => blk: {
            const i = try kiln.mp3.probe(input);
            break :blk .{ .sample_rate = i.sample_rate, .samples = i.samples, .min_start = i.min_start };
        },
        .wav => blk: {
            const i = try kiln.wav.probe(input);
            break :blk .{ .sample_rate = i.sample_rate, .samples = i.samples, .min_start = 0 };
        },
        .flac => blk: {
            flac_index.* = try kiln.flac.Index.init(gpa, input);
            const i = flac_index.*.?.info();
            break :blk .{ .sample_rate = i.sample_rate, .samples = i.samples, .min_start = 0 };
        },
        // trim は書き出せる形式だけを受け付ける
        .ogg, .m4a, .aac => unreachable,
    };
}

/// 切り出し(と書き出し)に対応している形式か
fn writable(f: kiln.Format) bool {
    return switch (f) {
        .mp3, .wav, .flac => true,
        .ogg, .m4a, .aac => false,
    };
}

/// 切り出す区間の指定(end が null なら末尾まで)
const Range = struct { start: u64, end: ?u64 };
/// 実際に切り出した区間
const Trimmed = struct {
    start: u64,
    end: u64,
    /// MP3 / FLAC をデコードしたとき、復号できなかったフレームの数
    invalid_frames: u64 = 0,
};

/// 書き出しの内容
const Job = struct {
    format: kiln.Format,
    input: []const u8,
    range: Range,
    /// 形式を変えて書くときの設定(null なら入力と同じ形式で切り出す)
    convert: ?Convert,
    /// FLAC の読み書きの作業領域に使う
    gpa: std.mem.Allocator,
    /// FLAC の入力のフレームの一覧(FLAC のときだけ)
    flac_index: ?*const kiln.flac.Index = null,
};

const Convert = union(enum) {
    /// MP3 / FLAC をデコードして WAV で書く。format が null なら FLAC のビット深度を保つ形式
    wav: struct { format: ?kiln.pcm.Format, dither: kiln.pcm.Dither },
    /// WAV / MP3 を FLAC で書く
    flac: kiln.flac.WriteOptions,
};

/// 書き出しの結果
const Written = struct {
    trimmed: Trimmed,
    /// FLAC を流して書いたとき、出力の先頭に書き戻す STREAMINFO
    patch: ?kiln.flac.StreamInfoPatch = null,
};

/// 区間を切り出して(または形式を変えて)`w` に書き、実際に書いた区間を返す。
/// `seekable` なら FLAC は流して書き、STREAMINFO の書き戻しを返す(呼び出し側が書き戻す)。
/// そうでなければ(stdout)、メモリ上で書き戻してから書く
fn run(job: Job, w: *Io.Writer, seekable: bool) !Written {
    const c = job.convert orelse {
        if (job.format == .flac) return flacOut(job, w, seekable);
        return .{ .trimmed = try trimTo(job.format, job.input, job.range, w) };
    };
    const start = job.range.start;
    const end = job.range.end;
    switch (c) {
        .wav => |o| return .{ .trimmed = switch (job.format) {
            .mp3 => blk: {
                const r = try kiln.mp3.toWav(job.input, .{ .start = start, .end = end }, .{ .format = o.format.?, .dither = o.dither }, w);
                break :blk .{ .start = r.start, .end = r.end, .invalid_frames = r.invalid_frames };
            },
            .flac => blk: {
                const r = try job.flac_index.?.toWav(job.gpa, .{ .start = start, .end = end }, .{ .format = o.format, .dither = o.dither }, w);
                break :blk .{ .start = r.start, .end = r.end, .invalid_frames = r.invalid_frames };
            },
            .wav, .ogg, .m4a, .aac => unreachable,
        } },
        .flac => return flacOut(job, w, seekable),
    }
}

/// FLAC を書く(WAV / MP3 からの変換と、FLAC の切り出し)。`seekable` なら流して書き、STREAMINFO の
/// 書き戻しを返す。そうでなければ(stdout には書き戻せないので)、メモリ上で書き戻してから書く
fn flacOut(job: Job, w: *Io.Writer, seekable: bool) !Written {
    const start = job.range.start;
    const end = job.range.end;
    var mem: Io.Writer.Allocating = .init(job.gpa);
    defer mem.deinit();
    const out = if (seekable) w else &mem.writer;
    const o: kiln.flac.WriteOptions = if (job.convert) |c| c.flac else .{};
    var written: Written = switch (job.format) {
        .wav => blk: {
            const r = try kiln.wav.toFlac(job.gpa, job.input, .{ .start = start, .end = end }, o, out);
            break :blk .{ .trimmed = .{ .start = r.start, .end = r.end }, .patch = r.patch };
        },
        .mp3 => blk: {
            const r = try kiln.mp3.toFlac(job.gpa, job.input, .{ .start = start, .end = end }, o, out);
            const t = r.result;
            break :blk .{ .trimmed = .{ .start = t.start, .end = t.end, .invalid_frames = t.invalid_frames }, .patch = r.patch };
        },
        .flac => blk: {
            const r = try job.flac_index.?.trim(job.gpa, .{ .start = start, .end = end }, out);
            break :blk .{ .trimmed = .{ .start = r.start, .end = r.end, .invalid_frames = r.invalid_frames }, .patch = r.patch };
        },
        .ogg, .m4a, .aac => unreachable,
    };
    if (!seekable) {
        const data = try kiln.flac.takePatched(&mem, written.patch.?);
        defer job.gpa.free(data);
        try w.writeAll(data);
        written.patch = null;
    }
    return written;
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
        // FLAC → FLAC は run が flacOut で書く
        .flac, .ogg, .m4a, .aac => unreachable,
    };
}

/// トリムした結果を書き出す。ファイルへは一時ファイルに書き、最後まで書けたときだけ
/// 出力先に置き換える(失敗しても、既存の出力先のファイルは元のまま残る)
fn writeOutput(io: Io, path: []const u8, job: Job, stdout: *Io.Writer) !Trimmed {
    if (std.mem.eql(u8, path, "-")) {
        const r = try run(job, stdout, false);
        try stdout.flush();
        return r.trimmed;
    }
    var af = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &buf);
    const r = try run(job, &fw.interface, true);
    try fw.interface.flush();
    // FLAC は STREAMINFO を最後に書き戻す(フレームはメモリにためずに流して書く)
    if (r.patch) |p| try af.file.writePositionalAll(io, &p.bytes, p.offset);
    try af.replace(io);
    return r.trimmed;
}

/// コアのエラーを利用者向けの説明にする
fn describe(format: kiln.Format, err: anyerror) []const u8 {
    return switch (err) {
        error.NotMp3 => "not an MP3 file",
        error.NotWav => "not a WAV file",
        error.NotFlac => "not a FLAC file",
        error.InvalidFlac => "broken FLAC file (missing or invalid STREAMINFO / metadata blocks)",
        error.InvalidWav => "broken WAV file (missing or invalid fmt / data chunk)",
        error.NotOgg => "not an Ogg file",
        error.InvalidOgg => "broken Ogg file (missing or invalid Vorbis / Opus headers)",
        error.NotM4a => "not an M4A (MP4) file",
        error.InvalidM4a => "broken M4A file (missing or invalid moov / sample tables)",
        error.NotAac => "not an AAC (ADTS) file",
        error.UnsupportedFormat => switch (format) {
            .mp3 => "unsupported MPEG audio (only MPEG-1 Layer III is supported)",
            .wav => "unsupported WAV (only little-endian RIFF with PCM or IEEE float is supported; RF64, RIFX and compressed encodings are not)",
            .flac => "unsupported FLAC (only native FLAC is supported; Ogg FLAC is not)",
            .ogg => "unsupported Ogg (only a single Vorbis or Opus stream is supported; Ogg FLAC, Speex and chained or multiplexed streams are not)",
            .m4a => "unsupported M4A (only AAC and ALAC audio tracks are supported; fragmented MP4 is not)",
            .aac => "unsupported AAC (ADTS with channel configuration 0 is not supported)",
        },
        error.EmptyRange => "empty range",
        error.TooLarge => "output is too large",
        error.InternalError => "internal error (a bug in kiln; please report it)",
        error.InvalidOptions => "cannot write with these settings (FLAC supports 1 to 8 channels and sample rates below 1048576 Hz)",
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
    try std.testing.expectEqual(kiln.Format.flac, (try parseTrimArgs(&.{ "a", "b", "--format", "flac" }, &w)).?.format.?);
    const fl = (try parseTrimArgs(&.{ "a", "b", "--format", "flac", "--bits", "24", "--compression", "8" }, &w)).?;
    try std.testing.expectEqual(24, fl.bits.?);
    try std.testing.expectEqual(8, fl.compression.?);
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
        &.{ "in.mp3", "out.mp3", "--format", "ogg" },
        &.{ "in.mp3", "out.wav", "--sample-format", "s16" },
        &.{ "in.mp3", "out.wav", "--dither" },
        &.{ "in.mp3", "out.wav", "--dither", "rpdf" },
        &.{ "in.wav", "out.flac", "--bits", "3" },
        &.{ "in.wav", "out.flac", "--bits", "x" },
        &.{ "in.wav", "out.flac", "--compression", "9" },
    }) |bad| {
        try std.testing.expectEqual(null, try parseTrimArgs(bad, &w));
    }
}
