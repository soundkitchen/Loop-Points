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
