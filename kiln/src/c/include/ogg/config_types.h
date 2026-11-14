// SPDX-License-Identifier: MIT
// libogg がビルドのときに作る config_types.h の代わり(configure や CMake を使わないため)。
// libogg の os_types.h が、決まった環境(Windows、macOS など)以外でここから整数の型を取る
#ifndef __CONFIG_TYPES_H__
#define __CONFIG_TYPES_H__

#include <stdint.h>

typedef int16_t ogg_int16_t;
typedef uint16_t ogg_uint16_t;
typedef int32_t ogg_int32_t;
typedef uint32_t ogg_uint32_t;
typedef int64_t ogg_int64_t;
typedef uint64_t ogg_uint64_t;

#endif
