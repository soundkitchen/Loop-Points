// SPDX-License-Identifier: MIT
//! Vorbis I のヘッダの読み取り(識別ヘッダと設定ヘッダ)と、音声パケットの長さ。
//! 設定ヘッダは、末尾のモードの表(各モードのブロックの大小)を知るためだけに読む。
//! コードブック・フロア・レジデュー・マッピングは、構造をたどって読み飛ばす(中身は使わない)。
const std = @import("std");
const page = @import("page.zig");

pub const Error = error{ InvalidOgg, UnsupportedFormat };

pub const Identification = struct {
    channels: u8,
    sample_rate: u32,
    /// 短いブロックと長いブロックの長さ(64〜8192)
    blocksize: [2]u16,
};

/// 識別ヘッダ(パケット 1)を読む。`packet` は先頭 30 バイト
pub fn identification(packet: []const u8) Error!Identification {
    if (packet.len < 30 or packet[0] != 1 or !std.mem.eql(u8, packet[1..7], "vorbis")) return error.InvalidOgg;
    if (std.mem.readInt(u32, packet[7..11], .little) != 0) return error.UnsupportedFormat;
    const channels = packet[11];
    const rate = std.mem.readInt(u32, packet[12..16], .little);
    const b0: u4 = @truncate(packet[28]);
    const b1: u4 = @truncate(packet[28] >> 4);
    if (channels == 0 or rate == 0 or b0 < 6 or b1 > 13 or b0 > b1 or packet[29] & 1 == 0) return error.InvalidOgg;
    return .{ .channels = channels, .sample_rate = rate, .blocksize = .{ @as(u16, 1) << b0, @as(u16, 1) << b1 } };
}

/// モードの表。`long[i]` はモード i が長いブロックか
pub const Modes = struct {
    count: u8,
    long: [64]bool,

    /// モード番号のビット数
    pub fn bits(m: Modes) u6 {
        return ilog(m.count - 1);
    }
};

/// 設定ヘッダ(パケット 5)を読み、モードの表を返す
pub fn setup(r: *page.PacketReader, channels: u8) Error!Modes {
    var b: page.BitReader = .{ .src = r };
    return setupBits(&b, channels) catch |err| switch (err) {
        error.EndOfPacket => error.InvalidOgg,
        else => |e| e,
    };
}

fn setupBits(b: *page.BitReader, channels: u8) (Error || page.BitReader.Error)!Modes {
    if (try b.read(u8, 8) != 5) return error.InvalidOgg;
    for ("vorbis") |c| if (try b.read(u8, 8) != c) return error.InvalidOgg;

    const books: u16 = @as(u16, try b.read(u8, 8)) + 1;
    for (0..books) |_| try codebook(b);

    // 時間領域の変換(すべて 0 でなければならない)
    const times: u8 = @as(u8, try b.read(u6, 6)) + 1;
    for (0..times) |_| if (try b.read(u16, 16) != 0) return error.InvalidOgg;

    const floors: u8 = @as(u8, try b.read(u6, 6)) + 1;
    for (0..floors) |_| try floor(b, books);

    const residues: u8 = @as(u8, try b.read(u6, 6)) + 1;
    for (0..residues) |_| try residue(b, books);

    const mappings: u8 = @as(u8, try b.read(u6, 6)) + 1;
    for (0..mappings) |_| try mapping(b, channels, floors, residues);

    var modes: Modes = .{ .count = @as(u8, try b.read(u6, 6)) + 1, .long = @splat(false) };
    for (0..modes.count) |i| {
        modes.long[i] = try b.flag();
        // 窓と変換の種類は 0 だけ
        if (try b.read(u16, 16) != 0 or try b.read(u16, 16) != 0) return error.InvalidOgg;
        if (try b.read(u8, 8) >= mappings) return error.InvalidOgg;
    }
    if (!try b.flag()) return error.InvalidOgg;
    return modes;
}

fn codebook(b: *page.BitReader) !void {
    if (try b.read(u24, 24) != 0x564342) return error.InvalidOgg;
    const dims = try b.read(u16, 16);
    const entries = try b.read(u24, 24);
    if (try b.flag()) {
        // 長さの昇順に、同じ長さの項目の数を並べたもの
        var cur: u32 = 0;
        var len: u32 = @as(u32, try b.read(u5, 5)) + 1;
        while (cur < entries) : (len += 1) {
            if (len > 32) return error.InvalidOgg;
            const n = try b.read(u32, ilog(entries - cur));
            if (n > entries - cur) return error.InvalidOgg;
            cur += n;
        }
    } else {
        const sparse = try b.flag();
        for (0..entries) |_| {
            if (sparse and !try b.flag()) continue;
            _ = try b.read(u5, 5);
        }
    }
    const lookup = try b.read(u4, 4);
    switch (lookup) {
        0 => {},
        1, 2 => {
            _ = try b.read(u32, 32);
            _ = try b.read(u32, 32);
            const value_bits: u6 = @as(u6, try b.read(u4, 4)) + 1;
            _ = try b.flag();
            if (dims == 0) return error.InvalidOgg;
            const count: u64 = if (lookup == 1) lookup1Values(entries, dims) else @as(u64, entries) * dims;
            // 値の表は使わないので読み飛ばす(パケットが足りなければ EndOfPacket)
            var i: u64 = 0;
            while (i < count) : (i += 1) _ = try b.read(u32, value_bits);
        },
        else => return error.InvalidOgg,
    }
}

/// r^dims <= entries となる最大の r
fn lookup1Values(entries: u32, dims: u16) u64 {
    var r: u64 = @intFromFloat(@floor(std.math.pow(f64, @floatFromInt(entries), 1.0 / @as(f64, @floatFromInt(dims)))));
    while (powAtMost(r + 1, dims, entries)) r += 1;
    while (r > 0 and !powAtMost(r, dims, entries)) r -= 1;
    return r;
}

fn powAtMost(base: u64, exp: u16, limit: u32) bool {
    var v: u64 = 1;
    for (0..exp) |_| {
        v = std.math.mul(u64, v, base) catch return false;
        if (v > limit) return false;
    }
    return true;
}

fn floor(b: *page.BitReader, books: u16) !void {
    switch (try b.read(u16, 16)) {
        0 => {
            _ = try b.read(u8, 8); // order
            _ = try b.read(u16, 16); // rate
            _ = try b.read(u16, 16); // bark map size
            _ = try b.read(u6, 6); // amplitude bits
            _ = try b.read(u8, 8); // amplitude offset
            const n: u8 = @as(u8, try b.read(u4, 4)) + 1;
            for (0..n) |_| if (try b.read(u8, 8) >= books) return error.InvalidOgg;
        },
        1 => {
            const partitions = try b.read(u5, 5);
            var classes: [32]u4 = undefined;
            var max_class: i8 = -1;
            for (classes[0..partitions]) |*c| {
                c.* = try b.read(u4, 4);
                max_class = @max(max_class, c.*);
            }
            var dims: [16]u8 = undefined;
            var c: i8 = 0;
            while (c <= max_class) : (c += 1) {
                const ci: usize = @intCast(c);
                dims[ci] = @as(u8, try b.read(u3, 3)) + 1;
                const subclasses = try b.read(u2, 2);
                if (subclasses != 0 and try b.read(u8, 8) >= books) return error.InvalidOgg;
                for (0..@as(usize, 1) << subclasses) |_| {
                    const book = try b.read(u8, 8);
                    if (book != 0 and book - 1 >= books) return error.InvalidOgg;
                }
            }
            _ = try b.read(u2, 2); // multiplier
            const range_bits = try b.read(u4, 4);
            for (classes[0..partitions]) |cl| {
                for (0..dims[cl]) |_| _ = try b.read(u16, range_bits);
            }
        },
        else => return error.InvalidOgg,
    }
}

fn residue(b: *page.BitReader, books: u16) !void {
    if (try b.read(u16, 16) > 2) return error.InvalidOgg;
    _ = try b.read(u24, 24); // begin
    _ = try b.read(u24, 24); // end
    _ = try b.read(u24, 24); // partition size - 1
    const classifications: u8 = @as(u8, try b.read(u6, 6)) + 1;
    if (try b.read(u8, 8) >= books) return error.InvalidOgg;
    var cascade: [64]u8 = undefined;
    for (cascade[0..classifications]) |*c| {
        const low = try b.read(u3, 3);
        const high: u8 = if (try b.flag()) try b.read(u5, 5) else 0;
        c.* = high * 8 + low;
    }
    for (cascade[0..classifications]) |c| {
        for (0..8) |j| {
            if (c >> @intCast(j) & 1 != 0 and try b.read(u8, 8) >= books) return error.InvalidOgg;
        }
    }
}

fn mapping(b: *page.BitReader, channels: u8, floors: u8, residues: u8) !void {
    if (try b.read(u16, 16) != 0) return error.InvalidOgg;
    const submaps: u8 = if (try b.flag()) @as(u8, try b.read(u4, 4)) + 1 else 1;
    if (try b.flag()) {
        const steps: u16 = @as(u16, try b.read(u8, 8)) + 1;
        const bits = ilog(channels - 1);
        for (0..steps) |_| {
            const mag = try b.read(u8, bits);
            const ang = try b.read(u8, bits);
            if (mag == ang or mag >= channels or ang >= channels) return error.InvalidOgg;
        }
    }
    if (try b.read(u2, 2) != 0) return error.InvalidOgg;
    if (submaps > 1) {
        for (0..channels) |_| if (try b.read(u4, 4) >= submaps) return error.InvalidOgg;
    }
    for (0..submaps) |_| {
        _ = try b.read(u8, 8);
        if (try b.read(u8, 8) >= floors) return error.InvalidOgg;
        if (try b.read(u8, 8) >= residues) return error.InvalidOgg;
    }
}

/// 値を表すのに要るビット数(ilog(0) = 0、ilog(1) = 1、ilog(4) = 3)
pub fn ilog(v: u32) u6 {
    return @intCast(32 - @clz(v));
}

/// 音声パケットの先頭のバイトから、ブロックの長さを返す。音声パケットでなければ null
pub fn blockSize(first: u8, id: Identification, modes: Modes) ?u16 {
    if (first & 1 != 0) return null;
    const bits = modes.bits();
    const mode: u8 = if (bits == 0) 0 else @truncate((first >> 1) & ((@as(u8, 1) << @min(bits, 7)) - 1));
    if (bits > 7 or mode >= modes.count) return null;
    return id.blocksize[@intFromBool(modes.long[mode])];
}

/// 音声パケットの長さ(サンプル数)を順に数える。長さは、前のパケットのブロックの長さ / 4 + 今のパケットのブロックの長さ / 4
pub const Counter = struct {
    id: Identification,
    modes: Modes,
    /// 前の音声パケットのブロックの長さ。null はまだ音声パケットがない
    prev: ?u16 = null,

    /// 次のパケットの長さ。`first` はパケットの先頭のバイト(空のパケットは null)。
    /// 音声パケットでなければ null(前のブロックの長さは変えない)。最初の音声パケットは 0
    pub fn next(c: *Counter, first: ?u8) ?u64 {
        const bs = blockSize(first orelse return null, c.id, c.modes) orelse return null;
        defer c.prev = bs;
        return if (c.prev) |p| p / 4 + bs / 4 else 0;
    }
};

test Counter {
    const id: Identification = .{ .channels = 1, .sample_rate = 44100, .blocksize = .{ 256, 2048 } };
    var modes: Modes = .{ .count = 2, .long = @splat(false) };
    modes.long[1] = true;
    var c: Counter = .{ .id = id, .modes = modes };
    try std.testing.expectEqual(0, c.next(0b10).?); // 長いブロック(最初は 0)
    try std.testing.expectEqual(null, c.next(null)); // 空のパケット
    try std.testing.expectEqual(null, c.next(1)); // 音声パケットではない
    try std.testing.expectEqual(512 + 64, c.next(0b00).?); // 長い → 短い
    try std.testing.expectEqual(128, c.next(0b00).?); // 短い → 短い
}

test ilog {
    try std.testing.expectEqual(0, ilog(0));
    try std.testing.expectEqual(1, ilog(1));
    try std.testing.expectEqual(2, ilog(2));
    try std.testing.expectEqual(2, ilog(3));
    try std.testing.expectEqual(3, ilog(4));
}

test lookup1Values {
    try std.testing.expectEqual(9, lookup1Values(81, 2));
    try std.testing.expectEqual(3, lookup1Values(81, 4));
    try std.testing.expectEqual(2, lookup1Values(80, 4));
    try std.testing.expectEqual(1, lookup1Values(1, 8));
}
