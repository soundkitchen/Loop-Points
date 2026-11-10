// SPDX-License-Identifier: MIT
//! K!LN の wasm 向けエントリ。JS から呼ぶ export 関数だけを置き、処理はコアに任せる。
//! JS 側は kiln_alloc で確保した linear memory に入力を書き、ポインタと長さを渡す。
const std = @import("std");
const kiln = @import("kiln");

const gpa = std.heap.wasm_allocator;

/// linear memory に `len` バイトを確保する。失敗時は 0(null)を返す
export fn kiln_alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// kiln_alloc で確保した領域を解放する。kiln_alloc が失敗して返した 0(null)を
/// 渡されても何もしない(ReleaseSmall では安全チェックがないため、ここで弾く)
export fn kiln_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

/// linear memory に f32 を `count` 個ぶん確保する(4 バイト境界に揃う)。失敗時は 0(null)を返す
export fn kiln_alloc_f32(count: usize) ?[*]f32 {
    const buf = gpa.alloc(f32, count) catch return null;
    return buf.ptr;
}

/// kiln_alloc_f32 で確保した領域を解放する
export fn kiln_free_f32(ptr: ?[*]f32, count: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..count]);
}

/// バージョン文字列の先頭ポインタ(長さは kiln_version_len)
export fn kiln_version_ptr() [*]const u8 {
    return kiln.version.ptr;
}

export fn kiln_version_len() usize {
    return kiln.version.len;
}

// --- 結果の受け渡し ---
// export 関数は成功なら true を返し、結果を下の変数に置く。JS 側はアクセサで読み出す。
// 失敗なら false を返し、エラー名を kiln_error_ptr / kiln_error_len で読める。

var last_error: []const u8 = "";
var output: []u8 = &.{};
var values: [9]u64 = @splat(0);

/// kiln_value で読む数値を置く(足りない分は 0)
fn setValues(v: anytype) void {
    values = @splat(0);
    inline for (v, 0..) |x, i| values[i] = x;
}

/// JS に返しうるエラー。wasm/kiln.d.ts の KilnErrorCode と同じ一覧にする(足したら kiln.d.ts も直し、
/// wasm/types/ の型検査を通す。docs/architecture.md §2.3)。
/// fail はこの集合しか受け付けないので、export が新しいエラーを返しうるようになるとコンパイルが通らなくなる
pub const KilnError = error{
    NotMp3,
    NotWav,
    NotFlac,
    UnsupportedFormat,
    InvalidWav,
    InvalidFlac,
    NotOgg,
    InvalidOgg,
    NotM4a,
    InvalidM4a,
    NotAac,
    EmptyRange,
    TooLarge,
    OutOfMemory,
    InvalidOptions,
    /// kiln の不具合(起きるはずのない食い違い)
    InternalError,
};

fn fail(err: KilnError) bool {
    last_error = @errorName(err);
    return false;
}

/// 直前の失敗のエラー名(`NotMp3` など)の先頭ポインタ(長さは kiln_error_len)
export fn kiln_error_ptr() [*]const u8 {
    return last_error.ptr;
}

export fn kiln_error_len() usize {
    return last_error.len;
}

/// 直前の処理が返した数値。何番目に何が入るかは各関数の説明を参照
export fn kiln_value(i: u32) u64 {
    return if (i < values.len) values[i] else 0;
}

/// 直前の処理が出力したバイト列の先頭ポインタ(長さは kiln_output_len)。
/// 次の出力を作る前か、kiln_output_free を呼ぶまで有効
export fn kiln_output_ptr() [*]u8 {
    return output.ptr;
}

export fn kiln_output_len() usize {
    return output.len;
}

/// 出力のバイト列を解放する
export fn kiln_output_free() void {
    gpa.free(output);
    output = &.{};
}

/// MP3 を解析する。成功すると kiln_value に
/// 0: サンプルレート、1: チャンネル数、2: サンプル数、3: フレーム数、4: 指定できる先頭の最小値
/// を置く
export fn kiln_mp3_probe(ptr: [*]const u8, len: usize) bool {
    const info = kiln.mp3.probe(ptr[0..len]) catch |err| return fail(err);
    setValues(.{ info.sample_rate, info.channels, info.samples, info.frames, info.min_start });
    return true;
}

/// MP3 を区間 [start, end) でトリムする(位置はサンプル数。has_end が false なら末尾まで)。
/// 成功すると出力を kiln_output_* に、実際に切り出した区間を kiln_value の 0: start、1: end に、
/// 入力のサンプルレートを 2 に置く
export fn kiln_mp3_trim(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool) bool {
    kiln_output_free();
    const t = kiln.mp3.trimAlloc(gpa, ptr[0..len], .{
        .start = start,
        .end = if (has_end) end else null,
    }) catch |err| return fail(err);
    output = t.data;
    setValues(.{ t.start, t.end, t.sample_rate, 0, 0 });
    return true;
}

/// WAV を解析する。成功すると kiln_value に
/// 0: サンプルレート、1: チャンネル数、2: サンプル形式(kiln.pcm.Format の番号)、3: サンプル数
/// を置く
export fn kiln_wav_probe(ptr: [*]const u8, len: usize) bool {
    const info = kiln.wav.probe(ptr[0..len]) catch |err| return fail(err);
    setValues(.{ info.sample_rate, info.channels, @backingInt(info.format), info.samples, 0 });
    return true;
}

/// WAV を区間 [start, end) で切り出す(位置はサンプル数。has_end が false なら末尾まで)。
/// 成功すると出力を kiln_output_* に、実際に切り出した区間を kiln_value の 0: start、1: end に、
/// 入力のサンプルレートを 2 に置く
export fn kiln_wav_trim(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool) bool {
    kiln_output_free();
    const t = kiln.wav.trimAlloc(gpa, ptr[0..len], .{
        .start = start,
        .end = if (has_end) end else null,
    }) catch |err| return fail(err);
    output = t.data;
    setValues(.{ t.start, t.end, t.sample_rate, 0, 0 });
    return true;
}

/// チャンネルごとに並べた f32(`channels` 個のチャンネルが、それぞれ `frames` 個ずつ続く)を WAV にする。
/// format は kiln.pcm.Format の番号、dither は 0: なし、1: TPDF。成功すると出力を kiln_output_* に置く
export fn kiln_wav_encode(ptr: [*]const f32, channels: u32, frames: usize, sample_rate: u32, format: u32, dither: u32) bool {
    kiln_output_free();
    const fmt = std.enums.fromInt(kiln.pcm.Format, format) orelse return fail(error.InvalidOptions);
    if (dither > 1 or channels == 0) return fail(error.InvalidOptions);
    const slices = gpa.alloc([]const f32, channels) catch |err| return fail(err);
    defer gpa.free(slices);
    for (slices, 0..) |*c, i| c.* = ptr[i * frames ..][0..frames];
    output = kiln.wav.encodePlanarAlloc(gpa, slices, .{
        .sample_rate = sample_rate,
        .format = fmt,
        .dither = if (dither == 1) .tpdf else .none,
    }) catch |err| return fail(err);
    return true;
}

/// デコードした PCM をチャンネルごとの f32 に並べて書く sink。kiln.mp3.decode(f32)と
/// kiln.flac.decode(整数。`scale` を掛けて f32 にする)に渡す
const PlanarSink = struct {
    out: []f32,
    channels: usize,
    frames: usize,
    /// 整数を f32 にするときの倍率(2^-(bits - 1))
    scale: f64 = 1,
    pos: usize = 0,

    pub fn writeF32(s: *PlanarSink, samples: []const f32) !void {
        s.put(f32, samples);
    }

    pub fn writeI32(s: *PlanarSink, samples: []const i32) !void {
        s.put(i32, samples);
    }

    fn put(s: *PlanarSink, comptime T: type, samples: []const T) void {
        const n = samples.len / s.channels;
        for (0..n) |i| {
            for (0..s.channels) |ch| {
                const v = samples[i * s.channels + ch];
                s.out[ch * s.frames + s.pos + i] = if (T == f32) v else @floatCast(@as(f64, @floatFromInt(v)) * s.scale);
            }
        }
        s.pos += n;
    }
};

/// MP3 の区間 [start, end) をデコードする(位置はサンプル数。has_end が false なら末尾まで)。
/// 成功すると、チャンネルごとに並べた f32(チャンネル 0 の全サンプル、チャンネル 1 の全サンプル…)を
/// kiln_output_* に、kiln_value の 0: start、1: end、2: サンプルレート、3: チャンネル数、
/// 4: 復号できなかったフレームの数を置く
export fn kiln_mp3_decode(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool) bool {
    kiln_output_free();
    const input = ptr[0..len];
    const info = kiln.mp3.probe(input) catch |err| return fail(err);
    const e = @min(if (has_end) end else info.samples, info.samples);
    if (start >= e) return fail(error.EmptyRange);
    const frames: usize = std.math.cast(usize, e - start) orelse return fail(error.TooLarge);
    const count = std.math.mul(usize, frames, info.channels) catch return fail(error.TooLarge);
    const samples = gpa.alloc(f32, count) catch |err| return fail(err);
    var sink: PlanarSink = .{ .out = samples, .channels = info.channels, .frames = frames };
    const r = kiln.mp3.decode(input, .{ .start = start, .end = e }, &sink) catch |err| {
        gpa.free(samples);
        return fail(err);
    };
    output = std.mem.sliceAsBytes(samples);
    setValues(.{ r.start, r.end, r.sample_rate, r.channels, r.invalid_frames });
    return true;
}

/// MP3 の区間 [start, end) をデコードして WAV にする。format は kiln.pcm.Format の番号、
/// dither は 0: なし、1: TPDF。成功すると WAV を kiln_output_* に、kiln_value の 0: start、1: end、
/// 2: サンプルレート、3: チャンネル数、4: 復号できなかったフレームの数を置く(kiln_mp3_decode と同じ並び)
export fn kiln_mp3_to_wav(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool, format: u32, dither: u32) bool {
    kiln_output_free();
    const fmt = std.enums.fromInt(kiln.pcm.Format, format) orelse return fail(error.InvalidOptions);
    if (dither > 1) return fail(error.InvalidOptions);
    // 入力の解析は 1 回で、出力は前もって計算した大きさで一度に確保する
    const t = kiln.mp3.toWavAlloc(gpa, ptr[0..len], .{ .start = start, .end = if (has_end) end else null }, .{
        .format = fmt,
        .dither = if (dither == 1) .tpdf else .none,
    }) catch |err| return fail(err);
    output = t.data;
    const r = t.result;
    setValues(.{ r.start, r.end, r.sample_rate, r.channels, r.invalid_frames });
    return true;
}

/// FLAC を解析する。成功すると kiln_value に
/// 0: サンプルレート、1: チャンネル数、2: ビット深度、3: サンプル数、4: フレーム数
/// を置く
export fn kiln_flac_probe(ptr: [*]const u8, len: usize) bool {
    const info = kiln.flac.probe(ptr[0..len]) catch |err| return fail(err);
    setValues(.{ info.sample_rate, info.channels, info.bits_per_sample, info.samples, info.frames });
    return true;
}

/// FLAC のメタデータ(STREAMINFO)だけを読む。フレームは見ないので kiln_flac_probe より軽い
/// (JS が秒をサンプル位置に直すのに使う)。成功すると kiln_value に
/// 0: サンプルレート、1: チャンネル数、2: ビット深度を置く
export fn kiln_flac_format(ptr: [*]const u8, len: usize) bool {
    const f = kiln.flac.streamFormat(ptr[0..len]) catch |err| return fail(err);
    setValues(.{ f.sample_rate, f.channels, f.bits_per_sample, 0, 0 });
    return true;
}

/// FLAC の区間 [start, end) をデコードする(位置はサンプル数。has_end が false なら末尾まで)。
/// 成功すると、チャンネルごとに並べた f32(整数のサンプル / 2^(bits - 1))を kiln_output_* に、
/// kiln_value の 0: start、1: end、2: サンプルレート、3: チャンネル数、4: 復号できなかったフレームの数を置く
/// (kiln_mp3_decode と同じ並び)。入力の解析(フレームの区切りを探す走査)は 1 回
export fn kiln_flac_decode(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool) bool {
    kiln_output_free();
    var ix = kiln.flac.Index.init(gpa, ptr[0..len]) catch |err| return fail(err);
    defer ix.deinit(gpa);
    const info = ix.info();
    const e = @min(if (has_end) end else info.samples, info.samples);
    if (start >= e) return fail(error.EmptyRange);
    const frames: usize = std.math.cast(usize, e - start) orelse return fail(error.TooLarge);
    const count = std.math.mul(usize, frames, info.channels) catch return fail(error.TooLarge);
    const samples = gpa.alloc(f32, count) catch |err| return fail(err);
    var sink: PlanarSink = .{
        .out = samples,
        .channels = info.channels,
        .frames = frames,
        .scale = std.math.ldexp(@as(f64, 1), 1 - @as(i32, info.bits_per_sample)),
    };
    const r = ix.decode(gpa, .{ .start = start, .end = e }, &sink) catch |err| {
        gpa.free(samples);
        return fail(err);
    };
    output = std.mem.sliceAsBytes(samples);
    setValues(.{ r.start, r.end, r.sample_rate, r.channels, r.invalid_frames });
    return true;
}

/// FLAC の区間 [start, end) をデコードして WAV にする。format は kiln.pcm.Format の番号で、
/// has_format が false ならビット深度を保つ形式。dither は 0: なし、1: TPDF。
/// 成功すると WAV を kiln_output_* に、kiln_value に kiln_flac_decode と同じ値を置く
export fn kiln_flac_to_wav(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool, format: u32, has_format: bool, dither: u32) bool {
    kiln_output_free();
    const fmt: ?kiln.pcm.Format = if (has_format)
        std.enums.fromInt(kiln.pcm.Format, format) orelse return fail(error.InvalidOptions)
    else
        null;
    if (dither > 1) return fail(error.InvalidOptions);
    const t = kiln.flac.toWavAlloc(gpa, ptr[0..len], .{ .start = start, .end = if (has_end) end else null }, .{
        .format = fmt,
        .dither = if (dither == 1) .tpdf else .none,
    }) catch |err| return fail(err);
    output = t.data;
    const r = t.result;
    setValues(.{ r.start, r.end, r.sample_rate, r.channels, r.invalid_frames });
    return true;
}

/// FLAC の書き出しの指定を確かめる。compression は 0〜8、dither は 0: なし、1: TPDF
fn flacOptions(bits: ?u32, compression: u32, dither: u32) KilnError!kiln.flac.WriteOptions {
    if (compression > kiln.flac.max_compression or dither > 1) return error.InvalidOptions;
    if (bits) |b| if (b < 4 or b > 32) return error.InvalidOptions;
    return .{
        .bits_per_sample = if (bits) |b| @intCast(b) else null,
        .compression = @intCast(compression),
        .dither = if (dither == 1) .tpdf else .none,
    };
}

/// チャンネルごとに並べた f32(kiln_wav_encode と同じ並び)を FLAC にする。bits はビット深度(4〜32)。
/// 成功すると出力を kiln_output_* に置く
export fn kiln_flac_encode(ptr: [*]const f32, channels: u32, frames: usize, sample_rate: u32, bits: u32, compression: u32, dither: u32) bool {
    kiln_output_free();
    const o = flacOptions(bits, compression, dither) catch |err| return fail(err);
    if (channels == 0 or channels > 8) return fail(error.InvalidOptions);
    var slices: [8][]const f32 = undefined;
    for (slices[0..channels], 0..) |*c, i| c.* = ptr[i * frames ..][0..frames];
    output = kiln.flac.encodePlanarAlloc(gpa, slices[0..channels], sample_rate, o) catch |err| return fail(err);
    return true;
}

/// WAV の区間 [start, end) を FLAC にする(位置はサンプル数。has_end が false なら末尾まで)。
/// has_bits が false ならビット深度は既定(整数の WAV は元のビット深度、浮動小数点は 16)。
/// 成功すると出力を kiln_output_* に、kiln_value の 0: start、1: end、2: サンプルレートを置く(kiln_wav_trim と同じ)
export fn kiln_wav_to_flac(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool, bits: u32, has_bits: bool, compression: u32, dither: u32) bool {
    kiln_output_free();
    const o = flacOptions(if (has_bits) bits else null, compression, dither) catch |err| return fail(err);
    const t = kiln.wav.toFlacAlloc(gpa, ptr[0..len], .{ .start = start, .end = if (has_end) end else null }, o) catch |err| return fail(err);
    output = t.data;
    setValues(.{ t.start, t.end, t.sample_rate, 0, 0 });
    return true;
}

/// MP3 の区間 [start, end) をデコードして FLAC にする。bits はビット深度(4〜32)。
/// 成功すると出力を kiln_output_* に、kiln_value に kiln_mp3_decode と同じ値を置く
export fn kiln_mp3_to_flac(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool, bits: u32, compression: u32, dither: u32) bool {
    kiln_output_free();
    const o = flacOptions(bits, compression, dither) catch |err| return fail(err);
    const t = kiln.mp3.toFlacAlloc(gpa, ptr[0..len], .{ .start = start, .end = if (has_end) end else null }, o) catch |err| return fail(err);
    output = t.data;
    const r = t.result;
    setValues(.{ r.start, r.end, r.sample_rate, r.channels, r.invalid_frames });
    return true;
}

/// FLAC を区間 [start, end) で切り出す(位置はサンプル数。has_end が false なら末尾まで)。
/// 成功すると出力を kiln_output_* に、kiln_value の 0: start、1: end、2: サンプルレート、
/// 4: 壊れたフレーム(無音として作り直した)の数を置く(3 は 0)
export fn kiln_flac_trim(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool) bool {
    kiln_output_free();
    const t = kiln.flac.trimAlloc(gpa, ptr[0..len], .{ .start = start, .end = if (has_end) end else null }) catch |err| return fail(err);
    output = t.data;
    setValues(.{ t.start, t.end, t.sample_rate, 0, t.invalid_frames });
    return true;
}

/// Ogg(Vorbis / Opus)を解析する。成功すると kiln_value に
/// 0: サンプルレート、1: チャンネル数、2: サンプル数、3: コーデック(0: Vorbis、1: Opus)、
/// 4: エンコード前のサンプルレート(Opus。0 は不明)、5: pre-skip、6: 飛ばしたページの数を置く
export fn kiln_ogg_probe(ptr: [*]const u8, len: usize) bool {
    const i = kiln.ogg.probe(ptr[0..len]) catch |err| return fail(err);
    setValues(.{ i.sample_rate, i.channels, i.samples, @backingInt(i.codec), i.input_sample_rate, i.pre_skip, i.invalid_pages });
    return true;
}

/// m4a(AAC / ALAC)を解析する。成功すると AAC の AudioSpecificConfig を kiln_output_* に(ALAC は空)、
/// kiln_value に 0: サンプルレート、1: チャンネル数、2: サンプル数、3: コーデック(0: AAC、1: ALAC)、
/// 4: オブジェクトタイプ、5: SBR、6: PS(どちらも 0: なし、1: あり、2: 不明)、7: 先頭の遅延、
/// 8: ALAC のビット深度を置く
export fn kiln_m4a_probe(ptr: [*]const u8, len: usize) bool {
    kiln_output_free();
    const i = kiln.m4a.probe(ptr[0..len]) catch |err| return fail(err);
    output = gpa.dupe(u8, i.audio_specific_config) catch |err| return fail(err);
    setValues(.{ i.sample_rate, i.channels, i.samples, @backingInt(i.codec), i.object_type, tristate(i.sbr), tristate(i.ps), i.encoder_delay, i.bits_per_sample });
    return true;
}

fn tristate(v: ?bool) u64 {
    return if (v) |b| @intFromBool(b) else 2;
}

/// aac(ADTS)を解析する。成功すると kiln_value に 0: ヘッダのサンプルレート、1: ヘッダのチャンネル数、
/// 2: サンプル数、3: フレーム数、4: プロファイル(0: Main、1: LC、2: SSR、3: LTP)、5: MPEG の版(2 か 4)を置く
export fn kiln_aac_probe(ptr: [*]const u8, len: usize) bool {
    const i = kiln.aac.probe(ptr[0..len]) catch |err| return fail(err);
    setValues(.{ i.sample_rate, i.channels, i.samples, i.frames, @backingInt(i.profile), i.mpeg_version });
    return true;
}
