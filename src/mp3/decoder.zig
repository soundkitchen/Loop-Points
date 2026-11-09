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

    /// 1 フレーム(ヘッダから始まるフレーム全体)を復号し、PCM を `out[チャンネル]` に書く。
    /// 戻り値はチャンネル数。サイド情報が壊れているフレームは無音を書き、`InvalidFrame` を返す
    /// (デコーダの状態は保ち、次のフレームから続けられる)
    pub fn decodeFrame(d: *Decoder, bytes: []const u8, out: *[2][1152]f32) Error!u8 {
        const h = Header.parse(bytes).?;
        const nch = h.channels();
        const sr: usize = h.sampleRateIndex();
        const side_start: usize = 4 + @as(usize, if (h.hasCrc()) 2 else 0);
        var sr_reader: Reader = .{ .data = bytes[side_start..] };
        const si = layer3.readSideInfo(&sr_reader, nch) catch |err| {
            for (out[0..nch]) |*o| @memset(o, 0);
            return err;
        };
        const main = bytes[side_start + layer3.sideInfoLen(nch) ..];

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
                var sub: [18][32]f64 = undefined;
                const block_type: u2 = if (g.window_switching) g.block_type else 0;
                synth.imdct(&xr[ch], &d.overlap[ch], block_type, g.window_switching and g.mixed, &sub);
                for (0..18) |t| {
                    d.synth[ch].run(&sub[t], out[ch][gr * 576 + t * 32 ..][0..32]);
                }
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
            const n = @min(max_reservoir, bytes.len - 4);
            @memcpy(d.reservoir[0..n], bytes[bytes.len - n ..]);
            d.reservoir_len = n;
        }
        return nch;
    }
};
