#!/usr/bin/env python3
"""テスト用の MP3 を作り直すスクリプト。

正弦波と疑似乱数ノイズを混ぜた 2 秒の音声を Python で合成し、lame でエンコードする。
lame のバージョンが変わると出力のバイト列も変わるため、作り直したら testdata/README.md の
lame のバージョンも更新すること。

使い方: python3 testdata/generate.py(lame が PATH にあること)
"""
import math
import os
import struct
import subprocess
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


def main():
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
    main()
