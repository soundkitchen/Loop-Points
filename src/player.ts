// ループ区間つきの再生。書き出した値を使う側と同じく AudioBufferSourceNode の loop / loopStart / loopEnd で鳴らす。
// AudioContext は、鳴らすバッファと同じレートで作る。レートが違うと、AudioBufferSourceNode が鳴らしながら線形補間で
// 変換し、高域が落ちて折り返しの雑音が乗る (44.1kHz を 48kHz で鳴らすと、10kHz で -1.5dB、雑音が -22dB)。
// 同じレートならバッファのサンプルをそのまま鳴らし、出力の機器のレートへの変換はブラウザに任せる
export class LoopPlayer {
  // 出力の機器のレート (レートを指定しない AudioContext のレート)。元のレートが分からない音源は、このレートでデコードする。
  // ページを開いたときの値で、あとで出力の機器を切り替えても変えない (違っていても、そのレートの AudioContext で鳴らせる)
  readonly outputRate: number;
  private ctx: AudioContext;
  private gain: GainNode;
  private src: AudioBufferSourceNode | null = null;
  private buffer: AudioBuffer | null = null;
  private pos = 0;        // 再生位置 (秒)
  private last = 0;       // 前回 pos を進めたときの ctx.currentTime
  private loopStart = 0;
  private loopEnd = 0;
  private once = false;   // playOnce で鳴らしている間。ループしない
  private onceEnd = 0;    // playOnce で止める位置 (秒)

  constructor() {
    this.ctx = new AudioContext();
    this.outputRate = this.ctx.sampleRate;
    this.gain = this.ctx.createGain();
    this.gain.connect(this.ctx.destination);
  }

  get playing() { return this.src !== null; }

  setVolume(v: number) { this.gain.gain.value = v; }

  // rate の AudioContext に切り替える。レートの違う音源に切り替えたときだけ作り直す
  private use(rate: number) {
    if (this.ctx.sampleRate === rate) return;
    // 先に作る。作れずに投げたときに、閉じたコンテキストを残さない
    const ctx = new AudioContext({ sampleRate: rate });
    const gain = ctx.createGain();
    gain.gain.value = this.gain.gain.value;
    gain.connect(ctx.destination);
    void this.ctx.close();
    this.ctx = ctx;
    this.gain = gain;
  }

  // from がループの終わり以降なら開始点から鳴らす。仕様では offset > loopEnd で始めるとループに入らず、バッファの終わりで止まる
  play(buffer: AudioBuffer, from: number, loopStart: number, loopEnd: number) {
    this.stop();
    this.use(buffer.sampleRate);
    void this.ctx.resume();
    if (from >= loopEnd) from = loopStart;
    const src = this.ctx.createBufferSource();
    src.buffer = buffer;
    src.loop = true;
    src.loopStart = loopStart;
    src.loopEnd = loopEnd;
    src.connect(this.gain);
    src.onended = () => { if (this.src === src) this.src = null; };
    src.start(0, from);
    this.src = src;
    this.buffer = buffer;
    this.once = false;
    this.loopStart = loopStart;
    this.loopEnd = loopEnd;
    this.pos = from;
    this.last = this.ctx.currentTime;
  }

  // from から to まで 1 回だけ鳴らして止める
  playOnce(buffer: AudioBuffer, from: number, to: number) {
    this.stop();
    this.use(buffer.sampleRate);
    void this.ctx.resume();
    const src = this.ctx.createBufferSource();
    src.buffer = buffer;
    src.connect(this.gain);
    src.onended = () => { if (this.src === src) this.src = null; };
    src.start(0, from, to - from);
    this.src = src;
    this.buffer = buffer;
    this.once = true;
    this.onceEnd = to;
    this.pos = from;
    this.last = this.ctx.currentTime;
  }

  // 再生中でも止めずに区間だけ差し替える。ただし、ループに入ったあとの再生位置が新しい区間の外に出たら、
  // AudioBufferSourceNode の折り返し方と表示がずれないよう、新しい開始点から鳴らし直す
  setLoop(loopStart: number, loopEnd: number) {
    if (this.once) return;         // ループしていないので関係ない。次の play で新しい区間を受け取る
    const pos = this.position();   // 古い区間で今の位置まで進めておく
    const inLoop = pos !== null && pos >= this.loopStart;
    this.loopStart = loopStart;
    this.loopEnd = loopEnd;
    if (!this.src || pos === null) return;
    if (pos >= loopEnd || (inLoop && pos < loopStart)) {
      this.play(this.buffer!, loopStart, loopStart, loopEnd);
      return;
    }
    this.src.loopStart = loopStart;
    this.src.loopEnd = loopEnd;
  }

  stop() {
    this.src?.stop();
    this.src?.disconnect();
    this.src = null;
  }

  // 今の再生位置 (秒)。オーディオの時計で進め、ループの終わりを越えたら AudioBufferSourceNode と同じく開始点へ折り返す
  position(): number | null {
    if (!this.src) return null;
    const now = this.ctx.currentTime;
    this.pos += now - this.last;
    this.last = now;
    // 1 回だけのときは、止まるまでの数フレームで終わりを越えて表示しないよう、終わりで止める
    if (this.once) return Math.min(this.pos, this.onceEnd);
    if (this.pos >= this.loopEnd) {
      this.pos = this.loopStart + ((this.pos - this.loopStart) % (this.loopEnd - this.loopStart));
    }
    return this.pos;
  }
}
