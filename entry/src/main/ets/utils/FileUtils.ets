import { fileIo as fs } from '@kit.CoreFileKit';

export async function ensureDirectory(path: string): Promise<void> {
  try {
    await fs.mkdir(path);
  } catch (_) {
    try {
      const info = await fs.stat(path);
      if (!info.isDirectory()) {
        throw new Error('Path exists but is not a directory');
      }
    } catch (_) {
      throw new Error('Directory could not be created');
    }
  }
}

export async function pathExists(path: string): Promise<boolean> {
  try {
    await fs.stat(path);
    return true;
  } catch (_) {
    return false;
  }
}

export async function removeTree(path: string): Promise<void> {
  if (!await pathExists(path)) {
    return;
  }
  const info = await fs.stat(path);
  if (!info.isDirectory()) {
    await fs.unlink(path);
    return;
  }
  const children = await fs.listFile(path);
  for (const child of children) {
    await removeTree(`${path}/${child}`);
  }
  await fs.rmdir(path);
}

export function parentPath(path: string): string {
  const normalized = path.replace(/\\/g, '/');
  const index = normalized.lastIndexOf('/');
  return index > 0 ? normalized.substring(0, index) : normalized;
}

export function joinRelative(base: string, relative: string): string {
  const parts: string[] = [];
  const source = `${base}/${relative}`.replace(/\\/g, '/').split('/');
  for (const part of source) {
    if (part.length === 0 || part === '.') {
      continue;
    }
    if (part === '..') {
      parts.pop();
    } else {
      parts.push(part);
    }
  }
  const prefix = base.startsWith('/') ? '/' : '';
  return `${prefix}${parts.join('/')}`;
}
