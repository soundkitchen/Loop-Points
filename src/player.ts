// ループ区間つきの再生。書き出した値を使う側と同じく AudioBufferSourceNode の loop / loopStart / loopEnd で鳴らす
export class LoopPlayer {
  readonly gain: GainNode;
  private src: AudioBufferSourceNode | null = null;
  private buffer: AudioBuffer | null = null;
  private pos = 0;        // 再生位置 (秒)
  private last = 0;       // 前回 pos を進めたときの ctx.currentTime
  private loopStart = 0;
  private loopEnd = 0;
  private once = false;   // playOnce で鳴らしている間。ループしない
  private onceEnd = 0;    // playOnce で止める位置 (秒)

  constructor(readonly ctx: AudioContext) {
    this.gain = ctx.createGain();
    this.gain.connect(ctx.destination);
  }

  get playing() { return this.src !== null; }

  // from がループの終わり以降なら開始点から鳴らす。仕様では offset > loopEnd で始めるとループに入らず、バッファの終わりで止まる
  play(buffer: AudioBuffer, from: number, loopStart: number, loopEnd: number) {
    this.stop();
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
