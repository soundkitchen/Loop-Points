// SPDX-License-Identifier: MIT
//! 1 本のストリーム(論理ビットストリーム)のパケットを順にたどる。解析(`ogg.probe`)と切り出し(`ogg.trim`)が
//! 同じ規則でパケットを数えるよう、ここにまとめる(読めないページ、欠けたページ、続きのフラグの扱い)。
const std = @import("std");
const page = @import("page.zig");
const opus = @import("opus.zig");

pub const Error = error{
    /// 多重化(先頭に複数の BOS)や連結(EOS の後に新しい BOS)
    UnsupportedFormat,
};

/// ストリームの中のパケット
pub const Packet = struct {
    /// パケットが始まるページと、その中のセグメントの番号
    page: page.Page,
    seg: usize,
    len: usize,
    /// パケットが終わるページ
    end: page.Page,
};

pub const Walker = struct {
    it: page.Iterator,
    serial: u32,
    expect_seq: u32,
    /// 前のページまでに飛ばした(読めなかった)ページの数。ページ番号の飛びがそれで説明できるかを見る
    skipped_before: u64 = 0,
    /// 欠けたページの数(読めずに飛ばしたページでは説明できない、ページ番号の飛び)
    missing: u64 = 0,
    ended: bool = false,
    cur: ?page.Page = null,
    seg: usize = 0,
    /// 始まりを読めなかったパケットの続きを飛ばしている
    skipping: bool = false,
    /// 続いているパケット(前のページから続くもの)。null は続いていない(欠けたページの後など)
    open: ?Packet = null,

    /// `first` は入力の最初の(BOS の)ページ
    pub fn init(input: []const u8, first: page.Page) Walker {
        return .{ .it = .{ .input = input }, .serial = first.serial, .expect_seq = first.sequence };
    }

    /// 次に終わったパケット。欠けたページの前で途切れたパケットと、始まりを読めなかったパケットは返さない
    pub fn next(w: *Walker) Error!?Packet {
        while (true) {
            if (w.cur == null or w.seg == w.cur.?.lacing.len) {
                if (w.cur) |c| {
                    if (c.eos()) w.ended = true;
                }
                w.cur = (try w.nextPage()) orelse return null;
                w.seg = 0;
            }
            const p = w.cur.?;
            const seg = w.seg;
            const l = p.lacing[seg];
            w.seg += 1;
            if (w.skipping) {
                if (l < 255) w.skipping = false;
                continue;
            }
            if (w.open == null) w.open = .{ .page = p, .seg = seg, .len = 0, .end = undefined };
            w.open.?.len += l;
            if (l == 255) continue;
            var done = w.open.?;
            done.end = p;
            w.open = null;
            return done;
        }
    }

    /// 同じストリームの次のページ。ページ番号の飛びと続きのフラグを見て、途切れたパケットを捨てる
    fn nextPage(w: *Walker) Error!?page.Page {
        while (w.it.next()) |p| {
            if (p.serial == w.serial and !w.ended) {
                if (p.sequence != w.expect_seq) {
                    // 欠けたページがある。読めずに飛ばしたページがなければ、ページそのものがない
                    // (飛ばしたページは Iterator が数える)
                    if (w.it.invalid == w.skipped_before) w.missing += 1;
                    w.open = null;
                }
                w.expect_seq = p.sequence +% 1;
                w.skipped_before = w.it.invalid;
                if (!p.continued()) w.open = null;
                w.skipping = p.continued() and w.open == null;
                return p;
            } else if (p.bos()) {
                return error.UnsupportedFormat;
            }
        }
        return null;
    }

    /// 読めずに飛ばしたページと、欠けたページの数(最後まで読んだ後に使う)
    pub fn invalidPages(w: *const Walker) u64 {
        return w.missing + w.it.invalid;
    }
};

/// Opus の音声パケットの長さ(48kHz のサンプル数)。壊れた(120ms を超える)パケットと空のパケットは 0
pub fn opusSamples(input: []const u8, pk: Packet) u32 {
    var two: [2]u8 = @splat(0);
    var r: page.PacketReader = .init(input, pk.page, pk.seg);
    for (&two) |*b| b.* = r.byte() orelse break;
    return opus.packetSamples(pk.len, two[0], two[1]) orelse 0;
}

/// パケットの先頭のバイト(空のパケットは null)
pub fn firstByte(input: []const u8, pk: Packet) ?u8 {
    if (pk.len == 0) return null;
    var r: page.PacketReader = .init(input, pk.page, pk.seg);
    return r.byte();
}

/// テスト用: ストリームのパケットをすべて集める。返したものは呼び出し側が解放する
pub fn collectAll(gpa: std.mem.Allocator, input: []const u8) ![]Packet {
    var first_it: page.Iterator = .{ .input = input };
    var w: Walker = .init(input, first_it.next().?);
    var list: std.ArrayList(Packet) = .empty;
    errdefer list.deinit(gpa);
    while (try w.next()) |pk| try list.append(gpa, pk);
    return list.toOwnedSlice(gpa);
}
