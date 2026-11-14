// SPDX-License-Identifier: MIT
// 最小の libc(stdlib.h の説明を参照)。CPU の命令になるものはコンパイラの組み込みを使い、
// ほかは src/c/libc.zig が Zig の標準ライブラリで用意する
#ifndef KILN_C_MATH_H
#define KILN_C_MATH_H

double kiln_c_acos(double x);
double kiln_c_atan(double x);
double kiln_c_cos(double x);
double kiln_c_exp(double x);
double kiln_c_ldexp(double x, int exp);
double kiln_c_log(double x);
double kiln_c_pow(double x, double y);
double kiln_c_rint(double x);
double kiln_c_sin(double x);

static inline double kiln_c_sqrt(double x) { return __builtin_sqrt(x); }
static inline double kiln_c_floor(double x) { return __builtin_floor(x); }
static inline double kiln_c_ceil(double x) { return __builtin_ceil(x); }
static inline double kiln_c_fabs(double x) { return __builtin_fabs(x); }

#define acos kiln_c_acos
#define atan kiln_c_atan
#define cos kiln_c_cos
#define exp kiln_c_exp
#define ldexp kiln_c_ldexp
#define log kiln_c_log
#define pow kiln_c_pow
#define rint kiln_c_rint
#define sin kiln_c_sin
#define sqrt kiln_c_sqrt
#define floor kiln_c_floor
#define ceil kiln_c_ceil
#define fabs kiln_c_fabs

#endif
