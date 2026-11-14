// SPDX-License-Identifier: MIT
// 取り込んだ C のライブラリ(vendor/)のための、最小の libc。kiln は libc をリンクしないので、
// ライブラリが使う関数だけを src/c/libc.zig(Zig の標準ライブラリ)で用意する。
// どの環境の libc とも名前がぶつからないよう、実体は kiln_c_ で始まる名前にして、マクロで置き換える
#ifndef KILN_C_STDLIB_H
#define KILN_C_STDLIB_H

#include <stddef.h>

void *kiln_c_malloc(size_t size);
void *kiln_c_calloc(size_t count, size_t size);
void *kiln_c_realloc(void *ptr, size_t size);
void kiln_c_free(void *ptr);
void kiln_c_qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *));
_Noreturn void kiln_c_exit(int code);

static inline int kiln_c_abs(int x) { return x < 0 ? -x : x; }
static inline long kiln_c_labs(long x) { return x < 0 ? -x : x; }

#define malloc kiln_c_malloc
#define calloc kiln_c_calloc
#define realloc kiln_c_realloc
#define free kiln_c_free
#define qsort kiln_c_qsort
#define exit kiln_c_exit
#define abs kiln_c_abs
#define labs kiln_c_labs

#endif
