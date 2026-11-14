// SPDX-License-Identifier: MIT
// libvorbis(vendor/libvorbis)のエンコーダーを、Zig(src/ogg/encode.zig)から呼ぶための薄い包み。
// libvorbis の構造体を Zig に見せず、ポインタと数値だけでやり取りする。
// PCM を受け取って Vorbis のパケットを返すところまでで、Ogg のページは Zig の側で作る(libogg のページの
// 組み立ては使わない)。
#include <stdlib.h>
#include <vorbis/vorbisenc.h>

typedef struct kiln_vorbis {
  vorbis_info info;
  vorbis_comment comment;
  vorbis_dsp_state dsp;
  vorbis_block block;
  ogg_packet headers[3];
  // 今のブロックに、まだ取り出していないパケットがあるかもしれない
  int in_block;
} kiln_vorbis;

// kiln_vorbis_open の戻り値
enum { KILN_VORBIS_OK = 0, KILN_VORBIS_UNSUPPORTED = 1, KILN_VORBIS_FAILED = 2 };

// エンコーダーを作る。quality は libvorbis の値(-0.1〜1.0。oggenc の -q の 10 分の 1)。
// libvorbis が対応しないチャンネル数・サンプルレート・品質の組み合わせなら KILN_VORBIS_UNSUPPORTED
int kiln_vorbis_open(kiln_vorbis **out, int channels, long rate, float quality) {
  kiln_vorbis *v = calloc(1, sizeof(*v));
  vorbis_info_init(&v->info);
  if (vorbis_encode_init_vbr(&v->info, channels, rate, quality) != 0) {
    vorbis_info_clear(&v->info);
    free(v);
    return KILN_VORBIS_UNSUPPORTED;
  }
  vorbis_comment_init(&v->comment);
  if (vorbis_analysis_init(&v->dsp, &v->info) != 0) {
    vorbis_comment_clear(&v->comment);
    vorbis_info_clear(&v->info);
    free(v);
    return KILN_VORBIS_FAILED;
  }
  // ここから先は kiln_vorbis_close で片づけられる
  *out = v;
  if (vorbis_block_init(&v->dsp, &v->block) != 0) return KILN_VORBIS_FAILED;
  if (vorbis_analysis_headerout(&v->dsp, &v->comment, &v->headers[0], &v->headers[1], &v->headers[2]) != 0)
    return KILN_VORBIS_FAILED;
  return KILN_VORBIS_OK;
}

// ヘッダのパケット(0: 識別、1: コメント、2: 設定)。kiln_vorbis_close まで有効
const unsigned char *kiln_vorbis_header(const kiln_vorbis *v, int index, size_t *len) {
  *len = (size_t)v->headers[index].bytes;
  return v->headers[index].packet;
}

// frames サンプル分の、チャンネルごとの書き込み先を返す。書いたら kiln_vorbis_wrote を呼ぶ
float **kiln_vorbis_buffer(kiln_vorbis *v, int frames) {
  return vorbis_analysis_buffer(&v->dsp, frames);
}

// kiln_vorbis_buffer に frames サンプルを書いたことを知らせる。0 は入力の終わり。成功は 0
int kiln_vorbis_wrote(kiln_vorbis *v, int frames) {
  return vorbis_analysis_wrote(&v->dsp, frames);
}

// できあがったパケットを 1 つ取り出す。1: 取り出した(data は次に呼ぶまで有効)、0: 今はない(入力が足りない)、
// 負: 失敗。granule は、このパケットまでを復号したときの位置。last は、ストリームの最後のパケットか
int kiln_vorbis_packet(kiln_vorbis *v, const unsigned char **data, size_t *len, long long *granule, int *last) {
  for (;;) {
    if (v->in_block) {
      ogg_packet packet;
      if (vorbis_bitrate_flushpacket(&v->dsp, &packet) == 1) {
        *data = packet.packet;
        *len = (size_t)packet.bytes;
        *granule = packet.granulepos;
        *last = packet.e_o_s != 0;
        return 1;
      }
      v->in_block = 0;
    }
    int r = vorbis_analysis_blockout(&v->dsp, &v->block);
    if (r != 1) return r;
    if (vorbis_analysis(&v->block, NULL) != 0) return -1;
    if (vorbis_bitrate_addblock(&v->block) != 0) return -1;
    v->in_block = 1;
  }
}

void kiln_vorbis_close(kiln_vorbis *v) {
  vorbis_block_clear(&v->block);
  vorbis_dsp_clear(&v->dsp);
  vorbis_comment_clear(&v->comment);
  vorbis_info_clear(&v->info);
  free(v);
}
