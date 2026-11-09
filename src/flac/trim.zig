// SPDX-License-Identifier: MIT
//! FLAC → FLAC の切り出し(docs/flac.md §7)。
//!
//! 区間に丸ごと入るフレームは、ヘッダだけを書き換えてそのままコピーする(元の圧縮のまま)。
//! 区間の先頭と末尾にかかるフレーム(と壊れたフレーム)は復号して作り直す。先頭が途中から始まるので、
//! 出力は可変ブロック長のストリーム(フレームの番号はサンプル位置)にする。
const std = @import("std");
const Io = std.Io;
const frame = @import("frame.zig");
const bits = @import("bits.zig");
const metadata = @import("metadata.zig");
const stream = @import("stream.zig");
const decoder = @import("decoder.zig");
const encoder = @import("encoder.zig");

/// 作り直すフレームのブロック長
const chunk = 4096;
/// 最後のフレームを除き、フレームはこれより短くしない(STREAMINFO の最小ブロック長は 16 以上)
const min_block = 16;
/// 作り直すフレームの圧縮の段階(作り直すのは数フレームだけなので、最も小さくなる設定にする)
const compression = encoder.max_compression;

pub const Result = struct {
    /// 区間にかかった壊れたフレーム(無音として作り直した)の数
    invalid_frames: u64,
    /// 出力の先頭に書き戻す STREAMINFO
    patch: encoder.StreamInfoPatch,
};

/// 残すメタデータブロック(Vorbis コメント、画像、APPLICATION)。シークテーブル・CUE シート・PADDING・
/// 未知の種類は、位置がずれる・意味が分からないので捨てる
fn keep(kind: metadata.BlockType) bool {
    return kind == .vorbis_comment or kind == .picture or kind == .application;
}

/// 解析済みの `ix` の区間 `[start, end)`(丸め済み)を FLAC にして `w` に書く
pub fn trim(gpa: std.mem.Allocator, input: []const u8, ix: *const stream.Index, start: u64, end: u64, w: *Io.Writer) !Result {
    const si = ix.stream.info();
    try writeHeader(input, ix.stream.meta, si, w);

    var t: Trimmer = .{
        .w = w,
        .channels = si.channels,
        .bits_per_sample = si.bits,
        .md5 = .init(.{}),
        .fe = try .init(gpa, .{
            .sample_rate = si.sample_rate,
            .channels = si.channels,
            .bits_per_sample = si.bits,
            .compression = compression,
        }, pending_cap),
        .pending = undefined,
    };
    defer t.fe.deinit();
    const pend = try gpa.alloc(i64, pending_cap * @as(usize, si.channels));
    defer gpa.free(pend);
    for (0..si.channels) |ch| t.pending[ch] = pend[ch * pending_cap ..][0..pending_cap];

    var d: decoder.Decoder = .init(gpa);
    defer d.deinit();
    var invalid: u64 = 0;
    for (ix.frames) |f| {
        if (f.sample >= end) break;
        if (f.sample + f.samples <= start) continue;
        const lo = @max(start, f.sample) - f.sample;
        const hi = @min(end, f.sample + f.samples) - f.sample;
        const samples: ?[]const i64 = if (f.header) |h|
            d.decodeFrame(f.bytes(input), h, if (h.bits != 0) h.bits else si.bits) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidFrame => null,
            }
        else
            null;
        if (samples == null) invalid += f.count;
        const whole = samples != null and lo == 0 and hi == f.samples;
        if (whole and (t.pending_len == 0 or t.pending_len >= min_block)) {
            // 丸ごと入る正しいフレームはコピーする(たまっている分は先に書く)
            try t.flushAll();
            try t.copy(f.bytes(input), f.header.?, samples.?);
        } else {
            // 区間にかかるフレーム、壊れたフレーム(無音)、短すぎて単独では書けない分の続きは作り直す
            try t.append(samples, if (f.header) |h| h.block_size else 0, lo, hi);
        }
    }
    try t.flushAll();

    // 最小・最大のブロック長は 16〜65535 でなければならない(RFC 9639 §8.2。ffmpeg は最大が 16 未満の
    // ストリームを開かない)。最後のフレームは最小より短くてよいので、短いフレーム 1 つだけでも 16 にする
    var info = encoder.streamInfoBytes(.{
        .min_block = @intCast(std.math.clamp(t.minBlock(), min_block, 65535)),
        .max_block = @intCast(std.math.clamp(t.max_block, min_block, 65535)),
        .min_frame = t.min_frame,
        .max_frame = t.max_frame,
        .sample_rate = si.sample_rate,
        .channels = si.channels,
        .bits_per_sample = si.bits,
        .total = end - start,
    });
    var digest: [16]u8 = undefined;
    t.md5.final(&digest);
    info[18..34].* = digest;
    return .{ .invalid_frames = invalid, .patch = .{ .offset = 8, .bytes = info } };
}

/// `fLaC`、STREAMINFO(仮)、残すメタデータブロックを書く
fn writeHeader(input: []const u8, meta: metadata.Metadata, si: metadata.StreamInfo, w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("fLaC");
    // 残すブロックを数える(最後のブロックの印を付けるため)
    var kept: usize = 0;
    var it = blockIterator(input, meta);
    while (it.next()) |b| {
        if (keep(b.kind)) kept += 1;
    }
    try w.writeAll(&.{ if (kept == 0) 0x80 else 0x00, 0x00, 0x00, 0x22 });
    try w.writeAll(&encoder.streamInfoBytes(.{
        .min_block = 0,
        .max_block = 0,
        .min_frame = 0,
        .max_frame = 0,
        .sample_rate = si.sample_rate,
        .channels = si.channels,
        .bits_per_sample = si.bits,
        .total = 0,
    }));
    it = blockIterator(input, meta);
    var written: usize = 0;
    while (it.next()) |b| {
        if (!keep(b.kind)) continue;
        written += 1;
        const last: u8 = if (written == kept) 0x80 else 0;
        var h: [4]u8 = undefined;
        h[0] = last | @as(u8, @backingInt(b.kind));
        std.mem.writeInt(u24, h[1..4], @intCast(b.body.len), .big);
        try w.writeAll(&h);
        try w.writeAll(b.body);
    }
}

const Block = struct { kind: metadata.BlockType, body: []const u8 };

/// メタデータブロックを順にたどる(`Metadata.parse` が確かめた後なので、長さは入力に収まる)
const BlockIterator = struct {
    input: []const u8,
    pos: usize,
    end: usize,

    fn next(it: *BlockIterator) ?Block {
        if (it.pos >= it.end) return null;
        const h = it.input[it.pos..][0..4];
        const len = std.mem.readInt(u24, h[1..4], .big);
        const b: Block = .{ .kind = @fromBackingInt(@intCast(h[0] & 0x7F)), .body = it.input[it.pos + 4 ..][0..len] };
        it.pos += 4 + @as(usize, len);
        return b;
    }
};

fn blockIterator(input: []const u8, meta: metadata.Metadata) BlockIterator {
    return .{ .input = input, .pos = meta.start + 4, .end = meta.frames_start };
}

/// 作り直す分をためておく長さ(1 フレームのブロック長 + 最小のブロック長に余裕を足したもの)
const pending_cap = 2 * chunk;

const Trimmer = struct {
    w: *Io.Writer,
    channels: u8,
    bits_per_sample: u8,
    md5: std.crypto.hash.Md5,
    fe: encoder.FrameEncoder,
    /// 作り直す分(チャンネルごと)
    pending: [8][]i64,
    pending_len: usize = 0,
    /// 次に書くフレームのサンプル位置
    position: u64 = 0,
    /// 書いたフレームのブロック長(最後のフレームを除く最小と、最大)
    min_block: u32 = std.math.maxInt(u32),
    max_block: u32 = 0,
    /// 直前に書いたフレームのブロック長(最後のフレームかどうかは終わるまで分からない)
    last_block: u32 = 0,
    min_frame: u32 = std.math.maxInt(u32),
    max_frame: u32 = 0,

    /// 最後のフレームを除いたブロック長の最小(フレームが 1 つならそのブロック長)
    fn minBlock(t: *const Trimmer) u32 {
        return if (t.min_block == std.math.maxInt(u32)) t.last_block else t.min_block;
    }

    fn noteFrame(t: *Trimmer, block: u32, len: usize) void {
        if (t.last_block != 0) t.min_block = @min(t.min_block, t.last_block);
        t.last_block = block;
        t.max_block = @max(t.max_block, block);
        const l: u32 = @intCast(len);
        t.min_frame = @min(t.min_frame, l);
        t.max_frame = @max(t.max_frame, l);
        t.position += block;
    }

    /// チャンネルごとのサンプル(`samples` は block 個ずつ。null なら無音)の `[lo, hi)` を、
    /// 作り直す分に足す。たまったら、最小のブロック長以上を残して書く
    fn append(t: *Trimmer, samples: ?[]const i64, block: u32, lo: u64, hi: u64) !void {
        var i = lo;
        while (i < hi) {
            const n: usize = @intCast(@min(hi - i, pending_cap - t.pending_len));
            for (0..t.channels) |ch| {
                const dst = t.pending[ch][t.pending_len..][0..n];
                if (samples) |s| {
                    const off: usize = @intCast(i);
                    @memcpy(dst, s[ch * block + off ..][0..n]);
                } else @memset(dst, 0);
            }
            t.md5Planar(t.pending, t.pending_len, n);
            t.pending_len += n;
            i += n;
            while (t.pending_len >= chunk + min_block) try t.emit(chunk);
        }
    }

    /// たまっている分をすべて書く(長ければ、ほぼ等しい 2 つに分けて最小のブロック長を下回らないようにする)
    fn flushAll(t: *Trimmer) !void {
        if (t.pending_len > chunk) try t.emit(t.pending_len / 2);
        if (t.pending_len > 0) try t.emit(t.pending_len);
    }

    /// たまっている分の先頭 `n` サンプルを 1 フレームに作り直して書く
    fn emit(t: *Trimmer, n: usize) !void {
        var chans: [8][]const i64 = undefined;
        for (0..t.channels) |ch| chans[ch] = t.pending[ch][0..n];
        const bytes = t.fe.encode(chans[0..t.channels], t.position, true);
        try t.w.writeAll(bytes);
        t.noteFrame(@intCast(n), bytes.len);
        const rest = t.pending_len - n;
        for (0..t.channels) |ch| std.mem.copyForwards(i64, t.pending[ch][0..rest], t.pending[ch][n..t.pending_len]);
        t.pending_len = rest;
    }

    /// フレーム `fr`(ヘッダ `h`、復号した `samples`)を、可変ブロック長のヘッダに書き換えてコピーする
    fn copy(t: *Trimmer, fr: []const u8, h: frame.Header, samples: []const i64) !void {
        var hb: [32]u8 = undefined;
        var bw: bits.Writer = .{ .buf = &hb };
        bw.put(0xFFF9, 16);
        bw.put(fr[2], 8);
        bw.put(fr[3], 8);
        encoder.putCodedNumber(&bw, t.position);
        // 番号の後のブロック長・サンプルレート(あれば)はそのまま
        const old_len: usize = if (fr[4] < 0x80) 1 else @clz(~fr[4]);
        for (fr[4 + old_len .. h.len - 1]) |b| bw.put(b, 8);
        bw.put(frame.Crc8.hash(bw.written()), 8);
        const head = bw.written();
        const body = fr[h.len .. fr.len - 2];
        var crc: frame.Crc16 = .init();
        crc.update(head);
        crc.update(body);
        var c: [2]u8 = undefined;
        std.mem.writeInt(u16, &c, crc.final(), .big);
        try t.w.writeAll(head);
        try t.w.writeAll(body);
        try t.w.writeAll(&c);
        var chans: [8][]const i64 = undefined;
        for (0..t.channels) |ch| chans[ch] = samples[ch * h.block_size ..][0..h.block_size];
        t.md5Planar(chans[0..t.channels], 0, h.block_size);
        t.noteFrame(h.block_size, head.len + body.len + 2);
    }

    /// チャンネルごとのサンプル `chans` の `[off, off + n)` で MD5 を更新する
    fn md5Planar(t: *Trimmer, chans: anytype, off: usize, n: usize) void {
        var buf: [4096]i32 = undefined;
        const nch = t.channels;
        const per = buf.len / nch;
        var i: usize = 0;
        while (i < n) {
            const m = @min(per, n - i);
            for (0..m) |j| {
                for (0..nch) |ch| buf[j * nch + ch] = @intCast(chans[ch][off + i + j]);
            }
            encoder.md5Update(&t.md5, t.bits_per_sample, buf[0 .. m * nch]);
            i += m;
        }
    }
};
