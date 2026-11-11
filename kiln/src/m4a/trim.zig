// SPDX-License-Identifier: MIT
//! m4a(AAC)の無劣化の切り出し(設計は docs/m4a.md §5)。
//!
//! 区間を含む AAC のフレーム(MP4 のサンプル)を、前の 2 フレームと後ろの 1 フレームと一緒にそのままコピーし、
//! 編集リスト(elst)と iTunes の `iTunSMPB` の両方で前後の余分を捨てさせる。後ろのフレームが入力の末尾で
//! 足りなければ、最後のフレームをもう一度置く。ボックスは作り直す
//! (ftyp、サンプルの説明(stsd)、ハンドラ、タグ、タイムスケールは元のまま)。出力は ftyp、moov、mdat の順。
//! タイムスケールを変えないのは、Apple のデコーダが編集リストを読まずに iTunSMPB だけを読み、HE-AAC では
//! その値を中心のレートの単位で読む一方、ffmpeg はメディアのタイムスケールの単位で読むため(docs/m4a.md §5.1)
const std = @import("std");
const Io = std.Io;
const box = @import("box.zig");

/// 区間の前に残すフレームの数。AAC はフレームの重ね合わせのため、前のフレームから復号しないと元と同じ値にならない
/// (AAC-LC は 1 つで足りる。HE-AAC は 1 つだと SBR の差が大きく残るので 2 つにする。それ以上増やしても差はほぼ変わらない)
pub const preroll_frames = 2;
/// 区間の後ろに残すフレームの数。区間の終わりのフレームで出力が終わると、短い区間(最後のフレームの中で
/// 終わる区間の先頭が、そのフレームの後ろのほうにあるとき)で Chromium がデコードに失敗し、ffmpeg は何も出さないため
pub const postroll_frames = 1;

pub const Error = error{ InvalidM4a, OutOfMemory } || Io.Writer.Error;

/// MP4 のサンプル(AAC のフレーム)
pub const Sample = struct {
    /// 入力の中の位置と大きさ
    offset: u64,
    size: u32,
    /// 長さ(メディアのタイムスケールの単位)
    duration: u32,
};

/// サンプルの表(stts、stsz、stsc、stco / co64)を合わせて読み、サンプルを順に返す。メモリは確保しない
pub const Samples = struct {
    stts: []const u8,
    stsz: []const u8,
    stsc: []const u8,
    stco: []const u8,
    co64: bool,
    count: u32,
    fixed_size: u32,
    stts_n: u32,
    stsc_n: u32,
    chunk_n: u32,

    i: u32 = 0,
    stts_i: u32 = 0,
    stts_left: u32 = 0,
    delta: u32 = 0,
    stsc_i: u32 = 0,
    chunk: u32 = 0,
    chunk_left: u32 = 0,
    pos: u64 = 0,

    /// `stbl` はサンプルの表のボックスの中身。stz2(圧縮したサンプルの大きさ)は扱わない(null)
    pub fn init(stbl: []const u8) box.Error!?Samples {
        const stts = try box.Iterator.find(stbl, "stts") orelse return error.InvalidM4a;
        const stsz = try box.Iterator.find(stbl, "stsz") orelse return null;
        const stsc = try box.Iterator.find(stbl, "stsc") orelse return error.InvalidM4a;
        var co64 = false;
        const stco = try box.Iterator.find(stbl, "stco") orelse blk: {
            co64 = true;
            break :blk try box.Iterator.find(stbl, "co64") orelse return error.InvalidM4a;
        };
        return .{
            .stts = stts.body,
            .stsz = stsz.body,
            .stsc = stsc.body,
            .stco = stco.body,
            .co64 = co64,
            .fixed_size = try box.int(u32, stsz.body, 4),
            .count = try box.int(u32, stsz.body, 8),
            .stts_n = try box.int(u32, stts.body, 4),
            .stsc_n = try box.int(u32, stsc.body, 4),
            .chunk_n = try box.int(u32, stco.body, 4),
        };
    }

    /// 次のサンプル。表が食い違えば(足りない、stsc が 1 番目のチャンクから始まらないなど)InvalidM4a
    pub fn next(s: *Samples) box.Error!?Sample {
        if (s.i == s.count) return null;
        while (s.stts_left == 0) {
            if (s.stts_i == s.stts_n) return error.InvalidM4a;
            s.stts_left = try box.int(u32, s.stts, 8 + @as(usize, s.stts_i) * 8);
            s.delta = try box.int(u32, s.stts, 12 + @as(usize, s.stts_i) * 8);
            s.stts_i += 1;
        }
        s.stts_left -= 1;
        const size = if (s.fixed_size != 0) s.fixed_size else try box.int(u32, s.stsz, 12 + @as(usize, s.i) * 4);
        while (s.chunk_left == 0) {
            if (s.chunk == s.chunk_n or s.stsc_n == 0) return error.InvalidM4a;
            // チャンクの番号(1 から)が、次の項目の最初のチャンクに届いたら次の項目へ
            while (s.stsc_i + 1 < s.stsc_n and try s.firstChunk(s.stsc_i + 1) <= s.chunk + 1) s.stsc_i += 1;
            if (try s.firstChunk(s.stsc_i) > s.chunk + 1) return error.InvalidM4a;
            s.chunk_left = try box.int(u32, s.stsc, 12 + @as(usize, s.stsc_i) * 12);
            s.pos = if (s.co64) try box.int(u64, s.stco, 8 + @as(usize, s.chunk) * 8) else try box.int(u32, s.stco, 8 + @as(usize, s.chunk) * 4);
            s.chunk += 1;
        }
        s.chunk_left -= 1;
        const offset = s.pos;
        s.pos = std.math.add(u64, s.pos, size) catch return error.InvalidM4a;
        s.i += 1;
        return .{ .offset = offset, .size = size, .duration = s.delta };
    }

    fn firstChunk(s: *const Samples, i: u32) box.Error!u32 {
        return box.int(u32, s.stsc, 8 + @as(usize, i) * 12);
    }
};

/// 切り出しに使う、元のファイルの部品
pub const Source = struct {
    input: []const u8,
    /// ftyp ボックス全体
    ftyp: []const u8,
    /// トラックの中身(mdia などを探す)
    trak: []const u8,
    /// サンプルの表のボックスの中身
    stbl: []const u8,
    /// moov の直下の udta(タグ)。なければ null
    udta: ?box.Box,
    /// メディアのタイムスケール(出力もこのまま使う)
    timescale: u32,
    /// 先頭の遅延(タイムスケールの単位)
    delay: u64,
};

/// 再生位置 `[start, end)`(メディアのタイムスケールの単位)を切り出して `w` に書く。範囲は呼び出し側が丸めておく
/// (`start < end`、`delay + end` がメディアの長さ以下)。サンプルのデータが入力の外を指していれば InvalidM4a
pub fn trim(gpa: std.mem.Allocator, src: Source, start: u64, end: u64, w: *Io.Writer) Error!void {
    const ms = std.math.add(u64, start, src.delay) catch return error.InvalidM4a;
    const me = std.math.add(u64, end, src.delay) catch return error.InvalidM4a;

    // 区間の先頭を含むサンプルと、区間の終わりより前に始まる最後のサンプル
    var first: u32 = 0;
    var last: u32 = 0;
    var count: u32 = 0;
    {
        var it = try Samples.init(src.stbl) orelse return error.InvalidM4a;
        var pos: u64 = 0;
        while (try it.next()) |smp| : (count += 1) {
            if (pos <= ms) first = count;
            if (pos < me) last = count;
            pos = std.math.add(u64, pos, smp.duration) catch return error.InvalidM4a;
        }
        if (pos < me) return error.InvalidM4a;
    }
    const k = first -| preroll_frames;
    const l = @min(last + postroll_frames, count - 1);
    // 後ろに残すフレームが足りない分は、最後のフレームを繰り返す(再生されない)
    const repeat = last + postroll_frames - l;

    // コピーするサンプル(繰り返す分も含む)と、その長さの表
    var copied: std.ArrayList(Sample) = .empty;
    defer copied.deinit(gpa);
    try copied.ensureTotalCapacity(gpa, l - k + 1 + repeat);
    var stts: std.ArrayList([2]u32) = .empty;
    defer stts.deinit(gpa);
    var k_start: u64 = 0;
    var media: u64 = 0;
    var payload: u64 = 0;
    {
        var it = (try Samples.init(src.stbl)).?;
        var i: u32 = 0;
        while (try it.next()) |smp| : (i += 1) {
            if (i < k) {
                k_start += smp.duration;
                continue;
            }
            if (i > l) break;
            if (smp.offset > src.input.len or smp.size > src.input.len - smp.offset) return error.InvalidM4a;
            const copies: u32 = if (i == l) 1 + repeat else 1;
            for (0..copies) |_| {
                if (stts.items.len > 0 and stts.items[stts.items.len - 1][1] == smp.duration) {
                    stts.items[stts.items.len - 1][0] += 1;
                } else {
                    try stts.append(gpa, .{ 1, smp.duration });
                }
                copied.appendAssumeCapacity(smp);
                media += smp.duration;
                payload += smp.size;
            }
        }
    }
    var m: Moov = .{ .seg = end - start, .media = media, .media_time = ms - k_start, .stts = stts.items, .samples = copied.items, .chunk_offset = 0 };

    // moov を組み立てる。チャンクは 1 つで、mdat の中身の位置は moov の長さで決まる。moov の長さは位置の値によらない
    // (位置は stco の 32 ビットで書く。moov が 4GB を超えることはないので co64 は使わない)
    var b: Builder = .{ .gpa = gpa };
    defer b.list.deinit(gpa);
    const mdat_header: u64 = if (payload + 8 > std.math.maxInt(u32)) 16 else 8;
    try writeMoov(&b, src, m);
    m.chunk_offset = std.math.cast(u32, src.ftyp.len + b.list.items.len + mdat_header) orelse return error.InvalidM4a;
    b.list.clearRetainingCapacity();
    try writeMoov(&b, src, m);

    try w.writeAll(src.ftyp);
    try w.writeAll(b.list.items);
    if (mdat_header == 16) {
        try w.writeInt(u32, 1, .big);
        try w.writeAll("mdat");
        try w.writeInt(u64, payload + 16, .big);
    } else {
        try w.writeInt(u32, @intCast(payload + 8), .big);
        try w.writeAll("mdat");
    }
    for (copied.items) |smp| {
        const at: usize = @intCast(smp.offset);
        try w.writeAll(src.input[at..][0..smp.size]);
    }
}

const Moov = struct {
    /// 再生する長さと、コピーしたサンプルの長さの合計(タイムスケールの単位)
    seg: u64,
    media: u64,
    /// 先頭で捨てる長さ(最初にコピーしたサンプルの先頭から、区間の先頭まで)
    media_time: u64,
    stts: []const [2]u32,
    samples: []const Sample,
    chunk_offset: u32,
};

fn writeMoov(b: *Builder, src: Source, m: Moov) Error!void {
    const moov = try b.begin("moov");
    const mvhd = try beginTimes(b, "mvhd", src.timescale, m.seg);
    // 再生速度、音量、予約、行列、予約、次のトラックの番号
    try b.int(u32, 0x00010000);
    try b.int(u16, 0x0100);
    try b.zeros(10);
    try b.matrix();
    try b.zeros(24);
    try b.int(u32, 2);
    b.end(mvhd);

    const trak = try b.begin("trak");
    {
        // tkhd(有効で、ムービーに含める)
        const v1 = m.seg > std.math.maxInt(u32);
        const tkhd = try b.begin("tkhd");
        try b.int(u32, (@as(u32, @intFromBool(v1)) << 24) | 3);
        if (v1) {
            try b.zeros(16);
            try b.int(u32, 1);
            try b.zeros(4);
            try b.int(u64, m.seg);
        } else {
            try b.zeros(8);
            try b.int(u32, 1);
            try b.zeros(4);
            try b.int(u32, @intCast(m.seg));
        }
        // 予約、レイヤー、代替グループ、音量、予約、行列、幅、高さ
        try b.zeros(8 + 2 + 2);
        try b.int(u16, 0x0100);
        try b.zeros(2);
        try b.matrix();
        try b.zeros(8);
        b.end(tkhd);

        // 編集リスト: 先頭の media_time を捨て、seg の長さだけ再生する
        const edts = try b.begin("edts");
        const elst = try b.begin("elst");
        const ev1 = m.seg > std.math.maxInt(u32) or m.media_time > std.math.maxInt(i32);
        try b.int(u32, @as(u32, @intFromBool(ev1)) << 24);
        try b.int(u32, 1);
        if (ev1) {
            try b.int(u64, m.seg);
            try b.int(u64, m.media_time);
        } else {
            try b.int(u32, @intCast(m.seg));
            try b.int(u32, @intCast(m.media_time));
        }
        try b.int(u16, 1);
        try b.int(u16, 0);
        b.end(elst);
        b.end(edts);

        const mdia = try b.begin("mdia");
        {
            const orig_mdhd = try box.findPath(src.trak, &.{ "mdia", "mdhd" }) orelse return error.InvalidM4a;
            const lang_at: usize = if (orig_mdhd.body.len > 0 and orig_mdhd.body[0] == 1) 32 else 20;
            const lang = try box.int(u16, orig_mdhd.body, lang_at);
            const mdhd = try beginTimes(b, "mdhd", src.timescale, m.media);
            try b.int(u16, lang);
            try b.int(u16, 0);
            b.end(mdhd);

            const hdlr = try box.findPath(src.trak, &.{ "mdia", "hdlr" }) orelse return error.InvalidM4a;
            try b.raw(hdlr.raw);

            const minf = try b.begin("minf");
            if (try box.findPath(src.trak, &.{ "mdia", "minf", "smhd" })) |smhd| {
                try b.raw(smhd.raw);
            } else {
                const smhd = try b.begin("smhd");
                try b.zeros(8);
                b.end(smhd);
            }
            if (try box.findPath(src.trak, &.{ "mdia", "minf", "dinf" })) |dinf| {
                try b.raw(dinf.raw);
            } else {
                // データはこのファイルの中にある(url の flags が 1)
                try b.raw("\x00\x00\x00\x24dinf\x00\x00\x00\x1cdref\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0curl \x00\x00\x00\x01");
            }
            const stbl = try b.begin("stbl");
            const stsd = try box.Iterator.find(src.stbl, "stsd") orelse return error.InvalidM4a;
            try b.raw(stsd.raw);
            const stts = try b.begin("stts");
            try b.int(u32, 0);
            try b.int(u32, @intCast(m.stts.len));
            for (m.stts) |e| {
                try b.int(u32, e[0]);
                try b.int(u32, e[1]);
            }
            b.end(stts);
            const stsc = try b.begin("stsc");
            try b.int(u32, 0);
            try b.int(u32, 1);
            try b.int(u32, 1);
            try b.int(u32, @intCast(m.samples.len));
            try b.int(u32, 1);
            b.end(stsc);
            const stsz = try b.begin("stsz");
            try b.int(u32, 0);
            try b.int(u32, 0);
            try b.int(u32, @intCast(m.samples.len));
            for (m.samples) |smp| try b.int(u32, smp.size);
            b.end(stsz);
            const stco = try b.begin("stco");
            try b.int(u32, 0);
            try b.int(u32, 1);
            try b.int(u32, m.chunk_offset);
            b.end(stco);
            b.end(stbl);
            b.end(minf);
        }
        b.end(mdia);
    }
    b.end(trak);

    try writeUdta(b, src.udta, m);
    b.end(moov);
}

/// mvhd / mdhd を始め、版・作成と更新の時刻・タイムスケール・長さまでを書く。続きは呼び出し側が書いて閉じる
fn beginTimes(b: *Builder, kind: *const [4]u8, rate: u32, duration: u64) Error!usize {
    const at = try b.begin(kind);
    const v1 = duration > std.math.maxInt(u32);
    try b.int(u32, @as(u32, @intFromBool(v1)) << 24);
    if (v1) {
        try b.zeros(16);
        try b.int(u32, rate);
        try b.int(u64, duration);
    } else {
        try b.zeros(8);
        try b.int(u32, rate);
        try b.int(u32, @intCast(duration));
    }
    return at;
}

/// moov の直下の udta を、iTunSMPB だけを書き直してコピーする。ほかのタグはそのまま残す。
/// なければ meta(ハンドラ mdir)と ilst を作る
fn writeUdta(b: *Builder, orig: ?box.Box, m: Moov) Error!void {
    const udta = try b.begin("udta");
    var wrote = false;
    if (orig) |u| {
        var it: box.Iterator = .{ .data = u.body };
        while (try it.next()) |child| {
            if (!child.is("meta") or wrote) {
                try b.raw(child.raw);
                continue;
            }
            // meta は ISO ではフルボックス、QuickTime ではただのボックス(中身が hdlr で始まる)
            const full = !(child.body.len >= 8 and std.mem.eql(u8, child.body[4..8], "hdlr"));
            const head: usize = if (full) 4 else 0;
            if (child.body.len < head) return error.InvalidM4a;
            const meta = try b.begin("meta");
            try b.raw(child.body[0..head]);
            var wrote_ilst = false;
            var mi: box.Iterator = .{ .data = child.body[head..] };
            while (try mi.next()) |mc| {
                if (!mc.is("ilst") or wrote_ilst) {
                    try b.raw(mc.raw);
                    continue;
                }
                const ilst = try b.begin("ilst");
                var ii: box.Iterator = .{ .data = mc.body };
                while (try ii.next()) |item| {
                    if (!isSmpb(item)) try b.raw(item.raw);
                }
                try writeSmpb(b, m);
                b.end(ilst);
                wrote_ilst = true;
            }
            if (!wrote_ilst) {
                const ilst = try b.begin("ilst");
                try writeSmpb(b, m);
                b.end(ilst);
            }
            b.end(meta);
            wrote = true;
        }
    }
    if (!wrote) {
        const meta = try b.begin("meta");
        try b.int(u32, 0);
        try b.raw("\x00\x00\x00\x21hdlr\x00\x00\x00\x00\x00\x00\x00\x00mdirappl\x00\x00\x00\x00\x00\x00\x00\x00\x00");
        const ilst = try b.begin("ilst");
        try writeSmpb(b, m);
        b.end(ilst);
        b.end(meta);
    }
    b.end(udta);
}

fn isSmpb(item: box.Box) bool {
    if (!item.is("----")) return false;
    const name = (box.Iterator.find(item.body, "name") catch return false) orelse return false;
    return name.body.len >= 4 and std.mem.eql(u8, name.body[4..], "iTunSMPB");
}

/// iTunSMPB: 遅延、末尾の詰め物、長さ(メディアのタイムスケールの単位、16 進)
fn writeSmpb(b: *Builder, m: Moov) Error!void {
    const item = try b.begin("----");
    try b.raw("\x00\x00\x00\x1cmean\x00\x00\x00\x00com.apple.iTunes");
    try b.raw("\x00\x00\x00\x14name\x00\x00\x00\x00iTunSMPB");
    const data = try b.begin("data");
    // 種類(1: UTF-8)とロケール
    try b.int(u32, 1);
    try b.int(u32, 0);
    var text: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&text, " 00000000 {X:0>8} {X:0>8} {X:0>16}", .{
        @as(u32, @truncate(m.media_time)),
        @as(u32, @truncate(m.media - m.media_time - m.seg)),
        m.seg,
    }) catch unreachable;
    try b.raw(s);
    for (0..8) |_| try b.raw(" 00000000");
    b.end(data);
    b.end(item);
}

/// ボックスを組み立てる(長さは閉じるときに書く)
const Builder = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn begin(b: *Builder, kind: *const [4]u8) error{OutOfMemory}!usize {
        const at = b.list.items.len;
        try b.list.appendSlice(b.gpa, "\x00\x00\x00\x00");
        try b.list.appendSlice(b.gpa, kind);
        return at;
    }

    fn end(b: *Builder, at: usize) void {
        std.mem.writeInt(u32, b.list.items[at..][0..4], @intCast(b.list.items.len - at), .big);
    }

    fn int(b: *Builder, comptime T: type, v: T) error{OutOfMemory}!void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .big);
        try b.list.appendSlice(b.gpa, &buf);
    }

    fn zeros(b: *Builder, n: usize) error{OutOfMemory}!void {
        try b.list.appendNTimes(b.gpa, 0, n);
    }

    fn raw(b: *Builder, bytes: []const u8) error{OutOfMemory}!void {
        try b.list.appendSlice(b.gpa, bytes);
    }

    /// 単位行列(16.16 と 2.30 の固定小数点)
    fn matrix(b: *Builder) error{OutOfMemory}!void {
        for ([_]u32{ 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 }) |v| try b.int(u32, v);
    }
};

test Samples {
    // stsc: 1〜2 番目のチャンクは 2 サンプル、3 番目からは 1 サンプル
    const stbl = "\x00\x00\x00\x20stts\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x04\x00\x00\x04\x00\x00\x00\x00\x01\x00\x00\x02\xa8" ++
        "\x00\x00\x00\x28stsz\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x0a\x00\x00\x00\x0b\x00\x00\x00\x0c\x00\x00\x00\x0d\x00\x00\x00\x0e" ++
        "\x00\x00\x00\x28stsc\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x00\x00\x00\x1cstco\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x64\x00\x00\x00\xc8\x00\x00\x01\x2c";
    var it = (try Samples.init(stbl)).?;
    const want = [_]Sample{
        .{ .offset = 100, .size = 10, .duration = 1024 },
        .{ .offset = 110, .size = 11, .duration = 1024 },
        .{ .offset = 200, .size = 12, .duration = 1024 },
        .{ .offset = 212, .size = 13, .duration = 1024 },
        .{ .offset = 300, .size = 14, .duration = 680 },
    };
    for (want) |w| try std.testing.expectEqual(w, (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}

test writeUdta {
    const gpa = std.testing.allocator;
    const m: Moov = .{ .seg = 100, .media = 3072, .media_time = 1500, .stts = &.{}, .samples = &.{}, .chunk_offset = 0 };
    // udta: chpl(ほかの子)と、meta(フルボックス)の中の hdlr、ilst(©nam と古い iTunSMPB)
    const name = "\x00\x00\x00\x19\xa9nam\x00\x00\x00\x11data\x00\x00\x00\x01\x00\x00\x00\x00a";
    const old = "\x00\x00\x00\x48----\x00\x00\x00\x1cmean\x00\x00\x00\x00com.apple.iTunes\x00\x00\x00\x14name\x00\x00\x00\x00iTunSMPB\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00";
    const hdlr = "\x00\x00\x00\x21hdlr\x00\x00\x00\x00\x00\x00\x00\x00mdirappl\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const ilst = "\x00\x00\x00\x69ilst" ++ name ++ old;
    const meta = "\x00\x00\x00\x96meta\x00\x00\x00\x00" ++ hdlr ++ ilst;
    const chpl = "\x00\x00\x00\x0cchpl\x00\x00\x00\x00";
    const udta_body = chpl ++ meta;
    var b: Builder = .{ .gpa = gpa };
    defer b.list.deinit(gpa);
    try writeUdta(&b, .{ .kind = "udta".*, .body = udta_body, .raw = udta_body }, m);
    const out = b.list.items;
    try std.testing.expect(std.mem.indexOf(u8, out, chpl) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, hdlr) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, old) == null);
    try std.testing.expectEqual(1, std.mem.count(u8, out, "iTunSMPB"));
    try std.testing.expect(std.mem.indexOf(u8, out, " 00000000 000005DC 000005C0 0000000000000064 00000000") != null);
    // 長さが合っていて、もう一度たどれる
    var it: box.Iterator = .{ .data = out };
    const u = (try it.next()).?;
    try std.testing.expect(u.is("udta"));
    try std.testing.expectEqual(out.len, u.raw.len);
    // udta がなければ meta と ilst を作る
    b.list.clearRetainingCapacity();
    try writeUdta(&b, null, m);
    try std.testing.expectEqual(1, std.mem.count(u8, b.list.items, "iTunSMPB"));
    try std.testing.expect(std.mem.indexOf(u8, b.list.items, "mdirappl") != null);
}
