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

fn fail(err: anyerror) bool {
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
/// 成功すると出力を kiln_output_* に、実際に切り出した区間を kiln_value の 0: start、1: end に置く
export fn kiln_mp3_trim(ptr: [*]const u8, len: usize, start: u64, end: u64, has_end: bool) bool {
    kiln_output_free();
    const t = kiln.mp3.trimAlloc(gpa, ptr[0..len], .{
        .start = start,
        .end = if (has_end) end else null,
    }) catch |err| return fail(err);
    output = t.data;
    values = .{ t.start, t.end, 0, 0, 0 };
    return true;
}
