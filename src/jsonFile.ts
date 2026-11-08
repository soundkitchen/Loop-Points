// File System Access API で JSON と音源を直接読み書きする。使えるのは Chromium 系のブラウザだけ
type PickerTypes = { description: string; accept: Record<string, string[]> }[];

declare global {
  interface Window {
    showOpenFilePicker?(options: { types: PickerTypes }): Promise<FileSystemFileHandle[]>;
    showSaveFilePicker?(options: { suggestedName: string; types: PickerTypes }): Promise<FileSystemFileHandle>;
  }
  interface FileSystemHandle {
    queryPermission(descriptor: { mode: 'readwrite' }): Promise<PermissionState>;
    requestPermission(descriptor: { mode: 'readwrite' }): Promise<PermissionState>;
  }
  interface DataTransferItem {
    getAsFileSystemHandle?(): Promise<FileSystemHandle | null>;
  }
}

const JSON_TYPES: PickerTypes = [{ description: 'JSON', accept: { 'application/json': ['.json'] } }];

export const fileAccessSupported = typeof window.showOpenFilePicker === 'function' && typeof window.showSaveFilePicker === 'function';

// ファイル選択のダイアログを閉じただけのとき
export const isAbort = (e: unknown) => e instanceof DOMException && e.name === 'AbortError';

export async function pickJsonToOpen(): Promise<FileSystemFileHandle> {
  const [handle] = await window.showOpenFilePicker!({ types: JSON_TYPES });
  return handle;
}

export function pickJsonToSave(suggestedName: string): Promise<FileSystemFileHandle> {
  return window.showSaveFilePicker!({ suggestedName, types: JSON_TYPES });
}

export function pickAudioToSave(suggestedName: string, format: { description: string; mime: string; ext: string }): Promise<FileSystemFileHandle> {
  return window.showSaveFilePicker!({ suggestedName, types: [{ description: format.description, accept: { [format.mime]: [format.ext] } }] });
}

// 開いたファイルは読み取りの許可しかないので、最初の保存で書き込みの許可を求める
export async function canWrite(handle: FileSystemFileHandle): Promise<boolean> {
  const mode = { mode: 'readwrite' } as const;
  return (await handle.queryPermission(mode)) === 'granted' || (await handle.requestPermission(mode)) === 'granted';
}

// 書き込んで、書き込み後の最終更新日時を返す。close するまで元のファイルは変わらない
export async function writeContent(handle: FileSystemFileHandle, content: string | Blob): Promise<number> {
  const writable = await handle.createWritable();
  try {
    await writable.write(content);
    await writable.close();
  } catch (e) {
    // 開いたままだと一時ファイルとロックが残る。abort の失敗より、元の失敗を伝える
    await writable.abort().catch(() => {});
    throw e;
  }
  return (await handle.getFile()).lastModified;
}
