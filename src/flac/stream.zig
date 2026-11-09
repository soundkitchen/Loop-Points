// SPDX-License-Identifier: MIT
//! FLAC のストリーム全体の解析: メタデータと、フレームの区切り。
//!
//! フレームの終わりはヘッダに書かれていないので、次のように見つける(docs/flac.md §2):
//! 1. 次のフレームヘッダ(同期コード・CRC-8 が正しく、ストリームと同じ設定のもの)が現れ、
//!    そこまでの CRC-16 が合う位置。最後のフレームは入力の終わりで CRC-16 が合う位置
//! 2. 見つからなければ、サブフレームの構造を読んで終わりを求め、CRC-16 が合えばそこ
//!    (最後のフレームの後に ID3v1 タグなどが続く場合)
//! 3. それもだめなら、最初に現れた次のフレームヘッダまでを壊れたフレームとする(無音にする)。
//!    次のフレームヘッダもなければ(途中で切れた最後のフレームなど)、そこでストリームが終わる
const std = @import("std");
const frame = @import("frame.zig");
const metadata = @import("metadata.zig");
const decoder = @import("decoder.zig");
const Header = frame.Header;

pub const Error = metadata.Error;
pub const StreamInfo = metadata.StreamInfo;

pub const Frame = struct {
    /// フレームの範囲 [start, end)(入力の先頭からのバイト位置。CRC-16 を含む)
    start: usize,
    end: usize,
    header: Header,
    /// CRC-16 が合っている。false なら壊れたフレーム(復号せずに無音にする)
    ok: bool,
    /// フレームの先頭のサンプル位置(先頭のフレームから数えたもの)
    sample: u64,

    pub fn bytes(f: Frame, input: []const u8) []const u8 {
        return input[f.start..f.end];
    }
};

pub const Stream = struct {
    meta: metadata.Metadata,
    /// 実際のフレームから数えた長さ(STREAMINFO の総サンプル数は使わない)
    samples: u64,
    frames: u64,

    /// `input` 全体を解析し、フレームの区切りをすべて確かめる
    pub fn parse(input: []const u8) Error!Stream {
        const meta = try metadata.Metadata.parse(input);
        var s: Stream = .{ .meta = meta, .samples = 0, .frames = 0 };
        var it = s.iterator(input);
        while (it.next()) |f| {
            s.samples += f.header.block_size;
            s.frames += 1;
        }
        return s;
    }

    pub fn info(s: *const Stream) StreamInfo {
        return s.meta.info;
    }

    pub fn iterator(s: *const Stream, input: []const u8) Iterator {
        return .{ .input = input, .info = s.meta.info, .pos = s.meta.frames_start };
    }
};

pub const Iterator = struct {
    input: []const u8,
    info: StreamInfo,
    pos: usize,
    sample: u64 = 0,
    /// 最初のフレームのブロック長の方式(以降のフレームもそろっていること)
    variable: ?bool = null,

    /// `pos` にあるフレームヘッダを解析する。ストリームの設定(STREAMINFO のサンプルレート・
    /// チャンネル数・ビット深度、ブロック長の方式)と食い違うものは受け付けない
    fn headerAt(it: *const Iterator, pos: usize) ?Header {
        const h = Header.parse(it.input[pos..]) orelse return null;
        if (h.channels != it.info.channels) return null;
        if (h.sample_rate != 0 and h.sample_rate != it.info.sample_rate) return null;
        if (h.bits != 0 and h.bits != it.info.bits) return null;
        if (it.variable) |v| if (h.variable != v) return null;
        return h;
    }

    /// 次のフレーム。ストリームの終わりなら null
    pub fn next(it: *Iterator) ?Frame {
        const input = it.input;
        const start = it.pos;
        if (start >= input.len) return null;
        const h = it.headerAt(start) orelse return null;
        it.variable = h.variable;

        const found = it.findEnd(start, h) orelse return null;
        it.pos = found.end;
        const f: Frame = .{ .start = start, .end = found.end, .header = h, .ok = found.ok, .sample = it.sample };
        it.sample += h.block_size;
        return f;
    }

    const End = struct { end: usize, ok: bool };

    fn findEnd(it: *const Iterator, start: usize, h: Header) ?End {
        const input = it.input;
        const limit = @min(input.len, start + maxFrameLen(h, it.info.bits));
        var crc: frame.Crc16 = .init();
        crc.update(input[start .. start + h.len]);
        // 最初に現れた次のフレームヘッダ(CRC-16 が合わなかったときの区切り)
        var resync: ?usize = null;
        // サブフレームは少なくとも 1 バイト、CRC-16 は 2 バイト
        const min_end = start + h.len + 3;
        var p = start + h.len;
        while (p < limit) : (p += 1) {
            if (p >= min_end and input[p] == 0xFF and it.headerAt(p) != null) {
                if (crc.final() == 0) return .{ .end = p, .ok = true };
                if (resync == null) resync = p;
            }
            crc.update(input[p..][0..1]);
        }
        if (limit == input.len and p >= min_end and crc.final() == 0) return .{ .end = p, .ok = true };

        // 構造を読んで終わりを求める(最後のフレームの後にタグなどが続く場合)
        const bits = if (h.bits != 0) h.bits else it.info.bits;
        if (decoder.frameLen(input[start..], h, bits)) |len| {
            if (frame.Crc16.hash(input[start..][0..len]) == 0) return .{ .end = start + len, .ok = true };
        }
        if (resync) |r| return .{ .end = r, .ok = false };
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
