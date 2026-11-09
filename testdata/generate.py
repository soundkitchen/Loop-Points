#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""テスト用の MP3 と WAV を作り直すスクリプト。

MP3: 正弦波と疑似乱数ノイズを混ぜた 2 秒の音声を Python で合成し、lame でエンコードする。
lame のバージョンが変わると出力のバイト列も変わるため、作り直したら testdata/README.md の
lame のバージョンも更新すること。

WAV: 同じような合成音(0.25 秒)を、形式やチャンクの並びを変えて Python だけで書く。

使い方: python3 testdata/generate.py [mp3|wav](省くと両方。mp3 は lame が PATH にあること)
"""
import math
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def synth(rate, channels, seconds=2.0):
    """チャンネルごとに周波数の違う正弦波に、小さなノイズを混ぜた 16bit PCM を返す。"""
    n = int(rate * seconds)
    seed = 1
    out = bytearray()
    for i in range(n):
        t = i / rate
        for ch in range(channels):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            noise = (seed / 0x7FFFFFFF - 0.5) * 0.1
            freq = 440.0 * (1 + ch) * (1 + 0.5 * t)  # ゆっくり上がるスイープ
            v = 0.5 * math.sin(2 * math.pi * freq * t) + noise
            out += struct.pack('<h', int(max(-1.0, min(1.0, v)) * 32767))
    return bytes(out)


def wav(path, rate, channels):
    pcm = synth(rate, channels)
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVE')
        f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 1, channels, rate,
                                      rate * channels * 2, channels * 2, 16))
        f.write(b'data' + struct.pack('<I', len(pcm)) + pcm)


def syncsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


def c2pa_like_id3():
    """Lyria の出力と同じく、MIME が application/c2pa の GEOB を 1 つだけ持つ ID3v2.3 タグ。
    中身は検証できない仮のバイト列。"""
    body = b'\x00' + b'application/c2pa\x00' + b'c2pa\x00' + b'c2pa manifest store\x00'
    body += bytes(range(256)) * 4
    frame = b'GEOB' + struct.pack('>I', len(body)) + b'\x00\x00' + body
    return b'ID3\x03\x00\x00' + syncsafe(len(frame)) + frame


# (出力名, サンプルレート, チャンネル数, lame の引数, 先頭に付ける ID3v2)
CASES = [
    # Lyria と同じ構成: CBR 192kbps、joint stereo、Xing/LAME タグなし、C2PA の GEOB 付き
    ('lyria-like.mp3', 44100, 2, ['-b', '192', '-m', 'j', '-t'], c2pa_like_id3),
    # LAME タグ付きの CBR(Info フレームあり)
    ('cbr128-lame.mp3', 44100, 2, ['-b', '128', '-m', 'j'], None),
    # LAME タグ付きの VBR(Xing フレームあり)
    ('vbr-lame.mp3', 44100, 2, ['-V', '4', '-m', 'j'], None),
    # 低ビットレートのモノラル 48kHz、タグなし。Info フレームが元のビットレートに収まらず、
    # ビットリザーバが深い(先頭に多くのフレームが要る)場合の確認用
    ('mono48k-notag.mp3', 48000, 1, ['-b', '48', '-m', 'm', '--resample', '48', '-t'], None),
]


def synth_float(rate, channels, seconds):
    """synth と同じ考え方の合成音を、-1〜1 の浮動小数点のフレームの列で返す。"""
    seed = 1
    frames = []
    for i in range(int(rate * seconds)):
        t = i / rate
        frame = []
        for ch in range(channels):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            noise = (seed / 0x7FFFFFFF - 0.5) * 0.1
            frame.append(0.5 * math.sin(2 * math.pi * 330.0 * (1 + ch) * (1 + t) * t) + noise)
        frames.append(frame)
    return frames


def encode_sample(v, fmt):
    """-1〜1 の値を WAV のサンプル 1 つのバイト列にする。"""
    if fmt == 'u8':
        return struct.pack('<B', round(v * 127) + 128)
    if fmt == 's16':
        return struct.pack('<h', round(v * 32767))
    if fmt == 's24':
        return struct.pack('<i', round(v * 8388607))[:3]
    if fmt == 's32':
        return struct.pack('<i', round(v * 2147483647))
    if fmt == 'f32':
        return struct.pack('<f', v)
    if fmt == 'f64':
        return struct.pack('<d', v)
    raise ValueError(fmt)


def chunk(cid, body):
    """RIFF のチャンク。中身が奇数バイトなら、詰め物の 1 バイトを足す。"""
    return cid + struct.pack('<I', len(body)) + body + (b'\x00' if len(body) % 2 else b'')


def wav_case(rate, channels, fmt, seconds=0.25, extensible=False, fact=False, list_before=False, extra_after=False):
    bits = {'u8': 8, 's16': 16, 's24': 24, 's32': 32, 'f32': 32, 'f64': 64}[fmt]
    is_float = fmt in ('f32', 'f64')
    block = channels * bits // 8
    frames = synth_float(rate, channels, seconds)
    data = b''.join(encode_sample(v, fmt) for fr in frames for v in fr)
    base = struct.pack('<HHIIHH', 0xFFFE if extensible else (3 if is_float else 1),
                       channels, rate, rate * block, block, bits)
    if extensible:
        guid_tail = b'\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71'
        fmt_body = base + struct.pack('<HHI', 22, bits, (1 << channels) - 1) + struct.pack('<H', 3 if is_float else 1) + guid_tail
    elif is_float:
        fmt_body = base + struct.pack('<H', 0)  # cbSize
    else:
        fmt_body = base
    chunks = chunk(b'fmt ', fmt_body)
    if fact:
        chunks += chunk(b'fact', struct.pack('<I', len(frames)))
    if list_before:
        chunks += chunk(b'LIST', b'INFO' + chunk(b'ISFT', b'kiln testdata\x00'))
    chunks += chunk(b'data', data)
    if extra_after:
        chunks += chunk(b'id3 ', b'ID3\x03\x00\x00\x00\x00\x00\x00')
    return b'RIFF' + struct.pack('<I', 4 + len(chunks)) + b'WAVE' + chunks


# (出力名, wav_case の引数)
WAV_CASES = [
    # 16bit ステレオ。data の前に LIST チャンク
    ('s16-stereo.wav', dict(rate=44100, channels=2, fmt='s16', list_before=True)),
    # 8bit モノラル、奇数フレーム(data の後に詰め物の 1 バイト)。data の後にもチャンク
    ('u8-mono.wav', dict(rate=8000, channels=1, fmt='u8', seconds=0.250125, extra_after=True)),
    # 24bit ステレオ 48kHz
    ('s24-stereo.wav', dict(rate=48000, channels=2, fmt='s24')),
    # 32bit 浮動小数点ステレオ(fmt は 18 バイト、fact チャンク付き)
    ('f32-stereo.wav', dict(rate=44100, channels=2, fmt='f32', fact=True)),
    # 64bit 浮動小数点モノラル
    ('f64-mono.wav', dict(rate=22050, channels=1, fmt='f64', fact=True)),
    # WAVE_FORMAT_EXTENSIBLE、32bit 整数 3 チャンネル
    ('s32-3ch-ext.wav', dict(rate=48000, channels=3, fmt='s32', extensible=True)),
]


def main_wav():
    for name, args in WAV_CASES:
        data = wav_case(**args)
        with open(os.path.join(HERE, name), 'wb') as f:
            f.write(data)
        print(name, len(data))


def main_mp3():
    with tempfile.TemporaryDirectory() as tmp:
        for name, rate, channels, args, id3 in CASES:
            src = os.path.join(tmp, 'in.wav')
            enc = os.path.join(tmp, 'out.mp3')
            wav(src, rate, channels)
            subprocess.run(['lame', '--quiet', *args, src, enc], check=True)
            data = open(enc, 'rb').read()
            if id3:
                data = id3() + data
            with open(os.path.join(HERE, name), 'wb') as f:
                f.write(data)
            print(name, len(data))


if __name__ == '__main__':
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if which in ('all', 'mp3'):
        main_mp3()
    if which in ('all', 'wav'):
        main_wav()
