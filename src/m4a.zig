// SPDX-License-Identifier: MIT
//! m4a(MP4 コンテナの AAC / ALAC)の解析(設計は docs/m4a.md)。
//!
//! 最初の音声トラックを見る。長さは、編集リスト(elst)か iTunes の `iTunSMPB` で先頭の遅延と末尾の詰め物を
//! 除いたもの。音声データ(mdat)は読まない。
const std = @import("std");
const box = @import("m4a/box.zig");
const asc = @import("m4a/asc.zig");

pub const ParseError = error{
    /// 先頭が MP4 の `ftyp` ボックスではない
    NotM4a,
    /// ボックスの長さが壊れている、`moov` がない、サンプルの表が食い違う、など
    InvalidM4a,
    /// AAC / ALAC 以外の中身、音声トラックがない、断片化した MP4(fragmented MP4)など
    UnsupportedFormat,
};

pub const Codec = enum { aac, alac };

pub const Info = struct {
    codec: Codec,
    /// AAC の中心の方式のオブジェクトタイプ(1: Main、2: LC、3: SSR、4: LTP など。SBR / PS は含めない)。ALAC は 0
    object_type: u8,
    /// SBR があるか(true なら HE-AAC)。設定やタイムスケールから分からなければ null。ALAC は false
    sbr: ?bool,
    /// PS があるか(true なら HE-AAC v2)。分からなければ null。ALAC は false
    ps: ?bool,
    /// デコード結果のサンプルレート(HE-AAC は SBR の後のレート)
    sample_rate: u32,
    /// デコード結果のチャンネル数(HE-AAC v2 は PS の後の 2)
    channels: u8,
    /// ALAC のビット深度(AAC は 0)
    bits_per_sample: u8,
    /// 再生される長さ(`sample_rate` のサンプル数)。先頭の遅延と末尾の詰め物を除いたもの
    samples: u64,
    /// 先頭で捨てる遅延(`sample_rate` のサンプル数)。編集リストか iTunSMPB から読む。なければ 0
    encoder_delay: u64,
    /// AAC の AudioSpecificConfig(入力の一部。WebCodecs の `description` などに使える)。ALAC は空
    audio_specific_config: []const u8,
};

/// 先頭が `ftyp` ボックスか(`kiln.detect` に使う)
pub fn hasSignature(input: []const u8) bool {
    if (input.len < 8 or !std.mem.eql(u8, input[4..8], "ftyp")) return false;
    const size = std.mem.readInt(u32, input[0..4], .big);
    return size >= 8;
}

pub fn probe(input: []const u8) ParseError!Info {
    if (!hasSignature(input)) return error.NotM4a;
    const moov = try findMoov(input);
    var movie_timescale: u32 = 0;
    var track: ?box.Box = null;
    var udta: ?box.Box = null;
    var it: box.Iterator = .{ .data = moov.body };
    while (try it.next()) |b| {
        if (b.is("mvhd")) {
            movie_timescale = try box.int(u32, b.body, if (b.body.len > 0 and b.body[0] == 1) 20 else 12);
        } else if (b.is("mvex")) {
            return error.UnsupportedFormat;
        } else if (b.is("udta")) {
            udta = b;
        } else if (b.is("trak") and track == null) {
            const hdlr = try box.findPath(b.body, &.{ "mdia", "hdlr" }) orelse continue;
            if (std.mem.eql(u8, (try slice(hdlr.body, 8, 4)), "soun")) track = b;
        }
    }
    const trak = track orelse return error.UnsupportedFormat;

    const mdhd = try box.findPath(trak.body, &.{ "mdia", "mdhd" }) orelse return error.InvalidM4a;
    const v1 = mdhd.body.len > 0 and mdhd.body[0] == 1;
    const timescale = try box.int(u32, mdhd.body, if (v1) 20 else 12);
    if (timescale == 0) return error.InvalidM4a;
    const stbl = try box.findPath(trak.body, &.{ "mdia", "minf", "stbl" }) orelse return error.InvalidM4a;

    var info = try sampleEntry(stbl.body, timescale);

    // メディアの長さ(タイムスケールの単位)。stts の合計と、stsz のサンプル数が合うことも確かめる
    const media = try mediaDuration(stbl.body);

    // 先頭の遅延と再生する長さ(タイムスケールの単位)
    var delay: u64 = 0;
    var length: u64 = media;
    if (try box.findPath(trak.body, &.{ "edts", "elst" })) |elst| {
        if (movie_timescale == 0) return error.InvalidM4a;
        const e = try editList(elst.body, movie_timescale, timescale, media);
        delay = e.delay;
        length = e.length;
    } else if (try iTunSMPB(udta, trak)) |s| {
        // 長さが書かれ、メディアに収まるときだけ使う
        if (s.samples > 0 and s.delay + s.samples <= media) {
            delay = s.delay;
            length = s.samples;
        }
    }
    info.samples = rescale(length, timescale, info.sample_rate);
    info.encoder_delay = rescale(delay, timescale, info.sample_rate);
    return info;
}

/// 最上位のボックスから `moov` を探す。`moof` があれば断片化した MP4。
/// 最後のボックス(多くは `mdat`)が途切れていても、`moov` を読めていれば構わない
fn findMoov(input: []const u8) ParseError!box.Box {
    var it: box.Iterator = .{ .data = input };
    var moov: ?box.Box = null;
    while (true) {
        const b = it.next() catch break orelse break;
        if (b.is("moov")) {
            if (moov != null) return error.InvalidM4a;
            moov = b;
        } else if (b.is("moof")) {
            return error.UnsupportedFormat;
        }
    }
    return moov orelse error.InvalidM4a;
}

fn slice(data: []const u8, at: usize, len: usize) box.Error![]const u8 {
    if (data.len < at or data.len - at < len) return error.InvalidM4a;
    return data[at..][0..len];
}

/// stsd の最初の項目(音声のサンプルエントリ)から、コーデックとサンプルレートなどを読む
fn sampleEntry(stbl: []const u8, timescale: u32) ParseError!Info {
    const stsd = try box.Iterator.find(stbl, "stsd") orelse return error.InvalidM4a;
    if (try box.int(u32, stsd.body, 4) == 0) return error.InvalidM4a;
    var entries: box.Iterator = .{ .data = stsd.body[8..] };
    const entry = try entries.next() orelse return error.InvalidM4a;
    // AudioSampleEntry: 予約(6)、データ参照(2)、版(2)、改訂(2)、ベンダー(4)、チャンネル数(2)、
    // サンプルのビット数(2)、圧縮 ID(2)、パケットの大きさ(2)、サンプルレート(16.16 の固定小数点、4)
    const version = try box.int(u16, entry.body, 8);
    const channels = try box.int(u16, entry.body, 16);
    const rate = try box.int(u32, entry.body, 24) >> 16;
    const children_at: usize = switch (version) {
        0 => 28,
        // QuickTime の版 1 は 16 バイト多い。版 2 は形が違うので扱わない
        1 => 44,
        else => return error.UnsupportedFormat,
    };
    const children = try slice(entry.body, children_at, entry.body.len - @min(entry.body.len, children_at));

    if (entry.is("alac")) {
        const cfg = try box.Iterator.find(children, "alac") orelse return error.InvalidM4a;
        // ALACSpecificConfig(フルボックスの 4 バイトの後): frameLength(4)、compatibleVersion(1)、bitDepth(1)、
        // pb / mb / kb(3)、numChannels(1)、maxRun(2)、maxFrameBytes(4)、avgBitRate(4)、sampleRate(4)
        const c = try slice(cfg.body, 4, 24);
        const ch = c[9];
        const r = std.mem.readInt(u32, c[20..24], .big);
        if (ch == 0 or r == 0 or c[5] == 0) return error.InvalidM4a;
        return .{
            .codec = .alac,
            .object_type = 0,
            .sbr = false,
            .ps = false,
            .sample_rate = r,
            .channels = ch,
            .bits_per_sample = c[5],
            .samples = 0,
            .encoder_delay = 0,
            .audio_specific_config = &.{},
        };
    }
    if (!entry.is("mp4a")) return error.UnsupportedFormat;

    // esds は直下か、QuickTime の `wave` の中にある
    const esds = try box.Iterator.find(children, "esds") orelse blk: {
        const wave = try box.Iterator.find(children, "wave") orelse return error.InvalidM4a;
        break :blk try box.Iterator.find(wave.body, "esds") orelse return error.InvalidM4a;
    };
    const config = try decoderConfig(esds.body);
    const c = try asc.parse(config);

    // 設定に SBR の印がないとき: 中心のレートが 24kHz を超えるなら SBR はない(HE-AAC の中心は 24kHz まで)。
    // タイムスケールかサンプルエントリのレートが中心の 2 倍なら SBR がある。どちらでもなければ分からない
    var sbr = c.sbr;
    var sbr_rate = c.sbr_rate;
    if (sbr == null) {
        if (c.core_rate > 24000) {
            sbr = false;
        } else if (timescale == 2 * c.core_rate or rate == 2 * c.core_rate) {
            sbr = true;
            sbr_rate = 2 * c.core_rate;
        }
    }
    var ps = c.ps;
    if (sbr == false) ps = false;
    const out_rate = if (sbr == true) sbr_rate orelse 2 * c.core_rate else c.core_rate;
    var out_channels: u8 = if (ps == true) 2 else c.channels;
    if (out_channels == 0) out_channels = std.math.cast(u8, channels) orelse return error.InvalidM4a;
    return .{
        .codec = .aac,
        .object_type = c.object_type,
        .sbr = sbr,
        .ps = ps,
        .sample_rate = out_rate,
        .channels = out_channels,
        .bits_per_sample = 0,
        .samples = 0,
        .encoder_delay = 0,
        .audio_specific_config = config,
    };
}

/// esds の記述子をたどり、DecoderSpecificInfo(AudioSpecificConfig)を返す
fn decoderConfig(esds: []const u8) ParseError![]const u8 {
    var d = try slice(esds, 4, esds.len - @min(esds.len, 4));
    // ES_Descriptor
    var es = try descriptor(&d, 0x03);
    _ = try slice(es, 0, 3);
    const flags = es[2];
    var at: usize = 3;
    if (flags & 0x80 != 0) at += 2;
    if (flags & 0x40 != 0) at += 1 + (try slice(es, at, 1))[0];
    if (flags & 0x20 != 0) at += 2;
    es = try slice(es, at, es.len - @min(es.len, at));
    // DecoderConfigDescriptor
    var dc = try descriptor(&es, 0x04);
    const oti = (try slice(dc, 0, 1))[0];
    switch (oti) {
        // MPEG-4 Audio と、MPEG-2 AAC(Main / LC / SSR)
        0x40, 0x66, 0x67, 0x68 => {},
        // MP3 など
        else => return error.UnsupportedFormat,
    }
    dc = try slice(dc, 13, dc.len - @min(dc.len, 13));
    return descriptor(&dc, 0x05);
}

/// `d` の先頭の記述子が `tag` なら中身を返し、`d` をその後ろへ進める
fn descriptor(d: *[]const u8, tag: u8) ParseError![]const u8 {
    if (d.len < 2 or d.*[0] != tag) return error.InvalidM4a;
    var len: usize = 0;
    var i: usize = 1;
    while (true) : (i += 1) {
        if (i >= d.len or i > 4) return error.InvalidM4a;
        const b = d.*[i];
        len = (len << 7) | (b & 0x7F);
        if (b & 0x80 == 0) break;
    }
    i += 1;
    if (d.len - i < len) return error.InvalidM4a;
    const body = d.*[i..][0..len];
    d.* = d.*[i + len ..];
    return body;
}

/// stts の合計(タイムスケールの単位)。stsz のサンプル数と合わなければ InvalidM4a
fn mediaDuration(stbl: []const u8) ParseError!u64 {
    const stts = try box.Iterator.find(stbl, "stts") orelse return error.InvalidM4a;
    const n = try box.int(u32, stts.body, 4);
    if ((stts.body.len - 8) / 8 < n) return error.InvalidM4a;
    var total: u64 = 0;
    var count: u64 = 0;
    for (0..n) |i| {
        const c = try box.int(u32, stts.body, 8 + i * 8);
        const delta = try box.int(u32, stts.body, 12 + i * 8);
        count += c;
        total += @as(u64, c) * delta;
    }
    if (try box.Iterator.find(stbl, "stsz")) |stsz| {
        if (try box.int(u32, stsz.body, 8) != count) return error.InvalidM4a;
    } else if (try box.Iterator.find(stbl, "stz2")) |stz2| {
        if (try box.int(u32, stz2.body, 8) != count) return error.InvalidM4a;
    } else return error.InvalidM4a;
    return total;
}

const Edit = struct { delay: u64, length: u64 };

/// 編集リストから、先頭の遅延と再生する長さ(メディアのタイムスケールの単位)を求める。
/// 空の編集(media_time = -1。無音を挟む)も長さに含める。遅延は最初の空でない編集の開始位置
fn editList(elst: []const u8, movie_ts: u32, media_ts: u32, media: u64) ParseError!Edit {
    const v1 = elst.len > 0 and elst[0] == 1;
    const n = try box.int(u32, elst, 4);
    const entry_len: usize = if (v1) 20 else 12;
    if ((elst.len - @min(elst.len, 8)) / entry_len < n) return error.InvalidM4a;
    var r: Edit = .{ .delay = 0, .length = 0 };
    var seen_media = false;
    for (0..n) |i| {
        const at = 8 + i * entry_len;
        const dur: u64 = if (v1) try box.int(u64, elst, at) else try box.int(u32, elst, at);
        const time: i64 = if (v1) try box.int(i64, elst, at + 8) else try box.int(i32, elst, at + 4);
        if (time < -1) return error.InvalidM4a;
        var d = rescale(dur, movie_ts, media_ts);
        if (time >= 0) {
            const t: u64 = @intCast(time);
            // 長さ 0 の編集は「メディアの最後まで」
            if (dur == 0) d = media -| t;
            if (!seen_media) r.delay = t;
            seen_media = true;
        }
        r.length += d;
    }
    if (!seen_media) return .{ .delay = 0, .length = media };
    return r;
}

const Smpb = struct { delay: u64, samples: u64 };

/// iTunes の `iTunSMPB`(moov か trak の udta / meta / ilst / `----`)の遅延と長さ
fn iTunSMPB(moov_udta: ?box.Box, trak: box.Box) ParseError!?Smpb {
    const trak_udta = try box.Iterator.find(trak.body, "udta");
    for ([_]?box.Box{ moov_udta, trak_udta }) |u| {
        const ud = u orelse continue;
        const meta = try box.Iterator.find(ud.body, "meta") orelse continue;
        // meta は ISO ではフルボックス(4 バイトの版と flags が先にある)、QuickTime ではただのボックス
        const body = if (meta.body.len >= 8 and std.mem.eql(u8, meta.body[4..8], "hdlr")) meta.body else try slice(meta.body, 4, meta.body.len - @min(meta.body.len, 4));
        const ilst = try box.Iterator.find(body, "ilst") orelse continue;
        var items: box.Iterator = .{ .data = ilst.body };
        while (try items.next()) |item| {
            if (!item.is("----")) continue;
            const name = try box.Iterator.find(item.body, "name") orelse continue;
            if (!std.mem.eql(u8, try slice(name.body, 4, name.body.len - @min(name.body.len, 4)), "iTunSMPB")) continue;
            const data = try box.Iterator.find(item.body, "data") orelse continue;
            return parseSmpb(try slice(data.body, 8, data.body.len - @min(data.body.len, 8)));
        }
    }
    return null;
}

/// " 00000000 00000840 0000019E 0000000000005622 ..." の 2 番目(遅延)と 4 番目(長さ)を読む
fn parseSmpb(text: []const u8) ?Smpb {
    var it = std.mem.tokenizeAny(u8, text, " \x00");
    var fields: [4]u64 = undefined;
    for (&fields) |*f| {
        const t = it.next() orelse return null;
        f.* = std.fmt.parseInt(u64, t, 16) catch return null;
    }
    return .{ .delay = fields[1], .samples = fields[3] };
}

/// タイムスケール `from` の値を `to` の単位に直す(切り捨て)
fn rescale(v: u64, from: u32, to: u32) u64 {
    if (from == to) return v;
    const r = @as(u128, v) * to / from;
    return std.math.cast(u64, r) orelse std.math.maxInt(u64);
}

test {
    _ = box;
    _ = asc;
}

const testdata = @import("testdata");

test "probe: AAC-LC(ffmpeg、編集リスト)" {
    const i = try probe(testdata.aac_lc_ffmpeg_m4a);
    try std.testing.expectEqual(Codec.aac, i.codec);
    try std.testing.expectEqual(2, i.object_type);
    try std.testing.expectEqual(false, i.sbr.?);
    try std.testing.expectEqual(false, i.ps.?);
    try std.testing.expectEqual(44100, i.sample_rate);
    try std.testing.expectEqual(2, i.channels);
    try std.testing.expectEqual(22050, i.samples);
    try std.testing.expectEqual(1024, i.encoder_delay);
    try std.testing.expectEqualSlices(u8, "\x12\x10\x56\xe5\x00", i.audio_specific_config);
}

test "probe: AAC-LC(afconvert、iTunSMPB)" {
    const i = try probe(testdata.aac_lc_afconvert_m4a);
    try std.testing.expectEqual(false, i.sbr.?);
    try std.testing.expectEqual(44100, i.sample_rate);
    try std.testing.expectEqual(22050, i.samples);
    try std.testing.expectEqual(2112, i.encoder_delay);
}

test "probe: HE-AAC と HE-AAC v2(afconvert)" {
    const he = try probe(testdata.aac_he_afconvert_m4a);
    try std.testing.expectEqual(true, he.sbr.?);
    try std.testing.expectEqual(false, he.ps.?);
    try std.testing.expectEqual(44100, he.sample_rate);
    try std.testing.expectEqual(2, he.channels);
    // iTunSMPB はタイムスケール(中心の 22.05kHz)の単位なので、出力のレートに直す
    try std.testing.expectEqual(22050, he.samples);
    try std.testing.expectEqual(4224, he.encoder_delay);
    const v2 = try probe(testdata.aac_hev2_afconvert_m4a);
    try std.testing.expectEqual(true, v2.sbr.?);
    try std.testing.expectEqual(true, v2.ps.?);
    try std.testing.expectEqual(44100, v2.sample_rate);
    try std.testing.expectEqual(2, v2.channels);
    try std.testing.expectEqual(22050, v2.samples);
}

test "probe: ALAC" {
    const i = try probe(testdata.alac_afconvert_m4a);
    try std.testing.expectEqual(Codec.alac, i.codec);
    try std.testing.expectEqual(16, i.bits_per_sample);
    try std.testing.expectEqual(44100, i.sample_rate);
    try std.testing.expectEqual(2, i.channels);
    try std.testing.expectEqual(11025, i.samples);
    try std.testing.expectEqual(0, i.encoder_delay);
}

test "probe: エラー" {
    try std.testing.expectError(error.NotM4a, probe("RIFF\x00\x00\x00\x00WAVE"));
    try std.testing.expectError(error.InvalidM4a, probe("\x00\x00\x00\x08ftyp"));
    // moov の中の長さを壊す
    const gpa = std.testing.allocator;
    const buf = try gpa.dupe(u8, testdata.aac_lc_ffmpeg_m4a);
    defer gpa.free(buf);
    const at = std.mem.indexOf(u8, buf, "stts").? - 4;
    std.mem.writeInt(u32, buf[at..][0..4], 0xFFFF, .big);
    try std.testing.expectError(error.InvalidM4a, probe(buf));
}

test rescale {
    try std.testing.expectEqual(22050, rescale(11025, 22050, 44100));
    try std.testing.expectEqual(1, rescale(1, 3, 3));
}

test parseSmpb {
    const s = parseSmpb(" 00000000 00000840 0000019E 0000000000005622 00000000").?;
    try std.testing.expectEqual(2112, s.delay);
    try std.testing.expectEqual(22050, s.samples);
    try std.testing.expectEqual(null, parseSmpb(" 0000 zz"));
}
