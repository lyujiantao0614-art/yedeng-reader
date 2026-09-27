import { fileIo as fs } from '@kit.CoreFileKit';

// Keep platform-declared file exceptions behind one explicit boundary while
// preserving the original error for the importing service to classify.
export interface FileIoOptions {
  offset?: number;
  length?: number;
  encoding?: string;
}

function platformError(error: Object, operation: string): Error {
  return error instanceof Error ? error : new Error(`${operation} failed`);
}

export async function openFile(path: string, mode: number): Promise<fs.File> {
  try { return await fs.open(path, mode); }
  catch (error) { throw platformError(error, 'open'); }
}

export async function statFile(file: string | number): Promise<fs.Stat> {
  try { return await fs.stat(file); }
  catch (error) { throw platformError(error, 'stat'); }
}

export async function readFile(fd: number, buffer: ArrayBuffer, options?: FileIoOptions): Promise<number> {
  try { return await fs.read(fd, buffer, options); }
  catch (error) { throw platformError(error, 'read'); }
}

export async function writeFile(fd: number, buffer: ArrayBuffer | string,
  options?: FileIoOptions): Promise<number> {
  try { return await fs.write(fd, buffer, options); }
  catch (error) { throw platformError(error, 'write'); }
}

export async function truncateFile(file: string | number, length: number): Promise<void> {
  try { await fs.truncate(file, length); }
  catch (error) { throw platformError(error, 'truncate'); }
}

export async function readTextFile(path: string): Promise<string> {
  try { return await fs.readText(path); }
  catch (error) { throw platformError(error, 'readText'); }
}

export function closeFile(file: number | fs.File): void {
  try { fs.closeSync(file); }
  catch (error) { throw platformError(error, 'close'); }
}
