// SPDX-License-Identifier: MIT
//! Ogg(Vorbis / Opus)の解析と、無劣化の切り出し(設計は docs/ogg.md)。
//!
//! 中身が 1 本のストリーム(論理ビットストリーム)だけのファイルを扱う。長さはグラニュール位置から数え、
//! 先頭と末尾の切り詰め(Opus の pre-skip、最初と最後のページのグラニュール位置)を反映する。
const std = @import("std");
const Io = std.Io;
const page = @import("ogg/page.zig");
const vorbis = @import("ogg/vorbis.zig");
const opus = @import("ogg/opus.zig");
const stream = @import("ogg/stream.zig");
const trim_impl = @import("ogg/trim.zig");

pub const ParseError = error{
    /// 先頭が Ogg のページ(`OggS`)ではない
    NotOgg,
    /// ヘッダが壊れている、ヘッダが揃う前に終わっている、など
    InvalidOgg,
    /// Vorbis / Opus 以外の中身(Ogg FLAC、Speex など)、複数のストリームを連結・多重化したもの
    UnsupportedFormat,
};

pub const Codec = enum { vorbis, opus };

pub const Info = struct {
    codec: Codec,
    /// デコード結果のサンプルレート(Opus は常に 48000)
    sample_rate: u32,
    /// Opus の ID ヘッダに書かれた、エンコード前の音源のサンプルレート(0 は不明。Vorbis は 0)
    input_sample_rate: u32,
    channels: u8,
    /// 再生される長さ(サンプル数)。先頭の切り詰め(Opus の pre-skip など)と末尾の切り詰めを除いたもの
    samples: u64,
    /// Opus の pre-skip(48kHz のサンプル数。Vorbis は 0)
    pre_skip: u16,
    /// 読めずに飛ばしたページ(CRC が合わない、途切れた、欠けた)の数
    invalid_pages: u64,
    /// `trim` で切り出せるか。読めないページや欠けたページがあるもの(InvalidOgg)と、先頭の切り詰めのある Vorbis
    /// (UnsupportedFormat)は切り出せない
    trimmable: bool,
};

/// 先頭が Ogg のページか(`kiln.detect` に使う)
pub fn hasSignature(input: []const u8) bool {
    return input.len >= 4 and std.mem.eql(u8, input[0..4], page.capture);
}

/// 最初のページの識別ヘッダに書かれた、デコード結果のサンプルレート(Opus は常に 48000。`kiln.detect` に使う)。
/// 後ろのページは見ないので、kiln が扱わない Ogg(連結、多重化、壊れたページのあるもの)でも、入力が
/// ファイルの先頭の一部でも読める。Vorbis でも Opus でもない、識別ヘッダが読めないときは null
pub fn headerSampleRate(input: []const u8) ?u32 {
    if (!hasSignature(input)) return null;
    var it: page.Iterator = .{ .input = input };
    const first = it.next() orelse return null;
    if (!first.bos() or first.lacing.len == 0) return null;
    var id_buf: [300]u8 = undefined;
    const id = readPacket(input, first, 0, &id_buf);
    if (std.mem.startsWith(u8, id, "OpusHead")) return opus.sample_rate;
    if (std.mem.startsWith(u8, id, "\x01vorbis")) return (vorbis.identification(id) catch return null).sample_rate;
    return null;
}

/// 入力全体を解析して、コーデック・サンプルレート・長さなどを返す
pub fn probe(input: []const u8) ParseError!Info {
    return (try analyze(input)).info;
}

/// 解析の結果と、切り出しに使う位置の情報
const Analysis = struct {
    info: Info,
    /// 先頭の切り詰めで、pre-skip のほかに捨てる長さ。再生位置 t は、デコード結果の先頭から数えて
    /// t + pre_skip + lead の位置にある
    lead: u64,
    /// Vorbis の音声パケットの長さを数えるもの(ヘッダから作った、数える前の状態。Opus は null)
    vorbis: ?vorbis.Counter,
};

fn analyze(input: []const u8) ParseError!Analysis {
    if (!hasSignature(input)) return error.NotOgg;
    var first_it: page.Iterator = .{ .input = input };
    const first = first_it.next() orelse return error.InvalidOgg;
    if (!first.bos() or first.lacing.len == 0) return error.InvalidOgg;

    // 識別ヘッダ(最初のパケット)
    var id_buf: [300]u8 = undefined;
    const id = readPacket(input, first, 0, &id_buf);
    var info: Info = .{
        .codec = undefined,
        .sample_rate = undefined,
        .input_sample_rate = 0,
        .channels = undefined,
        .samples = 0,
        .pre_skip = 0,
        .invalid_pages = 0,
        .trimmable = false,
    };
    var vorbis_id: vorbis.Identification = undefined;
    var modes: vorbis.Modes = undefined;
    if (std.mem.startsWith(u8, id, "OpusHead")) {
        const h = try opus.head(id);
        info.codec = .opus;
        info.sample_rate = opus.sample_rate;
        info.input_sample_rate = h.input_sample_rate;
        info.channels = h.channels;
        info.pre_skip = h.pre_skip;
    } else if (std.mem.startsWith(u8, id, "\x01vorbis")) {
        vorbis_id = try vorbis.identification(id);
        info.codec = .vorbis;
        info.sample_rate = vorbis_id.sample_rate;
        info.channels = vorbis_id.channels;
    } else {
        // Ogg FLAC、Speex、Theora など
        return error.UnsupportedFormat;
    }
    const header_packets: u64 = if (info.codec == .opus) 2 else 3;

    // パケットを順にたどり、長さを数える
    var w: stream.Walker = .init(input, first);
    var packets: u64 = 0;
    var counter: ?vorbis.Counter = null;
    // ヘッダから作った、数える前の状態(切り出しに渡す)
    var counter_init: ?vorbis.Counter = null;
    // 音声パケットの長さの合計(最初のグラニュール位置が付いたページまで)
    var audio_total: u64 = 0;
    var start_pos: ?i128 = null;
    // 最初にグラニュール位置が付いたページが、最後のページでもあるか
    var first_is_last = false;
    var last_granule: ?i64 = null;
    // 音声パケットが終わった最後のページ。次のパケットが別のページで終わったときに、グラニュール位置を反映する
    var pending: ?page.Page = null;
    const settle = struct {
        fn f(pp: page.Page, total: u64, sp: *?i128, fil: *bool, lg: *?i64) void {
            if (pp.granule < 0) return;
            if (sp.* == null) {
                sp.* = @as(i128, pp.granule) - total;
                fil.* = pp.eos();
            }
            lg.* = pp.granule;
        }
    }.f;
    while (try w.next()) |pk| {
        defer packets += 1;
        if (packets < header_packets) {
            try headerPacket(input, info.codec, packets, pk, &vorbis_id, &modes);
            if (info.codec == .vorbis and packets == 2) {
                counter = .{ .id = vorbis_id, .modes = modes };
                counter_init = counter;
            }
            continue;
        }
        if (pending) |pp| {
            if (pp.start != pk.end.start) {
                settle(pp, audio_total, &start_pos, &first_is_last, &last_granule);
                pending = null;
            }
        }
        const dur: u64 = switch (info.codec) {
            .opus => stream.opusSamples(input, pk),
            .vorbis => counter.?.next(stream.firstByte(input, pk)) orelse 0,
        };
        if (start_pos == null) audio_total += dur;
        pending = pk.end;
    }
    if (pending) |pp| settle(pp, audio_total, &start_pos, &first_is_last, &last_granule);
    info.invalid_pages = w.invalidPages();
    if (packets < header_packets) return error.InvalidOgg;

    var lead: u64 = 0;
    if (last_granule) |last| {
        // 最初のグラニュール位置が、そこまでのパケットの長さより小さいとき(先頭の位置が負)は、
        // 最初のページが最後のページでもあれば末尾の切り詰め、そうでなければ先頭の切り詰め。
        // どちらも再生は位置 0 から始まり、長さは最後のグラニュール位置まで。先頭の切り詰めでは、
        // デコード結果の先頭の、その分を捨てる
        const sp = start_pos.?;
        const base = @max(sp, 0);
        const n = @as(i128, last) - base - info.pre_skip;
        info.samples = if (n > 0) std.math.cast(u64, n) orelse std.math.maxInt(u64) else 0;
        if (sp < 0 and !first_is_last) lead = std.math.cast(u64, -sp) orelse std.math.maxInt(u64);
    }
    // 先頭の切り詰めは、Chromium も ffmpeg も Vorbis では守らない(デコード結果の位置が解析と合わない)ので切り出さない
    info.trimmable = info.invalid_pages == 0 and !(info.codec == .vorbis and lead != 0);
    return .{ .info = info, .lead = lead, .vorbis = counter_init };
}

pub const TrimOptions = struct {
    /// 切り出す区間の先頭(再生位置のサンプル数。Opus は 48kHz で、pre-skip を除いた位置)
    start: u64 = 0,
    /// 切り出す区間の終わり(この位置は含まない)。null なら末尾まで
    end: ?u64 = null,
};

/// 実際に切り出した区間(範囲外の指定を丸めた後の位置。Vorbis の `start` は、パケットの区切りに寄せた位置)
pub const TrimResult = struct {
    start: u64,
    end: u64,
    sample_rate: u32,
};

pub const TrimError = ParseError || Io.Writer.Error || error{
    OutOfMemory,
    /// 丸めた後の区間が空(start >= end)
    EmptyRange,
};

/// 区間 `[options.start, options.end)` を、再エンコードせずに切り出して `w` に Ogg で書く。末尾は長さで切り詰める。
/// 読めないページや欠けたページがあるものは InvalidOgg(欠けた分の位置が分からないため)。`w.flush()` は呼び出し側が行う。
/// Opus はサンプル単位で区間どおりになる(docs/ogg.md §6)。Vorbis は、末尾はサンプル単位、先頭は区間の先頭を含む
/// パケットの区切りに寄せる(`start` 以下。docs/ogg.md §7)。先頭の切り詰めのある Vorbis は UnsupportedFormat
pub fn trim(gpa: std.mem.Allocator, input: []const u8, options: TrimOptions, w: *Io.Writer) TrimError!TrimResult {
    const a = try analyze(input);
    const info = a.info;
    if (info.invalid_pages != 0) return error.InvalidOgg;
    const end = @min(options.end orelse info.samples, info.samples);
    if (options.start >= end) return error.EmptyRange;
    const start = switch (info.codec) {
        .opus => blk: {
            try trim_impl.opusTrim(gpa, input, info.pre_skip, a.lead, options.start, end, w);
            break :blk options.start;
        },
        .vorbis => blk: {
            // 先頭の切り詰めは扱わない(analyze の trimmable)
            if (!info.trimmable) return error.UnsupportedFormat;
            break :blk try trim_impl.vorbisTrim(gpa, input, a.vorbis.?, info.sample_rate, options.start, end, w);
        },
    };
    return .{ .start = start, .end = end, .sample_rate = info.sample_rate };
}

pub const Trimmed = struct {
    data: []u8,
    start: u64,
    end: u64,
    sample_rate: u32,
};

/// `trim` の一括版。返した `data` は呼び出し側が `gpa` で解放する
pub fn trimAlloc(gpa: std.mem.Allocator, input: []const u8, options: TrimOptions) (ParseError || error{ OutOfMemory, EmptyRange })!Trimmed {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const r = trim(gpa, input, options, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return .{ .data = try out.toOwnedSlice(), .start = r.start, .end = r.end, .sample_rate = r.sample_rate };
}

/// ヘッダのパケット(Opus のコメント、Vorbis のコメントと設定)を確かめる
fn headerPacket(
    input: []const u8,
    codec: Codec,
    index: u64,
    pk: stream.Packet,
    id: *const vorbis.Identification,
    modes: *vorbis.Modes,
) ParseError!void {
    if (index == 0) return;
    const len = pk.len;
    var head: [8]u8 = undefined;
    const got = readPacket(input, pk.page, pk.seg, &head);
    switch (codec) {
        .opus => if (!std.mem.eql(u8, got, "OpusTags")) return error.InvalidOgg,
        .vorbis => if (index == 1) {
            if (got.len < 7 or !std.mem.eql(u8, got[0..7], "\x03vorbis")) return error.InvalidOgg;
        } else {
            if (len < 7) return error.InvalidOgg;
            var r: page.PacketReader = .init(input, pk.page, pk.seg);
            modes.* = try vorbis.setup(&r, id.channels);
        },
    }
}

/// パケットの先頭を `buf` に読み、読めた分を返す
fn readPacket(input: []const u8, p: page.Page, seg: usize, buf: []u8) []u8 {
    var r: page.PacketReader = .init(input, p, seg);
    var n: usize = 0;
    while (n < buf.len) : (n += 1) buf[n] = r.byte() orelse break;
    return buf[0..n];
}

test {
    _ = page;
    _ = vorbis;
    _ = opus;
    _ = stream;
    _ = trim_impl;
}

const testdata = @import("testdata");

test "probe: Opus(opusenc)" {
    const i = try probe(testdata.opus_stereo);
    try std.testing.expectEqual(Codec.opus, i.codec);
    try std.testing.expectEqual(48000, i.sample_rate);
    try std.testing.expectEqual(44100, i.input_sample_rate);
    try std.testing.expectEqual(2, i.channels);
    try std.testing.expectEqual(312, i.pre_skip);
    try std.testing.expectEqual(24000, i.samples);
    try std.testing.expectEqual(0, i.invalid_pages);
    try std.testing.expect(i.trimmable);
}

test "probe: Vorbis(oggenc)" {
    const i = try probe(testdata.vorbis_stereo);
    try std.testing.expectEqual(Codec.vorbis, i.codec);
    try std.testing.expectEqual(44100, i.sample_rate);
    try std.testing.expectEqual(0, i.input_sample_rate);
    try std.testing.expectEqual(2, i.channels);
    try std.testing.expectEqual(22050, i.samples);
    try std.testing.expect(i.trimmable);
}

test "probe: Opus(ffmpeg、モノラル)と Vorbis(モノラル 22.05kHz)" {
    const o = try probe(testdata.opus_mono_ffmpeg);
    try std.testing.expectEqual(1, o.channels);
    try std.testing.expectEqual(48000, o.input_sample_rate);
    try std.testing.expectEqual(312, o.pre_skip);
    try std.testing.expectEqual(24000, o.samples);
    const v = try probe(testdata.vorbis_mono22k);
    try std.testing.expectEqual(22050, v.sample_rate);
    try std.testing.expectEqual(1, v.channels);
    try std.testing.expectEqual(11025, v.samples);
}

/// テスト用: `n` 番目のページのグラニュール位置を書き換え、CRC を付け直す
fn setGranule(buf: []u8, n: usize, granule: i64) void {
    var it: page.Iterator = .{ .input = buf };
    for (0..n) |_| _ = it.next().?;
    const p = it.next().?;
    std.mem.writeInt(i64, buf[p.start + 6 ..][0..8], granule, .little);
    @memset(buf[p.start + 22 ..][0..4], 0);
    var crc = page.Crc.init();
    crc.update(buf[p.start..p.end]);
    std.mem.writeInt(u32, buf[p.start + 22 ..][0..4], crc.final(), .little);
}

/// テスト用: 最初に音声パケットが終わるページの番号と、そのグラニュール位置
fn firstAudioPage(input: []const u8) struct { usize, i64 } {
    var it: page.Iterator = .{ .input = input };
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (p.granule > 0) return .{ i, p.granule };
    }
    unreachable;
}

test "probe: 最初のページのグラニュール位置(先頭の位置)" {
    const gpa = std.testing.allocator;
    // 音声が 2 ページにまたがる(最初のページが最後のページではない)
    for ([_][]const u8{testdata.vorbis_stereo}) |src| {
        const base = try probe(src);
        const buf = try gpa.dupe(u8, src);
        defer gpa.free(buf);
        const n, const g = firstAudioPage(buf);
        // 途中から切り出したストリーム: 最初のページの位置が 1000 先にある。長さは 1000 減る
        setGranule(buf, n, g + 1000);
        try std.testing.expectEqual(base.samples - 1000, (try probe(buf)).samples);
        // 先頭の切り詰め: 最初のページの位置が 100 足りない。最後の位置までが長さなので変わらない
        setGranule(buf, n, g - 100);
        try std.testing.expectEqual(base.samples, (try probe(buf)).samples);
    }
}

test "probe: 音声が 1 ページだけのとき、足りないグラニュール位置は末尾の切り詰め" {
    const gpa = std.testing.allocator;
    const buf = try gpa.dupe(u8, testdata.opus_stereo);
    defer gpa.free(buf);
    const n, const g = firstAudioPage(buf);
    setGranule(buf, n, g - 100);
    try std.testing.expectEqual(24000 - 100, (try probe(buf)).samples);
}

test "probe: 壊れたページは飛ばして数える" {
    const gpa = std.testing.allocator;
    const buf = try gpa.dupe(u8, testdata.vorbis_stereo);
    defer gpa.free(buf);
    const base = try probe(buf);
    // 音声は 2 ページ(グラニュール位置 22016 と、最後の 22050)。最後のページを壊すと、長さはその前のページまで
    var it: page.Iterator = .{ .input = buf };
    const n, const g = firstAudioPage(buf);
    for (0..n + 1) |_| _ = it.next().?;
    const last = it.next().?;
    try std.testing.expect(last.eos());
    buf[last.end - 1] ^= 0xFF;
    const got = try probe(buf);
    try std.testing.expectEqual(1, got.invalid_pages);
    try std.testing.expect(!got.trimmable);
    try std.testing.expectEqual(@as(u64, @intCast(g)), got.samples);
    try std.testing.expectEqual(22050, base.samples);
    // 末尾で途切れた: 最後の完全なページまで
    const cut = try probe(testdata.vorbis_stereo[0 .. testdata.vorbis_stereo.len - 10]);
    try std.testing.expectEqual(1, cut.invalid_pages);
    try std.testing.expect(cut.samples < base.samples);
}

test "probe: 連結・多重化したストリームは扱わない" {
    const gpa = std.testing.allocator;
    const two = try std.mem.concat(gpa, u8, &.{ testdata.opus_stereo, testdata.opus_mono_ffmpeg });
    defer gpa.free(two);
    try std.testing.expectError(error.UnsupportedFormat, probe(two));
}

test "probe: エラー" {
    try std.testing.expectError(error.NotOgg, probe("RIFF"));
    try std.testing.expectError(error.InvalidOgg, probe("OggS"));
    // 識別ヘッダまでで途切れた
    try std.testing.expectError(error.InvalidOgg, probe(testdata.vorbis_stereo[0..200]));
    // Ogg FLAC
    var buf: [128]u8 = undefined;
    const p = page.build(&buf, page.flag_bos, 0, 1, 0, &.{"\x7FFLAC\x01\x00\x00\x01fLaC"}, false);
    try std.testing.expectError(error.UnsupportedFormat, probe(p));
}

/// テスト用: 音声パケット(Opus はヘッダの 2 つ、Vorbis は 3 つを除く)のバイト列を順に集める。返したものは呼び出し側が解放する
fn audioPackets(gpa: std.mem.Allocator, input: []const u8) ![][]u8 {
    const packets = try stream.collectAll(gpa, input);
    defer gpa.free(packets);
    const headers: usize = if ((try probe(input)).codec == .opus) 2 else 3;
    const out = try gpa.alloc([]u8, packets.len - headers);
    for (packets[headers..], out) |pk, *o| {
        o.* = try gpa.alloc(u8, pk.len);
        var r: page.PacketReader = .init(input, pk.page, pk.seg);
        for (o.*) |*b| b.* = r.byte().?;
    }
    return out;
}

fn freePackets(gpa: std.mem.Allocator, packets: [][]u8) void {
    for (packets) |p| gpa.free(p);
    gpa.free(packets);
}

test "trim: Opus を区間どおりに切り出す" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ testdata.opus_stereo, testdata.opus_mono_ffmpeg }) |src| {
        const base = try probe(src);
        const src_packets = try audioPackets(gpa, src);
        defer freePackets(gpa, src_packets);
        for ([_][2]u64{ .{ 0, base.samples }, .{ 5000, 15000 }, .{ 0, 100 }, .{ 1, 2 }, .{ 23000, base.samples }, .{ 3840, 7000 } }) |se| {
            const t = try trimAlloc(gpa, src, .{ .start = se[0], .end = se[1] });
            defer gpa.free(t.data);
            try std.testing.expectEqual(se[0], t.start);
            try std.testing.expectEqual(se[1], t.end);
            try std.testing.expectEqual(48000, t.sample_rate);
            const got = try probe(t.data);
            try std.testing.expectEqual(Codec.opus, got.codec);
            try std.testing.expectEqual(se[1] - se[0], got.samples);
            try std.testing.expectEqual(base.channels, got.channels);
            try std.testing.expectEqual(base.input_sample_rate, got.input_sample_rate);
            try std.testing.expectEqual(0, got.invalid_pages);
            // 区間の前に 80ms 以上(ファイルの先頭に近ければ取れる分だけ)残し、パケットは元のままコピーする
            try std.testing.expect(got.pre_skip >= @min(trim_impl.preroll, se[0] + base.pre_skip));
            const out_packets = try audioPackets(gpa, t.data);
            defer freePackets(gpa, out_packets);
            const first = for (src_packets, 0..) |p, i| {
                if (std.mem.eql(u8, p, out_packets[0])) break i;
            } else return error.TestUnexpectedResult;
            for (out_packets, src_packets[first..][0..out_packets.len]) |o, s| try std.testing.expectEqualSlices(u8, s, o);
            // 出力の再生位置 0 が、元の start と同じ所を指す: 元のデコード結果で、最初にコピーしたパケットの
            // 開始位置 + 新しい pre-skip = start + 元の pre-skip + lead
            try std.testing.expectEqual(se[0] + base.pre_skip + (try analyze(src)).lead, opusStart(src_packets[0..first]) + got.pre_skip);
        }
    }
}

/// テスト用: Opus のパケットの長さの合計
fn opusStart(packets: []const []const u8) u64 {
    var n: u64 = 0;
    for (packets) |p| n += opus.packetSamples(p.len, p[0], if (p.len > 1) p[1] else 0) orelse 0;
    return n;
}

test "trim: 音声が 1 ページだけ(最初のページが最後のページ)なら、足りないグラニュール位置は末尾の切り詰め" {
    // opus_stereo は音声が 1 ページで、グラニュール位置(24312)がパケットの合計(24960)より小さい。先頭は捨てない
    const a = try analyze(testdata.opus_stereo);
    try std.testing.expectEqual(0, a.lead);
}

test "trim: 先頭の切り詰め(最初のページのグラニュール位置が、パケットの合計より小さい)" {
    const gpa = std.testing.allocator;
    // opus_stereo のパケットを 5 個ずつのページに詰め直し、最初の音声ページのグラニュール位置を 500 減らす
    const src = testdata.opus_stereo;
    const packets = try stream.collectAll(gpa, src);
    defer gpa.free(packets);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var pw: trim_impl.PageWriter = try .init(gpa, &out.writer, packets[0].page.serial);
    defer pw.deinit();
    try pw.packetFrom(src, packets[0], 0);
    try pw.flush(false);
    try pw.packetFrom(src, packets[1], 0);
    try pw.flush(false);
    var total: i64 = 0;
    for (packets[2..], 0..) |pk, i| {
        total += stream.opusSamples(src, pk);
        const first_page = i < 5;
        try pw.packetFrom(src, pk, if (first_page) total - 500 else total);
        if (i % 5 == 4) try pw.flush(false);
    }
    try pw.flush(true);
    const buf = out.written();
    const a = try analyze(buf);
    try std.testing.expectEqual(500, a.lead);
    // Opus の先頭の切り詰めは pre-skip で捨てさせられるので切り出せる
    try std.testing.expect(a.info.trimmable);
    const src_packets = try audioPackets(gpa, buf);
    defer freePackets(gpa, src_packets);
    const t = try trimAlloc(gpa, buf, .{ .start = 6000, .end = 9000 });
    defer gpa.free(t.data);
    const got = try probe(t.data);
    try std.testing.expectEqual(3000, got.samples);
    const out_packets = try audioPackets(gpa, t.data);
    defer freePackets(gpa, out_packets);
    const first = for (src_packets, 0..) |p, i| {
        if (std.mem.eql(u8, p, out_packets[0])) break i;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(6000 + a.info.pre_skip + 500, opusStart(src_packets[0..first]) + got.pre_skip);
}

test "trim: 途中から切り出したストリーム(最初のグラニュール位置が先にある)" {
    const gpa = std.testing.allocator;
    const buf = try gpa.dupe(u8, testdata.opus_stereo);
    defer gpa.free(buf);
    const n, const g = firstAudioPage(buf);
    setGranule(buf, n, g + 1000);
    const base = try probe(buf);
    const t = try trimAlloc(gpa, buf, .{ .start = 2000, .end = 6000 });
    defer gpa.free(t.data);
    try std.testing.expectEqual(4000, (try probe(t.data)).samples);
    // 全体を切り出すと、長さは元と同じ
    const all = try trimAlloc(gpa, buf, .{});
    defer gpa.free(all.data);
    try std.testing.expectEqual(base.samples, (try probe(all.data)).samples);
}

test "trim: 範囲外と、扱えない入力" {
    const gpa = std.testing.allocator;
    // 末尾は長さで切り詰める
    const t = try trimAlloc(gpa, testdata.opus_stereo, .{ .start = 20000, .end = 1_000_000 });
    defer gpa.free(t.data);
    try std.testing.expectEqual(24000, t.end);
    try std.testing.expectError(error.EmptyRange, trimAlloc(gpa, testdata.opus_stereo, .{ .start = 24000 }));
    try std.testing.expectError(error.EmptyRange, trimAlloc(gpa, testdata.opus_stereo, .{ .start = 5, .end = 5 }));
    // 壊れたページがあるものは切り出さない
    const buf = try gpa.dupe(u8, testdata.opus_stereo);
    defer gpa.free(buf);
    buf[buf.len - 1] ^= 0xFF;
    try std.testing.expectError(error.InvalidOgg, trimAlloc(gpa, buf, .{}));
    try std.testing.expectError(error.NotOgg, trimAlloc(gpa, "RIFF", .{}));
}

/// テスト用: Vorbis の音声パケットの開始位置(デコード結果の先頭から)
fn vorbisStarts(gpa: std.mem.Allocator, input: []const u8, packets: []const []const u8) ![]u64 {
    var c = (try analyze(input)).vorbis.?;
    const out = try gpa.alloc(u64, packets.len);
    var pos: u64 = 0;
    for (packets, out) |p, *o| {
        o.* = pos;
        pos += c.next(if (p.len > 0) p[0] else null) orelse 0;
    }
    return out;
}

test "trim: Vorbis は末尾を区間どおりに、先頭をパケットの区切りに寄せて切り出す" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ testdata.vorbis_stereo, testdata.vorbis_mono22k }) |src| {
        const base = try probe(src);
        const long = (try analyze(src)).vorbis.?.id.blocksize[1];
        const src_packets = try audioPackets(gpa, src);
        defer freePackets(gpa, src_packets);
        const starts = try vorbisStarts(gpa, src, src_packets);
        defer gpa.free(starts);
        const n = base.samples;
        for ([_][2]u64{ .{ 0, n }, .{ 5000, 9000 }, .{ 0, 1 }, .{ 1, 2 }, .{ 3000, 3001 }, .{ n - 10, n }, .{ n - 1, n }, .{ 777, n } }) |se| {
            const t = try trimAlloc(gpa, src, .{ .start = se[0], .end = se[1] });
            defer gpa.free(t.data);
            try std.testing.expectEqual(se[1], t.end);
            try std.testing.expectEqual(base.sample_rate, t.sample_rate);
            // 先頭は、区間の先頭より前の(長いブロックの半分より近い)パケットの区切り
            try std.testing.expect(t.start <= se[0] and se[0] - t.start < long / 2);
            const got = try probe(t.data);
            try std.testing.expectEqual(Codec.vorbis, got.codec);
            try std.testing.expectEqual(se[1] - t.start, got.samples);
            try std.testing.expectEqual(base.channels, got.channels);
            try std.testing.expectEqual(base.sample_rate, got.sample_rate);
            try std.testing.expectEqual(0, got.invalid_pages);
            try std.testing.expectEqual(0, (try analyze(t.data)).lead);
            // パケットは元のままコピーし、2 つ目のパケット(最初に音を出すもの)の開始位置が切り始めの位置
            const out_packets = try audioPackets(gpa, t.data);
            defer freePackets(gpa, out_packets);
            try std.testing.expect(out_packets.len >= 2);
            const first = for (src_packets, 0..) |p, i| {
                if (i + 1 < src_packets.len and std.mem.eql(u8, p, out_packets[0]) and std.mem.eql(u8, src_packets[i + 1], out_packets[1])) break i;
            } else return error.TestUnexpectedResult;
            for (out_packets, src_packets[first..][0..out_packets.len]) |o, sp| try std.testing.expectEqualSlices(u8, sp, o);
            try std.testing.expectEqual(t.start, starts[first + 1]);
            // 最初の音声パケットは、それだけでグラニュール位置 0 のページにする
            var it: page.Iterator = .{ .input = t.data };
            var audio_page: ?page.Page = null;
            var i: usize = 0;
            while (it.next()) |pg| : (i += 1) {
                if (i == 2) audio_page = pg;
            }
            try std.testing.expectEqual(1, audio_page.?.lacing.len - std.mem.count(u8, audio_page.?.lacing, &.{255}));
            try std.testing.expectEqual(0, audio_page.?.granule);
        }
    }
}

test "trim: Vorbis の先頭の切り詰めは扱わず、途中から切り出したストリームは切り出す" {
    const gpa = std.testing.allocator;
    const buf = try gpa.dupe(u8, testdata.vorbis_stereo);
    defer gpa.free(buf);
    const n, const g = firstAudioPage(buf);
    // 1 サンプルの切り詰めでも切り出さない(probe の trimmable も false)
    for ([_]i64{ 1, 2, 100 }) |d| {
        setGranule(buf, n, g - d);
        try std.testing.expect(!(try probe(buf)).trimmable);
        try std.testing.expectError(error.UnsupportedFormat, trimAlloc(gpa, buf, .{}));
    }
    setGranule(buf, n, g + 1000);
    const base = try probe(buf);
    try std.testing.expect(base.trimmable);
    const all = try trimAlloc(gpa, buf, .{});
    defer gpa.free(all.data);
    try std.testing.expectEqual(0, all.start);
    try std.testing.expectEqual(base.samples, (try probe(all.data)).samples);
    // 壊れたページがあるものは切り出さない
    buf[buf.len - 1] ^= 0xFF;
    try std.testing.expectError(error.InvalidOgg, trimAlloc(gpa, buf, .{}));
}
