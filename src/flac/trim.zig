// SPDX-License-Identifier: MIT
//! FLAC → FLAC の切り出し(docs/flac.md §7)。
//!
//! 区間に丸ごと入るフレームは、ヘッダだけを書き換えてそのままコピーする(元の圧縮のまま)。
//! 区間の先頭と末尾にかかるフレーム(と壊れたフレーム)は復号して作り直す。
//!
//! 出力のフレームの長さの並びを先に求め(書き出さずに同じ手順をたどる)、最後を除くフレームが
//! すべて同じ長さなら固定ブロック長(番号はフレーム番号)、そうでなければ可変ブロック長(番号は
//! サンプル位置)のストリームにする。Safari(CoreAudio)は、可変ブロック長で STREAMINFO の最小と
//! 最大のブロック長が等しいストリームと、最初のフレームが 192 サンプル未満のストリームを読めないため
//! (docs/flac.md §7.2)。可変ブロック長では、最後を除き作り直すフレームを 192 サンプル以上にするので、
//! 最小と最大は必ず違う値になる。
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
/// 最後を除き、作り直すフレームはこれより短くしない(Safari は最初のフレームが 192 サンプル未満の
/// 可変ブロック長のストリームを読めない。192 は FLAC の決まったブロック長の最小)
const min_emit = 192;
/// STREAMINFO の最小・最大のブロック長の下限(RFC 9639 §8.2)
const min_streaminfo_block = 16;
/// 作り直すフレームの圧縮の段階(作り直すのは数フレームだけなので、最も小さくなる設定にする)
const compression = encoder.max_compression;

pub const Result = struct {
    /// 区間にかかった壊れたフレーム(無音として作り直した)の数
    invalid_frames: u64,
    /// 出力の先頭に書き戻す STREAMINFO
    patch: encoder.StreamInfoPatch,
};

/// 残すメタデータブロック(Vorbis コメント、画像、APPLICATION)。シークテーブル・CUE シート・PADDING・
/// 未知の種類は、位置がずれる・意味が分からないので捨てる。中身の構造が壊れているもの(長さがブロックを
/// 超えるなど)も、出力を不正にしないよう捨てる
fn keep(b: Block) bool {
    return switch (b.kind) {
        .vorbis_comment => validVorbisComment(b.body),
        .picture => validPicture(b.body),
        .application => b.body.len >= 4,
        else => false,
    };
}

/// 長さ(`endian` の u32)と、その長さのバイト列を読み進める。ブロックを超えれば false
fn skipField(body: []const u8, pos: *usize, endian: std.builtin.Endian) bool {
    if (body.len - pos.* < 4) return false;
    const len = std.mem.readInt(u32, body[pos.*..][0..4], endian);
    pos.* += 4;
    if (body.len - pos.* < len) return false;
    pos.* += len;
    return true;
}

/// Vorbis コメント(RFC 9639 §8.6): ベンダー文字列、コメントの数、コメント(長さはリトルエンディアン)
fn validVorbisComment(body: []const u8) bool {
    var pos: usize = 0;
    if (!skipField(body, &pos, .little)) return false;
    if (body.len - pos < 4) return false;
    const count = std.mem.readInt(u32, body[pos..][0..4], .little);
    pos += 4;
    for (0..count) |_| if (!skipField(body, &pos, .little)) return false;
    return true;
}

/// 画像(RFC 9639 §8.8): 種類、MIME 型、説明、幅・高さ・色深度・色数、画像データ(ビッグエンディアン)
fn validPicture(body: []const u8) bool {
    var pos: usize = 4;
    if (body.len < pos) return false;
    if (!skipField(body, &pos, .big) or !skipField(body, &pos, .big)) return false;
    if (body.len - pos < 16) return false;
    pos += 16;
    return skipField(body, &pos, .big);
}

/// 解析済みの `ix` の区間 `[start, end)`(丸め済み)を FLAC にして `w` に書く
pub fn trim(gpa: std.mem.Allocator, input: []const u8, ix: *const stream.Index, start: u64, end: u64, w: *Io.Writer) !Result {
    const si = ix.stream.info();

    // 1 回目: フレームの長さの並びだけを求めて、固定ブロック長にできるかを決める
    var plan: Trimmer = .{ .channels = si.channels };
    var largest: u64 = 0;
    for (ix.frames) |f| {
        if (f.sample >= end) break;
        if (f.sample + f.samples <= start) continue;
        if (f.header != null) largest = @max(largest, f.samples);
        try walk(&plan, f, start, end);
    }
    try plan.flushAll();
    const fixed = plan.sizes.isFixed();

    try writeHeader(input, ix.stream.meta, si, w);
    // 作り直す分をためる長さ: 4096 サンプルずつ書くので 2 倍あれば足りる。丸ごと入るフレームが
    // 復号できなかったときは、そのブロック長の無音を 1 フレームで書くので、それも入るようにする
    const cap: usize = @intCast(@min(@max(2 * chunk, largest), 65535));
    var t: Trimmer = .{
        .w = w,
        .channels = si.channels,
        .bits_per_sample = si.bits,
        .stream_bits = si.bits,
        .fixed = fixed,
        .md5 = .init(.{}),
        .fe = try .init(gpa, .{
            .sample_rate = si.sample_rate,
            .channels = si.channels,
            .bits_per_sample = si.bits,
            .compression = compression,
        }, @intCast(cap)),
        .cap = cap,
        .input = input,
    };
    defer t.fe.?.deinit();
    const pend = try gpa.alloc(i64, cap * @as(usize, si.channels));
    defer gpa.free(pend);
    for (0..si.channels) |ch| t.pending[ch] = pend[ch * cap ..][0..cap];
    var d: decoder.Decoder = .init(gpa);
    defer d.deinit();
    t.decoder = &d;

    // 2 回目: 書き出す(1 回目と同じ手順をたどるので、フレームの長さの並びは同じになる)
    for (ix.frames) |f| {
        if (f.sample >= end) break;
        if (f.sample + f.samples <= start) continue;
        try walk(&t, f, start, end);
    }
    try t.flushAll();

    const s = t.sizes;
    // 固定ブロック長でフレームが 1 つだけなら、ブロック長は書いたフレーム以上の値ならよい。エンコーダと
    // 同じく 4096 にする(Safari は最小・最大が 16 の 10 サンプルの FLAC を読めず、4096 なら読める)
    const max_block = if (t.fixed and s.count == 1) @max(s.max, chunk) else s.max;
    const min_block = if (t.fixed) max_block else s.minExceptLast();
    var info = encoder.streamInfoBytes(.{
        .min_block = @intCast(std.math.clamp(min_block, min_streaminfo_block, 65535)),
        .max_block = @intCast(std.math.clamp(max_block, min_streaminfo_block, 65535)),
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
    return .{ .invalid_frames = t.invalid, .patch = .{ .offset = 8, .bytes = info } };
}

/// フレーム `f` の区間 `[start, end)` にかかる分を処理する(1 回目は長さの並びだけを求める)
fn walk(t: *Trimmer, f: stream.Frame, start: u64, end: u64) !void {
    const lo = @max(start, f.sample) - f.sample;
    const hi = @min(end, f.sample + f.samples) - f.sample;
    const whole = f.header != null and lo == 0 and hi == f.samples;
    if (whole and (t.pending_len == 0 or t.pending_len >= min_emit)) {
        // 丸ごと入る正しいフレームはコピーする(たまっている分は先に書く)
        try t.flushAll();
        if (t.dry()) return t.note(@intCast(f.samples), 0);
        return t.copy(f);
    }
    // 区間にかかるフレーム、壊れたフレーム(無音)、短すぎて単独では書けない分の続きは作り直す
    const samples: ?[]const i64 = if (t.dry()) null else t.decode(f);
    try t.append(samples, if (f.header) |h| h.block_size else 0, lo, hi);
}

/// `fLaC`、STREAMINFO(仮)、残すメタデータブロックを書く
fn writeHeader(input: []const u8, meta: metadata.Metadata, si: metadata.StreamInfo, w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("fLaC");
    // 残すブロックを数える(最後のブロックの印を付けるため)
    var kept: usize = 0;
    var it = blockIterator(input, meta);
    while (it.next()) |b| {
        if (keep(b)) kept += 1;
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
        if (!keep(b)) continue;
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

/// 書いたフレームの長さの並びの要約
const Sizes = struct {
    count: u64 = 0,
    first: u32 = 0,
    /// 直前のフレームの長さ(最後のフレームかどうかは終わるまで分からない)
    last: u32 = 0,
    max: u32 = 0,
    /// 直前のフレームより前のフレームの最小
    min_before_last: u32 = std.math.maxInt(u32),
    /// 直前のフレームより前のフレームが、すべて最初のフレームと同じ長さか
    uniform_before_last: bool = true,

    fn add(s: *Sizes, n: u32) void {
        if (s.count == 0) {
            s.first = n;
        } else {
            s.min_before_last = @min(s.min_before_last, s.last);
            if (s.last != s.first) s.uniform_before_last = false;
        }
        s.last = n;
        s.max = @max(s.max, n);
        s.count += 1;
    }

    /// 固定ブロック長にできるか: 最後を除くフレームがすべて同じ長さで、最後のフレームはそれ以下
    fn isFixed(s: *const Sizes) bool {
        return s.count > 0 and s.uniform_before_last and s.last <= s.first and s.first <= 65535;
    }

    /// 最後を除くフレームの最小(フレームが 1 つならその長さ)
    fn minExceptLast(s: *const Sizes) u32 {
        return if (s.count <= 1) s.last else s.min_before_last;
    }
};

/// 1 回目(長さの並びだけを求める)と 2 回目(書き出す)で同じ手順をたどる。`w` が null なら 1 回目
const Trimmer = struct {
    channels: u8,
    w: ?*Io.Writer = null,
    bits_per_sample: u8 = 0,
    stream_bits: u8 = 0,
    fixed: bool = false,
    md5: std.crypto.hash.Md5 = undefined,
    fe: ?encoder.FrameEncoder = null,
    decoder: ?*decoder.Decoder = null,
    input: []const u8 = &.{},
    /// 作り直す分(チャンネルごと)
    pending: [8][]i64 = undefined,
    cap: usize = 2 * chunk,
    pending_len: usize = 0,
    /// 書いたフレームの数とサンプル数(次のフレームの番号になる)
    frame_index: u64 = 0,
    position: u64 = 0,
    sizes: Sizes = .{},
    min_frame: u32 = std.math.maxInt(u32),
    max_frame: u32 = 0,
    invalid: u64 = 0,

    fn dry(t: *const Trimmer) bool {
        return t.w == null;
    }

    /// フレームを復号する。壊れていれば null(数える)
    fn decode(t: *Trimmer, f: stream.Frame) ?[]const i64 {
        const h = f.header orelse {
            t.invalid += f.count;
            return null;
        };
        return t.decoder.?.decodeFrame(f.bytes(t.input), h, if (h.bits != 0) h.bits else t.stream_bits) catch {
            t.invalid += f.count;
            return null;
        };
    }

    /// 書いたフレームを記録する
    fn note(t: *Trimmer, block: u32, len: usize) void {
        t.sizes.add(block);
        t.frame_index += 1;
        t.position += block;
        if (!t.dry()) {
            const l: u32 = @intCast(len);
            t.min_frame = @min(t.min_frame, l);
            t.max_frame = @max(t.max_frame, l);
        }
    }

    /// 次のフレームの番号(固定ブロック長ではフレーム番号、可変ではサンプル位置)
    fn number(t: *const Trimmer) u64 {
        return if (t.fixed) t.frame_index else t.position;
    }

    /// チャンネルごとのサンプル(`samples` は block 個ずつ。null なら無音)の `[lo, hi)` を、
    /// 作り直す分に足す。たまったら、短すぎるフレームが残らないように書く
    fn append(t: *Trimmer, samples: ?[]const i64, block: u32, lo: u64, hi: u64) !void {
        var i = lo;
        while (i < hi) {
            const n: usize = @intCast(@min(hi - i, 2 * chunk - t.pending_len));
            if (!t.dry()) {
                for (0..t.channels) |ch| {
                    const dst = t.pending[ch][t.pending_len..][0..n];
                    if (samples) |s| {
                        const off: usize = @intCast(i);
                        @memcpy(dst, s[ch * block + off ..][0..n]);
                    } else @memset(dst, 0);
                }
                t.md5Planar(t.pending, t.pending_len, n);
            }
            t.pending_len += n;
            i += n;
            while (t.pending_len >= chunk + min_emit) try t.emit(chunk);
        }
    }

    /// たまっている分をすべて書く(長ければ、ほぼ等しい 2 つに分けて短すぎるフレームを作らない)
    fn flushAll(t: *Trimmer) !void {
        if (t.pending_len > chunk) try t.emit(t.pending_len / 2);
        if (t.pending_len > 0) try t.emit(t.pending_len);
    }

    /// たまっている分の先頭 `n` サンプルを 1 フレームに作り直して書く
    fn emit(t: *Trimmer, n: usize) !void {
        if (t.dry()) {
            t.note(@intCast(n), 0);
        } else {
            var chans: [8][]const i64 = undefined;
            for (0..t.channels) |ch| chans[ch] = t.pending[ch][0..n];
            const bytes = t.fe.?.encode(chans[0..t.channels], t.number(), !t.fixed);
            try t.w.?.writeAll(bytes);
            t.note(@intCast(n), bytes.len);
            const rest = t.pending_len - n;
            for (0..t.channels) |ch| std.mem.copyForwards(i64, t.pending[ch][0..rest], t.pending[ch][n..t.pending_len]);
        }
        t.pending_len -= n;
    }

    /// 丸ごと入るフレーム `f` を、番号を書き換えてコピーする。復号できなければ同じ長さの無音を作り直す
    fn copy(t: *Trimmer, f: stream.Frame) !void {
        const h = f.header.?;
        const samples = t.decode(f) orelse {
            std.debug.assert(t.pending_len == 0);
            if (h.block_size > t.cap) {
                // ブロック長 65536 のフレーム(STREAMINFO に書けない長さ)は 1 フレームでは作り直せないので、
                // 分けて作り直す。長さの並びは 1 回目と変わるが、可変ブロック長なら差し支えない
                // (固定ブロック長は 65535 以下のときだけ選ぶ)
                return t.append(null, 0, 0, h.block_size);
            }
            // 同じ長さの無音を 1 フレームで書く(1 回目の長さの並びと合わせる)
            for (0..t.channels) |ch| @memset(t.pending[ch][0..h.block_size], 0);
            t.md5Planar(t.pending, 0, h.block_size);
            t.pending_len = h.block_size;
            return t.emit(h.block_size);
        };
        const fr = f.bytes(t.input);
        var hb: [32]u8 = undefined;
        var bw: bits.Writer = .{ .buf = &hb };
        bw.put(if (t.fixed) 0xFFF8 else 0xFFF9, 16);
        bw.put(fr[2], 8);
        bw.put(fr[3], 8);
        encoder.putCodedNumber(&bw, t.number());
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
        const w = t.w.?;
        try w.writeAll(head);
        try w.writeAll(body);
        try w.writeAll(&c);
        var chans: [8][]const i64 = undefined;
        for (0..t.channels) |ch| chans[ch] = samples[ch * h.block_size ..][0..h.block_size];
        t.md5Planar(chans[0..t.channels], 0, h.block_size);
        t.note(h.block_size, head.len + body.len + 2);
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

test "残すメタデータブロックの中身を確かめる" {
    // Vorbis コメント: ベンダー "ab"、コメント 1 つ "x=1"
    const vc = "\x02\x00\x00\x00ab" ++ "\x01\x00\x00\x00" ++ "\x03\x00\x00\x00x=1";
    try std.testing.expect(validVorbisComment(vc));
    try std.testing.expect(!validVorbisComment(vc[0 .. vc.len - 1]));
    // コメントの数が多すぎる、長さが大きすぎる
    try std.testing.expect(!validVorbisComment("\x02\x00\x00\x00ab" ++ "\x02\x00\x00\x00" ++ "\x03\x00\x00\x00x=1"));
    try std.testing.expect(!validVorbisComment("\x02\x00\x00\x00ab" ++ "\x01\x00\x00\x00" ++ "\x03\x00\x00\xC8x=1"));
    // 画像: 種類 3、MIME "a"、説明 ""、幅など 16 バイト、データ 2 バイト
    const pic = "\x00\x00\x00\x03" ++ "\x00\x00\x00\x01a" ++ "\x00\x00\x00\x00" ++ @as([16]u8, @splat(0)) ++ "\x00\x00\x00\x02xy";
    try std.testing.expect(validPicture(pic));
    try std.testing.expect(!validPicture(pic[0 .. pic.len - 1]));
    try std.testing.expect(keep(.{ .kind = .application, .body = "abcd" }));
    try std.testing.expect(!keep(.{ .kind = .application, .body = "abc" }));
    try std.testing.expect(!keep(.{ .kind = .padding, .body = "" }));
}
