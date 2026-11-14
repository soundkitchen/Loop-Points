// SPDX-License-Identifier: MIT
//! PCM を Ogg Vorbis にエンコードする(設計と検証は docs/ogg.md §8)。
//!
//! 符号化は libvorbis(vendor/libvorbis。BSD-3-Clause)で行い、Ogg のページは kiln が作る(trim.zig の
//! `PageWriter`。切り出しと同じ並べ方)。libvorbis は src/c/vorbis_enc.c の薄い包み越しに呼ぶ。
const std = @import("std");
const Io = std.Io;
const libc = @import("../c/libc.zig");
const trim = @import("trim.zig");

const Handle = opaque {};
extern fn kiln_vorbis_open(out: *?*Handle, channels: c_int, rate: c_long, quality: f32) c_int;
extern fn kiln_vorbis_header(v: *const Handle, index: c_int, len: *usize) [*]const u8;
extern fn kiln_vorbis_buffer(v: *Handle, frames: c_int) [*][*]f32;
extern fn kiln_vorbis_wrote(v: *Handle, frames: c_int) c_int;
extern fn kiln_vorbis_packet(v: *Handle, data: *[*]const u8, len: *usize, granule: *c_longlong, last: *c_int) c_int;
extern fn kiln_vorbis_close(v: *Handle) void;

/// チャンネル数の上限。Vorbis の仕様がチャンネルの並びを決めているのは 8 までで、Chromium も 8 までしかデコードしない
pub const max_channels = 8;

/// 品質の範囲と既定(oggenc の -q と同じ目盛り。大きいほど音がよく、ファイルが大きい)
pub const min_quality: f32 = -1;
pub const max_quality: f32 = 10;
pub const default_quality: f32 = 5;

/// 既定のシリアル番号(ASCII の "KILN")。同じ入力から毎回同じ出力になるよう、乱数にしない
pub const default_serial: u32 = 0x4b494c4e;

pub const Options = struct {
    sample_rate: u32,
    /// 1〜8
    channels: u8,
    /// -1〜10(oggenc の -q と同じ)。ビットレートは音源によって変わる(可変ビットレート)
    quality: f32 = default_quality,
    /// Ogg のストリームのシリアル番号。ほかの Ogg とつなげる(連結する)ときだけ、重ならない値にする
    serial: u32 = default_serial,
};

pub const InitError = Io.Writer.Error || error{
    /// チャンネル数・サンプルレート・品質が範囲外か、libvorbis がその組み合わせに対応していない
    InvalidOptions,
    OutOfMemory,
    InternalError,
};
pub const WriteError = Io.Writer.Error || error{
    /// 書くサンプル数が、チャンネルごとに違う
    InvalidOptions,
    InternalError,
};

/// 入力のチャンネル(WAV や Web Audio の並び)を、Vorbis のチャンネルの並び(Vorbis I §4.3.9)に入れ替える表。
/// `order[n - 1][c]` は、n チャンネルのときに Vorbis の c 番目に置く、入力のチャンネル。
/// 入力は、3: 左・右・中央、5: 左・右・中央・後左・後右、6: 5.1(左・右・中央・LFE・後左・後右)、
/// 7: 6.1(左・右・中央・LFE・後中央・横左・横右)、8: 7.1(左・右・中央・LFE・後左・後右・横左・横右)。
/// Vorbis は、3: 左・中央・右、5: 左・中央・右・後左・後右、6: それに LFE、7: 左・中央・右・横左・横右・後中央・LFE、
/// 8: 左・中央・右・横左・横右・後左・後右・LFE。デコーダーは逆に入れ替えて、入力と同じ並びで返す
const order = [max_channels][max_channels]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, 2, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 0, 0, 0, 0 },
    .{ 0, 2, 1, 3, 4, 0, 0, 0 },
    .{ 0, 2, 1, 4, 5, 3, 0, 0 },
    .{ 0, 2, 1, 5, 6, 4, 3, 0 },
    .{ 0, 2, 1, 6, 7, 4, 5, 3 },
};

/// libvorbis に一度に渡すサンプル数(libvorbis の例や oggenc と同じ)。libvorbis は、ストリームの先頭の処理
/// (先頭より前を予測で埋める)に、そのときまでに渡された分をすべて使う。そのため、渡す区切りが変わると出力も変わり、
/// 大きな区切りではスタックに大きな領域を取る。呼び出し側の書き方に関係なく、いつもこの数ずつ渡す
const chunk = 1024;

/// ストリーミングのエンコーダー。`init` → `writePlanarF32` を何度でも → `finish` → `deinit`。
/// 出力は、`writePlanarF32` をどう分けて呼んでも同じになる。`w.flush()` は呼び出し側が行う
pub const Encoder = struct {
    /// libvorbis が確保する領域(libvorbis を呼ぶ間だけ使わせる)
    heap: libc.Heap,
    handle: *Handle,
    pw: trim.PageWriter,
    channels: u8,
    sample_rate: u32,
    /// libvorbis の入力のバッファに書いて、まだ渡していないサンプル数(`chunk` 未満)
    staged: usize = 0,
    /// 書いた音声パケットの数と、最後のもののグラニュール位置
    audio_packets: u64 = 0,
    granule: i64 = 0,
    finished: bool = false,

    pub fn init(gpa: std.mem.Allocator, w: *Io.Writer, options: Options) InitError!Encoder {
        if (options.channels == 0 or options.channels > max_channels) return error.InvalidOptions;
        // 範囲の外と NaN を除く
        if (!(options.quality >= min_quality and options.quality <= max_quality)) return error.InvalidOptions;
        const rate = std.math.cast(c_long, options.sample_rate) orelse return error.InvalidOptions;
        if (rate == 0) return error.InvalidOptions;

        var heap: libc.Heap = .init(gpa);
        errdefer heap.deinit();
        const binding = heap.bind();
        defer binding.release();
        var opened: ?*Handle = null;
        const status = kiln_vorbis_open(&opened, options.channels, rate, options.quality / 10);
        errdefer if (opened) |h| kiln_vorbis_close(h);
        switch (status) {
            0 => {},
            1 => return error.InvalidOptions,
            else => return error.InternalError,
        }
        const handle = opened.?;

        var pw: trim.PageWriter = try .init(gpa, w, options.serial);
        errdefer pw.deinit();
        // 識別ヘッダだけの最初のページと、コメント・設定のヘッダ(音声は新しいページから始める)
        for (0..3) |i| {
            var len: usize = 0;
            const p = kiln_vorbis_header(handle, @intCast(i), &len);
            try pw.packet(p[0..len], 0);
            if (i != 1) try pw.flush(false);
        }
        return .{ .heap = heap, .handle = handle, .pw = pw, .channels = options.channels, .sample_rate = options.sample_rate };
    }

    pub fn deinit(e: *Encoder) void {
        {
            const binding = e.heap.bind();
            defer binding.release();
            kiln_vorbis_close(e.handle);
        }
        e.heap.deinit();
        e.pw.deinit();
    }

    /// チャンネルごとの PCM を足す。チャンネルの並びは WAV や Web Audio と同じ(`order` の説明を参照)
    pub fn writePlanarF32(e: *Encoder, channels: []const []const f32) WriteError!void {
        std.debug.assert(!e.finished);
        if (channels.len != e.channels) return error.InvalidOptions;
        const frames = channels[0].len;
        for (channels) |c| if (c.len != frames) return error.InvalidOptions;

        const binding = e.heap.bind();
        defer binding.release();
        const map = order[e.channels - 1];
        var pos: usize = 0;
        while (pos < frames) {
            // 同じ位置のバッファが返る(前に書いた、まだ渡していない分は残っている)
            const buffers = kiln_vorbis_buffer(e.handle, chunk);
            const n = @min(chunk - e.staged, frames - pos);
            for (0..e.channels) |c| @memcpy(buffers[c][e.staged..][0..n], channels[map[c]][pos..][0..n]);
            e.staged += n;
            pos += n;
            if (e.staged == chunk) try e.commit();
        }
    }

    /// 入力の終わりを知らせ、残りのパケットと最後のページを書く
    pub fn finish(e: *Encoder) WriteError!void {
        std.debug.assert(!e.finished);
        e.finished = true;
        const binding = e.heap.bind();
        defer binding.release();
        if (e.staged > 0) try e.commit();
        if (kiln_vorbis_wrote(e.handle, 0) != 0) return error.InternalError;
        try e.drain();
        try e.pw.flush(true);
    }

    /// バッファに書いた分を libvorbis に渡し、できあがったパケットを書く
    fn commit(e: *Encoder) WriteError!void {
        if (kiln_vorbis_wrote(e.handle, @intCast(e.staged)) != 0) return error.InternalError;
        e.staged = 0;
        try e.drain();
    }

    /// できあがったパケットをページに詰める
    fn drain(e: *Encoder) WriteError!void {
        while (true) {
            var data: [*]const u8 = undefined;
            var len: usize = 0;
            var granule: c_longlong = 0;
            var last: c_int = 0;
            const r = kiln_vorbis_packet(e.handle, &data, &len, &granule, &last);
            if (r == 0) return;
            if (r < 0 or granule < e.granule) return error.InternalError;
            // 最初の音声パケット(何も出さない)は、それだけで 1 ページにする。短い音源で音声が 1 ページに収まると、
            // 末尾の切り詰めを Chromium と ffmpeg が守らないため(docs/ogg.md §7.1)。2 つ目を足す前にページを終える
            if (e.audio_packets == 1) try e.pw.flush(false);
            try e.pw.audioBytes(data[0..len], granule, @intCast(granule - e.granule), e.sample_rate);
            e.audio_packets += 1;
            e.granule = granule;
        }
    }
};

pub const EncodeOptions = struct {
    /// -1〜10(oggenc の -q と同じ)
    quality: f32 = default_quality,
    serial: u32 = default_serial,
};

pub const AllocError = error{ OutOfMemory, InvalidOptions, InternalError };

/// 一括版。チャンネルごとの PCM(どのチャンネルも同じ長さ。1 サンプル以上)を Ogg Vorbis にする。
/// 返したバイト列は呼び出し側が `gpa` で解放する
pub fn encodePlanarAlloc(gpa: std.mem.Allocator, channels: []const []const f32, sample_rate: u32, options: EncodeOptions) AllocError![]u8 {
    if (channels.len == 0 or channels.len > max_channels) return error.InvalidOptions;
    // 長さ 0 の Vorbis は、デコーダーによって扱いが違うので作らない
    if (channels[0].len == 0) return error.InvalidOptions;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    encodeTo(gpa, channels, sample_rate, options, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

fn encodeTo(gpa: std.mem.Allocator, channels: []const []const f32, sample_rate: u32, options: EncodeOptions, w: *Io.Writer) InitError!void {
    var enc: Encoder = try .init(gpa, w, .{
        .sample_rate = sample_rate,
        .channels = @intCast(channels.len),
        .quality = options.quality,
        .serial = options.serial,
    });
    defer enc.deinit();
    try enc.writePlanarF32(channels);
    try enc.finish();
}
