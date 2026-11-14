// SPDX-License-Identifier: MIT
// 最小の libc(stdlib.h の説明を参照)。libogg の os_types.h が、macOS 向けのビルド(コアのテスト)で
// ここから整数の型を取る
#ifndef KILN_C_SYS_TYPES_H
#define KILN_C_SYS_TYPES_H

#include <stdint.h>

typedef uint16_t u_int16_t;
typedef uint32_t u_int32_t;
typedef uint64_t u_int64_t;

#endif
