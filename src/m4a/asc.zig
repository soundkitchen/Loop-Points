// SPDX-License-Identifier: MIT
//! MPEG-4 Audio の AudioSpecificConfig(ISO/IEC 14496-3 §1.6.2.1)の読み取り。
//! AAC の種類(オブジェクトタイプ)、サンプルレート、チャンネル数と、SBR / PS の印を読む。
//! 音声データは読まない(HE-AAC の暗黙の印は分からない)。
const std = @import("std");

pub const Error = error{ InvalidM4a, UnsupportedFormat };

pub const rates = [_]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };

pub const Config = struct {
    /// 中心の符号化方式のオブジェクトタイプ(1: Main、2: LC、3: SSR、4: LTP など。SBR / PS の 5 / 29 は含めない)
    object_type: u8,
    /// 中心の符号化方式のサンプルレート
    core_rate: u32,
    /// channelConfiguration から分かるチャンネル数(PS の前)
    channels: u8,
    /// SBR があるか。設定に書かれていなければ null(暗黙の印は音声データの中にしかない)
    sbr: ?bool,
    /// SBR があるときの出力のサンプルレート
    sbr_rate: ?u32,
    /// PS があるか(モノラルを 2 チャンネルにする)。書かれていなければ null
    ps: ?bool,
};

const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    fn read(b: *Bits, n: u6) Error!u32 {
        var v: u32 = 0;
        for (0..n) |_| {
            if (b.pos >= b.data.len * 8) return error.InvalidM4a;
            const bit = (b.data[b.pos / 8] >> @intCast(7 - b.pos % 8)) & 1;
            v = (v << 1) | bit;
            b.pos += 1;
        }
        return v;
    }

    fn left(b: Bits) usize {
        return b.data.len * 8 - b.pos;
    }

    fn objectType(b: *Bits) Error!u8 {
        const t = try b.read(5);
        return @intCast(if (t == 31) 32 + try b.read(6) else t);
    }

    fn sampleRate(b: *Bits) Error!u32 {
        const i = try b.read(4);
        if (i == 15) return b.read(24);
        if (i >= rates.len) return error.InvalidM4a;
        return rates[i];
    }
};

pub fn parse(data: []const u8) Error!Config {
    var b: Bits = .{ .data = data };
    var t = try b.objectType();
    const rate = try b.sampleRate();
    const cc = try b.read(4);
    var c: Config = .{ .object_type = t, .core_rate = rate, .channels = 0, .sbr = null, .sbr_rate = null, .ps = null };
    // 明示的な(階層的な)印: 先頭が SBR(5)か PS(29)で、その後に中心の方式が続く
    if (t == 5 or t == 29) {
        c.sbr = true;
        c.ps = t == 29;
        c.sbr_rate = try b.sampleRate();
        t = try b.objectType();
        if (t == 22) _ = try b.read(4);
        c.object_type = t;
    }
    switch (t) {
        1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23 => {},
        // AAC 以外(CELP、HVXC、ALS など)は扱わない
        else => return error.UnsupportedFormat,
    }
    // GASpecificConfig
    _ = try b.read(1); // frameLengthFlag(960 サンプルのフレーム)
    if (try b.read(1) == 1) _ = try b.read(14); // coreCoderDelay
    const ext = try b.read(1);
    if (cc == 0) {
        c.channels = try programConfigChannels(&b);
        // PCE の後のバイト境界は扱いが面倒なので、後ろの印(後方互換の SBR の印)は読まない
        return finish(c);
    }
    c.channels = switch (cc) {
        1...6 => @intCast(cc),
        7 => 8,
        11 => 7,
        12, 14 => 8,
        13 => 24,
        else => return error.UnsupportedFormat,
    };
    if (t == 6 or t == 20) _ = try b.read(3);
    if (ext == 1) {
        if (t == 22) _ = try b.read(16);
        if (t == 17 or t == 19 or t == 20 or t == 23) _ = try b.read(3);
        _ = try b.read(1);
    }
    // 誤り耐性のある方式(ER)は epConfig が続く。後方互換の印は見ない
    if (t >= 17) return finish(c);
    // 後方互換の印: 中心の設定の後ろに、同期ワード 0x2B7 と SBR の有無、0x548 と PS の有無が続く
    if (c.sbr == null and b.left() >= 16) {
        if (try b.read(11) == 0x2B7) {
            const et = try b.objectType();
            if (et == 5) {
                const present = try b.read(1) == 1;
                c.sbr = present;
                if (present) {
                    c.sbr_rate = try b.sampleRate();
                    if (b.left() >= 12 and try b.read(11) == 0x548) c.ps = try b.read(1) == 1;
                } else {
                    c.ps = false;
                }
            }
        }
    }
    return finish(c);
}

/// PS が書かれていなくても、SBR がないか中心がモノラルでなければ PS はない(PS は SBR の上でモノラルを広げるもの)
fn finish(c: Config) Config {
    var r = c;
    if (r.ps == null and (r.sbr == false or r.channels != 1)) r.ps = false;
    return r;
}

/// program_config_element からチャンネル数を数える
fn programConfigChannels(b: *Bits) Error!u8 {
    _ = try b.read(4); // element_instance_tag
    _ = try b.read(2); // object_type
    _ = try b.read(4); // sampling_frequency_index
    const front = try b.read(4);
    const side = try b.read(4);
    const back = try b.read(4);
    const lfe = try b.read(2);
    _ = try b.read(3); // assoc data
    _ = try b.read(4); // valid cc
    if (try b.read(1) == 1) _ = try b.read(4);
    if (try b.read(1) == 1) _ = try b.read(4);
    if (try b.read(1) == 1) _ = try b.read(3);
    var n: u32 = lfe;
    for (0..front + side + back) |_| {
        const cpe = try b.read(1);
        _ = try b.read(4);
        n += 1 + cpe;
    }
    for (0..lfe) |_| _ = try b.read(4);
    if (n == 0 or n > 255) return error.InvalidM4a;
    return @intCast(n);
}

test "AAC-LC(ffmpeg: 後方互換の印で SBR なし)" {
    const c = try parse("\x12\x10\x56\xe5\x00");
    try std.testing.expectEqual(2, c.object_type);
    try std.testing.expectEqual(44100, c.core_rate);
    try std.testing.expectEqual(2, c.channels);
    try std.testing.expectEqual(false, c.sbr.?);
    try std.testing.expectEqual(false, c.ps.?);
}

test "AAC-LC(印なし)" {
    const c = try parse("\x12\x10");
    try std.testing.expectEqual(null, c.sbr);
    try std.testing.expectEqual(false, c.ps.?);
}

test "HE-AAC(afconvert: 後方互換の印で SBR あり)" {
    const c = try parse("\x13\x90\x56\xe5\xa0");
    try std.testing.expectEqual(22050, c.core_rate);
    try std.testing.expectEqual(true, c.sbr.?);
    try std.testing.expectEqual(44100, c.sbr_rate.?);
    try std.testing.expectEqual(false, c.ps.?);
}

test "HE-AAC v2(afconvert: SBR と PS)" {
    const c = try parse("\x13\x88\x56\xe5\xa5\x48\x80");
    try std.testing.expectEqual(1, c.channels);
    try std.testing.expectEqual(true, c.sbr.?);
    try std.testing.expectEqual(true, c.ps.?);
}

test "明示的な印(オブジェクトタイプ 29 = PS)" {
    // AOT 29、22.05kHz、モノラル、SBR 44.1kHz、中心は AOT 2
    var buf: [4]u8 = undefined;
    var v: u32 = 0;
    // 11101 0111 0001 0100 00010 000 ...
    v = (29 << 27) | (7 << 23) | (1 << 19) | (4 << 15) | (2 << 10);
    std.mem.writeInt(u32, &buf, v, .big);
    const c = try parse(&buf);
    try std.testing.expectEqual(2, c.object_type);
    try std.testing.expectEqual(true, c.sbr.?);
    try std.testing.expectEqual(true, c.ps.?);
    try std.testing.expectEqual(44100, c.sbr_rate.?);
}

test "扱えない・壊れた設定" {
    // AOT 8(CELP)
    try std.testing.expectError(error.UnsupportedFormat, parse("\x41\x10"));
    try std.testing.expectError(error.InvalidM4a, parse("\x12"));
    // サンプルレートの番号 13 は予約
    try std.testing.expectError(error.InvalidM4a, parse("\x16\x90"));
}
