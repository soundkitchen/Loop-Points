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
var values: [5]u64 = @splat(0);

/// JS に返しうるエラー。wasm/kiln.d.ts の KilnErrorCode と同じ一覧にする(足したら kiln.d.ts も直し、
/// wasm/types/ の型検査を通す。docs/architecture.md §2.3)。
/// fail はこの集合しか受け付けないので、export が新しいエラーを返しうるようになるとコンパイルが通らなくなる
pub const KilnError = error{
    NotMp3,
    NotWav,
    UnsupportedFormat,
    InvalidWav,
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
    values = .{ info.sample_rate, info.channels, info.samples, info.frames, info.min_start };
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
    values = .{ t.start, t.end, t.sample_rate, 0, 0 };
    return true;
}

/// WAV を解析する。成功すると kiln_value に
/// 0: サンプルレート、1: チャンネル数、2: サンプル形式(kiln.pcm.Format の番号)、3: サンプル数
/// を置く
export fn kiln_wav_probe(ptr: [*]const u8, len: usize) bool {
    const info = kiln.wav.probe(ptr[0..len]) catch |err| return fail(err);
    values = .{ info.sample_rate, info.channels, @backingInt(info.format), info.samples, 0 };
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
    values = .{ t.start, t.end, t.sample_rate, 0, 0 };
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

/// デコードした PCM をチャンネルごとに並べて書く sink(kiln.mp3.decode に渡す)
const PlanarSink = struct {
    out: []f32,
    channels: usize,
    frames: usize,
    pos: usize = 0,

    pub fn writeF32(s: *PlanarSink, samples: []const f32) !void {
        const n = samples.len / s.channels;
        for (0..n) |i| {
            for (0..s.channels) |ch| s.out[ch * s.frames + s.pos + i] = samples[i * s.channels + ch];
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
    values = .{ r.start, r.end, r.sample_rate, r.channels, r.invalid_frames };
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
    values = .{ r.start, r.end, r.sample_rate, r.channels, r.invalid_frames };
    return true;
}
