// SPDX-License-Identifier: MIT
// 最小の libc(stdlib.h の説明を参照)。mem* はコンパイラも自分で呼ぶので、標準の名前のまま使う
// (wasm では Zig の compiler_rt が持つ)
#ifndef KILN_C_STRING_H
#define KILN_C_STRING_H

#include <stddef.h>

void *memcpy(void *dest, const void *src, size_t n);
void *memmove(void *dest, const void *src, size_t n);
void *memset(void *dest, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);

static inline size_t kiln_c_strlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}

static inline char *kiln_c_strcpy(char *dest, const char *src) {
  size_t i = 0;
  while ((dest[i] = src[i])) i++;
  return dest;
}

static inline char *kiln_c_strcat(char *dest, const char *src) {
  kiln_c_strcpy(dest + kiln_c_strlen(dest), src);
  return dest;
}

#define strlen kiln_c_strlen
#define strcpy kiln_c_strcpy
#define strcat kiln_c_strcat

#endif
