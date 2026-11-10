// SPDX-License-Identifier: MIT
//! CLI の時刻指定(`--start` / `--end` / `--duration`)の解析。
//!
//! - `1.5`: 秒
//! - `1:02.5` / `1:02:03.5`: 分:秒 / 時:分:秒(分と秒は 60 未満)
//! - `66150s`: サンプル数
//!
//! 秒は浮動小数点を使わずに解析し、サンプル位置へは切り捨てで変換する。
const std = @import("std");

/// 小数部の桁数の上限(これより細かい桁は切り捨てる)
const max_frac_digits = 9;

pub const Time = union(enum) {
    samples: u64,
    /// 秒を whole + frac / 10^max_frac_digits で表す
    seconds: struct { whole: u64, frac: u64 },

    /// サンプル位置に変換する(切り捨て)
    pub fn toSamples(t: Time, sample_rate: u32) error{Overflow}!u64 {
        return switch (t) {
            .samples => |n| n,
            .seconds => |s| try std.math.add(
                u64,
                try std.math.mul(u64, s.whole, sample_rate),
                s.frac * sample_rate / std.math.pow(u64, 10, max_frac_digits),
            ),
        };
    }
};

pub const ParseError = error{InvalidTime};

pub fn parse(text: []const u8) ParseError!Time {
    if (text.len == 0) return error.InvalidTime;
    if (text[text.len - 1] == 's') {
        return .{ .samples = parseDigits(text[0 .. text.len - 1]) orelse return error.InvalidTime };
    }

    var parts = std.mem.splitScalar(u8, text, ':');
    var whole: u64 = 0;
    var frac: u64 = 0;
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (count == 3) return error.InvalidTime;
        const last = parts.peek() == null;
        var int_part = part;
        if (last) {
            if (std.mem.indexOfScalar(u8, part, '.')) |dot| {
                int_part = part[0..dot];
                frac = parseFrac(part[dot + 1 ..]) orelse return error.InvalidTime;
            }
        }
        const v = parseDigits(int_part) orelse return error.InvalidTime;
        // 先頭以外(分・秒)は 60 未満
        if (count > 0 and v >= 60) return error.InvalidTime;
        whole = std.math.add(u64, std.math.mul(u64, whole, 60) catch return error.InvalidTime, v) catch
            return error.InvalidTime;
    }
    return .{ .seconds = .{ .whole = whole, .frac = frac } };
}

/// 10 進数字だけからなる文字列を整数にする(空や桁あふれは null)
fn parseDigits(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var v: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, c - '0') catch return null;
    }
    return v;
}

/// 小数部の数字列を 10^max_frac_digits 倍した整数にする(余分な桁は切り捨て)
fn parseFrac(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var v: u64 = 0;
    for (0..max_frac_digits) |i| {
        const c: u8 = if (i < text.len) text[i] else '0';
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    for (text[@min(text.len, max_frac_digits)..]) |c| if (c < '0' or c > '9') return null;
    return v;
}

test parse {
    const t = std.testing;
    try t.expectEqual(66150, try (try parse("1.5")).toSamples(44100));
    try t.expectEqual(44100 * 62 + 22050, try (try parse("1:02.5")).toSamples(44100));
    try t.expectEqual(44100 * 3723, try (try parse("1:02:03")).toSamples(44100));
    try t.expectEqual(66150, try (try parse("66150s")).toSamples(44100));
    try t.expectEqual(0, try (try parse("0")).toSamples(44100));
    // 0.1 秒 = 4410 サンプル(浮動小数点の誤差で 4409 にならない)
    try t.expectEqual(4410, try (try parse("0.1")).toSamples(44100));
    // 1/44100 秒より細かい端数は切り捨て
    try t.expectEqual(0, try (try parse("0.0000226")).toSamples(44100));
    try t.expectEqual(1, try (try parse("0.0000227")).toSamples(44100));
    try t.expectEqual(44100, try (try parse("1.0000000009999")).toSamples(44100));

    for ([_][]const u8{ "", "s", "1.5s", "-1", "1:60", "1:2:3:4", "1.", ".5", "1.5.2", "a", "1:02.5x", "99999999999999999999" }) |bad| {
        try t.expectError(error.InvalidTime, parse(bad));
    }
    try t.expectError(error.Overflow, (try parse("18446744073709551615")).toSamples(44100));
}
