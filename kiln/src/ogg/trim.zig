// SPDX-License-Identifier: MIT
//! Ogg Opus の無劣化の切り出し(設計は docs/ogg.md §6)。
//!
//! 区間を含む音声パケットを、区間の前の 80ms(デコーダの状態がそろうまでの分)と一緒にそのままコピーし、
//! ID ヘッダの pre-skip で先頭の余分を、最後のページのグラニュール位置で末尾の余分を捨てさせる(RFC 7845 §4.2、§4.5)。
//! ページは作り直す(ページ番号・グラニュール位置・CRC)。serial とコメントヘッダは元のまま。
const std = @import("std");
const Io = std.Io;
const page = @import("page.zig");
const stream = @import("stream.zig");

/// 区間の前に残す長さ(48kHz のサンプル数)。RFC 7845 §4.6 が勧める 80ms
pub const preroll: u64 = 3840;
/// 1 ページに入れる音声の長さの目安(48kHz で 1 秒)。シークの細かさのため
const page_samples: u64 = 48000;
/// ID ヘッダの最大の長さ(19 バイト + ストリーム数などの 2 バイト + チャンネルの割り当て表 255)
const max_head_len = 21 + 255;

pub const Error = error{ InvalidOgg, OutOfMemory, UnsupportedFormat } || Io.Writer.Error;

/// 再生位置 `[start, end)`(48kHz のサンプル数。pre-skip を除いた位置)を切り出して `w` に書く。
/// `pre_skip` は入力の ID ヘッダの値、`lead` は先頭の切り詰めで pre-skip のほかに捨てる長さ(ogg.zig の analyze)。
/// 範囲は呼び出し側が丸めておく(`start < end <= 長さ`)。パケットの数え方は probe と同じ(stream.Walker)
pub fn opusTrim(gpa: std.mem.Allocator, input: []const u8, pre_skip: u16, lead: u64, start: u64, end: u64, w: *Io.Writer) Error!void {
    var first_it: page.Iterator = .{ .input = input };
    const first = first_it.next() orelse return error.InvalidOgg;
    var walker: stream.Walker = .init(input, first);
    var packets: std.ArrayList(stream.Packet) = .empty;
    defer packets.deinit(gpa);
    while (try walker.next()) |pk| try packets.append(gpa, pk);
    if (packets.items.len < 3) return error.InvalidOgg;
    const audio = packets.items[2..];

    // 再生位置 t は、デコード結果の先頭から数えて t + pre_skip + lead の位置にある
    const s_idx = start + pre_skip + lead;
    const e_idx = end + pre_skip + lead;
    const want = s_idx -| preroll;

    // 最初に使うパケット(開始位置が want 以下の最後のもの)と、最後に使うパケット(開始位置が e_idx より前の最後のもの)
    var k: usize = 0;
    var k_start: u64 = 0;
    var last: usize = 0;
    var pos: u64 = 0;
    for (audio, 0..) |pk, i| {
        if (pos <= want) {
            k = i;
            k_start = pos;
        }
        if (pos < e_idx) last = i;
        pos += stream.opusSamples(input, pk);
    }
    const new_skip = std.math.cast(u16, s_idx - k_start) orelse return error.InvalidOgg;

    var pw: PageWriter = try .init(gpa, w, first.serial);
    defer pw.deinit();

    // ID ヘッダ(pre-skip だけ書き換える)とコメントヘッダ。どちらもそれだけでページを終える
    var head_buf: [max_head_len]u8 = undefined;
    const head_pk = packets.items[0];
    if (head_pk.len > head_buf.len or head_pk.len < 19) return error.InvalidOgg;
    var hr: page.PacketReader = .init(input, head_pk.page, head_pk.seg);
    for (head_buf[0..head_pk.len]) |*b| b.* = hr.byte() orelse return error.InvalidOgg;
    std.mem.writeInt(u16, head_buf[10..12], new_skip, .little);
    try pw.packet(head_buf[0..head_pk.len], 0);
    try pw.flush(false);
    try pw.packetFrom(input, packets.items[1], 0);
    try pw.flush(false);

    // 音声。最後のページのグラニュール位置で末尾を切り詰める
    const final_granule = std.math.cast(i64, @as(u64, new_skip) + (end - start)) orelse return error.InvalidOgg;
    var out_pos: u64 = 0;
    for (audio[k .. last + 1], k..) |pk, i| {
        if (pw.packets > 0 and (pw.page_samples >= page_samples or pw.nseg + pk.len / 255 + 1 > 255)) try pw.flush(false);
        const n = stream.opusSamples(input, pk);
        out_pos += n;
        const granule = if (i == last) final_granule else std.math.cast(i64, out_pos) orelse return error.InvalidOgg;
        try pw.packetFrom(input, pk, granule);
        pw.page_samples += n;
    }
    try pw.flush(true);
}

/// パケットを受け取ってページに詰め、`w` に書く。1 ページに入らないパケットは次のページへ続ける
pub const PageWriter = struct {
    w: *Io.Writer,
    gpa: std.mem.Allocator,
    serial: u32,
    sequence: u32 = 0,
    body: []u8,
    body_len: usize = 0,
    lacing: [255]u8 = undefined,
    nseg: usize = 0,
    /// 今のパケットの、まだセグメントにしていないバイト数(0〜255)
    seg_fill: usize = 0,
    /// このページで終わったパケットの数と、最後のもののグラニュール位置
    packets: usize = 0,
    granule: i64 = -1,
    /// このページの先頭が、前のページから続くパケットか
    continued: bool = false,
    /// このページに入れた音声の長さ(呼び出し側が数える)
    page_samples: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, w: *Io.Writer, serial: u32) error{OutOfMemory}!PageWriter {
        // 1 ページの本文(セグメント 255 個分)と、まだセグメントにしていない今のパケットの途中(最大 255 バイト)
        return .{ .w = w, .gpa = gpa, .serial = serial, .body = try gpa.alloc(u8, 255 * 256) };
    }

    pub fn deinit(pw: *PageWriter) void {
        pw.gpa.free(pw.body);
    }

    /// パケット全体を足す。`granule` はこのパケットまでを復号したときの位置
    pub fn packet(pw: *PageWriter, bytes: []const u8, granule: i64) Io.Writer.Error!void {
        try pw.write(bytes);
        try pw.endPacket(granule);
    }

    /// 入力の中のパケットを、ページをまたいで読みながら足す
    pub fn packetFrom(pw: *PageWriter, input: []const u8, pk: stream.Packet, granule: i64) Io.Writer.Error!void {
        var r: page.PacketReader = .init(input, pk.page, pk.seg);
        while (r.slice()) |part| try pw.write(part);
        try pw.endPacket(granule);
    }

    /// パケットの続きのバイト列を足す。セグメント(255 バイト)の区切りごとにまとめて写す
    fn write(pw: *PageWriter, bytes: []const u8) Io.Writer.Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            if (pw.seg_fill == 255) try pw.commitSegment(255);
            const n = @min(255 - pw.seg_fill, rest.len);
            @memcpy(pw.body[pw.body_len..][0..n], rest[0..n]);
            pw.body_len += n;
            pw.seg_fill += n;
            rest = rest[n..];
        }
    }

    fn endPacket(pw: *PageWriter, granule: i64) Io.Writer.Error!void {
        // 255 バイトちょうどで終わるセグメントの後には、長さ 0 のセグメントが要る
        if (pw.seg_fill == 255) try pw.commitSegment(255);
        try pw.commitSegment(pw.seg_fill);
        pw.packets += 1;
        pw.granule = granule;
    }

    /// 長さ `len` のセグメントを表に足す。表がいっぱいなら、そこまでを 1 ページとして書く(パケットは次のページへ続く)
    fn commitSegment(pw: *PageWriter, len: usize) Io.Writer.Error!void {
        if (pw.nseg == 255) {
            try pw.emit(false);
            pw.continued = true;
        }
        pw.lacing[pw.nseg] = @intCast(len);
        pw.nseg += 1;
        pw.seg_fill = 0;
    }

    /// パケットの区切りでページを終える。`eos` なら最後のページ
    pub fn flush(pw: *PageWriter, eos: bool) Io.Writer.Error!void {
        std.debug.assert(pw.seg_fill == 0);
        if (pw.nseg == 0 and !eos) return;
        try pw.emit(eos);
        pw.continued = false;
    }

    fn emit(pw: *PageWriter, eos: bool) Io.Writer.Error!void {
        // セグメントにしたバイトだけを、このページの本文にする(残りは次のページへ)
        var used: usize = 0;
        for (pw.lacing[0..pw.nseg]) |l| used += l;
        var h: [page.header_len]u8 = undefined;
        @memcpy(h[0..4], page.capture);
        h[4] = 0;
        h[5] = (if (pw.sequence == 0) page.flag_bos else 0) |
            (if (pw.continued) page.flag_continued else 0) |
            (if (eos) page.flag_eos else 0);
        std.mem.writeInt(i64, h[6..14], if (pw.packets > 0) pw.granule else -1, .little);
        std.mem.writeInt(u32, h[14..18], pw.serial, .little);
        std.mem.writeInt(u32, h[18..22], pw.sequence, .little);
        @memset(h[22..26], 0);
        h[26] = @intCast(pw.nseg);
        var crc = page.Crc.init();
        crc.update(&h);
        crc.update(pw.lacing[0..pw.nseg]);
        crc.update(pw.body[0..used]);
        std.mem.writeInt(u32, h[22..26], crc.final(), .little);
        try pw.w.writeAll(&h);
        try pw.w.writeAll(pw.lacing[0..pw.nseg]);
        try pw.w.writeAll(pw.body[0..used]);

        // セグメントにしていない分(今のパケットの途中)を先頭に寄せる
        std.mem.copyForwards(u8, pw.body[0 .. pw.body_len - used], pw.body[used..pw.body_len]);
        pw.body_len -= used;
        pw.sequence +%= 1;
        pw.nseg = 0;
        pw.packets = 0;
        pw.granule = -1;
        pw.page_samples = 0;
    }
};

test "PageWriter: 1 ページに入らないパケットは次のページへ続ける" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var pw: PageWriter = try .init(gpa, &out.writer, 9);
    defer pw.deinit();
    const big = try gpa.alloc(u8, 255 * 255 + 1000);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 7);
    const ones: [255]u8 = @splat(1);
    try pw.packet("head", 0);
    try pw.flush(false);
    try pw.packet(big, 0);
    try pw.packet(&ones, 5);
    try pw.packet("tail", 9);
    try pw.flush(true);

    const data = out.written();
    const packets = try stream.collectAll(gpa, data);
    defer gpa.free(packets);
    try std.testing.expectEqual(4, packets.len);
    const want = [_][]const u8{ "head", big, &ones, "tail" };
    for (packets, want) |pk, w| {
        try std.testing.expectEqual(w.len, pk.len);
        var r: page.PacketReader = .init(data, pk.page, pk.seg);
        for (w) |b| try std.testing.expectEqual(b, r.byte().?);
        try std.testing.expectEqual(null, r.byte());
    }
    // 最初のページは BOS、大きなパケットの途中で終わるページのグラニュール位置は -1、最後は EOS
    var it: page.Iterator = .{ .input = data };
    try std.testing.expect(it.next().?.bos());
    const second = it.next().?;
    try std.testing.expectEqual(-1, second.granule);
    var last: page.Page = second;
    while (it.next()) |p| last = p;
    try std.testing.expect(last.eos());
    try std.testing.expectEqual(9, last.granule);
}
