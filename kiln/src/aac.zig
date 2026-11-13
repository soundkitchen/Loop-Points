// SPDX-License-Identifier: MIT
//! aac(ADTS のフレームを並べた AAC)の解析(設計は docs/aac.md)。
//!
//! フレームのヘッダだけを読む。音声データは読まないので、HE-AAC(SBR / PS)かどうかは分からない
//! (ADTS のヘッダには書けない。HE-AAC ならデコード結果のレートはヘッダの 2 倍、v2 なら 2 チャンネル)。
//! 切り出しは、フレームを m4a に入れ替えて行う(docs/aac.md §5)。
const std = @import("std");
const Io = std.Io;
const id3 = @import("mp3/id3.zig");
const m4a_trim = @import("m4a/trim.zig");

pub const ParseError = error{
    /// 先頭(ID3v2 タグがあればその後)が ADTS のフレームではない
    NotAac,
    /// チャンネル構成が 0(プログラム設定が音声データの中にある)など
    UnsupportedFormat,
};

pub const rates = [_]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };

/// ADTS のヘッダに書けるプロファイル(オブジェクトタイプ 1〜4)
pub const Profile = enum(u2) { main, lc, ssr, ltp };

pub const Info = struct {
    profile: Profile,
    /// ヘッダの MPEG の版(2 か 4)
    mpeg_version: u8,
    /// ヘッダのサンプルレート(HE-AAC ならデコード結果はこの 2 倍)
    sample_rate: u32,
    /// ヘッダのチャンネル数(HE-AAC v2 ならデコード結果は 2)
    channels: u8,
    /// フレームの数
    frames: u64,
    /// 長さ(ヘッダのサンプルレートのサンプル数。フレームあたり 1024)。先頭の遅延も含む
    samples: u64,
    /// `trim` で切り出せるか(どのフレームも raw_data_block が 1 つで、m4a の 1 サンプルにできるか)
    trimmable: bool,
    /// HE-AAC として(`sbr` を付けて)`trim` で切り出せるか。`trimmable` に加えて、出力のレート(ヘッダの 2 倍)を
    /// レートの表に書けること(ヘッダのレートが 48kHz 以下で、7350Hz でない)
    sbr_trimmable: bool,
};

const Header = struct {
    mpeg_version: u8,
    profile: Profile,
    rate_index: u4,
    channel_config: u3,
    /// ヘッダを含むフレームの長さ
    len: u13,
    /// フレームに入っている raw_data_block の数(1〜4)
    blocks: u3,
    /// ヘッダの長さ(CRC があれば 9、なければ 7)
    header_len: u4,

    fn parse(d: []const u8) ?Header {
        if (d.len < 7 or d[0] != 0xFF or d[1] & 0xF6 != 0xF0) return null;
        const h: Header = .{
            .mpeg_version = if (d[1] & 0x08 != 0) 2 else 4,
            .profile = @fromBackingInt(@intCast(d[2] >> 6)),
            .rate_index = @truncate(d[2] >> 2),
            .channel_config = @truncate((d[2] & 1) << 2 | d[3] >> 6),
            .len = @truncate(@as(u16, d[3] & 3) << 11 | @as(u16, d[4]) << 3 | d[5] >> 5),
            .blocks = @as(u3, @truncate(d[6] & 3)) + 1,
            .header_len = if (d[1] & 1 == 0) 9 else 7,
        };
        if (h.rate_index >= rates.len or h.len < h.header_len) return null;
        return h;
    }

    /// 同じストリームのフレームか(版・プロファイル・レート・チャンネル構成が同じ)
    fn sameStream(a: Header, b: Header) bool {
        return a.mpeg_version == b.mpeg_version and a.profile == b.profile and
            a.rate_index == b.rate_index and a.channel_config == b.channel_config;
    }
};

/// `pos` から始まる、`first` と同じストリームのフレーム。`lookahead` なら、次のフレームも続く
/// (か入力・タグが続く)ときだけ返す(最初のフレームと、ゴミの後で同期し直すときに偶然の一致を避ける)
fn frameAt(input: []const u8, pos: usize, first: ?Header, lookahead: bool) ?Header {
    const h = Header.parse(input[pos..]) orelse return null;
    if (first) |f| if (!f.sameStream(h)) return null;
    const end = pos + h.len;
    if (end > input.len) return null;
    if (end == input.len or !lookahead) return h;
    const next = Header.parse(input[end..]) orelse return if (isTag(input[end..])) h else null;
    return if (next.sameStream(h)) h else null;
}

/// 末尾に付くタグ(ID3v1、APEv2、ID3v2)
fn isTag(d: []const u8) bool {
    return std.mem.startsWith(u8, d, "TAG") or std.mem.startsWith(u8, d, "APETAGEX") or std.mem.startsWith(u8, d, "ID3");
}

/// 入力の末尾に付いたタグ(ID3v1、APEv2、フッタのある ID3v2)を取り除いた、音声の終わりの位置
fn audioEnd(input: []const u8, start: usize) usize {
    var end = input.len;
    while (end > start) {
        const d = input[start..end];
        if (d.len >= 128 and std.mem.startsWith(u8, d[d.len - 128 ..], "TAG")) {
            end -= 128;
        } else if (d.len >= 32 and std.mem.startsWith(u8, d[d.len - 32 ..], "APETAGEX")) {
            // APEv2 のフッタ: 大きさ(フッタを含み、ヘッダを含まない)と、ヘッダがあるかのフラグ(31 ビット目)
            const f = d[d.len - 32 ..];
            const size = std.mem.readInt(u32, f[12..16], .little);
            const total = @as(u64, size) + @as(u64, if (f[23] & 0x80 != 0) 32 else 0);
            if (size < 32 or total > d.len) break;
            end -= @intCast(total);
        } else if (d.len >= 10 and std.mem.startsWith(u8, d[d.len - 10 ..], "3DI")) {
            // ID3v2.4 のフッタ: ヘッダ・中身・フッタの全体を取り除く
            const total = 20 + @as(usize, id3.syncsafeDecode(d[d.len - 4 ..][0..4].*));
            if (total > d.len) break;
            end -= total;
        } else break;
    }
    return end;
}

/// フレームの中(ヘッダの後ろ)にタグの始まり(ID3v2 のヘッダか APEv2 のヘッダ)があるか。
/// 途切れたフレームの長さの欄が、後ろに付いたタグの中で終わっているのを見分ける
fn containsTag(d: []const u8) bool {
    if (std.mem.indexOf(u8, d, "APETAGEX") != null) return true;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, d, from, "ID3")) |i| : (from = i + 1) {
        const h = d[i..];
        if (h.len >= 10 and h[3] >= 2 and h[3] <= 4 and h[4] != 0xFF and
            h[6] & 0x80 == 0 and h[7] & 0x80 == 0 and h[8] & 0x80 == 0 and h[9] & 0x80 == 0) return true;
    }
    return false;
}

/// 先頭(ID3v2 タグがあればその後)が ADTS のフレームで、次のフレームも続くか(`kiln.detect` に使う)
pub fn hasSignature(input: []const u8) bool {
    return frameAt(input, id3.skipTags(input), null, true) != null;
}

/// フレームの位置とヘッダ
const Frame = struct { pos: usize, header: Header };

/// 最初のフレームと同じストリームのフレームを順にたどる。フレームの間のゴミは、同じストリームのフレームが
/// 続くところまで読み飛ばす。末尾のタグと、途切れた最後のフレームは返さない(解析と切り出しで同じ数え方をする)
const Frames = struct {
    /// 末尾のタグを除いた範囲
    audio: []const u8,
    first: Header,
    pos: usize,

    fn init(input: []const u8) ParseError!Frames {
        const pos = id3.skipTags(input);
        const first = frameAt(input, pos, null, true) orelse return error.NotAac;
        if (first.channel_config == 0) return error.UnsupportedFormat;
        // 末尾のタグを除いた範囲だけを読む(途切れた最後のフレームが、タグの中まで続いて見えないように)
        return .{ .audio = input[0..@max(pos, audioEnd(input, pos))], .first = first, .pos = pos };
    }

    fn next(f: *Frames) ?Frame {
        const audio = f.audio;
        while (f.pos < audio.len) {
            const pos = f.pos;
            if (frameAt(audio, pos, f.first, false)) |h| {
                // 次のフレームが続かず、中にタグの始まりがあれば、途切れたフレームの後ろにタグが付いている
                const end = pos + h.len;
                const next_ok = end == audio.len or if (Header.parse(audio[end..])) |n| n.sameStream(h) else false;
                if (!next_ok and containsTag(audio[pos + 7 .. end])) {
                    f.pos = audio.len;
                    return null;
                }
                f.pos = end;
                return .{ .pos = pos, .header = h };
            }
            if (isTag(audio[pos..])) {
                f.pos = audio.len;
                return null;
            }
            // ゴミか途切れたフレーム: 次の同期ワードを探す
            f.pos += 1;
            while (f.pos < audio.len and !(audio[f.pos] == 0xFF and frameAt(audio, f.pos, f.first, true) != null)) f.pos += 1;
        }
        return null;
    }
};

/// 入力全体を解析して、フレームの数と長さを返す。フレームの間のゴミは、同じストリームのフレームが
/// 続くところまで読み飛ばす。末尾のタグと、途切れた最後のフレームは数えない
pub fn probe(input: []const u8) ParseError!Info {
    var it = try Frames.init(input);
    var frames: u64 = 0;
    var samples: u64 = 0;
    var single = true;
    while (it.next()) |f| {
        frames += 1;
        samples += @as(u64, f.header.blocks) * 1024;
        single = single and f.header.blocks == 1;
    }
    const first = it.first;
    return .{
        .profile = first.profile,
        .mpeg_version = first.mpeg_version,
        .sample_rate = rates[first.rate_index],
        .channels = channelCount(first),
        .frames = frames,
        .samples = samples,
        .trimmable = single,
        .sbr_trimmable = single and sbrRateIndex(first) != null,
    };
}

/// HE-AAC の出力のレート(ヘッダの 2 倍)の、レートの表の番号。表になければ null
fn sbrRateIndex(h: Header) ?u4 {
    // 表の番号は 3 つ前(48kHz 以下で、7350Hz を除く)
    return if (h.rate_index >= 3 and h.rate_index <= 11) h.rate_index - 3 else null;
}

/// フレームの位置と長さ(ヘッダを含む)
pub const FrameSpan = struct { offset: usize, len: usize };

/// 先頭から `out.len` 個までのフレームの位置(解析と同じ数え方。ゴミは読み飛ばす)。WebCodecs の `AudioDecoder` に
/// フレームをそのまま渡して、実際のレートとチャンネル数を調べるのに使う(§3)
pub fn firstFrames(input: []const u8, out: []FrameSpan) ParseError![]FrameSpan {
    var it = try Frames.init(input);
    var n: usize = 0;
    while (n < out.len) : (n += 1) {
        const f = it.next() orelse break;
        out[n] = .{ .offset = f.pos, .len = f.header.len };
    }
    return out[0..n];
}

fn channelCount(h: Header) u8 {
    return if (h.channel_config == 7) 8 else h.channel_config;
}

// ---- 切り出し ----

pub const TrimOptions = struct {
    /// 切り出す区間の先頭(再生位置のサンプル数。デコード結果のサンプルレート。HE-AAC ならヘッダの 2 倍のレート)
    start: u64 = 0,
    /// 切り出す区間の終わり(この位置は含まない)。null なら末尾まで
    end: ?u64 = null,
    /// HE-AAC(SBR があり、デコード結果のレートがヘッダの 2 倍)か。ADTS のヘッダからは分からないので、呼び出し側が
    /// デコードして確かめる(ブラウザなら WebCodecs の AudioDecoder。docs/aac.md §3)。HE-AAC v2(PS)は扱えない
    sbr: bool = false,
};

/// 実際に切り出した区間(HE-AAC は 2 サンプル単位なので、`start` は指定以下、`end` は指定以上の偶数に寄せる)
pub const TrimResult = struct {
    start: u64,
    end: u64,
    /// デコード結果のサンプルレート
    sample_rate: u32,
};

pub const TrimError = ParseError || Io.Writer.Error || error{
    OutOfMemory,
    /// 丸めた後の区間が空(start >= end)
    EmptyRange,
};

/// 区間 `[options.start, options.end)` を、再エンコードせずに切り出して `w` に m4a で書く(ADTS には前後の余分を捨てる
/// 指定を書く場所がないため)。フレームのヘッダを外して m4a のサンプルにし、m4a の切り出し(`m4a.trim`)と同じく、
/// 前の 2 フレームと後ろの 1 フレームと一緒にコピーして、前後の余分を編集リストと iTunSMPB で捨てさせる。
/// タイムスケールはヘッダのレートなので、AAC-LC はサンプル単位、HE-AAC は 2 サンプル単位(docs/aac.md §5)。
/// 先頭の遅延はないものとする(ブラウザも ffmpeg も ADTS の先頭を捨てずにデコードする)。ID3 などのタグは書かない。
/// raw_data_block が 2 つ以上のフレームがあるもの(m4a の 1 サンプルにできない。`Info.trimmable` が false)と、HE-AAC で
/// 出力のレートを表に書けないもの(`Info.sbr_trimmable` が false)は UnsupportedFormat。モノラルの HE-AAC は、PS がない
/// ものとして書く(HE-AAC v2 は渡さないこと)。`w.flush()` は呼び出し側が行う
pub fn trim(gpa: std.mem.Allocator, input: []const u8, options: TrimOptions, w: *Io.Writer) TrimError!TrimResult {
    const frames = try Frames.init(input);
    const first = frames.first;
    // ビットレートの欄(esds)のために、フレームの大きさを数える
    var count: u64 = 0;
    var payload: u64 = 0;
    var max_size: u32 = 0;
    {
        var it = frames;
        while (it.next()) |f| {
            if (f.header.blocks != 1) return error.UnsupportedFormat;
            const size: u32 = f.header.len - f.header.header_len;
            count += 1;
            payload += size;
            max_size = @max(max_size, size);
        }
    }
    const scale: u32 = if (options.sbr) 2 else 1;
    const rate = rates[first.rate_index];
    const total = count * 1024 * scale;
    const end = @min(options.end orelse total, total);
    if (options.start >= end) return error.EmptyRange;
    // タイムスケールの単位に直す(先頭は切り捨て、終わりは切り上げ)
    const s = options.start / scale;
    const e = std.math.divCeil(u64, end, scale) catch unreachable;

    var stsd: m4a_trim.Builder = .{ .gpa = gpa };
    defer stsd.list.deinit(gpa);
    try writeStsd(&stsd, first, options.sbr, .{
        .buffer_size = max_size,
        .max_bitrate = bitrate(max_size, 1, rate),
        .avg_bitrate = bitrate(payload, count, rate),
    });
    const src: m4a_trim.Source = .{
        .input = input,
        .ftyp = m4a_ftyp,
        .language = und,
        .hdlr = sound_hdlr,
        .smhd = null,
        .dinf = null,
        .stsd = stsd.list.items,
        .udta = null,
        .timescale = rate,
        .delay = 0,
    };
    m4a_trim.trim(gpa, src, SampleFrames{ .frames = frames }, s, e, w) catch |err| switch (err) {
        // データは入力の中にあり、長さもあふれないので起きない
        error.InvalidM4a => return error.UnsupportedFormat,
        else => |x| return x,
    };
    return .{ .start = s * scale, .end = e * scale, .sample_rate = rate * scale };
}

pub const Trimmed = struct {
    data: []u8,
    start: u64,
    end: u64,
    sample_rate: u32,
};

/// `trim` の一括版。返した `data` は呼び出し側が `gpa` で解放する
pub fn trimAlloc(gpa: std.mem.Allocator, input: []const u8, options: TrimOptions) (ParseError || error{ OutOfMemory, EmptyRange })!Trimmed {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const r = trim(gpa, input, options, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return .{ .data = try out.toOwnedSlice(), .start = r.start, .end = r.end, .sample_rate = r.sample_rate };
}

/// ADTS のフレームを、m4a のサンプル(ヘッダを外した raw_data_block)として返す
const SampleFrames = struct {
    frames: Frames,

    pub fn next(f: *SampleFrames) error{}!?m4a_trim.Sample {
        const fr = f.frames.next() orelse return null;
        const h = fr.header;
        return .{ .offset = fr.pos + h.header_len, .size = h.len - h.header_len, .duration = 1024 };
    }
};

/// 出力の ftyp(afconvert の m4a と同じ)
const m4a_ftyp = "\x00\x00\x00\x1cftypM4A \x00\x00\x00\x00M4A mp42isom";
/// 言語が決まっていない(`und`)
const und: u16 = ('u' - 0x60) << 10 | ('n' - 0x60) << 5 | ('d' - 0x60);
/// 音声のハンドラ
const sound_hdlr = "\x00\x00\x00\x2dhdlr\x00\x00\x00\x00\x00\x00\x00\x00soun" ++ @as([12]u8, @splat(0)) ++ "SoundHandler\x00";

/// 秒あたりのビット数(フレームあたり 1024 サンプル)
fn bitrate(bytes: u64, frames: u64, rate: u32) u32 {
    if (frames == 0) return 0;
    return std.math.cast(u32, bytes * 8 * rate / (frames * 1024)) orelse std.math.maxInt(u32);
}

const Bitrates = struct { buffer_size: u32, max_bitrate: u32, avg_bitrate: u32 };

/// サンプルの説明(stsd)。mp4a と esds(ISO/IEC 14496-1 の ES_Descriptor)を、afconvert の m4a と同じ形で書く
fn writeStsd(b: *m4a_trim.Builder, h: Header, sbr: bool, br: Bitrates) TrimError!void {
    var asc_buf: [7]u8 = undefined;
    const asc = try audioSpecificConfig(&asc_buf, h, sbr);
    const rate = rates[h.rate_index];

    const stsd = try b.begin("stsd");
    try b.int(u32, 0);
    try b.int(u32, 1);
    const mp4a = try b.begin("mp4a");
    // 予約、データ参照の番号、予約(版など)、チャンネル数、サンプルの大きさ、予約、サンプルレート(16.16)
    try b.zeros(6);
    try b.int(u16, 1);
    try b.zeros(8);
    try b.int(u16, channelCount(h));
    try b.int(u16, 16);
    try b.zeros(4);
    try b.int(u32, if (rate <= std.math.maxInt(u16)) rate << 16 else 0);
    const esds = try b.begin("esds");
    try b.int(u32, 0);
    // ES_Descriptor(タグ 3): ES_ID とフラグ、DecoderConfigDescriptor(タグ 4)、SLConfigDescriptor(タグ 6)
    const dsi_len = 2 + asc.len;
    const dcd_len = 13 + dsi_len;
    try descriptorHeader(b, 3, 3 + 2 + dcd_len + 3);
    try b.int(u16, 0);
    try b.int(u8, 0);
    try descriptorHeader(b, 4, dcd_len);
    // オブジェクトタイプ(0x40: MPEG-4 Audio)、ストリームの種類(5: 音声)、バッファの大きさ、最大と平均のビットレート
    try b.int(u8, 0x40);
    try b.int(u8, 0x15);
    try b.int(u8, @truncate(br.buffer_size >> 16));
    try b.int(u16, @truncate(br.buffer_size));
    try b.int(u32, br.max_bitrate);
    try b.int(u32, br.avg_bitrate);
    // DecoderSpecificInfo(タグ 5): AudioSpecificConfig
    try descriptorHeader(b, 5, asc.len);
    try b.raw(asc);
    try descriptorHeader(b, 6, 1);
    try b.int(u8, 2);
    b.end(esds);
    b.end(mp4a);
    b.end(stsd);
}

fn descriptorHeader(b: *m4a_trim.Builder, tag: u8, len: usize) error{OutOfMemory}!void {
    try b.int(u8, tag);
    try b.int(u8, @intCast(len));
}

/// AudioSpecificConfig(ISO/IEC 14496-3 §1.6.2.1)。中心の方式(ヘッダのプロファイル、レート、チャンネル構成)の後ろに、
/// SBR の有無を明示する拡張(同期語 0x2B7、オブジェクトタイプ 5、sbrPresentFlag と、あれば出力のレート)を付ける。
/// SBR がないことも書くので、kiln の `m4a.probe` も含めて、デコーダが音声データを見ずにレートを決められる
/// (AAC-LC は ffmpeg、HE-AAC は afconvert の m4a と同じ形)。モノラルの HE-AAC には、PS がないこと(同期語 0x548 と
/// psPresentFlag)も付ける(書かないと、デコーダは PS があるかもしれないとして 2 チャンネルで出し、`m4a.probe` も PS が
/// 分からないとする)。PS のあるもの(HE-AAC v2)は扱わないので、PS があるとは書かない
fn audioSpecificConfig(buf: *[7]u8, h: Header, sbr: bool) error{UnsupportedFormat}![]const u8 {
    var bits: u64 = 0;
    bits = bits << 5 | (@as(u64, @intFromEnum(h.profile)) + 1);
    bits = bits << 4 | h.rate_index;
    bits = bits << 4 | h.channel_config;
    // GASpecificConfig: frameLengthFlag(1024)、dependsOnCoreCoder、extensionFlag
    bits = bits << 3;
    bits = bits << 11 | 0x2B7;
    bits = bits << 5 | 5;
    var n: u6 = 33;
    if (sbr) {
        bits = bits << 1 | 1;
        bits = bits << 4 | (sbrRateIndex(h) orelse return error.UnsupportedFormat);
        n += 4;
        if (h.channel_config == 1) {
            bits = bits << 11 | 0x548;
            bits = bits << 1;
            n += 12;
        }
    } else {
        bits = bits << 1;
    }
    const len = (@as(usize, n) + 7) / 8;
    bits <<= @intCast(len * 8 - n);
    for (0..len) |i| buf[i] = @truncate(bits >> @intCast((len - 1 - i) * 8));
    return buf[0..len];
}

const testdata = @import("testdata");

test "probe: ffmpeg と afconvert の AAC-LC" {
    const f = try probe(testdata.lc_ffmpeg_aac);
    try std.testing.expectEqual(Profile.lc, f.profile);
    try std.testing.expectEqual(44100, f.sample_rate);
    try std.testing.expectEqual(2, f.channels);
    try std.testing.expectEqual(23, f.frames);
    try std.testing.expectEqual(23 * 1024, f.samples);
    const a = try probe(testdata.lc_afconvert_aac);
    try std.testing.expectEqual(24, a.frames);
}

test "probe: HE-AAC はヘッダでは AAC-LC に見える" {
    const h = try probe(testdata.he_afconvert_aac);
    try std.testing.expectEqual(Profile.lc, h.profile);
    try std.testing.expectEqual(22050, h.sample_rate);
    try std.testing.expectEqual(2, h.channels);
}

test "probe: ゴミと途切れたフレーム" {
    const gpa = std.testing.allocator;
    const src = testdata.lc_ffmpeg_aac;
    const base = try probe(src);
    // 先頭に ID3v2、途中にゴミ、末尾に ID3v1 と途切れたフレーム
    const tag = "ID3\x03\x00\x00\x00\x00\x00\x00";
    // ゴミは 2 つ目のフレームの後に入れる(最初のフレームは、次のフレームが続くことで見分ける)
    const first_len = Header.parse(src).?.len;
    const two = first_len + Header.parse(src[first_len..]).?.len;
    const id3v1 = "TAG" ++ @as([125]u8, @splat('x'));
    const buf = try std.mem.concat(gpa, u8, &.{ tag, src[0..two], "junk\xFF\xF1", src[two..], src[0..20], id3v1 });
    defer gpa.free(buf);
    try std.testing.expectEqual(base.frames, (try probe(buf)).frames);
    try std.testing.expect(hasSignature(buf));
    try std.testing.expectError(error.NotAac, probe("junk"));

    // 途切れた最後のフレームの長さの欄が、末尾のタグの中で終わっていても数えない
    const cut = src[0 .. first_len - 50];
    const ape_footer = "APETAGEX" ++ "\xD0\x07\x00\x00" ++ "\x40\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ @as([8]u8, @splat(0));
    const ape = @as([32]u8, @splat('a')) ++ ape_footer;
    const id3v2 = "ID3\x03\x00\x00\x00\x00\x00\x40" ++ @as([64]u8, @splat(0));
    for ([_][]const u8{ id3v1, ape, id3v2 }) |tail| {
        const t = try std.mem.concat(gpa, u8, &.{ src, cut, tail });
        defer gpa.free(t);
        try std.testing.expectEqual(base.frames, (try probe(t)).frames);
    }
    try std.testing.expectError(error.NotAac, probe(testdata.cbr128_lame));
    try std.testing.expect(!hasSignature(testdata.cbr128_lame));
}

/// テスト用: 切り出して m4a として解析する
fn testTrim(gpa: std.mem.Allocator, input: []const u8, options: TrimOptions) !struct { r: TrimResult, data: []u8, info: m4a.Info } {
    const t = try trimAlloc(gpa, input, options);
    errdefer gpa.free(t.data);
    return .{ .r = .{ .start = t.start, .end = t.end, .sample_rate = t.sample_rate }, .data = t.data, .info = try m4a.probe(t.data) };
}

const m4a = @import("m4a.zig");

test "trim: AAC-LC をサンプル単位で m4a に切り出す" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ testdata.lc_ffmpeg_aac, testdata.lc_afconvert_aac }) |src| {
        const base = try probe(src);
        const n = base.samples;
        for ([_][2]u64{ .{ 0, n }, .{ 5000, 9000 }, .{ 0, 1 }, .{ 3000, 3001 }, .{ n - 10, n }, .{ n - 1, n }, .{ 777, n } }) |se| {
            const t = try testTrim(gpa, src, .{ .start = se[0], .end = se[1] });
            defer gpa.free(t.data);
            try std.testing.expectEqual(se[0], t.r.start);
            try std.testing.expectEqual(se[1], t.r.end);
            try std.testing.expectEqual(44100, t.r.sample_rate);
            // m4a として、SBR がないことが分かり、区間の長さで、切り出せる
            try std.testing.expectEqual(44100, t.info.sample_rate);
            try std.testing.expectEqual(2, t.info.channels);
            try std.testing.expectEqual(false, t.info.sbr);
            try std.testing.expectEqual(se[1] - se[0], t.info.samples);
            try std.testing.expect(t.info.trimmable);
            // 先頭の遅延は、最初にコピーしたフレーム(区間の先頭を含むフレームの 2 つ前)の先頭から区間の先頭まで
            const first = se[0] / 1024;
            try std.testing.expectEqual(se[0] - (first -| 2) * 1024, t.info.encoder_delay);
            // AudioSpecificConfig は ffmpeg の m4a と同じ形(SBR がないことを明示する)
            try std.testing.expectEqualSlices(u8, "\x12\x10\x56\xe5\x00", t.info.audio_specific_config);
        }
    }
    // 秒の端数のない区間を、もう一度 m4a として切り出せる
    const t = try testTrim(gpa, testdata.lc_ffmpeg_aac, .{ .start = 2000 });
    defer gpa.free(t.data);
    const again = try m4a.trimAlloc(gpa, t.data, .{ .start = 10, .end = 20 });
    defer gpa.free(again.data);
    try std.testing.expectEqual(10, (try m4a.probe(again.data)).samples);
}

test "trim: フレームは元のバイト列のまま(ヘッダを外す)" {
    const gpa = std.testing.allocator;
    const src = testdata.lc_ffmpeg_aac;
    const t = try testTrim(gpa, src, .{ .start = 0, .end = 1 });
    defer gpa.free(t.data);
    // 区間の先頭のフレームと、後ろの 1 フレーム
    var it = try Frames.init(src);
    for (0..2) |_| {
        const f = it.next().?;
        const payload = src[f.pos + f.header.header_len .. f.pos + f.header.len];
        try std.testing.expect(std.mem.indexOf(u8, t.data, payload) != null);
        try std.testing.expect(std.mem.indexOf(u8, t.data, src[f.pos..][0..7]) == null);
    }
    try std.testing.expect(it.next() != null);
}

test "trim: HE-AAC は出力のレートで 2 サンプル単位" {
    const gpa = std.testing.allocator;
    const src = testdata.he_afconvert_aac;
    const n = (try probe(src)).samples * 2;
    for ([_][4]u64{ .{ 5000, 15000, 5000, 15000 }, .{ 5001, 15001, 5000, 15002 }, .{ 0, n, 0, n }, .{ n - 1, n, n - 2, n } }) |c| {
        const t = try testTrim(gpa, src, .{ .start = c[0], .end = c[1], .sbr = true });
        defer gpa.free(t.data);
        try std.testing.expectEqual(c[2], t.r.start);
        try std.testing.expectEqual(c[3], t.r.end);
        try std.testing.expectEqual(44100, t.r.sample_rate);
        try std.testing.expectEqual(44100, t.info.sample_rate);
        try std.testing.expectEqual(true, t.info.sbr);
        try std.testing.expectEqual(c[3] - c[2], t.info.samples);
        try std.testing.expect(t.info.trimmable);
        // afconvert の HE-AAC の m4a と同じ形(タイムスケールとサンプルの説明のレートは中心のレート)
        try std.testing.expectEqualSlices(u8, "\x13\x90\x56\xe5\xa0", t.info.audio_specific_config);
    }
}

test "trim: 範囲外と、扱えない入力" {
    const gpa = std.testing.allocator;
    const src = testdata.lc_ffmpeg_aac;
    const n = (try probe(src)).samples;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.EmptyRange, trim(gpa, src, .{ .start = 10, .end = 10 }, &out.writer));
    try std.testing.expectError(error.EmptyRange, trim(gpa, src, .{ .start = n }, &out.writer));
    // 末尾を超える終わりは末尾に丸める
    const t = try trim(gpa, src, .{ .start = n - 5, .end = n + 100 }, &out.writer);
    try std.testing.expectEqual(n, t.end);
    try std.testing.expectError(error.NotAac, trim(gpa, testdata.cbr128_lame, .{}, &out.writer));

    // raw_data_block が 2 つのフレームがあるもの
    const two = try gpa.dupe(u8, src);
    defer gpa.free(two);
    two[6] |= 1;
    try std.testing.expect(!(try probe(two)).trimmable);
    try std.testing.expect((try probe(src)).trimmable);
    try std.testing.expectError(error.UnsupportedFormat, trim(gpa, two, .{}, &out.writer));

    // HE-AAC で、出力のレート(ヘッダの 2 倍)が表にないもの(ヘッダが 64kHz)
    const fast = try gpa.dupe(u8, src);
    defer gpa.free(fast);
    var it = try Frames.init(src);
    while (it.next()) |f| fast[f.pos + 2] = (fast[f.pos + 2] & 0xC3) | (2 << 2);
    try std.testing.expectEqual(64000, (try probe(fast)).sample_rate);
    try std.testing.expect((try probe(fast)).trimmable);
    try std.testing.expect(!(try probe(fast)).sbr_trimmable);
    try std.testing.expect((try probe(src)).sbr_trimmable);
    try std.testing.expectError(error.UnsupportedFormat, trim(gpa, fast, .{ .sbr = true }, &out.writer));
    _ = try trim(gpa, fast, .{}, &out.writer);
}

test "audioSpecificConfig: モノラルの HE-AAC には PS がないことも書く" {
    var buf: [7]u8 = undefined;
    const mono: Header = .{ .mpeg_version = 4, .profile = .lc, .rate_index = 7, .channel_config = 1, .len = 100, .blocks = 1, .header_len = 7 };
    const asc = try audioSpecificConfig(&buf, mono, true);
    const c = try @import("m4a/asc.zig").parse(asc);
    try std.testing.expectEqual(true, c.sbr);
    try std.testing.expectEqual(false, c.ps);
    try std.testing.expectEqual(44100, c.sbr_rate);
    // ステレオと AAC-LC には付けない(PS はモノラルにしかない)
    var stereo = mono;
    stereo.channel_config = 2;
    try std.testing.expectEqual(5, (try audioSpecificConfig(&buf, stereo, true)).len);
    try std.testing.expectEqual(5, (try audioSpecificConfig(&buf, mono, false)).len);
}

test firstFrames {
    const src = testdata.lc_ffmpeg_aac;
    var spans: [4]FrameSpan = undefined;
    const got = try firstFrames(src, &spans);
    try std.testing.expectEqual(4, got.len);
    var it = try Frames.init(src);
    for (got) |g| {
        const f = it.next().?;
        try std.testing.expectEqual(FrameSpan{ .offset = f.pos, .len = f.header.len }, g);
    }
    // フレームの数より多く求めても、あるだけ返す
    var many: [100]FrameSpan = undefined;
    try std.testing.expectEqual((try probe(src)).frames, (try firstFrames(src, &many)).len);
    try std.testing.expectError(error.NotAac, firstFrames("junk", &spans));
}
