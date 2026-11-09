// SPDX-License-Identifier: MIT
//! FLAC のストリーム全体の解析: メタデータと、フレームの区切り(docs/flac.md §2)。
//!
//! フレームの終わりはヘッダに書かれていないので、次のように見つける:
//! 1. 次のフレームヘッダ(同期コード・CRC-8 が正しく、ストリームと同じ設定で、番号が続いているもの)が
//!    現れ、そこまでの CRC-16 が合う位置。最後のフレームは入力の終わりで CRC-16 が合う位置
//! 2. 見つからなければ、サブフレームの構造を読んで終わりを求め、CRC-16 が合えばそこ
//!    (最後のフレームの後に ID3v1 タグなどが続く場合)
//!
//! どちらもだめなフレームや、ヘッダが壊れて読めない位置からは、番号が続く(または先に進んだ)ヘッダで、
//! そのフレームの CRC-16 も合うものを探して区切り直す。その間は壊れた区間として無音にし、
//! 長さはフレーム番号(可変ブロック長ではサンプル位置)の差から求める。見つからなければ
//! (途中で切れた最後のフレームなど)、そこでストリームが終わる。
//!
//! 番号は、固定ブロック長の印のストリームでもサンプル位置のことがある(古い形式の可変ブロック長)。
//! STREAMINFO のブロック長は誤っていることがあるので使わず、2 つ目のフレームの番号で見分ける。
const std = @import("std");
const frame = @import("frame.zig");
const metadata = @import("metadata.zig");
const decoder = @import("decoder.zig");
const Header = frame.Header;

pub const Error = metadata.Error;
pub const StreamInfo = metadata.StreamInfo;

pub const Frame = struct {
    /// フレーム(または壊れた区間)の範囲 [start, end)(入力の先頭からのバイト位置)
    start: usize,
    end: usize,
    /// 正しいフレームのヘッダ。null なら壊れた区間(復号せずに無音にする)
    header: ?Header,
    /// 先頭のサンプル位置(最初のフレームから数えたもの)
    sample: u64,
    /// サンプル数(壊れた区間では、失われたフレームを含めた長さ)
    samples: u64,
    /// 表しているフレームの数(正しいフレームは 1。壊れた区間では失われたフレームの数)
    count: u64,

    pub fn bytes(f: Frame, input: []const u8) []const u8 {
        return input[f.start..f.end];
    }
};

pub const Stream = struct {
    meta: metadata.Metadata,
    /// 実際のフレームから数えた長さ(STREAMINFO の総サンプル数は使わない)
    samples: u64,
    frames: u64,
    /// 壊れたフレームの数(`frames` に含む)
    invalid_frames: u64,

    /// `input` 全体を解析し、フレームの区切りをすべて確かめる
    pub fn parse(input: []const u8) Error!Stream {
        const meta = try metadata.Metadata.parse(input);
        var s: Stream = .{ .meta = meta, .samples = 0, .frames = 0, .invalid_frames = 0 };
        var it = s.iterator(input);
        while (it.next()) |f| s.add(f);
        return s;
    }

    fn add(s: *Stream, f: Frame) void {
        s.samples += f.samples;
        s.frames += f.count;
        if (f.header == null) s.invalid_frames += f.count;
    }

    pub fn info(s: *const Stream) StreamInfo {
        return s.meta.info;
    }

    pub fn iterator(s: *const Stream, input: []const u8) Iterator {
        return .{ .input = input, .info = s.meta.info, .pos = s.meta.frames_start };
    }
};

/// フレームの一覧(区切りを 1 回だけ探し、復号や切り出しで使い回す)
pub const Index = struct {
    stream: Stream,
    frames: []Frame,

    pub fn init(gpa: std.mem.Allocator, input: []const u8) (Error || error{OutOfMemory})!Index {
        const meta = try metadata.Metadata.parse(input);
        var s: Stream = .{ .meta = meta, .samples = 0, .frames = 0, .invalid_frames = 0 };
        var list: std.ArrayList(Frame) = .empty;
        errdefer list.deinit(gpa);
        var it = s.iterator(input);
        while (it.next()) |f| {
            try list.append(gpa, f);
            s.add(f);
        }
        return .{ .stream = s, .frames = try list.toOwnedSlice(gpa) };
    }

    pub fn deinit(ix: *Index, gpa: std.mem.Allocator) void {
        gpa.free(ix.frames);
    }
};

/// 番号の条件(フレーム番号、可変ブロック長ではサンプル位置)
const Number = union(enum) {
    any,
    exactly: u64,
    /// どちらか(番号の付け方がまだ分からないとき)
    either: [2]u64,
    at_least: u64,

    /// 条件に合う最小の番号
    fn min(n: Number) u64 {
        return switch (n) {
            .any => 0,
            .exactly, .at_least => |v| v,
            .either => |v| @min(v[0], v[1]),
        };
    }
};

pub const Iterator = struct {
    input: []const u8,
    info: StreamInfo,
    pos: usize,
    sample: u64 = 0,
    /// 最初のフレームのブロック長の方式(以降のフレームもそろっていること)
    variable: ?bool = null,
    /// 最初のフレームのブロック長(固定ブロック長で、失われたフレームの長さを求めるのに使う)
    first_block: ?u32 = null,
    /// 番号がサンプル位置か(可変ブロック長、または固定ブロック長の印で番号がサンプル位置の古い形式)。
    /// 固定ブロック長の印のストリームでは、2 つ目のフレームの番号を見て決める(null はまだ分からない)
    by_sample: ?bool = null,
    /// 次のフレームの番号の条件
    want: Number = .any,

    /// `pos` にあるフレームヘッダを解析する。ストリームの設定(STREAMINFO のサンプルレート・
    /// チャンネル数・ビット深度、ブロック長の方式)と食い違うもの、番号が条件に合わないものは受け付けない
    fn headerAt(it: *const Iterator, pos: usize, number: Number) ?Header {
        const h = Header.parse(it.input[pos..]) orelse return null;
        if (h.channels != it.info.channels) return null;
        if (h.sample_rate != 0 and h.sample_rate != it.info.sample_rate) return null;
        if (h.bits != 0 and h.bits != it.info.bits) return null;
        if (it.variable) |v| if (h.variable != v) return null;
        switch (number) {
            .any => {},
            .exactly => |n| if (h.number != n) return null,
            .either => |v| if (h.number != v[0] and h.number != v[1]) return null,
            .at_least => |n| if (h.number < n) return null,
        }
        return h;
    }

    /// 次のフレーム(または壊れた区間)。ストリームの終わりなら null
    pub fn next(it: *Iterator) ?Frame {
        while (true) {
            const start = it.pos;
            if (start >= it.input.len) return null;
            if (it.headerAt(start, it.want)) |h| {
                it.variable = h.variable;
                if (it.first_block == null) it.first_block = h.block_size;
                it.learnNumbering(h);
                const after = it.nextNumber(h);
                if (it.validEnd(start, h)) |end| {
                    return it.emit(.{ .start = start, .end = end, .header = h, .sample = it.sample, .samples = h.block_size, .count = 1 }, end, after);
                }
                // CRC-16 が合わない: 次の正しいフレームまでを壊れた区間にする
                const c = it.resync(start + h.len, after.min()) orelse return null;
                const gap = it.lost(c.header, after.min());
                return it.emit(.{
                    .start = start,
                    .end = c.pos,
                    .header = null,
                    .sample = it.sample,
                    .samples = h.block_size + gap.samples,
                    .count = 1 + gap.frames,
                }, c.pos, .{ .exactly = c.header.number });
            }
            // ヘッダが読めない(壊れている、番号が飛んでいる、フレームの間にゴミがある)
            const expected = it.want.min();
            const c = it.resync(start, expected) orelse return null;
            const gap = it.lost(c.header, expected);
            if (gap.samples == 0) {
                // 失われたフレームはない(フレームの間のゴミ)。読み飛ばして続ける
                it.pos = c.pos;
                it.want = .{ .exactly = c.header.number };
                continue;
            }
            return it.emit(.{
                .start = start,
                .end = c.pos,
                .header = null,
                .sample = it.sample,
                .samples = gap.samples,
                .count = @max(gap.frames, 1),
            }, c.pos, .{ .exactly = c.header.number });
        }
    }

    fn emit(it: *Iterator, f: Frame, end: usize, want: Number) Frame {
        it.pos = end;
        it.sample += f.samples;
        it.want = want;
        return f;
    }

    /// 番号の付け方を、受け付けたヘッダ `h` から決める(固定ブロック長の印のストリームでは 2 つ目のフレームで)
    fn learnNumbering(it: *Iterator, h: Header) void {
        if (it.by_sample != null) return;
        if (h.variable) {
            it.by_sample = true;
            return;
        }
        switch (it.want) {
            .either => |v| if (v[0] != v[1]) {
                it.by_sample = h.number == v[1];
            },
            else => {},
        }
    }

    /// ヘッダ `h` のフレームの次のフレームの番号の条件
    fn nextNumber(it: *const Iterator, h: Header) Number {
        const by_frame = h.number + 1;
        const by_sample = h.number + h.block_size;
        if (h.variable) return .{ .exactly = by_sample };
        const b = it.by_sample orelse return .{ .either = .{ by_frame, by_sample } };
        return .{ .exactly = if (b) by_sample else by_frame };
    }

    const Gap = struct { samples: u64, frames: u64 };

    /// 番号 `expected` のはずの位置に番号 `h.number` のフレームがあるとき、その間で失われた長さ
    fn lost(it: *const Iterator, h: Header, expected: u64) Gap {
        const d = h.number - expected;
        if (h.variable or it.by_sample == true) return .{ .samples = d, .frames = @intFromBool(d > 0) };
        return .{ .samples = d * (it.first_block orelse h.block_size), .frames = d };
    }

    const Candidate = struct { pos: usize, header: Header };

    /// `from` 以降で、番号が `expected` 以上のヘッダを持ち、そのフレームの CRC-16 も合う位置を探す
    /// (壊れたフレームの中に偶然できた同期コードは、番号か CRC-16 で弾く)
    fn resync(it: *const Iterator, from: usize, expected: u64) ?Candidate {
        const input = it.input;
        var p = from;
        while (std.mem.indexOfScalarPos(u8, input, p, 0xFF)) |q| : (p = q + 1) {
            const h = it.headerAt(q, .{ .at_least = expected }) orelse continue;
            var probe = it.*;
            probe.variable = h.variable;
            if (probe.validEnd(q, h) == null) continue;
            return .{ .pos = q, .header = h };
        }
        return null;
    }

    /// `start` のフレーム(ヘッダ `h`)の終わり。CRC-16 が合う区切りが見つからなければ null
    fn validEnd(it: *const Iterator, start: usize, h: Header) ?usize {
        const input = it.input;
        const limit = @min(input.len, start + maxFrameLen(h, it.info.bits));
        const want = it.nextNumber(h);
        var crc: frame.Crc16 = .init();
        // サブフレームは少なくとも 1 バイト、CRC-16 は 2 バイト
        const min_end = start + h.len + 3;
        crc.update(input[start..@min(min_end, limit)]);
        var p = @min(min_end, limit);
        while (p < limit) {
            // 次のヘッダの候補(0xFF)まではまとめて CRC を計算する
            const q = std.mem.indexOfScalarPos(u8, input[0..limit], p, 0xFF) orelse limit;
            crc.update(input[p..q]);
            p = q;
            if (p == limit) break;
            if (crc.final() == 0 and it.headerAt(p, want) != null) return p;
            crc.update(input[p..][0..1]);
            p += 1;
        }
        if (limit == input.len and p >= min_end and crc.final() == 0) return p;

        // 構造を読んで終わりを求める(最後のフレームの後にタグなどが続く場合)
        const bits = if (h.bits != 0) h.bits else it.info.bits;
        const len = decoder.frameLen(input[start..], h, bits) orelse return null;
        if (frame.Crc16.hash(input[start..][0..len]) == 0) return start + len;
        return null;
    }
};

/// フレームの大きさの上限の目安(この範囲で次のフレームヘッダを探す)。
/// すべてのサブフレームが無圧縮(side チャンネルは 1 ビット多い)の大きさに、ヘッダなどの余裕を足したもの
fn maxFrameLen(h: Header, stream_bits: u8) usize {
    const bits: usize = if (h.bits != 0) h.bits else stream_bits;
    const per_channel = (@as(usize, h.block_size) * (bits + 2) + 64 * 33) / 8 + 8;
    return h.len + per_channel * h.channels + 2;
}
