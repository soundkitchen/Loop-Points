// SPDX-License-Identifier: MIT
//! Ogg のページ(RFC 3533)の読み取りと、ページをまたぐパケットの読み出し。
const std = @import("std");

/// ページの CRC-32(多項式 0x04C11DB7、初期値 0、反転なし、最後の XOR なし。CRC の欄を 0 にして計算する)
pub const Crc = std.hash.crc.Generic(u32, .{
    .polynomial = 0x04C11DB7,
    .initial = 0,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0,
});

pub const capture = "OggS";
/// ページヘッダの固定部分の長さ(この後にセグメントの長さの表が続く)
pub const header_len = 27;

pub const flag_continued: u8 = 0x01;
pub const flag_bos: u8 = 0x02;
pub const flag_eos: u8 = 0x04;

pub const Page = struct {
    /// 入力の中での位置 [start, end)
    start: usize,
    end: usize,
    flags: u8,
    /// グラニュール位置。-1 はこのページで終わるパケットがないこと
    granule: i64,
    serial: u32,
    sequence: u32,
    /// セグメントの長さの表(255 未満の値でパケットが終わる)
    lacing: []const u8,
    body: []const u8,

    pub fn continued(p: Page) bool {
        return p.flags & flag_continued != 0;
    }
    pub fn bos(p: Page) bool {
        return p.flags & flag_bos != 0;
    }
    pub fn eos(p: Page) bool {
        return p.flags & flag_eos != 0;
    }

    /// このページで終わるパケットの数
    pub fn packetsEnded(p: Page) usize {
        var n: usize = 0;
        for (p.lacing) |l| {
            if (l < 255) n += 1;
        }
        return n;
    }
};

pub const ReadError = error{
    /// `pos` に `OggS` がない、またはページが入力の外まで続く
    NoPage,
    /// 構造は読めたが CRC が合わない、またはバージョンが 0 でない
    BadPage,
};

/// `pos` から始まるページを読む
pub fn read(input: []const u8, pos: usize) ReadError!Page {
    if (input.len - pos < header_len or !std.mem.eql(u8, input[pos..][0..4], capture)) return error.NoPage;
    const h = input[pos..][0..header_len];
    const nseg = h[26];
    if (input.len - pos - header_len < nseg) return error.NoPage;
    const lacing = input[pos + header_len ..][0..nseg];
    var body_len: usize = 0;
    for (lacing) |l| body_len += l;
    const body_start = pos + header_len + nseg;
    if (input.len - body_start < body_len) return error.NoPage;
    const end = body_start + body_len;
    if (h[4] != 0) return error.BadPage;
    var crc = Crc.init();
    crc.update(input[pos..][0..22]);
    crc.update(&.{ 0, 0, 0, 0 });
    crc.update(input[pos + 26 .. end]);
    if (crc.final() != std.mem.readInt(u32, h[22..26], .little)) return error.BadPage;
    return .{
        .start = pos,
        .end = end,
        .flags = h[5],
        .granule = std.mem.readInt(i64, h[6..14], .little),
        .serial = std.mem.readInt(u32, h[14..18], .little),
        .sequence = std.mem.readInt(u32, h[18..22], .little),
        .lacing = lacing,
        .body = input[body_start..end],
    };
}

/// 正しいページを順に返す。読めない場所(CRC が合わないページ、ゴミ)は次の `OggS` まで飛ばし、
/// 飛ばした箇所の数を `invalid` に数える。入力の終わりで途切れたページも 1 つと数える
pub const Iterator = struct {
    input: []const u8,
    pos: usize = 0,
    invalid: u64 = 0,

    pub fn next(it: *Iterator) ?Page {
        while (it.pos < it.input.len) {
            if (read(it.input, it.pos)) |p| {
                it.pos = p.end;
                return p;
            } else |_| {
                it.invalid += 1;
                it.pos = findCapture(it.input, it.pos + 1) orelse it.input.len;
            }
        }
        return null;
    }
};

fn findCapture(input: []const u8, from: usize) ?usize {
    if (from >= input.len) return null;
    const i = std.mem.indexOf(u8, input[from..], capture) orelse return null;
    return from + i;
}

/// 1 つのパケットのバイトを、ページをまたいで順に読む。同じ serial の正しいページだけをたどり、
/// 途中のページが欠けていたら(次のページが続きでないか、ページ番号が飛んでいる)パケットの終わりとみなす
pub const PacketReader = struct {
    input: []const u8,
    page: Page,
    /// 今のセグメントの番号と、その中で読んだバイト数
    seg: usize,
    in_seg: usize = 0,
    /// 今のセグメントの本文の中での開始位置
    seg_off: usize,
    /// 次のページを探す位置
    next_pos: usize,
    done: bool = false,

    /// `page` の `seg` 番目のセグメントから始まるパケットを読む
    pub fn init(input: []const u8, page: Page, seg: usize) PacketReader {
        var off: usize = 0;
        for (page.lacing[0..seg]) |l| off += l;
        return .{ .input = input, .page = page, .seg = seg, .seg_off = off, .next_pos = page.end };
    }

    /// 次のバイト。パケットの終わりなら null
    pub fn byte(r: *PacketReader) ?u8 {
        while (!r.done) {
            if (r.seg == r.page.lacing.len) {
                // ページの最後のセグメントが 255 で、パケットは次のページへ続く
                if (!r.nextPage()) {
                    r.done = true;
                    return null;
                }
                continue;
            }
            const len = r.page.lacing[r.seg];
            if (r.in_seg < len) {
                const b = r.page.body[r.seg_off + r.in_seg];
                r.in_seg += 1;
                return b;
            }
            if (len < 255) {
                r.done = true;
                return null;
            }
            r.seg_off += len;
            r.seg += 1;
            r.in_seg = 0;
        }
        return null;
    }

    /// パケットの続きを、ページの中で連続している分ずつ返す(セグメントの区切りでは分けない)。パケットの終わりなら null。
    /// `byte` と混ぜて使わない
    pub fn slice(r: *PacketReader) ?[]const u8 {
        while (!r.done) {
            if (r.seg == r.page.lacing.len) {
                if (!r.nextPage()) {
                    r.done = true;
                    return null;
                }
                continue;
            }
            // このページの中で、パケットが終わるか、ページが終わるまでのセグメントをまとめる
            var end_off = r.seg_off;
            var s = r.seg;
            while (s < r.page.lacing.len) {
                const l = r.page.lacing[s];
                end_off += l;
                s += 1;
                if (l < 255) {
                    r.done = true;
                    break;
                }
            }
            const out = r.page.body[r.seg_off + r.in_seg .. end_off];
            r.seg = s;
            r.seg_off = end_off;
            r.in_seg = 0;
            if (out.len > 0) return out;
        }
        return null;
    }

    fn nextPage(r: *PacketReader) bool {
        var it: Iterator = .{ .input = r.input, .pos = r.next_pos };
        while (it.next()) |p| {
            if (p.serial != r.page.serial) continue;
            // 続きのページでないか、ページ番号が飛んでいれば(間のページが欠けている)パケットの終わり
            if (!p.continued() or p.sequence != r.page.sequence +% 1) return false;
            r.page = p;
            r.seg = 0;
            r.in_seg = 0;
            r.seg_off = 0;
            r.next_pos = p.end;
            return true;
        }
        return false;
    }
};

/// LSB から順にビットを読む(Vorbis のビット順)
pub const BitReader = struct {
    src: *PacketReader,
    cur: u8 = 0,
    left: u4 = 0,

    pub const Error = error{EndOfPacket};

    pub fn read(b: *BitReader, comptime T: type, n: u6) Error!T {
        std.debug.assert(n <= @bitSizeOf(T));
        var v: u64 = 0;
        var got: u6 = 0;
        while (got < n) {
            if (b.left == 0) {
                b.cur = b.src.byte() orelse return error.EndOfPacket;
                b.left = 8;
            }
            const take: u6 = @min(n - got, b.left);
            const mask: u8 = @truncate((@as(u16, 1) << @intCast(take)) - 1);
            v |= @as(u64, b.cur & mask) << got;
            b.cur = @truncate(@as(u16, b.cur) >> @intCast(take));
            b.left -= @intCast(take);
            got += take;
        }
        return @intCast(v);
    }

    pub fn flag(b: *BitReader) Error!bool {
        return try b.read(u1, 1) == 1;
    }
};

/// テスト用: 1 ページを組み立てる(CRC も計算する)。`open` なら最後のパケットはこのページで終わらず、
/// 次のページへ続く(長さは 255 の倍数にする)
pub fn build(buf: []u8, flags: u8, granule: i64, serial: u32, sequence: u32, packets: []const []const u8, open: bool) []u8 {
    var nseg: usize = 0;
    var body: usize = 0;
    for (packets, 0..) |p, i| {
        const last_open = open and i == packets.len - 1;
        std.debug.assert(!last_open or p.len % 255 == 0);
        nseg += p.len / 255 + @intFromBool(!last_open);
        body += p.len;
    }
    const h = buf[0..header_len];
    @memcpy(h[0..4], capture);
    h[4] = 0;
    h[5] = flags;
    std.mem.writeInt(i64, h[6..14], granule, .little);
    std.mem.writeInt(u32, h[14..18], serial, .little);
    std.mem.writeInt(u32, h[18..22], sequence, .little);
    @memset(h[22..26], 0);
    h[26] = @intCast(nseg);
    var s: usize = header_len;
    var o: usize = header_len + nseg;
    for (packets, 0..) |p, i| {
        var left = p.len;
        while (left >= 255) : (left -= 255) {
            buf[s] = 255;
            s += 1;
        }
        if (!(open and i == packets.len - 1)) {
            buf[s] = @intCast(left);
            s += 1;
        }
        @memcpy(buf[o..][0..p.len], p);
        o += p.len;
    }
    var crc = Crc.init();
    crc.update(buf[0..o]);
    std.mem.writeInt(u32, buf[22..26], crc.final(), .little);
    return buf[0..o];
}

test "read と CRC" {
    var buf: [512]u8 = undefined;
    const p = build(&buf, flag_bos, 0, 7, 0, &.{"hello"}, false);
    const page = try read(p, 0);
    try std.testing.expect(page.bos());
    try std.testing.expectEqual(7, page.serial);
    try std.testing.expectEqualStrings("hello", page.body);
    try std.testing.expectEqual(1, page.packetsEnded());
    // CRC が合わない
    buf[p.len - 1] ^= 1;
    try std.testing.expectError(error.BadPage, read(p, 0));
    // 途切れたページ
    try std.testing.expectError(error.NoPage, read(p[0 .. p.len - 1], 0));
    try std.testing.expectError(error.NoPage, read("OggT", 0));
}

test "PacketReader はページをまたいで読む" {
    var input: [2048]u8 = undefined;
    var long: [300]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @truncate(i);
    // 1 ページ目: 短いパケット "ab" と、長いパケットの先頭 255 バイト。2 ページ目: その続き(45 バイト)
    var pos = build(&input, 0, -1, 1, 0, &.{ "ab", long[0..255] }, true).len;
    // 別の serial のページは飛ばす
    pos += build(input[pos..], 0, -1, 2, 0, &.{"zz"}, false).len;
    pos += build(input[pos..], flag_continued, 100, 1, 1, &.{long[255..]}, false).len;
    const first = try read(&input, 0);
    try std.testing.expectEqual(1, first.packetsEnded());
    var r1: PacketReader = .init(input[0..pos], first, 0);
    try std.testing.expectEqual('a', r1.byte().?);
    try std.testing.expectEqual('b', r1.byte().?);
    try std.testing.expectEqual(null, r1.byte());
    var r2: PacketReader = .init(input[0..pos], first, 1);
    for (long) |want| try std.testing.expectEqual(want, r2.byte().?);
    try std.testing.expectEqual(null, r2.byte());
}

test "PacketReader.slice はページの中で連続している分ずつ返す" {
    var input: [2048]u8 = undefined;
    var long: [600]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @truncate(i);
    // 1 ページ目: 短いパケット "ab" と、長いパケットの先頭 510 バイト。2 ページ目: その続き(90 バイト)と "cd"
    var pos = build(&input, 0, -1, 1, 0, &.{ "ab", long[0..510] }, true).len;
    pos += build(input[pos..], flag_continued, 100, 1, 1, &.{ long[510..], "cd" }, false).len;
    const first = try read(&input, 0);
    var r1: PacketReader = .init(input[0..pos], first, 0);
    try std.testing.expectEqualStrings("ab", r1.slice().?);
    try std.testing.expectEqual(null, r1.slice());
    var r2: PacketReader = .init(input[0..pos], first, 1);
    try std.testing.expectEqualSlices(u8, long[0..510], r2.slice().?);
    try std.testing.expectEqualSlices(u8, long[510..], r2.slice().?);
    try std.testing.expectEqual(null, r2.slice());
}

test "PacketReader は間のページが欠けていたら止まる" {
    var input: [2048]u8 = undefined;
    var long: [600]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @truncate(i);
    // 3 ページにまたがるパケットの、2 ページ目(ページ番号 1)が欠けている
    var pos = build(&input, 0, -1, 1, 0, &.{long[0..255]}, true).len;
    pos += build(input[pos..], flag_continued, 100, 1, 2, &.{long[510..]}, false).len;
    var r: PacketReader = .init(input[0..pos], try read(&input, 0), 0);
    for (long[0..255]) |want| try std.testing.expectEqual(want, r.byte().?);
    try std.testing.expectEqual(null, r.byte());
}

test BitReader {
    // 0b1011_0110, 0b0000_0011
    var input: [64]u8 = undefined;
    const p = build(&input, 0, 0, 1, 0, &.{&.{ 0xB6, 0x03 }}, false);
    var pr: PacketReader = .init(p, try read(p, 0), 0);
    var b: BitReader = .{ .src = &pr };
    try std.testing.expectEqual(0b0110, try b.read(u8, 4));
    try std.testing.expectEqual(0b11_1011, try b.read(u8, 6));
    try std.testing.expectEqual(0, try b.read(u8, 6));
    try std.testing.expectError(error.EndOfPacket, b.read(u8, 1));
}
