// SPDX-License-Identifier: MIT
//! 取り込んだ C のライブラリ(vendor/ の libvorbis と libogg)が使う libc の関数。kiln は libc を
//! リンクしないので、ライブラリが使うものだけを、Zig の標準ライブラリで用意する(設計は docs/ogg.md §8.2)。
//!
//! C からは `src/c/include/` のヘッダー越しに呼ぶ。どの環境の libc とも名前がぶつからないよう、
//! 実体は `kiln_c_` で始まる名前にしてある(ヘッダーのマクロが `malloc` などをこの名前に置き換える)。
//!
//! C のライブラリはアロケータを引数で受け取れない。そのため、ライブラリを呼ぶ側が `Heap` を作り、呼ぶ間だけ
//! `Heap.bind` で渡す。同時に 1 つしか渡せないので、複数のスレッドからは使えない(wasm は 1 スレッド)。
const std = @import("std");

var bound: ?*Heap = null;

/// C のライブラリが確保した領域の一覧。ライブラリが解放し忘れた領域も、`deinit` でまとめて解放する
/// (libvorbis 1.3.7 は、5.1 チャンネルの設定を作るときに 1 つ解放し忘れる。docs/ogg.md §8.2)
pub const Heap = struct {
    gpa: std.mem.Allocator,
    /// 確保している領域をつないだもの(新しいものが先頭)
    first: ?*Header = null,

    pub fn init(gpa: std.mem.Allocator) Heap {
        return .{ .gpa = gpa };
    }

    /// 残っている領域をすべて解放する
    pub fn deinit(h: *Heap) void {
        while (h.first) |hd| h.release(hd);
    }

    /// C のライブラリを呼ぶ間、このヒープから確保させる。返した値の `release` で元に戻す
    pub fn bind(h: *Heap) Binding {
        const b: Binding = .{ .previous = bound };
        bound = h;
        return b;
    }

    fn add(h: *Heap, hd: *Header) void {
        hd.prev = null;
        hd.next = h.first;
        if (h.first) |f| f.prev = hd;
        h.first = hd;
    }

    fn remove(h: *Heap, hd: *Header) void {
        if (hd.prev) |p| p.next = hd.next else h.first = hd.next;
        if (hd.next) |n| n.prev = hd.prev;
    }

    fn release(h: *Heap, hd: *Header) void {
        h.remove(hd);
        h.gpa.free(hd.block());
    }
};

pub const Binding = struct {
    previous: ?*Heap,

    pub fn release(b: Binding) void {
        bound = b.previous;
    }
};

/// 確保した領域の前に置く。`free` と `realloc` は大きさを受け取らないので、ここに持つ
const Header = extern struct {
    /// 呼び出し側が求めた大きさ(ヘッダを含まない)
    size: usize,
    prev: ?*Header,
    next: ?*Header,

    fn block(hd: *Header) []align(alignment) u8 {
        return @as([*]align(alignment) u8, @ptrCast(@alignCast(hd)))[0 .. header_len + hd.size];
    }

    fn user(hd: *Header) *anyopaque {
        return @ptrFromInt(@intFromPtr(hd) + header_len);
    }

    fn of(ptr: *anyopaque) *Header {
        return @ptrFromInt(@intFromPtr(ptr) - header_len);
    }
};

/// 返す領域は 16 バイト境界にそろえる
const alignment = 16;
const header_len = std.mem.alignForward(usize, @sizeOf(Header), alignment);

// C から見える名前(`kiln_c_malloc` など)で出す。wasm の export(JS から見える関数)には入れない
comptime {
    for (.{
        .{ &malloc, "malloc" },
        .{ &calloc, "calloc" },
        .{ &free, "free" },
        .{ &realloc, "realloc" },
        .{ &exit, "exit" },
        .{ &qsort, "qsort" },
        .{ &acos, "acos" },
        .{ &atan, "atan" },
        .{ &cos, "cos" },
        .{ &exp, "exp" },
        .{ &ldexp, "ldexp" },
        .{ &log, "log" },
        .{ &pow, "pow" },
        .{ &sin, "sin" },
        .{ &rint, "rint" },
    }) |entry| @export(entry[0], .{ .name = "kiln_c_" ++ entry[1], .visibility = .hidden });
}

/// 確保できなかったとき。libvorbis は確保の失敗を確かめずに使うので、null を返すと、壊れたまま動き続ける。
/// 続けられないので止める(wasm では trap。使う側は、そのインスタンスを使い続けない)
fn outOfMemory() noreturn {
    @trap();
}

fn malloc(size: usize) callconv(.c) *anyopaque {
    const h = bound.?;
    const total = std.math.add(usize, size, header_len) catch outOfMemory();
    const mem = h.gpa.alignedAlloc(u8, .fromByteUnits(alignment), total) catch outOfMemory();
    const hd: *Header = @ptrCast(mem.ptr);
    hd.size = size;
    h.add(hd);
    return hd.user();
}

fn calloc(count: usize, each: usize) callconv(.c) *anyopaque {
    const size = std.math.mul(usize, count, each) catch outOfMemory();
    const ptr = malloc(size);
    @memset(@as([*]u8, @ptrCast(ptr))[0..size], 0);
    return ptr;
}

fn free(ptr: ?*anyopaque) callconv(.c) void {
    bound.?.release(Header.of(ptr orelse return));
}

fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) *anyopaque {
    const h = bound.?;
    const old = Header.of(ptr orelse return malloc(size));
    const total = std.math.add(usize, size, header_len) catch outOfMemory();
    // 場所が変わることがあるので、一覧から外してから伸ばし、つなぎ直す
    h.remove(old);
    const mem = h.gpa.realloc(old.block(), total) catch outOfMemory();
    const hd: *Header = @ptrCast(mem.ptr);
    hd.size = size;
    h.add(hd);
    return hd.user();
}

/// libvorbis が、起きるはずのない状態(符号表の不整合)で呼ぶ。続けられないので止める
fn exit(_: c_int) callconv(.c) noreturn {
    @trap();
}

const Compare = *const fn (*const anyopaque, *const anyopaque) callconv(.c) c_int;

const SortContext = struct {
    items: [*]u8,
    each: usize,
    compare: Compare,

    pub fn lessThan(c: SortContext, a: usize, b: usize) bool {
        return c.compare(c.items + a * c.each, c.items + b * c.each) < 0;
    }

    pub fn swap(c: SortContext, a: usize, b: usize) void {
        const x = c.items[a * c.each ..][0..c.each];
        const y = c.items[b * c.each ..][0..c.each];
        for (x, y) |*p, *q| std.mem.swap(u8, p, q);
    }
};

/// C の qsort と同じく、等しい要素の並びは決まっていない(ヒープソート)
fn qsort(items: [*]u8, count: usize, each: usize, compare: Compare) callconv(.c) void {
    std.sort.heapContext(0, count, SortContext{ .items = items, .each = each, .compare = compare });
}

fn acos(x: f64) callconv(.c) f64 {
    return std.math.acos(x);
}

fn atan(x: f64) callconv(.c) f64 {
    return std.math.atan(x);
}

fn cos(x: f64) callconv(.c) f64 {
    return @cos(x);
}

fn exp(x: f64) callconv(.c) f64 {
    return @exp(x);
}

fn ldexp(x: f64, n: c_int) callconv(.c) f64 {
    return std.math.ldexp(x, n);
}

fn log(x: f64) callconv(.c) f64 {
    return @log(x);
}

fn pow(x: f64, y: f64) callconv(.c) f64 {
    return std.math.pow(f64, x, y);
}

fn sin(x: f64) callconv(.c) f64 {
    return @sin(x);
}

/// 最も近い整数に丸める。ちょうど半分のときは偶数にする(C の rint の、既定の丸め方)
fn rint(x: f64) callconv(.c) f64 {
    // 2^52 以上の f64 は整数しか表せないので、足してから引くと、小数部が今の丸め方(最も近い偶数)で落ちる
    const big = 4503599627370496.0;
    if (!(@abs(x) < big)) return x;
    const r = if (std.math.signbit(x)) (x - big) + big else (x + big) - big;
    // -0.3 などが +0 にならないよう、符号を戻す
    return std.math.copysign(r, x);
}

test rint {
    try std.testing.expectEqual(2.0, rint(2.5));
    try std.testing.expectEqual(4.0, rint(3.5));
    try std.testing.expectEqual(-2.0, rint(-2.5));
    try std.testing.expectEqual(1.0, rint(0.6));
    try std.testing.expectEqual(-1.0, rint(-0.6));
    try std.testing.expectEqual(0.0, rint(0.4));
    try std.testing.expect(std.math.signbit(rint(-0.3)));
    try std.testing.expectEqual(1e300, rint(1e300));
    try std.testing.expect(std.math.isNan(rint(std.math.nan(f64))));
}

test "malloc / realloc / free は、渡したヒープのアロケータで確保して解放する" {
    var heap: Heap = .init(std.testing.allocator);
    defer heap.deinit();
    const b = heap.bind();
    defer b.release();
    const p: [*]u8 = @ptrCast(malloc(10));
    for (0..10) |i| p[i] = @intCast(i);
    const q: [*]u8 = @ptrCast(realloc(p, 100_000));
    for (0..10) |i| try std.testing.expectEqual(i, q[i]);
    try std.testing.expectEqual(0, @intFromPtr(q) % alignment);
    free(q);
    const z: [*]u8 = @ptrCast(calloc(3, 7));
    for (0..21) |i| try std.testing.expectEqual(0, z[i]);
    free(z);
    free(null);
    try std.testing.expectEqual(null, heap.first);
}

test "Heap.deinit は、解放し忘れた領域も解放する" {
    var heap: Heap = .init(std.testing.allocator);
    const b = heap.bind();
    const a = malloc(100);
    _ = malloc(200);
    const c = malloc(300);
    _ = realloc(a, 5000);
    free(c);
    b.release();
    // 残った 2 つは、ここで解放される(解放されなければ、テスト用のアロケータが漏れを報告する)
    heap.deinit();
    try std.testing.expectEqual(null, heap.first);
}

fn compareInt(a: *const anyopaque, b: *const anyopaque) callconv(.c) c_int {
    const x = @as(*const c_int, @ptrCast(@alignCast(a))).*;
    const y = @as(*const c_int, @ptrCast(@alignCast(b))).*;
    return if (x < y) -1 else if (x > y) 1 else 0;
}

test qsort {
    var v = [_]c_int{ 5, -1, 9, 0, 3, 3, -7 };
    qsort(@ptrCast(&v), v.len, @sizeOf(c_int), compareInt);
    try std.testing.expectEqualSlices(c_int, &.{ -7, -1, 0, 3, 3, 5, 9 }, &v);
}
