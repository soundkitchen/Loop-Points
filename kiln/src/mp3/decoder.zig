// SPDX-License-Identifier: MIT
//! MPEG-1 Layer III のデコーダ。音声フレームを先頭から順に渡すと、1 フレーム(1152 サンプル)ずつ PCM を返す。
//!
//! ビットリザーバの扱いは ffmpeg に合わせている(docs/mp3-decoder.md):
//! - main_data_begin が残っているリザーバより大きいときは、データが足りないグラニュールを無音にする
//! - フレームを読み終えた位置より後のバイト(最大 512 バイト)を、次のフレームのリザーバとして残す
const std = @import("std");
const frame = @import("frame.zig");
const Header = frame.Header;
const Reader = @import("bits.zig").Reader;
const layer3 = @import("layer3.zig");
const synth = @import("synth.zig");

/// ビットリザーバとして残す最大のバイト数(main_data_begin は最大 511)
const max_reservoir = 512;

pub const Error = layer3.Error;

pub const Decoder = struct {
    reservoir: [max_reservoir]u8 = undefined,
    reservoir_len: usize = 0,
    overlap: [2][32][18]f64 = @splat(@splat(@splat(0))),
    synth: [2]synth.Synth = .{ .{}, .{} },
    /// グラニュール 0 のスケールファクタ(scfsi でグラニュール 1 が使い回す)
    scalefactors: [2]layer3.Scalefactors = .{ .{}, .{} },

    /// 1 フレーム(ヘッダから始まるフレーム。`bytes` はフレーム長以上あればよい)を復号し、
    /// PCM を `out[チャンネル]` に書く。戻り値はチャンネル数。
    ///
    /// 復号できないフレームは `InvalidFrame` を返す:
    /// - MPEG-1 Layer III のヘッダでない、またはフレームが途中で切れている: `out` に無音を書き、状態は変えない
    /// - サイド情報が壊れている: スペクトルを 0 として IMDCT と合成フィルタを進め(前のフレームの
    ///   重ね合わせの残りが出る)、`out` に書く。ビットリザーバには ffmpeg と同じくフレームの末尾を持ち越す
    pub fn decodeFrame(d: *Decoder, bytes: []const u8, out: *[2][1152]f32) Error!u8 {
        const h = Header.parse(bytes) orelse {
            for (out) |*o| @memset(o, 0);
            return error.InvalidFrame;
        };
        const nch = h.channels();
        const len = h.frameLen();
        const side_start: usize = 4 + @as(usize, if (h.hasCrc()) 2 else 0);
        if (bytes.len < len or len < side_start + layer3.sideInfoLen(nch)) {
            for (out) |*o| @memset(o, 0);
            return error.InvalidFrame;
        }
        const fr = bytes[0..len];
        const sr: usize = h.sampleRateIndex();
        var sr_reader: Reader = .{ .data = fr[side_start..] };
        const si = layer3.readSideInfo(&sr_reader, nch) catch |err| {
            // 状態を進める(重ね合わせの残りを出し、次のフレームでクリックが出ないように)
            for (0..2) |gr| {
                for (0..nch) |ch| d.synthesize(ch, gr, &@as([576]f64, @splat(0)), 0, false, out);
            }
            d.keepTail(fr);
            return err;
        };
        const main = fr[side_start + layer3.sideInfoLen(nch) ..];

        // リザーバと、このフレームのメインデータを続けて読む
        var buf: [max_reservoir + frame.max_frame_len]u8 = undefined;
        @memcpy(buf[0..d.reservoir_len], d.reservoir[0..d.reservoir_len]);
        @memcpy(buf[d.reservoir_len..][0..main.len], main);
        const total = d.reservoir_len + main.len;
        var r: Reader = .{ .data = buf[0..total] };

        // データが足りないグラニュールは飛ばす(無音にする)
        var bits = d.reservoir_len * 8;
        var first_gr: usize = 0;
        while (first_gr < 2 and bits / 8 < si.main_data_begin) : (first_gr += 1) {
            for (0..nch) |ch| bits += si.granules[first_gr][ch].part2_3_length;
        }
        r.pos = bits -| @as(usize, si.main_data_begin) * 8;

        const mode_ext = h.modeExtension();
        for (0..2) |gr| {
            var xr: [2][576]f64 = @splat(@splat(0));
            if (gr >= first_gr) {
                for (0..nch) |ch| {
                    const g = &si.granules[gr][ch];
                    const start = r.pos;
                    var sf: layer3.Scalefactors = .{};
                    layer3.readScalefactors(&r, g, si.scfsi[ch], gr, &d.scalefactors[ch], &sf);
                    if (gr == 0) d.scalefactors[ch] = sf;
                    var is: [576]i32 = undefined;
                    layer3.decodeHuffman(&r, g, sr, start + g.part2_3_length, &is);
                    layer3.requantize(g, &sf, sr, mode_ext == 2, &is, &xr[ch]);
                    if (ch == 1) {
                        // ステレオ処理は両チャンネルがそろってから
                        layer3.stereo(mode_ext, g, &sf, sr, &xr[0], &xr[1]);
                    }
                }
            }
            for (0..nch) |ch| {
                const g = &si.granules[gr][ch];
                layer3.reorder(g, sr, &xr[ch]);
                layer3.antialias(g, &xr[ch]);
                const block_type: u2 = if (g.window_switching) g.block_type else 0;
                d.synthesize(ch, gr, &xr[ch], block_type, g.window_switching and g.mixed, out);
            }
        }

        // 読み終えた位置より後のバイトを、次のフレームのリザーバにする
        const keep_from = (r.pos + 7) / 8;
        if (keep_from <= total) {
            const n = @min(total - keep_from, max_reservoir);
            std.mem.copyForwards(u8, d.reservoir[0..n], buf[total - n .. total]);
            d.reservoir_len = n;
        } else {
            // 読みすぎたときは、フレームの末尾をそのまま残す
            d.keepTail(fr);
        }
        return nch;
    }

    /// 1 グラニュール・1 チャンネルの IMDCT と合成フィルタ
    fn synthesize(d: *Decoder, ch: usize, gr: usize, xr: *const [576]f64, block_type: u2, mixed: bool, out: *[2][1152]f32) void {
        var sub: [18][32]f64 = undefined;
        synth.imdct(xr, &d.overlap[ch], block_type, mixed, &sub);
        for (0..18) |t| {
            d.synth[ch].run(&sub[t], out[ch][gr * 576 + t * 32 ..][0..32]);
        }
    }

    /// フレームの末尾(最大 512 バイト。ヘッダは含めない)を次のフレームのリザーバにする(ffmpeg と同じ)
    fn keepTail(d: *Decoder, fr: []const u8) void {
        const n = @min(max_reservoir, fr.len - 4);
        @memcpy(d.reservoir[0..n], fr[fr.len - n ..]);
        d.reservoir_len = n;
    }
};

test "decodeFrame: 扱えない入力は InvalidFrame" {
    var d: Decoder = .{};
    var out: [2][1152]f32 = undefined;
    // MPEG-2 のヘッダ、短すぎる入力
    try std.testing.expectError(error.InvalidFrame, d.decodeFrame("\xFF\xF3\x90\x64" ++ @as([300]u8, @splat(0)), &out));
    try std.testing.expectError(error.InvalidFrame, d.decodeFrame("\xFF\xFB\xB0\x64\x00", &out));
    try std.testing.expectError(error.InvalidFrame, d.decodeFrame("", &out));
    // サイド情報が壊れている(big_values > 288): 状態は進み、無音(前の重ね合わせは 0 なので 0)
    var f: [626]u8 = @splat(0);
    f[0..4].* = .{ 0xFF, 0xFB, 0xB0, 0x64 };
    // main_data_begin(9)、private(3)、scfsi(8) の後に part2_3_length(12)、big_values(9) = 511
    var w: std.Io.Writer = .fixed(f[4..12]);
    const bits: u64 = (@as(u64, 511) << (64 - 41));
    try w.writeInt(u64, bits, .big);
    try std.testing.expectError(error.InvalidFrame, d.decodeFrame(&f, &out));
    for (out[0]) |v| try std.testing.expectEqual(0, v);
    try std.testing.expectEqual(512, d.reservoir_len);
}
