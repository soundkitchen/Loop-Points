//! MP3 の無劣化・サンプル精度トリム(docs/lyria-mp3.md §4)。
//! フレームは再エンコードせずにそのまま連結し、先頭に付ける ID3v2(`iTunSMPB`)と
//! Info + LAME タグで、デコーダに余分な部分を落とさせる。
const std = @import("std");
const Io = std.Io;
const frame = @import("frame.zig");
const id3 = @import("id3.zig");
const xing = @import("xing.zig");
const stream = @import("stream.zig");
const Header = frame.Header;
const spf = frame.samples_per_frame;
const decoder_delay = stream.decoder_delay;

pub const Options = struct {
    /// 切り出す区間の先頭(タイムライン上のサンプル位置)
    start: u64 = 0,
    /// 切り出す区間の終わり(この位置は含まない)。null なら末尾まで
    end: ?u64 = null,
};

/// 実際に切り出した区間(範囲外の指定を丸めた後のタイムライン上の位置)
pub const Result = struct {
    start: u64,
    end: u64,
};

pub const Error = stream.Error || Io.Writer.Error || error{
    /// 丸めた後の区間が空(start >= end)
    EmptyRange,
    /// 出力が Xing ヘッダの 32bit のフィールドに収まらない(4GiB 以上)
    TooLarge,
};

/// LAME タグの delay / padding は 12bit
const max_lame_field = 4095;
/// 開始フレームの前に含めるフレーム数の下限。検証した形(2 フレーム)を下回らないようにする
const min_lead = 2;
/// 開始フレームの手前を振り返る数。ビットリザーバ(main_data_begin は最大 511 バイト)は、
/// メインデータ領域の最も小さいフレーム(32kbps / 48kHz のステレオで 60 バイト)でも 9 フレームに収まる
const max_back = 12;

/// 区間を丸める。タグなしの入力では、先頭の 529 サンプル(デコーダ遅延)は再現できないため切り上げる
pub fn clamp(s: stream.Stream, options: Options) error{EmptyRange}!Result {
    const start = @max(options.start, decoder_delay -| s.skip);
    const end = @min(options.end orelse s.samples, s.samples);
    if (start >= end) return error.EmptyRange;
    return .{ .start = start, .end = end };
}

/// フレームの情報(開始フレームの手前を振り返るために覚えておく分)
const FrameInfo = struct {
    offset: usize,
    header: Header,
    main_data_begin: u16,
};

/// `input` の区間 `[options.start, options.end)` を切り出して `w` に書く。
/// 書き終えた後の `w.flush()` は呼び出し側が行う
pub fn trim(input: []const u8, options: Options, w: *Io.Writer) Error!Result {
    const s = try stream.Stream.parse(input);
    const range = try clamp(s, options);

    // デコーダ出力上の位置 [s0, e0)
    const s0 = range.start + s.skip;
    const e0 = range.end + s.skip;
    const n = e0 - s0;
    const k = s0 / spf; // 開始フレーム
    const a = s0 % spf; // 開始フレーム内の端数
    // 最後のサンプルを含むフレームの 1 つ後まで含める(Safari 向け。ある分だけ)
    const end_frame = @min((e0 - 1) / spf + 2, s.frames);

    // 開始フレームの手前 max_back 個を覚えておき、開始フレームから連結範囲の終わりまでの
    // ビットレートが揃っているか(CBR か)を調べる
    var back_buf: [max_back]FrameInfo = undefined; // back[i] はフレーム k - 1 - i
    var cbr = true;
    var bitrate_index: ?u4 = null;
    var it = s.iterator();
    var i: u64 = 0;
    while (i < end_frame) : (i += 1) {
        const f = it.next().?;
        if (i >= k) {
            const bi = f.header.bitrateIndex();
            if (bitrate_index) |b| cbr = cbr and b == bi else bitrate_index = bi;
        } else if (i + max_back >= k) {
            back_buf[@intCast(k - 1 - i)] = .{
                .offset = f.offset,
                .header = f.header,
                .main_data_begin = f.header.mainDataBegin(f.bytes(input)),
            };
        }
    }
    const end_offset = it.pos;
    const back = back_buf[0..@intCast(@min(k, max_back))];

    const plan = planLead(back, a);
    // 入力からそのまま使うフレーム(carrier を使うときは 1 つ前のフレームから)
    const raw_lead = if (plan.carrier) plan.lead - 1 else plan.lead;
    for (back[0..@intCast(raw_lead)]) |b| cbr = cbr and b.header.bitrateIndex() == bitrate_index.?;
    // raw_lead が 0 になるのは開始フレームが先頭(k = 0)のときだけ
    const first_offset = if (raw_lead > 0) back[@intCast(raw_lead - 1)].offset else s.first_offset;
    const first_header = Header.parse(input[first_offset..]).?;

    var carrier_buf: [frame.max_frame_len]u8 = undefined;
    const carrier: []const u8 = if (plan.carrier) buildCarrier(&carrier_buf, input, back) else &.{};
    if (plan.carrier) cbr = cbr and Header.parse(carrier).?.bitrateIndex() == bitrate_index.?;

    const frames = end_frame - k + plan.lead;
    const delay = plan.lead * spf + a - decoder_delay;
    const padding = frames * spf - delay - n;
    std.debug.assert(delay <= max_lame_field and padding <= max_lame_field);

    // Info フレーム。ビットレートは元のフレームと同じ(VBR なら最小)にし、LAME タグが収まらなければ上げる
    var info_bi: u4 = if (cbr) first_header.bitrateIndex() else 1;
    while (frame.frameLenFor(info_bi, first_header.sampleRate(), false) < xing.infoFrameMinLen(first_header)) info_bi += 1;
    const info_header = first_header.forInfoFrame(info_bi);
    const audio_bytes = carrier.len + (end_offset - first_offset);
    const total_bytes = std.math.cast(u32, info_header.frameLen() + audio_bytes) orelse return error.TooLarge;

    var toc: [100]u8 = undefined;
    if (!cbr) buildToc(&toc, input, carrier.len, first_offset, end_offset, frames);

    try id3.writeItunSmpbTag(w, @intCast(delay + decoder_delay), @intCast(padding - decoder_delay), n);
    try xing.writeInfoFrame(w, .{
        .header = info_header,
        .vbr = !cbr,
        .frames = std.math.cast(u32, frames) orelse return error.TooLarge,
        .bytes = total_bytes,
        .toc = if (cbr) null else &toc,
        .delay = @intCast(delay),
        .padding = @intCast(padding),
    });
    try w.writeAll(carrier);
    try w.writeAll(input[first_offset..end_offset]);
    return range;
}

const Lead = struct {
    /// 開始フレームの手前に置くフレーム数(carrier を含む)
    lead: u64,
    /// 先頭に carrier(ビットリザーバの中身だけを運ぶ無音フレーム)を置くか
    carrier: bool,
};

/// 開始フレームの手前に置くフレームを決める。`back[i]` は開始フレームの i + 1 個前。
///
/// 開始フレームを正しくデコードするには、1 つ前のフレーム(MDCT のオーバーラップ)が正しく
/// デコードされている必要があり、そのためには 1 つ前のフレームが参照するビットリザーバ
/// (main_data_begin バイト)を含むフレームまで遡る必要がある。検証済みの 2 フレームを下限とする。
///
/// 低ビットレートでは遡るフレームが多くなり、delay(lead * spf + a - 529)が LAME タグの
/// 12bit に収まらないことがある。そのときは遡る代わりに、ビットリザーバの中身だけを詰めた
/// 無音フレーム(carrier)を 1 つ前のフレームの前に置き、lead を 2 にする
fn planLead(back: []const FrameInfo, a: u64) Lead {
    if (back.len == 0) return .{ .lead = 0, .carrier = false };
    var need: usize = back[0].main_data_begin;
    var lead: u64 = 1;
    while (need > 0 and lead < back.len) : (lead += 1) {
        need -|= back[@intCast(lead)].header.mainDataLen();
    }
    lead = @max(lead, @min(min_lead, back.len));
    if (lead * spf + a - decoder_delay <= max_lame_field) return .{ .lead = lead, .carrier = false };
    return .{ .lead = 2, .carrier = true };
}

/// carrier を `buf` に作る。ヘッダは開始フレームの 1 つ前(`back[0]`)と同じ設定で、
/// サイド情報はすべて 0(音声データなし)。メインデータ領域の末尾に、`back[0]` が参照する
/// ビットリザーバの中身(それより前のフレームのメインデータ領域の末尾 main_data_begin バイト)を置く
fn buildCarrier(buf: *[frame.max_frame_len]u8, input: []const u8, back: []const FrameInfo) []const u8 {
    const need: usize = back[0].main_data_begin;
    const h0 = back[0].header;
    var bi: u4 = 1;
    while (frame.frameLenFor(bi, h0.sampleRate(), false) - 4 - h0.sideInfoLen() < need) bi += 1;
    const h = h0.forInfoFrame(bi);
    const f = buf[0..h.frameLen()];
    @memset(f, 0);
    std.mem.writeInt(u32, f[0..4], h.raw, .big);

    var remaining = need;
    var dst_end = f.len;
    for (back[1..]) |b| {
        if (remaining == 0) break;
        const area = b.header.mainData(input[b.offset..][0..b.header.frameLen()]);
        const take = @min(remaining, area.len);
        @memcpy(f[dst_end - take .. dst_end], area[area.len - take ..]);
        dst_end -= take;
        remaining -= take;
    }
    return f;
}

/// VBR 用の TOC。i 番目は、連結した音声フレームのうち i% の位置のフレームが、音声フレーム全体の
/// バイト数のどこから始まるかを 256 分率で表したもの(LAME と同じく Info フレームは含めない)。
/// carrier があれば(`carrier_len` > 0)それを先頭のフレームとして数える
fn buildToc(toc: *[100]u8, input: []const u8, carrier_len: usize, first_offset: usize, end_offset: usize, frames: u64) void {
    var it: frame.Iterator = .{ .data = input[0..end_offset], .pos = first_offset };
    const total = carrier_len + (end_offset - first_offset);
    var j: u64 = 0;
    var pos: usize = 0;
    for (toc, 0..) |*v, i| {
        const target = i * frames / 100;
        while (j < target) : (j += 1) {
            pos += if (j == 0 and carrier_len > 0) carrier_len else it.next().?.header.frameLen();
        }
        v.* = @intCast(@min(255, pos * 256 / total));
    }
}

const testdata = @import("testdata");

/// トリム結果を確かめる。出力を解析し直したタイムラインの長さが切り出した長さに一致し、
/// 連結したフレームが(carrier を除いて)入力のバイト列そのままであること
fn expectTrim(input: []const u8, options: Options) !Result {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const r = try trim(input, options, &out.writer);
    const data = out.written();

    // C2PA の GEOB などは付かず、iTunSMPB の COMM だけ
    try std.testing.expectEqual(id3.itunsmpb_tag_len, id3.skipTags(data));
    try std.testing.expect(std.mem.indexOf(u8, data, "GEOB") == null);

    const s = try stream.Stream.parse(data);
    try std.testing.expectEqual(r.end - r.start, s.samples);
    var body = data[s.first_offset..];
    if (std.mem.indexOf(u8, input, body) == null) {
        // 先頭が carrier なら、それは作ったフレーム(main_data_begin が 0)で、残りが入力そのまま
        const c = Header.parse(body).?;
        try std.testing.expectEqual(0, c.mainDataBegin(body));
        body = body[c.frameLen()..];
    }
    try std.testing.expect(std.mem.indexOf(u8, input, body) != null);

    // iTunSMPB の priming = delay + 529、padding = 連結した長さ - priming - N
    const smpb = data[10 + 10 + 13 ..][0..116];
    var expect_buf: [116]u8 = undefined;
    const pad = s.frames * spf - s.skip - s.samples;
    const expect = try std.fmt.bufPrint(&expect_buf, " 00000000 {X:0>8} {X:0>8} {X:0>16}", .{ s.skip, pad, s.samples });
    try std.testing.expectEqualStrings(expect, smpb[0..expect.len]);
    return r;
}

test "trim: Lyria と同じ構成" {
    const in = testdata.lyria_like;
    // 端数 0 / 300 / 1151、フレーム境界での終わり、末尾まで
    for ([_]Options{
        .{ .start = 10 * spf, .end = 50 * spf },
        .{ .start = 10 * spf + 300, .end = 50 * spf - 500 },
        .{ .start = 3 * spf + 1151, .end = 3 * spf + 1152 },
        .{ .start = 20 * spf },
        .{ .start = 529, .end = 2000 },
    }) |o| {
        const r = try expectTrim(in, o);
        try std.testing.expectEqual(o.start, r.start);
        try std.testing.expectEqual(o.end orelse 78 * spf, r.end);
    }
}

test "trim: 範囲外は丸める" {
    const in = testdata.lyria_like;
    const r = try expectTrim(in, .{ .start = 0, .end = 1 << 40 });
    try std.testing.expectEqual(Result{ .start = 529, .end = 78 * spf }, r);
    var discard: Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.EmptyRange, trim(in, .{ .start = 100, .end = 529 }, &discard.writer));
    try std.testing.expectError(error.EmptyRange, trim(in, .{ .start = 78 * spf }, &discard.writer));
    try std.testing.expectError(error.NotMp3, trim("not an mp3", .{}, &discard.writer));
}

test "trim: LAME タグ付きの入力" {
    for ([_][]const u8{ testdata.cbr128_lame, testdata.vbr_lame }) |in| {
        // タグ付きの入力ではタイムラインの 0 から切れる
        try std.testing.expectEqual(Result{ .start = 0, .end = 88200 }, try expectTrim(in, .{}));
        _ = try expectTrim(in, .{ .start = 12345, .end = 67890 });
        _ = try expectTrim(in, .{ .start = 80000 });
    }
}

test "trim: CBR は Info、VBR は Xing" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try trim(testdata.cbr128_lame, .{ .start = 1000, .end = 50000 }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Info") != null);

    out.clearRetainingCapacity();
    _ = try trim(testdata.vbr_lame, .{ .start = 1000, .end = 50000 }, &out.writer);
    const data = out.written();
    const x = id3.itunsmpb_tag_len + 36;
    try std.testing.expectEqualStrings("Xing", data[x..][0..4]);
    const toc = data[x + 16 ..][0..100];
    try std.testing.expectEqual(0, toc[0]);
    for (toc[1..], toc[0..99]) |b, prev| try std.testing.expect(b >= prev);
}

test "trim: 低ビットレートのモノラル" {
    const in = testdata.mono48k_notag;
    _ = try expectTrim(in, .{ .start = 10 * spf + 77, .end = 40 * spf });
    // ビットリザーバが深く、carrier を使う区間(ffmpeg で一致を確かめたもの)
    for ([_]Options{
        .{ .start = 32640, .end = 97920 },
        .{ .start = 72267, .end = 81577 },
        .{ .start = 56666, .end = 68102 },
    }) |o| _ = try expectTrim(in, o);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try trim(in, .{ .start = 10 * spf }, &out.writer);
    // 48kbps のフレーム(144 バイト)には LAME タグが収まらないため、Info フレームは 64kbps(192 バイト)
    const info = Header.parse(out.written()[id3.itunsmpb_tag_len..]).?;
    try std.testing.expectEqual(64, info.bitrate());
}

test planLead {
    const h = Header.parse(&.{ 0xFF, 0xFB, 0xB0, 0x64 }).?; // メインデータ 590 バイト
    const f = struct {
        fn info(header: Header, mdb: u16) FrameInfo {
            return .{ .offset = 0, .header = header, .main_data_begin = mdb };
        }
    }.info;
    const t = std.testing;
    try t.expectEqual(Lead{ .lead = 0, .carrier = false }, planLead(&.{}, 600));
    try t.expectEqual(Lead{ .lead = 1, .carrier = false }, planLead(&.{f(h, 300)}, 600)); // ファイルの先頭付近
    try t.expectEqual(Lead{ .lead = 2, .carrier = false }, planLead(&.{ f(h, 0), f(h, 0), f(h, 0) }, 0)); // 下限
    try t.expectEqual(Lead{ .lead = 2, .carrier = false }, planLead(&.{ f(h, 511), f(h, 0), f(h, 0) }, 0));
    const low = Header.parse(&.{ 0xFF, 0xFB, 0x10, 0xC4 }).?; // 32kbps モノラル: メインデータ 83 バイト
    const deep = [_]FrameInfo{ f(low, 200), f(low, 0), f(low, 0), f(low, 0) };
    // delay = 4 * 1152 - 529 = 4079 は 12bit に収まる
    try t.expectEqual(Lead{ .lead = 4, .carrier = false }, planLead(&deep, 0));
    // delay = 4 * 1152 + 600 - 529 = 4679 は収まらないので carrier を使う
    try t.expectEqual(Lead{ .lead = 2, .carrier = true }, planLead(&deep, 600));
}

test buildCarrier {
    // 32kbps モノラルのフレームを 3 つ並べ、メインデータ領域に目印を書く
    const low = Header.parse(&.{ 0xFF, 0xFB, 0x10, 0xC4 }).?;
    const len = low.frameLen();
    var input: [3 * 104]u8 = undefined;
    for (0..3) |j| {
        const fr = input[j * len ..][0..len];
        @memset(fr, @intCast(j + 1));
        std.mem.writeInt(u32, fr[0..4], low.raw, .big);
    }
    const back = [_]FrameInfo{
        .{ .offset = 2 * len, .header = low, .main_data_begin = 100 },
        .{ .offset = 1 * len, .header = low, .main_data_begin = 0 },
        .{ .offset = 0, .header = low, .main_data_begin = 0 },
    };
    var buf: [frame.max_frame_len]u8 = undefined;
    const c = buildCarrier(&buf, &input, &back);
    const h = Header.parse(c).?;
    try std.testing.expect(h.mainDataLen() >= 100);
    try std.testing.expectEqual(0, h.mainDataBegin(c));
    // 末尾 100 バイトは、フレーム 1 のメインデータ領域(83 バイト)の前にフレーム 0 の末尾 17 バイト
    try std.testing.expect(std.mem.allEqual(u8, c[c.len - 83 ..], 2));
    try std.testing.expect(std.mem.allEqual(u8, c[c.len - 100 .. c.len - 83], 1));
    try std.testing.expect(std.mem.allEqual(u8, c[4 .. c.len - 100], 0));
}
